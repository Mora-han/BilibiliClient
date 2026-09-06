import Foundation
import zlib

/// 直播弹幕消息（聊天区的一行）。
struct LiveDanmakuMessage: Identifiable, Equatable {
    enum Kind: Equatable {
        case danmaku
        case gift
        case welcome
        case superChat
    }

    let id: Int
    let kind: Kind
    let user: String
    let text: String
}

/// 直播实时弹幕引擎：连接 B 站弹幕 WebSocket，
/// 订阅直播弹幕 / 礼物 / 进场 / 醒目留言，展示为聊天式实时消息列表。
@MainActor
final class LiveDanmakuEngine: ObservableObject {
    /// 实时消息（新消息追加在末尾，超出上限裁掉最旧的）
    @Published private(set) var messages: [LiveDanmakuMessage] = []
    /// 弹幕服务器连接状态（认证成功后为 true）
    @Published private(set) var connected = false
    /// 连接失败 / 被服务端断开的原因（nil = 正常）
    @Published private(set) var errorText: String?
    /// 正在建立连接（防止并发重复建连）
    private var connecting = false
    /// 连接代数：disconnect 后作废仍在途的 connect，防止旧连接回写
    private var generation = 0
    /// 心跳回复携带的实时在线人数（可能为 0/无）
    @Published private(set) var popularity: Int?

    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempts = 0

    private let roomId: Int
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var heartbeatTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var nextID = 1
    private var lastFlushSecond = Date().timeIntervalSince1970
    private var flushCount = 0
    private var pending: [LiveDanmakuMessage] = []
    private let maxMessages = 400
    /// 高热度直播间每秒最多渲染 80 条，超出丢弃，保证界面流畅
    private let maxPerSecond = 80

    init(roomId: Int) {
        self.roomId = roomId
        session = URLSession(configuration: .ephemeral)
    }

    var isConnected: Bool { connected }

    /// 获取弹幕服务器配置并连接。
    /// 幂等：已有连接或正在连接时直接返回，避免页面重复触发。
    func connect() async {
        if task != nil || connecting { return }
        connecting = true
        let gen = generation
        defer { connecting = false }
        errorText = nil
        do {
            let conf = try await LiveService().danmuConf(roomId: roomId)
            guard gen == generation else { return }
            guard let token = conf.token,
                  let host = conf.hostServerList?.first(where: { !($0.host ?? "").isEmpty }) ?? firstHost(from: conf),
                  let hostname = host.host else {
                errorText = "弹幕服务器配置不可用"
                return
            }
            try await openSocket(hostname: hostname,
                                 port: host.wssPort ?? 443,
                                 token: token)
        } catch {
            guard gen == generation else { return }
            errorText = error.localizedDescription
        }
    }

    private func firstHost(from conf: LiveDanmuConf) -> LiveDanmuConf.Host? {
        guard let host = conf.host, !host.isEmpty else { return nil }
        return LiveDanmuConf.Host(host: host, port: conf.port, wssPort: conf.port)
    }

    /// 断开连接并清理（页面退出时调用）。
    func disconnect() {
        generation += 1
        connecting = false
        reconnectAttempts = 0
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        task?.cancel()
        task = nil
        connected = false
    }

    /// 清空已收到的消息（进入直播间时重置旧房间的内容）。
    func reset() {
        messages = []
        pending = []
        popularity = nil
    }

    // MARK: - WebSocket

