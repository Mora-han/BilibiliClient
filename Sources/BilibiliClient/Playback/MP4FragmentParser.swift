import Foundation

/// 单个 fMP4 分片信息
struct MP4Fragment {
    let moofOffset: Int  // moof 盒子绝对偏移
    let size: Int        // moof + mdat 总字节数（分片区间）
    let duration: Double // 分片时长（秒）
}

/// 不依赖 sidx 的 fMP4 分片枚举：
/// 通过解析每个分片的 moof/tfhd/trun 得到分片边界与时长。
enum MP4FragmentParser {
    /// 从 init 段解析 timescale（moov/trak/mdia/mdhd）
    static func timescale(inInit data: Data) -> Int? {
        var reader = BoxWalker(data)
        while let box = reader.nextBox() {
            if box.type == "moov" {
                return timescale(inMoov: reader, box: box)
            }
            guard reader.skipToEnd(of: box) else { return nil }
        }
        return nil
    }

    private static func timescale(inMoov reader: BoxWalker, box: (size: Int, type: String)) -> Int? {
        var r = reader
        // 在 moov 内找 trak -> mdia -> mdhd
        while let child = r.nextBox() {
            if child.type == "trak" {
                var trakReader = r
                while let trakBox = trakReader.nextBox() {
                    if trakBox.type == "mdia" {
                        var mdiaReader = trakReader
                        while let mdiaBox = mdiaReader.nextBox() {
                            if mdiaBox.type == "mdhd" {
                                return timescale(inMdhd: mdiaReader)
                            }
                            guard mdiaReader.skipToEnd(of: mdiaBox) else { return nil }
                        }
                        return nil
                    }
                    guard trakReader.skipToEnd(of: trakBox) else { return nil }
                }
                return nil
            }
            guard r.skipToEnd(of: child) else { return nil }
        }
        return nil
    }

    /// mdhd: version/flags(4) + 创建/修改时间(4 或 8) + timescale(4)
    private static func timescale(inMdhd mdhdReader: BoxWalker) -> Int? {
        var r = mdhdReader
        guard let versionFlags = r.readUInt32() else { return nil }
        let version = Int(versionFlags >> 24)
        if version == 1 {
            guard let _ = r.readUInt64(), let _ = r.readUInt64() else { return nil }
        } else {
            guard let _ = r.readUInt32(), let _ = r.readUInt32() else { return nil }
        }
        guard let ts = r.readUInt32(), ts > 0 else { return nil }
        return Int(ts)
    }

    /// 在数据中找第一个 4 字节对齐的 "moof"
    static func firstMoofOffset(in data: Data, from start: Int = 0) -> Int? {
        let pattern = Data("moof".utf8)
        var searchFrom = start
        while let found = data.range(of: pattern, options: [], in: searchFrom..<data.count) {
            let offset = found.lowerBound
            if offset % 4 == 0 {
                return offset
            }
            searchFrom = found.lowerBound + 1
        }
        return nil
    }

    /// 从 buffer 的 start 位置开始，尽可能多地解析连续完整分片。
    ///
    /// 会跳过 moof 之前的前缀盒子（sidx/styp/ftyp 等）；
    /// 若最后一个盒子跨过 buffer 末尾（数据不完整），needsMore 为 true，
    /// 调用方应拉取更多数据追加到 buffer 后，再从 nextOffset 继续解析。
    static func parseFragments(buffer: Data,
                               start: Int,
                               timescale: Double,
                               baseOffset: Int) -> (fragments: [MP4Fragment], nextOffset: Int, needsMore: Bool) {
        guard start >= 0, start <= buffer.count else { return ([], start, false) }
        var reader = BoxWalker(buffer)
        guard reader.skip(start) else { return ([], start, false) }

        var fragments: [MP4Fragment] = []
        var lastConsumed = start
        var needsMore = false

        while true {
            // 1) 定位下一个 moof：先按盒子头逐个跳过（sidx/styp/ftyp 等），
            //    遇到不合规的数据再退化为字节扫描。
            guard let moofStart = nextMoof(reader: &reader) else {
                needsMore = reader.hasIncompleteBox
                if !needsMore {
                    lastConsumed = buffer.count
                }
                break
            }
            guard reader.skip(to: moofStart) else { break }

            // 2) 读取 moof 大小
            guard let moofBox = reader.nextBox(), moofBox.type == "moof" else {
                // 说明 moof 头跨过 buffer 末尾
                needsMore = true
                lastConsumed = moofStart
                break
            }
            let moofSize = moofBox.size
            if moofSize < 8 || moofSize == 0 {
                // 0 表示延伸到 EOF，无法在窗口中确定边界：标记需要更多数据
                needsMore = true
                lastConsumed = moofStart
                break
            }
            let moofEnd = moofStart + moofSize
            guard moofEnd <= buffer.count else {
                needsMore = true
                lastConsumed = moofStart
                break
            }

            // 3) moof 之后应为 mdat（允许中间夹少数盒子）
            guard let mdatStart = nextMdat(reader: &reader, moofEnd: moofEnd, bufferCount: buffer.count) else {
                needsMore = reader.hasIncompleteBox
                lastConsumed = moofStart
                break
            }
            guard reader.skip(to: mdatStart) else { break }
            guard let mdatBox = reader.nextBox(), mdatBox.type == "mdat" else {
                needsMore = true
                lastConsumed = moofStart
                break
            }
            let mdatSize = mdatBox.size
            if mdatSize < 8 || mdatSize == 0 {
                needsMore = true
                lastConsumed = moofStart
                break
            }
            let fragmentEnd = mdatStart + mdatSize
            // 枚举只需要 moof + mdat 头（知道边界与时长即可），
            // mdat 媒体数据不必在窗口内，留给播放时按 Range 拉取。

            // 4) 有效分片：计算时长并记录
            let duration = fragmentDuration(moofBuffer: buffer,
                                            moofRelStart: moofStart,
                                            timescale: timescale)
            fragments.append(MP4Fragment(moofOffset: baseOffset + moofStart,
                                         size: moofSize + mdatSize,
                                         duration: duration))
            lastConsumed = fragmentEnd
            guard reader.skip(to: fragmentEnd) else { break }
        }

        return (fragments, lastConsumed, needsMore)
    }

