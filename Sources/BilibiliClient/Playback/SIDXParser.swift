import Foundation

struct MediaSegment {
    let range: String
    let duration: Double
}

/// 解析 ISO-BMFF sidx 盒子，把 DASH 分片转换成 HLS 需要的
/// 字节区间（Range）与时长（EXTINF）列表。
/// 注意：部分流的 index_range 内 sidx 前还带有 styp/prft 等盒子，
/// 因此会先扫描定位 sidx 再解析。
enum SIDXParser {
    static func parse(_ data: Data, absoluteRangeStart: Int) -> [MediaSegment]? {
        var reader = Reader(data)
        var sidxOffsetInData = 0

        // 1) 扫描定位 sidx 盒子
        while true {
            guard let size32 = reader.peekUInt32(),
                  let type = reader.peekFourCC(from: reader.offset + 4) else { return nil }
            if type == "sidx" {
                sidxOffsetInData = reader.offset
                break
            }
            var skip: Int = Int(size32)
            if size32 == 1 {
                guard let large = reader.peekUInt64(from: reader.offset + 8) else { return nil }
                skip = Int(large)
            } else if size32 == 0 {
                // 盒子延伸到文件末尾，不可能再有 sidx
                return nil
            }
            guard skip >= 8, reader.skip(skip) else { return nil }
        }

        // 2) 消费 sidx 头（size + type）
        guard let boxSize32 = reader.readUInt32(),
              reader.readFourCC() != nil else { return nil }
        let boxSize: Int
        if boxSize32 == 1 {
            guard let large = reader.readUInt64() else { return nil }
            boxSize = Int(large)
        } else {
            boxSize = Int(boxSize32)
        }
        guard boxSize >= 12 else { return nil }

        // 3) version / flags
        guard let versionAndFlags = reader.readUInt32() else { return nil }
        let version = Int(versionAndFlags >> 24)

        var timescale: Double = 0
        var firstOffset = 0

        switch version {
        case 0:
            // reference_ID(4) + timescale(4) + earliest_presentation_time(4) + first_offset(4)
            guard let _ = reader.readUInt32(),
                  let ts = reader.readUInt32(),
                  let _ = reader.readUInt32(),
                  let fo = reader.readUInt32() else { return nil }
            timescale = Double(ts)
            firstOffset = Int(fo)
        case 1:
            // reference_ID(8) + timescale(4) + earliest_presentation_time(8) + first_offset(8)
            guard let _ = reader.readUInt64(),
                  let ts = reader.readUInt32(),
                  let _ = reader.readUInt64(),
                  let fo = reader.readUInt64() else { return nil }
            timescale = Double(ts)
            firstOffset = Int(fo)
        default:
            return nil
        }

        guard timescale > 0,
              let countRaw = reader.readUInt16() else { return nil }
        let referenceCount = Int(countRaw & 0x7FFF)

        var segments: [MediaSegment] = []
        // firstOffset 相对 sidx 盒子结束位置
        let sidxAbsoluteStart = absoluteRangeStart + sidxOffsetInData
        var offset = sidxAbsoluteStart + boxSize + firstOffset

        for _ in 0..<referenceCount {
            guard let ref = reader.readUInt32(),
                  let durationRaw = reader.readUInt32(),
                  reader.readUInt32() != nil else { return nil }

            let size = Int(ref & 0x7FFFFFFF)
            let duration = Double(durationRaw) / timescale
            segments.append(MediaSegment(range: "\(offset)-\(offset + size - 1)",
                                         duration: duration))
            offset += size
        }

        return segments.isEmpty ? nil : segments
    }

    private struct Reader {
        private let data: Data
        private(set) var offset = 0

        init(_ data: Data) {
            self.data = data
        }

        var remaining: Int { data.count - offset }

        func peekUInt16(from pos: Int) -> UInt16? {
            guard pos >= 0, pos + 2 <= data.count else { return nil }
            return data.subdata(in: pos..<pos + 2)
                .withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
        }

        func peekUInt32(from pos: Int = -1) -> UInt32? {
            let p = pos >= 0 ? pos : offset
            guard p >= 0, p + 4 <= data.count else { return nil }
            return data.subdata(in: p..<p + 4)
                .withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        }

        func peekUInt64(from pos: Int = -1) -> UInt64? {
            let p = pos >= 0 ? pos : offset
            guard p >= 0, p + 8 <= data.count else { return nil }
            return data.subdata(in: p..<p + 8)
                .withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
        }

        func peekFourCC(from pos: Int = -1) -> String? {
            let p = pos >= 0 ? pos : offset
            guard p >= 0, p + 4 <= data.count else { return nil }
            return String(data: data.subdata(in: p..<p + 4), encoding: .ascii)
        }

        mutating func readUInt16() -> UInt16? {
            guard let v = peekUInt16(from: offset) else { return nil }
            offset += 2
            return v
        }

        mutating func readUInt32() -> UInt32? {
            guard let v = peekUInt32(from: offset) else { return nil }
            offset += 4
            return v
        }

        mutating func readUInt64() -> UInt64? {
            guard let v = peekUInt64(from: offset) else { return nil }
            offset += 8
            return v
        }

        mutating func readFourCC() -> String? {
            guard let v = peekFourCC(from: offset) else { return nil }
            offset += 4
            return v
        }

        mutating func skip(_ count: Int) -> Bool {
            guard count >= 0, offset + count <= data.count else { return false }
            offset += count
            return true
        }
    }
}
