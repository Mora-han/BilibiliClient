import Foundation

struct MediaSegment {
    let range: String
    let duration: Double
}

/// 解析 ISO-BMFF sidx 盒子，把 DASH 分片转换成 HLS 需要的
/// 字节区间（Range）与时长（EXTINF）列表。
enum SIDXParser {
    static func parse(_ data: Data, absoluteRangeStart: Int) -> [MediaSegment]? {
        var reader = Reader(data)

        guard let boxSize = reader.readUInt32(),
              let type = reader.readFourCC(), type == "sidx" else { return nil }
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
        var offset = absoluteRangeStart + Int(boxSize) + firstOffset

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
        private var offset = 0

        init(_ data: Data) {
            self.data = data
        }

        mutating func readUInt16() -> UInt16? {
            guard offset + 2 <= data.count else { return nil }
            let value = data.subdata(in: offset..<offset + 2)
                .withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
            offset += 2
            return value
        }

        mutating func readUInt32() -> UInt32? {
            guard offset + 4 <= data.count else { return nil }
            let value = data.subdata(in: offset..<offset + 4)
                .withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            offset += 4
            return value
        }

        mutating func readUInt64() -> UInt64? {
            guard offset + 8 <= data.count else { return nil }
            let value = data.subdata(in: offset..<offset + 8)
                .withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
            offset += 8
            return value
        }

        mutating func readFourCC() -> String? {
            guard offset + 4 <= data.count else { return nil }
            let bytes = data.subdata(in: offset..<offset + 4)
            offset += 4
            return String(data: bytes, encoding: .ascii)
        }
    }
}