    private func openSocket(hostname: String, port: Int, token: String) async throws {
        guard let url = URL(string: "wss://\(hostname):\(port)/sub") else {
            throw APIError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.setValue(APIConstants.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://live.bilibili.com", forHTTPHeaderField: "Origin")
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()

        let auth = Self.packet(op: 7, protover: 1,
                               body: Data(Self.authBody(roomId: roomId, token: token).utf8))
        try await task.send(.data(auth))
        startReceiveLoop(task)
        startHeartbeat(task)
    }

    private func startReceiveLoop(_ task: URLSessionWebSocketTask) {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            while !Task.isCancelled, task === self?.task {
                do {
                    let message = try await task.receive()
                    guard !Task.isCancelled, task === self?.task else { break }
                    switch message {
                    case .data(let data):
                        self?.handleBinary(data)
                    case .string(let text):
                        if let data = text.data(using: .utf8) {
                            self?.handleBinary(data)
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    break
                }
            }
            if task === self?.task {
                self?.connected = false
                self?.task = nil
                self?.scheduleReconnect()
            }
        }
    }

    /// 连接意外断开后延迟重连（3 秒后最多再试 3 次，手动断开不触发）。
    private func scheduleReconnect() {
        guard reconnectTask == nil, reconnectAttempts < 3 else { return }
        reconnectAttempts += 1
        errorText = "弹幕连接已断开，正在重连…"
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            await self.connect()
        }
    }

    private func startHeartbeat(_ task: URLSessionWebSocketTask) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                guard !Task.isCancelled, let self, self.task === task else { break }
                try? await task.send(.data(Self.packet(op: 2, protover: 1, body: Data())))
            }
        }
    }

    // MARK: - 协议解析

    private func handleBinary(_ data: Data) {
        parsePackets(data)
        // 每批消息统一冲刷一次 UI，控制每秒渲染条数
        flushPending()
    }

    /// 解析数据包流（头部 4 字节总长 + 2 字节头长 16 + 2 字节协议版本
    /// + 4 字节 op + 4 字节序号；压缩包解压后递归解析内层包）。
    private func parsePackets(_ data: Data) {
        var offset = 0
        while offset + 16 <= data.count {
            let total = Self.readUInt32(data, at: offset)
            guard total >= 16, offset + total <= data.count else { break }
            // 头部：4B 总长 + 2B 头长(16) + 2B 协议版本(offset+6) + 4B op + 4B 序号
            let proto = Self.readUInt16(data, at: offset + 6)
            let op = Self.readUInt32(data, at: offset + 8)
            let body = data.subdata(in: (offset + 16)..<(offset + total))
            handlePacket(op: op, proto: proto, body: body)
            offset += total
        }
        // 兜底：个别批次解压后是多条 JSON 直接拼接（无包头的场景）
        if offset < data.count, data[offset] == 0x7B {
            handlePacket(op: 5, proto: 0, body: data.subdata(in: offset..<data.count))
        }
    }

    private func handlePacket(op: Int, proto: UInt16, body: Data) {
        switch op {
        case 7: // 认证请求（服务器收到后的回执在 op=8）
            break
        case 8: // 认证回复
            let code = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            if code?["code"] as? Int == 0 || code == nil {
                connected = true
                reconnectAttempts = 0
                errorText = nil
            } else {
                connected = false
                errorText = "弹幕连接认证失败"
            }
        case 3: // 心跳回复：body 为热度数值或 JSON
            parsePopularity(body)
        case 5: // 业务消息（弹幕等）
            switch proto {
            case 0, 1:
                parseMessages(body)
            case 2, 3:
                if let inflated = Self.inflate(body) {
                    parsePackets(inflated)
                }
            default:
                break
            }
        default:
            break
        }
    }

    private func parsePopularity(_ body: Data) {
        if let text = String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if let value = Int(text) {
                popularity = value
                return
            }
            if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let data = json["data"] as? [String: Any],
               let value = data["popularity"] as? NSNumber {
                popularity = value.intValue
            }
        }
    }

    private func parseMessages(_ body: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let cmd = json["cmd"] as? String else { return }
        if cmd.hasPrefix("DANMU_MSG") {
            guard let info = json["info"] as? [Any], info.count > 2,
                  let text = info[1] as? String else { return }
            let userInfo = info[2] as? [Any]
            let user = (userInfo?.count ?? 0) > 1 ? String(describing: userInfo?[1] ?? "") : ""
            append(.init(id: nextID, kind: .danmaku, user: user, text: text))
        } else if cmd == "SEND_GIFT" {
            guard let data = json["data"] as? [String: Any],
                  let user = data["uname"] as? String,
                  let gift = data["giftName"] as? String else { return }
            let num = (data["num"] as? NSNumber)?.intValue ?? 1
            append(.init(id: nextID, kind: .gift, user: user,
                         text: "投喂了 \(gift) ×\(num)"))
        } else if cmd == "INTERACT_WORD" {
            guard let data = json["data"] as? [String: Any],
                  let user = data["uname"] as? String else { return }
            append(.init(id: nextID, kind: .welcome, user: user,
                         text: "进入了直播间"))
        } else if cmd.hasPrefix("SUPER_CHAT_MESSAGE") {
            guard let data = json["data"] as? [String: Any],
                  let text = data["message"] as? String else { return }
            var user = ""
            if let userInfo = data["user_info"] as? [String: Any],
               let uname = userInfo["uname"] as? String {
                user = uname
            }
            append(.init(id: nextID, kind: .superChat, user: user, text: text))
        }
    }

    /// 加入缓冲并节流冲刷：单秒超过上限后丢弃后续消息，UI 始终流畅。
    private func append(_ message: LiveDanmakuMessage) {
        nextID += 1
        pending.append(message)
    }

    private func flushPending() {
        let now = Date().timeIntervalSince1970
        if now - lastFlushSecond >= 1 {
            lastFlushSecond = now
            flushCount = 0
        }
        guard !pending.isEmpty else { return }
        let room = maxPerSecond - flushCount
        guard room > 0 else {
            pending.removeAll(keepingCapacity: true)
            return
        }
        let accepted = Array(pending.prefix(room))
        pending.removeFirst(accepted.count)
        flushCount += accepted.count
        messages.append(contentsOf: accepted)
        if messages.count > maxMessages {
            messages.removeFirst(messages.count - maxMessages)
        }
    }

    // MARK: - 包构造

    private static func authBody(roomId: Int, token: String) -> String {
        let dict: [String: Any] = [
            "uid": 0,
            "roomid": roomId,
            "protover": 2,
            "platform": "web",
            "type": 2,
            "key": token,
        ]
        let data = try? JSONSerialization.data(withJSONObject: dict, options: [])
        return String(data: data ?? Data(), encoding: .utf8) ?? ""
    }

    /// 构造 B 站弹幕协议数据包（大端）。
    static func packet(op: UInt32, protover: UInt16, body: Data) -> Data {
        var data = Data()
        data.append(Self.uint32BE(UInt32(16 + body.count)))
        data.append(Self.uint16BE(16))
        data.append(Self.uint16BE(protover))
        data.append(Self.uint32BE(op))
        data.append(Self.uint32BE(1))
        data.append(body)
        return data
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> Int {
        guard offset + 4 <= data.count else { return 0 }
        return data.subdata(in: offset..<(offset + 4)).reduce(0) { ($0 << 8) | Int($1) }
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    private static func uint32BE(_ value: UInt32) -> Data {
        var big = value.bigEndian
        return withUnsafeBytes(of: &big) { Data($0) }
    }

    private static func uint16BE(_ value: UInt16) -> Data {
        var big = value.bigEndian
        return withUnsafeBytes(of: &big) { Data($0) }
    }

    /// zlib 解压（B 站 protover=2 使用 zlib 压缩）。
    /// 高热度房间的压缩批次较大，自动按块持续解压直到流结束。
    private static func inflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        var stream = z_stream()
        let initStatus = inflateInit2_(&stream,
                                       15 + 32,
                                       ZLIB_VERSION,
                                       Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else { return nil }
        defer { inflateEnd(&stream) }

        var output = Data()
        let chunkSize = 32768
        let outBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { outBuf.deallocate() }

        let result = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int32 in
            guard let base = src.baseAddress else { return Z_STREAM_ERROR }
            var srcPtr = base.assumingMemoryBound(to: UInt8.self)
            var remaining = data.count
            var status = Z_OK
            while remaining > 0 {
                stream.next_in = UnsafeMutablePointer<UInt8>(mutating: srcPtr)
                stream.avail_in = uInt(remaining)
                repeat {
                    stream.next_out = outBuf
                    stream.avail_out = uInt(chunkSize)
                    status = zlib.inflate(&stream, Z_NO_FLUSH)
                    if status == Z_STREAM_ERROR { return Z_STREAM_ERROR }
                    let produced = chunkSize - Int(stream.avail_out)
                    if produced > 0 { output.append(outBuf, count: produced) }
                } while stream.avail_out == 0 && status != Z_STREAM_END
                let consumed = remaining - Int(stream.avail_in)
                srcPtr += consumed
                remaining -= consumed
            }
            // 输入耗尽后再排空剩余输出
            while status == Z_OK {
                stream.next_out = outBuf
                stream.avail_out = uInt(chunkSize)
                status = zlib.inflate(&stream, Z_NO_FLUSH)
                if status == Z_STREAM_ERROR { return Z_STREAM_ERROR }
                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 { output.append(outBuf, count: produced) }
                if status == Z_STREAM_END { break }
                if stream.avail_out != 0 { break }
            }
            return status
        }
        return (result == Z_STREAM_END || result == Z_OK) && !output.isEmpty ? output : nil
    }
}