    /// 从当前 offset 开始找下一个 moof 的偏移：
    /// 优先按盒子头跳（兼容 sidx/styp/ftyp 前缀），数据不合规时字节扫描。
    private static func nextMoof(reader: inout BoxWalker) -> Int? {
        var cursor = reader

        // 先尝试按盒子头走最多 32 个盒子
        for _ in 0..<32 {
            if cursor.offset + 8 > cursor.dataCount {
                // 剩余不足一个盒子头：若已到末尾则是正常结束，否则数据不完整
                reader.hasIncompleteBox = cursor.offset < cursor.dataCount
                return nil
            }
            guard let box = cursor.nextBox() else {
                reader.hasIncompleteBox = true
                return nil
            }
            if box.type == "moof" {
                reader.hasIncompleteBox = false
                return cursor.offsetBeforeHeader
            }
            guard cursor.skipToEnd(of: box) else {
                reader.hasIncompleteBox = true
                return nil
            }
        }

        // 字节扫描兜底
        if let found = firstMoofOffset(in: cursor.data, from: cursor.offset) {
            reader.hasIncompleteBox = false
            return found
        }
        reader.hasIncompleteBox = false
        return nil
    }

    /// moof 之后找 mdat（允许中间夹少量盒子）。
    private static func nextMdat(reader: inout BoxWalker,
                                 moofEnd: Int,
                                 bufferCount: Int) -> Int? {
        var cursor = reader
        for _ in 0..<8 {
            guard let box = cursor.nextBox() else {
                reader.hasIncompleteBox = true
                return nil
            }
            if box.type == "mdat" {
                reader.hasIncompleteBox = false
                return cursor.offsetBeforeHeader
            }
            guard cursor.skipToEnd(of: box) else {
                reader.hasIncompleteBox = true
                return nil
            }
        }
        return nil
    }

    /// 解析 moof 内 traf/tfhd/trun 计算分片时长（秒）。
    private static func fragmentDuration(moofBuffer: Data, moofRelStart: Int, timescale: Double) -> Double {
        var reader = BoxWalker(moofBuffer)
        guard reader.skip(moofRelStart + 8) else { return 0 }
        guard let moofSize = reader.peekUInt32(at: moofRelStart), moofSize >= 8 else { return 0 }

        var totalDuration: UInt64 = 0

        while reader.offset < moofRelStart + Int(moofSize) {
            guard let box = reader.nextBox() else { break }
            if box.type == "traf" {
                var trafReader = BoxWalker(moofBuffer)
                // 跳到 traf 的 payload（子盒子起点），offsetBeforeHeader 是 traf 盒子头起点
                guard trafReader.skip(reader.offsetBeforeHeader + 8) else { break }
                var tfhdDefault: UInt32?
                while let trafBox = trafReader.nextBox() {
                    switch trafBox.type {
                    case "tfhd":
                        if let d = parseTFHD(reader: trafReader) {
                            tfhdDefault = d
                        }
                    case "trun":
                        totalDuration += parseTRUN(reader: trafReader,
                                                   defaultSampleDuration: tfhdDefault)
                    default:
                        break
                    }
                    guard trafReader.skipToEnd(of: trafBox) else { break }
                }
            }
            guard reader.skipToEnd(of: box) else { break }
        }
        guard timescale > 0 else { return 0 }
        return Double(totalDuration) / timescale
    }

