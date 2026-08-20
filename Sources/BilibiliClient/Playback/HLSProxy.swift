import Foundation
import Network

/// 本地轻量 HTTP 代理：把 B 站 DASH 分片流包装成标准 HLS，
/// 并在转发 CDN 请求时自动带上 Referer / Cookie / Range。
final class HLSProxy {
    static let shared = HLSProxy()

    struct Media {
        let baseURL: URL
        let initRange: String
        let segments: [MediaSegment]
        let bandwidth: Int
        let codecs: String?
        let width: Int?
        let height: Int?
    }

    struct Session {
        let video: Media
        let audio: Media
    }

    private var listener: NWListener?
    private var session: Session?
    private let queue = DispatchQueue(label: "com.codex.bilibili.hls", qos: .userInitiated)

    @discardableResult
    func start(video: Media, audio: Media) async throws -> URL {
        stop()
        session = Session(video: video, audio: audio)

        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            connection.start(queue: self.queue)
            self.handle(connection)
        }
        listener.start(queue: queue)
        self.listener = listener

        // 等待端口就绪（NWListener 端口可能异步生效）
        var port: UInt16 = 0
        for _ in 0..<20 {
            if let raw = listener.port?.rawValue, raw > 0 {
                port = raw
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard port > 0 else {
            stop()
            throw APIError.invalidResponse
        }
        return URL(string: "http://127.0.0.1:\(port)/master.m3u8")!
    }

    func stop() {
        listener?.cancel()
        listener = nil
        session = nil
    }

    // MARK: - 请求处理

    private func handle(_ connection: NWConnection) {
        receiveRequest(connection: connection, buffer: Data())
    }

    private func receiveRequest(connection: NWConnection, buffer: Data) {
        var newBuffer = buffer
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if let data, !data.isEmpty {
                newBuffer.append(data)
            }
            if let headerRange = newBuffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = newBuffer.subdata(in: newBuffer.startIndex..<headerRange.lowerBound)
                if let header = String(data: headerData, encoding: .utf8) {
                    self.respond(to: header, connection: connection)
                } else {
                    connection.cancel()
                }
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receiveRequest(connection: connection, buffer: newBuffer)
            }
        }
    }

    private struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
    }

    private func parse(_ header: String) -> HTTPRequest? {
        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let target = String(parts[1])
        let path = target.components(separatedBy: "?").first ?? target
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2 {
                headers[String(kv[0]).lowercased().trimmingCharacters(in: .whitespaces)] =
                    String(kv[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        return HTTPRequest(method: String(parts[0]), path: path, headers: headers)
    }

    private func respond(to header: String, connection: NWConnection) {
        guard let request = parse(header), request.method == "GET", let session else {
            send(status: "404 Not Found", contentType: "text/plain", body: "", to: connection)
            return
        }

        switch request.path {
        case "/master.m3u8":
            send(status: "200 OK",
                 contentType: "application/vnd.apple.mpegurl",
                 body: masterPlaylist(session),
                 to: connection)
        case "/video.m3u8":
            send(status: "200 OK",
                 contentType: "application/vnd.apple.mpegurl",
                 body: mediaPlaylist(session.video, mapURI: "init-v", segmentPrefix: "seg-v"),
                 to: connection)
        case "/audio.m3u8":
            send(status: "200 OK",
                 contentType: "application/vnd.apple.mpegurl",
                 body: mediaPlaylist(session.audio, mapURI: "init-a", segmentPrefix: "seg-a"),
                 to: connection)
        default:
            if request.path == "/init-v"
                || request.path == "/init-a"
                || request.path.hasPrefix("/seg-v/")
                || request.path.hasPrefix("/seg-a/") {
                sendBinary(path: request.path, session: session, request: request, connection: connection)
            } else {
                send(status: "404 Not Found", contentType: "text/plain", body: "", to: connection)
            }
        }
    }

    // MARK: - 播放列表生成

    private func masterPlaylist(_ session: Session) -> String {
        let video = session.video
        let resolution = video.width.flatMap { w in
            video.height.map { h in "\(w)x\(h)" }
        } ?? ""
        let codecs = video.codecs ?? "avc1.42E01E,mp4a.40.2"

        var lines: [String] = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"Audio\",DEFAULT=YES,AUTOSELECT=YES,URI=\"audio.m3u8\"",
            "#EXT-X-STREAM-INF:BANDWIDTH=\(video.bandwidth),AUDIO=\"audio\",CODECS=\"\(codecs)\"",
        ]
        if !resolution.isEmpty {
            lines[3] += ",RESOLUTION=\(resolution)"
        }
        lines.append("video.m3u8")
        return lines.joined(separator: "\n")
    }

    private func mediaPlaylist(_ media: Media, mapURI: String, segmentPrefix: String) -> String {
        let target = Int(ceil((media.segments.map(\.duration).max() ?? 2)))
        var lines: [String] = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(target)",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-MAP:URI=\"\(mapURI)\"",
        ]
        for (index, segment) in media.segments.enumerated() {
            lines.append("#EXTINF:\(Self.timeString(segment.duration)),")
            lines.append("\(segmentPrefix)/\(index)")
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n")
    }

    /// HLS EXTINF 时长文本（最长 6 位小数）。
    private static func timeString(_ value: Double) -> String {
        let rounded = (value * 1_000_000).rounded() / 1_000_000
        return String(rounded)
    }

    // MARK: - 二进制转发

    private func sendBinary(path: String,
                            session: Session,
                            request: HTTPRequest,
                            connection: NWConnection) {
        Task {
            do {
                let data = try await fetchData(path: path, session: session)
                let body: Data
                let status: String
                let extraHeaders: [String: String]

                if let range = parseRange(request.headers["range"], length: data.count) {
                    let sub = data.subdata(in: range.offset..<(range.offset + range.length))
                    body = sub
                    status = "206 Partial Content"
                    extraHeaders = [
                        "Content-Range": "bytes \(range.offset)-\(range.offset + range.length - 1)/\(data.count)",
                    ]
                } else {
                    body = data
                    status = "200 OK"
                    extraHeaders = [:]
                }

                var header = "HTTP/1.1 \(status)\r\n"
                header += "Content-Type: video/mp4\r\n"
                header += "Content-Length: \(body.count)\r\n"
                header += "Connection: close\r\n"
                for (key, value) in extraHeaders {
                    header += "\(key): \(value)\r\n"
                }
                header += "\r\n"

                connection.send(content: Data(header.utf8) + body,
                                completion: .contentProcessed { _ in connection.cancel() })
            } catch {
                send(status: "500 Internal Server Error",
                     contentType: "text/plain",
                     body: "",
                     to: connection)
            }
        }
    }

    private func fetchData(path: String, session: Session) async throws -> Data {
        let api = APIClient.shared
        switch path {
        case "/init-v":
            return try await api.streamData(from: session.video.baseURL, range: session.video.initRange).0
        case "/init-a":
            return try await api.streamData(from: session.audio.baseURL, range: session.audio.initRange).0
        default:
            if path.hasPrefix("/seg-v/"), let index = Int(path.dropFirst("/seg-v/".count)) {
                guard session.video.segments.indices.contains(index) else {
                    throw APIError.invalidResponse
                }
                return try await api.streamData(from: session.video.baseURL,
                                                range: session.video.segments[index].range).0
            }
            if path.hasPrefix("/seg-a/"), let index = Int(path.dropFirst("/seg-a/".count)) {
                guard session.audio.segments.indices.contains(index) else {
                    throw APIError.invalidResponse
                }
                return try await api.streamData(from: session.audio.baseURL,
                                                range: session.audio.segments[index].range).0
            }
            throw APIError.invalidResponse
        }
    }

    private func parseRange(_ header: String?, length: Int) -> (offset: Int, length: Int)? {
        guard let header, header.hasPrefix("bytes=") else { return nil }
        let value = header.dropFirst("bytes=".count)
        let parts = value.split(separator: "-")
        guard let startText = parts.first, let start = Int(startText) else { return nil }
        if parts.count == 2, let end = Int(parts[1]) {
            let clampedEnd = min(end, length - 1)
            guard clampedEnd >= start else { return nil }
            return (start, clampedEnd - start + 1)
        }
        return (start, max(length - start, 0))
    }

    private func send(status: String,
                      contentType: String,
                      body: String,
                      to connection: NWConnection) {
        let payload = Data(body.utf8)
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(payload.count)\r\n"
        header += "Connection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + payload,
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}
