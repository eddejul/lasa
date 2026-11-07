import Foundation
import NaturalLanguage

/// Gör om textfiler (txt, md, rtf, html) till enkla HTML-kapitel som visas i samma läsare som EPUB.
/// Körs i bakgrunden varje gång boken öppnas, det går fort. Långa texter delas i kapitel vid rubriker,
/// och annars ungefär var 60 000:e tecken, så att varje kapitel blir lätt för webbvyn.
enum TextBookConverter {

    static let maxChapterCharacters = 60_000

    /// Ett stycke, en rubrik, en lista eller annat som ska stå i ett kapitel.
    private struct Block {
        /// Rubriknivå 1 till 6, eller nil för vanlig text.
        var headingLevel: Int?
        /// Rubrikens text utan formatering, till innehållsförteckningen.
        var title: String
        var html: String
        var length: Int
    }

    static func open(_ book: Book, directory: URL, identifier: String) throws -> ReflowableBook {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: directory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileExtension = book.url.pathExtension.lowercased()
        if fileExtension == "html" || fileExtension == "htm" {
            return try openHTML(book, directory: directory, identifier: identifier)
        }

        let text: String
        let blocks: [Block]
        switch fileExtension {
        case "md", "markdown":
            text = try readText(book.url)
            blocks = markdownBlocks(text)
        case "rtf":
            text = RTFText.plainText(from: try Data(contentsOf: book.url))
            blocks = plainBlocks(text)
        default:
            text = try readText(book.url)
            blocks = plainBlocks(text)
        }
        let language = languageCode(for: text)

        var chapters: [ReflowableBook.Chapter] = []
        var toc: [ReflowableBook.TOCEntry] = []
        var body = ""
        var length = 0
        var headingNumber = 0
        let splitLevel = blocks.contains { $0.headingLevel == 1 } ? 1 : 2

        func flush() throws {
            guard !body.isEmpty else { return }
            let url = directory.appendingPathComponent(String(format: "kapitel-%03d.html", chapters.count + 1))
            try page(title: book.title, language: language, body: body).write(to: url, atomically: true, encoding: .utf8)
            chapters.append(ReflowableBook.Chapter(url: url, weight: max(length, 1), title: nil))
            body = ""
            length = 0
        }

        for block in blocks {
            if let level = block.headingLevel {
                if level <= splitLevel {
                    try flush()
                }
                headingNumber += 1
                let id = "rubrik-\(headingNumber)"
                if level <= 2, !block.title.isEmpty {
                    toc.append(ReflowableBook.TOCEntry(title: block.title,
                                                       level: max(level - splitLevel, 0),
                                                       chapter: chapters.count,
                                                       fragment: body.isEmpty ? nil : id))
                }
                body += "<h\(level) id=\"\(id)\">\(block.html)</h\(level)>\n"
                length += block.length
            } else {
                if length > maxChapterCharacters {
                    try flush()
                }
                body += block.html + "\n"
                length += block.length
            }
        }
        try flush()
        guard !chapters.isEmpty else { throw BookError.empty }

        for entry in toc where entry.fragment == nil && chapters[entry.chapter].title == nil {
            chapters[entry.chapter].title = entry.title
        }
        return ReflowableBook(title: book.title,
                              identifier: identifier,
                              rootDirectory: directory,
                              chapters: chapters,
                              toc: toc,
                              isPlainText: true)
    }

    // MARK: Läsa filen