    /// tfhd 返回 default_sample_duration（可能 nil）
    private static func parseTFHD(reader: BoxWalker) -> UInt32? {
        var r = reader
        guard let versionFlags = r.readUInt32() else { return nil }
        let flags = versionFlags & 0x00FFFFFF
        guard let _ = r.readUInt32() else { return nil }  // track_ID
        if flags & 0x1 != 0 { guard let _ = r.readUInt64() else { return nil } }  // base_data_offset
        if flags & 0x2 != 0 { guard let _ = r.readUInt32() else { return nil } }  // sample_description_index
        if flags & 0x8 != 0 {
            return r.readUInt32()  // default_sample_duration
        }
        return nil
    }

    /// trun 返回分片总时长（timescale 单位）
    private static func parseTRUN(reader: BoxWalker, defaultSampleDuration: UInt32?) -> UInt64 {
        var r = reader
        guard let versionFlags = r.readUInt32(),
              let sampleCount = r.readUInt32() else { return 0 }
        let flags = versionFlags & 0x00FFFFFF
        if flags & 0x1 != 0 { guard let _ = r.readUInt32() else { return 0 } }  // data_offset
        if flags & 0x4 != 0 { guard let _ = r.readUInt32() else { return 0 } }  // first_sample_flags

        var total: UInt64 = 0
        for _ in 0..<sampleCount {
            var duration: UInt32?
            if flags & 0x100 != 0 {
                duration = r.readUInt32()
            }
            if flags & 0x200 != 0 { guard let _ = r.readUInt32() else { return total } }
            if flags & 0x400 != 0 { guard let _ = r.readUInt32() else { return total } }
            if flags & 0x800 != 0 { guard let _ = r.readUInt32() else { return total } }
            total += UInt64(duration ?? defaultSampleDuration ?? 0)
        }
        return total
    }
}

/// 轻量盒子遍历器
struct BoxWalker {
    let data: Data
    private(set) var offset = 0
    private(set) var offsetBeforeHeader = 0
    /// 是否在盒子头处因数据不足而停止
    var hasIncompleteBox = false

    var dataCount: Int { data.count }

    init(_ data: Data) {
        self.data = data
    }

    mutating func nextBox() -> (size: Int, type: String)? {
        guard offset + 8 <= data.count else {
            hasIncompleteBox = true
            return nil
        }
        let size32 = u32(at: offset)
        let type = fourCC(at: offset + 4)
        offsetBeforeHeader = offset
        var size = Int(size32)
        var headerEnd = offset + 8
        if size == 1 {
            guard offset + 16 <= data.count else {
                hasIncompleteBox = true
                return nil
            }
            size = Int(u64(at: offset + 8))
            headerEnd = offset + 16
        } else if size == 0 {
            size = data.count - offset
        }
        guard size >= headerEnd - offset else {
            hasIncompleteBox = true
            return nil
        }
        offset = headerEnd
        return (size, type)
    }

    /// 跳过 size 字节（从当前 offset 起）
    mutating func skip(_ size: Int) -> Bool {
        guard size >= 0, offset + size <= data.count else { return false }
        offset += size
        return true
    }

    /// 跳到指定绝对偏移
    mutating func skip(to target: Int) -> Bool {
        guard target >= offset, target <= data.count else { return false }
        offset = target
        return true
    }

    /// 跳到盒子末尾（nextBox 之后调用，offset 已到 payload 起点）
    mutating func skipToEnd(of box: (size: Int, type: String)) -> Bool {
        let end = offsetBeforeHeader + box.size
        guard end >= offset, end <= data.count else { return false }
        offset = end
        return true
    }

    mutating func readUInt32() -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        let v = u32(at: offset)
        offset += 4
        return v
    }

    mutating func readUInt64() -> UInt64? {
        guard offset + 8 <= data.count else { return nil }
        let v = u64(at: offset)
        offset += 8
        return v
    }

    func peekUInt32(at pos: Int) -> UInt32? {
        guard pos >= 0, pos + 4 <= data.count else { return nil }
        return u32(at: pos)
    }

    private func u32(at pos: Int) -> UInt32 {
        data.subdata(in: pos..<pos + 4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    }

    private func u64(at pos: Int) -> UInt64 {
        data.subdata(in: pos..<pos + 8).withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
    }

    private func fourCC(at pos: Int) -> String {
        String(data: data.subdata(in: pos..<pos + 4), encoding: .ascii) ?? ""
    }
}
