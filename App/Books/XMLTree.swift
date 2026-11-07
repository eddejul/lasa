import Foundation

/// Ett element i ett litet XML-träd, för EPUB:ens styrfiler (container.xml, OPF, NCX och nav).
/// Namnrymdsprefix tas bort från element och attribut, så "dc:title" blir "title" och "epub:type" blir "type".
/// Textbitar ligger som barn med namnet "#text", i ordning med de andra barnen.
final class XMLNode {

    let name: String
    let attributes: [String: String]
    private(set) var children: [XMLNode] = []
    fileprivate var value = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    subscript(attribute: String) -> String? {
        attributes[attribute]
    }

    fileprivate func append(_ child: XMLNode) {
        children.append(child)
    }

    /// All text i elementet och dess barn, med blanktecken ihopslagna till ett mellanslag.
    var text: String {
        var parts: [String] = []
        collectText(into: &parts)
        return parts.joined()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func collectText(into parts: inout [String]) {
        if name == "#text" {
            parts.append(value)
            return
        }
        for child in children {
            child.collectText(into: &parts)
        }
    }

    /// Alla element med ett visst namn under det här, i dokumentets ordning.
    func descendants(named wanted: String) -> [XMLNode] {
        var result: [XMLNode] = []
        func visit(_ node: XMLNode) {
            for child in node.children {
                if child.name == wanted {
                    result.append(child)
                }
                visit(child)
            }
        }
        visit(self)
        return result
    }
}

enum XMLTree {

    static func parse(contentsOf url: URL) -> XMLNode? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    /// Läser så mycket som går. Ett fel mitt i filen ger trädet fram till felet.
    static func parse(_ data: Data) -> XMLNode? {
        let builder = XMLTreeBuilder()
        let parser = XMLParser(data: replacingNamedEntities(in: data))
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        _ = parser.parse()
        return builder.root
    }

    static func localName(_ name: String) -> String {
        guard let colon = name.lastIndex(of: ":") else { return name }
        return String(name[name.index(after: colon)...])
    }

    private static let xmlEntities: Set<String> = ["amp", "lt", "gt", "quot", "apos"]

    private static let namedEntities: [String: Int] = [
        "nbsp": 160, "shy": 173, "copy": 169, "reg": 174, "trade": 8482, "deg": 176, "sect": 167, "para": 182,
        "middot": 183, "bull": 8226, "times": 215, "hellip": 8230, "mdash": 8212, "ndash": 8211,
        "lsquo": 8216, "rsquo": 8217, "ldquo": 8220, "rdquo": 8221, "laquo": 171, "raquo": 187,
        "thinsp": 8201, "ensp": 8194, "emsp": 8195, "zwnj": 8204, "zwj": 8205,
        "aring": 229, "Aring": 197, "auml": 228, "Auml": 196, "ouml": 246, "Ouml": 214,
        "aelig": 230, "AElig": 198, "oslash": 248, "Oslash": 216, "uuml": 252, "Uuml": 220,
        "eacute": 233, "Eacute": 201, "egrave": 232, "agrave": 224, "aacute": 225, "ccedil": 231,
    ]

    /// XHTML utan DTD känner bara till fem namngivna tecken. Andra (som &nbsp;) får XMLParser att ge upp,
    /// så de byts mot sina nummer innan filen läses. Okända namn tas bort.
    static func replacingNamedEntities(in data: Data) -> Data {
        guard data.range(of: Data("&".utf8)) != nil,
              let text = String(data: data, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: "&([A-Za-z][A-Za-z0-9]{1,31});") else {
            return data
        }
        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return data }

        let result = NSMutableString(string: text)
        for match in matches.reversed() {
            let name = source.substring(with: match.range(at: 1))
            if xmlEntities.contains(name) {
                continue
            }
            let replacement = namedEntities[name].map { "&#\($0);" } ?? ""
            result.replaceCharacters(in: match.range, with: replacement)
        }
        return Data((result as String).utf8)
    }
}

private final class XMLTreeBuilder: NSObject, XMLParserDelegate {

    var root: XMLNode?
    private var stack: [XMLNode] = []

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        var attributes: [String: String] = [:]
        for (key, value) in attributeDict {
            attributes[XMLTree.localName(key)] = value
        }
        let node = XMLNode(name: XMLTree.localName(elementName), attributes: attributes)
        if let parent = stack.last {
            parent.append(node)
        } else if root == nil {
            root = node
        }
        stack.append(node)
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        if !stack.isEmpty {
            stack.removeLast()
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        appendText(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let string = String(data: CDATABlock, encoding: .utf8) {
            appendText(string)
        }
    }

    private func appendText(_ string: String) {
        guard let parent = stack.last else { return }
        if let last = parent.children.last, last.name == "#text" {
            last.value += string
        } else {
            let text = XMLNode(name: "#text", attributes: [:])
            text.value = string
            parent.append(text)
        }
    }
}