    /// UTF-8 först, sedan UTF-16 med BOM, sedan Windows-1252 och Latin-1 (vanligt i äldre svenska textfiler).
    static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        var text: String?
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf16)
        }
        if text == nil {
            text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .windowsCP1252)
                ?? String(data: data, encoding: .isoLatin1)
        }
        guard var result = text else { throw BookError.unreadableText }
        if result.hasPrefix("\u{FEFF}") {
            result.removeFirst()
        }
        return result
    }

    private static func languageCode(for text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(4000)))
        return recognizer.dominantLanguage?.rawValue ?? "sv"
    }

    private static func openHTML(_ book: Book, directory: URL, identifier: String) throws -> ReflowableBook {
        let target = directory.appendingPathComponent("kapitel-001.html")
        try FileManager.default.copyItem(at: book.url, to: target)
        EPUBBookReader.insertViewport(into: target)
        let size = (try? target.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 1
        return ReflowableBook(title: book.title,
                              identifier: identifier,
                              rootDirectory: directory,
                              chapters: [ReflowableBook.Chapter(url: target, weight: max(size, 1), title: nil)],
                              toc: [],
                              isPlainText: true)
    }

    // MARK: HTML

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let style = """
        body { font-family: "Iowan Old Style", Georgia, serif; line-height: 1.5; text-align: justify; \
        -webkit-hyphens: auto; hyphens: auto; }
        p { margin: 0 0 0.6em 0; }
        h1, h2, h3, h4, h5, h6 { line-height: 1.25; text-align: left; -webkit-hyphens: manual; hyphens: manual; \
        margin: 1.2em 0 0.6em 0; }
        h1 { font-size: 1.6em; }
        h2 { font-size: 1.35em; }
        h3 { font-size: 1.15em; }
        body > h1:first-child, body > h2:first-child { margin-top: 0.3em; }
        pre { white-space: pre-wrap; font-family: Menlo, monospace; font-size: 0.85em; text-align: left; }
        code { font-family: Menlo, monospace; font-size: 0.9em; }
        blockquote { margin: 0.8em 1.2em; font-style: italic; }
        ul, ol { margin: 0 0 0.6em 0; padding-left: 1.4em; }
        hr { border: none; border-top: 1px solid currentColor; opacity: 0.3; margin: 1.2em 0; }
        """

    private static func page(title: String, language: String, body: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="\(language)">
        <head>
        <meta charset="utf-8"/>
        \(EPUBBookReader.viewportMeta)
        <title>\(escape(title))</title>
        <style>
        \(style)
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    // MARK: Vanlig text

    private static let chapterWords = try? NSRegularExpression(
        pattern: "^(kapitel|chapter|del|part|avsnitt|bok|book|prolog|epilog|prologue|epilogue|förord|efterord|inledning|appendix|bilaga)\\b",
        options: [.caseInsensitive])

    private static let romanNumeral = try? NSRegularExpression(pattern: "^[IVXLC]{1,8}\\.?$")

    /// En rad som ser ut som en kapitelrubrik: "KAPITEL 3", "Del två", "IV", eller kort och bara versaler.
    private static func isHeading(_ line: String) -> Bool {
        guard line.count <= 60 else { return false }
        let range = NSRange(location: 0, length: (line as NSString).length)
        if chapterWords?.firstMatch(in: line, range: range) != nil {
            return true
        }
        if romanNumeral?.firstMatch(in: line, range: range) != nil {
            return true
        }
        let letters = line.filter { $0.isLetter }
        return letters.count >= 4 && line.count <= 40 && !letters.contains { $0.isLowercase } && !line.hasSuffix(".")
    }

    /// Stycken skiljs av tomma rader. Är texten radbruten för hand (som i Projekt Runeberg och Gutenberg)
    /// slås raderna i ett stycke ihop, annars är varje rad ett eget stycke.
    private static func plainBlocks(_ text: String) -> [Block] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let filled = lines.filter { !$0.isEmpty }
        let wrapped = filled.filter { $0.count >= 45 && $0.count <= 90 }.count
        let hardWrapped = filled.count >= 10 && filled.count < lines.count
            && Double(wrapped) / Double(max(filled.count, 1)) > 0.5

        var blocks: [Block] = []
        var paragraph: [String] = []

        func emit(_ line: String) {
            if isHeading(line) {
                blocks.append(Block(headingLevel: 2, title: line, html: escape(line), length: line.count))
            } else {
                blocks.append(Block(headingLevel: nil, title: "", html: "<p>\(escape(line))</p>", length: line.count))
            }
        }

        func flush() {
            guard !paragraph.isEmpty else { return }
            if hardWrapped {
                if paragraph.count == 1 {
                    emit(paragraph[0])
                } else {
                    let joined = paragraph.joined(separator: " ")
                    blocks.append(Block(headingLevel: nil, title: "", html: "<p>\(escape(joined))</p>",
                                        length: joined.count))
                }
            } else {
                paragraph.forEach(emit)
            }
            paragraph.removeAll()
        }

        for line in lines {
            if line.isEmpty {
                flush()
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }

    // MARK: Markdown

    /// Det vanligaste i Markdown: rubriker, stycken, listor, citat, kodblock, linjer, fetstil, kursiv och länkar.
    private static func markdownBlocks(_ text: String) -> [Block] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var blocks: [Block] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let joined = paragraph.joined(separator: " ")
            blocks.append(Block(headingLevel: nil, title: "", html: "<p>\(inline(joined))</p>", length: joined.count))
            paragraph.removeAll()
        }

        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index])
                    index += 1
                }
                index += 1
                let joined = code.joined(separator: "\n")
                blocks.append(Block(headingLevel: nil, title: "",
                                    html: "<pre><code>\(escape(joined))</code></pre>", length: joined.count))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let heading = markdownHeading(trimmed) {
                flushParagraph()
                blocks.append(Block(headingLevel: heading.level, title: plain(heading.text),
                                    html: inline(heading.text), length: heading.text.count))
                index += 1
                continue
            }

            if isRule(trimmed) {
                flushParagraph()
                blocks.append(Block(headingLevel: nil, title: "", html: "<hr/>", length: 0))
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while index < lines.count {
                    let line = lines[index].trimmingCharacters(in: .whitespaces)
                    guard line.hasPrefix(">") else { break }
                    quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                let joined = quote.filter { !$0.isEmpty }.joined(separator: " ")
                blocks.append(Block(headingLevel: nil, title: "",
                                    html: "<blockquote><p>\(inline(joined))</p></blockquote>", length: joined.count))
                continue
            }

            if let first = listItem(trimmed) {
                flushParagraph()
                var items = [first.text]
                index += 1
                while index < lines.count {
                    let raw = lines[index]
                    let line = raw.trimmingCharacters(in: .whitespaces)
                    if line.isEmpty {
                        break
                    }
                    if let item = listItem(line), item.ordered == first.ordered {
                        items.append(item.text)
                    } else if raw.hasPrefix(" ") || raw.hasPrefix("\t") {
                        items[items.count - 1] += " " + line
                    } else {
                        break
                    }
                    index += 1
                }
                let tag = first.ordered ? "ol" : "ul"
                let html = "<\(tag)>" + items.map { "<li>\(inline($0))</li>" }.joined() + "</\(tag)>"
                blocks.append(Block(headingLevel: nil, title: "", html: html,
                                    length: items.reduce(0) { $0 + $1.count }))
                continue
            }

            paragraph.append(trimmed)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    private static func markdownHeading(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes >= 1, hashes <= 6 else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") {
            text.removeLast()
        }
        text = text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (hashes, text)
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func listItem(_ line: String) -> (ordered: Bool, text: String)? {
        if let first = line.first, "-*+".contains(first), line.dropFirst().first == " " {
            return (false, String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
        }
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let rest = line.dropFirst(digits.count)
            if let marker = rest.first, marker == "." || marker == ")", rest.dropFirst().first == " " {
                return (true, String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    private static let inlineRules: [(NSRegularExpression, String)] = {
        let patterns: [(String, String)] = [
            ("`([^`]+)`", "<code>$1</code>"),
            ("!\\[([^\\]]*)\\]\\([^)]*\\)", "$1"),
            ("\\[([^\\]]+)\\]\\((https?://[^)\\s]+)[^)]*\\)", "<a href=\"$2\">$1</a>"),
            ("\\[([^\\]]+)\\]\\([^)]*\\)", "$1"),
            ("\\*\\*([^*]+)\\*\\*", "<strong>$1</strong>"),
            ("__([^_]+)__", "<strong>$1</strong>"),
            ("\\*([^*\\s][^*]*)\\*", "<em>$1</em>"),
            ("(^|[^A-Za-z0-9])_([^_\\s][^_]*)_(?=[^A-Za-z0-9]|$)", "$1<em>$2</em>"),
        ]
        return patterns.compactMap { pair in
            (try? NSRegularExpression(pattern: pair.0)).map { ($0, pair.1) }
        }
    }()

    private static func inline(_ text: String) -> String {
        var result = escape(text)
        for (regex, template) in inlineRules {
            let range = NSRange(location: 0, length: (result as NSString).length)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }

    private static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "*", with: "")
    }
}
