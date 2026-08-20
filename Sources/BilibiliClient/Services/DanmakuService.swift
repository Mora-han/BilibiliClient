import Foundation

/// 一条弹幕（B 站 XML 接口 <d p="time,mode,fontsize,color,...">text</d>）
struct DanmakuItem: Identifiable {
    let id: Int
    let time: Double      // 出现时间（秒）
    let mode: Int         // 1 滚动 / 4 底部 / 5 顶部
    let fontSize: Int     // B 站字号（12/18/25/36）
    let color: UInt32     // 0xRRGGBB
    let text: String
}

/// 拉取并解析 B 站弹幕 XML。
/// 经典接口 comment.bilibili.com/{cid}.xml，无需登录即可获取。
enum DanmakuService {
    static func fetch(cid: Int) async throws -> [DanmakuItem] {
        guard let url = URL(string: "https://comment.bilibili.com/\(cid).xml") else {
            throw APIError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.setValue(APIConstants.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(APIConstants.referer, forHTTPHeaderField: "Referer")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw APIError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        let parser = XMLParser(data: data)
        let delegate = DanmakuXMLParserDelegate()
        parser.delegate = delegate
        parser.parse()
        return delegate.items.sorted { $0.time < $1.time }
    }
}

/// XMLParser 委托：收集 <d p="...">文本</d>
private final class DanmakuXMLParserDelegate: NSObject, XMLParserDelegate {
    var items: [DanmakuItem] = []
    private var currentP: String?
    private var currentText = ""

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        if elementName == "d" {
            currentP = attributeDict["p"]
            currentText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentP != nil {
            currentText += string
        }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        guard elementName == "d", let p = currentP else {
            if elementName == "d" { currentP = nil }
            return
        }
        if let item = Self.parse(p, text: currentText) {
            items.append(item)
        }
        currentP = nil
        currentText = ""
    }

    /// p: time,mode,fontsize,color,timestamp,pool,userhash,dmid
    private static func parse(_ p: String, text: String) -> DanmakuItem? {
        let fields = p.split(separator: ",")
        guard fields.count >= 4,
              let time = Double(fields[0]),
              let mode = Int(fields[1]),
              let fontSize = Int(fields[2]),
              let color = UInt32(fields[3]),
              mode == 1 || mode == 4 || mode == 5 else {
            return nil
        }
        let dmid = fields.count >= 8 ? (Int(fields[7]) ?? 0) : 0
        let id = dmid != 0 ? dmid : (text + p).hashValue
        return DanmakuItem(id: id,
                           time: time,
                           mode: mode,
                           fontSize: fontSize,
                           color: color,
                           text: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
