import Foundation
import PDFKit

/// En träff i boken.
struct SearchHit {
    /// PDF: sidans plats i filen. EPUB och text: kapitlet.
    let section: Int
    /// PDF: var träffen står i sidans text (UTF-16). EPUB och text: i kapitlets text utan taggar.
    let start: Int
    let length: Int
    /// Vilken träff i avsnittet det är, från 0. EPUB-läsaren letar upp samma träff i webbvyn.
    let occurrence: Int
    /// Texten runt träffen, och var träffen står i den (UTF-16).
    let snippet: String
    let match: NSRange
}

/// Text där små bokstäver, ett mellanslag mellan orden och borttagna avstavningar gör att en sökning hittar
/// "kunskap" även när det står "Kun-\nskap" i PDF:en. `map` pekar från varje tecken tillbaka till originalet.
struct FoldedText {
    let text: NSString
    let map: [Int]

    init(_ original: NSString) {
        var units: [unichar] = []
        var map: [Int] = []
        units.reserveCapacity(original.length)
        map.reserveCapacity(original.length)
        let length = original.length
        var index = 0
        while index < length {
            let unit = original.character(at: index)
            if unit == 0xAD {
                index += 1
                continue
            }
            if FoldedText.isSpace(unit) {
                if let last = units.last, last != 0x20 {
                    units.append(0x20)
                    map.append(index)
                }
                index += 1
                continue
            }
            if FoldedText.isHyphen(unit), units.last.map({ !FoldedText.isSpaceUnit($0) }) == true {
                // Avstavning vid radslut: streck, blanktecken med en radbrytning, och sedan en liten bokstav.
                var look = index + 1
                var sawBreak = false
                while look < length, FoldedText.isSpace(original.character(at: look)) {
                    if FoldedText.isLineBreak(original.character(at: look)) {
                        sawBreak = true
                    }
                    look += 1
                }
                if sawBreak, look < length, FoldedText.isLowercaseLetter(original.character(at: look)) {
                    index = look
                    continue
                }
            }
            units.append(FoldedText.lower(unit))
            map.append(index)
            index += 1
        }
        self.text = NSString(characters: units, length: units.count)
        self.map = map
    }

    /// Söktexten på samma form, utan mellanslag i början och slutet.
    static func query(_ text: String) -> String {
        let folded = FoldedText(text as NSString).text as String
        return folded.trimmingCharacters(in: .whitespaces)
    }

    /// Originalets intervall för ett intervall i den vikta texten.
    func originalRange(of range: NSRange) -> NSRange {
        guard range.length > 0, range.location < map.count else { return NSRange(location: 0, length: 0) }
        let start = map[range.location]
        let last = map[min(NSMaxRange(range) - 1, map.count - 1)]
        return NSRange(location: start, length: last - start + 1)
    }

    private static func isSpaceUnit(_ unit: unichar) -> Bool {
        unit == 0x20
    }

    static func isSpace(_ unit: unichar) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0xA0 || isLineBreak(unit) || unit == 0x0B || unit == 0x0C
    }

    static func isLineBreak(_ unit: unichar) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029
    }

    private static func isHyphen(_ unit: unichar) -> Bool {
        unit == 0x2D || unit == 0x2010 || unit == 0x2011
    }

    private static func isLowercaseLetter(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return scalar.properties.isLowercase
    }

    private static func lower(_ unit: unichar) -> unichar {
        if unit >= 0x41, unit <= 0x5A {
            return unit + 32
        }
        if unit < 0xC0 {
            return unit
        }
        guard let scalar = Unicode.Scalar(unit) else { return unit }
        let lowered = Array(scalar.properties.lowercaseMapping.utf16)
        return lowered.count == 1 ? lowered[0] : unit
    }
}

/// Söker i en bok i bakgrunden och lämnar träffarna i omgångar på huvudtråden.
final class BookSearch {

    /// Var texten kommer ifrån.
    enum Source {
        /// En PDF. Sökningen öppnar ett eget dokument, så att läsarens dokument bara används på huvudtråden.
        case pdf(URL)
        /// Kapitlen i en EPUB eller textfil, som filer på disk.
        case chapters([URL])
    }

    static let maxHits = 500
    private static let context = 60

    private let source: Source
    private let queue = DispatchQueue(label: "se.edvin.lasa.search", qos: .userInitiated)
    private var token: CancelToken?
    /// Kapiteltexterna sparas mellan sökningarna, de är dyra att ta fram. Används bara på sökkön.
    private var chapterTexts: [Int: FoldedChapter] = [:]
    private var pdfDocument: PDFDocument?

    private struct FoldedChapter {
        let original: NSString
        let folded: FoldedText
    }

    private final class CancelToken {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }

    init(source: Source) {
        self.source = source
    }

    /// Avbryter en pågående sökning och startar en ny. `update` får alla träffar hittills, och sant när sökningen är klar.
    func start(_ query: String, update: @escaping ([SearchHit], Bool) -> Void) {
        token?.cancel()
        let folded = FoldedText.query(query)
        guard (folded as NSString).length >= 2 else {
            update([], true)
            return
        }
        let token = CancelToken()
        self.token = token
        queue.async { [weak self] in
            self?.run(folded, token: token, update: update)
        }
    }

    func cancel() {
        token?.cancel()
        token = nil
    }

    // MARK: På sökkön

    private func run(_ query: String, token: CancelToken, update: @escaping ([SearchHit], Bool) -> Void) {
        var hits: [SearchHit] = []
        var lastReport = CFAbsoluteTimeGetCurrent()
        let count = sectionCount()
        for section in 0..<count {
            if token.isCancelled {
                return
            }
            if let text = text(of: section) {
                hits += Self.find(query, in: text.folded, original: text.original, section: section,
                                  limit: Self.maxHits - hits.count)
            }
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastReport > 0.25 || hits.count >= Self.maxHits {
                lastReport = now
                let snapshot = hits
                let done = hits.count >= Self.maxHits
                DispatchQueue.main.async {
                    if !token.isCancelled {
                        update(snapshot, done)
                    }
                }
                if done {
                    return
                }
            }
        }
        let final = hits
        DispatchQueue.main.async {
            if !token.isCancelled {
                update(final, true)
            }
        }
    }

    private func sectionCount() -> Int {
        switch source {
        case .pdf(let url):
            if pdfDocument == nil {
                pdfDocument = PDFDocument(url: url)
            }
            return pdfDocument?.pageCount ?? 0
        case .chapters(let urls):
            return urls.count
        }
    }

    private func text(of section: Int) -> FoldedChapter? {
        switch source {
        case .pdf:
            // Sidornas text sparas inte, en stor PDF skulle ta för mycket minne.
            guard let string = pdfDocument?.page(at: section)?.string, !string.isEmpty else { return nil }
            let original = string as NSString
            return FoldedChapter(original: original, folded: FoldedText(original))
        case .chapters(let urls):
            if let cached = chapterTexts[section] {
                return cached
            }
            guard section < urls.count else { return nil }
            let text = Self.plainText(ofChapterAt: urls[section]) as NSString
            let chapter = FoldedChapter(original: text, folded: FoldedText(text))
            chapterTexts[section] = chapter
            return chapter
        }
    }

    private static func find(_ query: String, in folded: FoldedText, original: NSString, section: Int,
                             limit: Int) -> [SearchHit] {
        var hits: [SearchHit] = []
        let haystack = folded.text
        var searchRange = NSRange(location: 0, length: haystack.length)
        var occurrence = 0
        while hits.count < limit {
            let found = haystack.range(of: query, options: [.literal], range: searchRange)
            guard found.location != NSNotFound, found.length > 0 else { break }
            let range = folded.originalRange(of: found)
            let (snippet, match) = Self.snippet(original: original, range: range)
            hits.append(SearchHit(section: section, start: range.location, length: range.length,
                                  occurrence: occurrence, snippet: snippet, match: match))
            occurrence += 1
            let next = NSMaxRange(found)
            searchRange = NSRange(location: next, length: haystack.length - next)
        }
        return hits
    }

    /// Texten runt träffen på en rad, med träffen markerad.
    static func snippet(original: NSString, range: NSRange) -> (String, NSRange) {
        let start = max(0, range.location - context)
        let end = min(original.length, NSMaxRange(range) + context)
        var before = collapse(original.substring(with: NSRange(location: start, length: range.location - start)))
        let match = collapse(original.substring(with: range))
        var after = collapse(original.substring(with: NSRange(location: NSMaxRange(range), length: end - NSMaxRange(range))))
        // Börja och sluta vid hela ord.
        if start > 0, let space = before.firstIndex(of: " ") {
            before = "…" + String(before[before.index(after: space)...])
        }
        if end < original.length, let space = after.lastIndex(of: " ") {
            after = String(after[..<space]) + "…"
        }
        before = String(before.drop { $0 == " " })
        let snippet = before + match + after
        return (snippet.trimmingCharacters(in: .whitespaces),
                NSRange(location: (before as NSString).length, length: (match as NSString).length))
    }

    /// Blanktecken i följd blir ett mellanslag, avstavningar försvinner. Inget tas bort i kanterna.
    private static func collapse(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\u{00AD}", with: "")
        for hyphen in ["-", "\u{2010}", "\u{2011}"] {
            result = result.replacingOccurrences(of: hyphen + "\r\n", with: "")
            result = result.replacingOccurrences(of: hyphen + "\n", with: "")
        }
        var output = ""
        var lastWasSpace = false
        for character in result {
            if character.isWhitespace {
                if !lastWasSpace {
                    output.append(" ")
                }
                lastWasSpace = true
            } else {
                output.append(character)
                lastWasSpace = false
            }
        }
        return output
    }

    // MARK: Kapitlens text

    private static let removals: [NSRegularExpression] = [
        "<head[\\s>].*?</head\\s*>",
        "<script[\\s>].*?</script\\s*>",
        "<style[\\s>].*?</style\\s*>",
        "<!--.*?-->",
        "<[^>]*>",
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive, .dotMatchesLineSeparators]) }

    private static let entity = try? NSRegularExpression(pattern: "&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);")

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "shy": "\u{00AD}",
        "mdash": "\u{2014}", "ndash": "\u{2013}", "hellip": "\u{2026}", "laquo": "\u{00AB}", "raquo": "\u{00BB}",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "lsquo": "\u{2018}", "rsquo": "\u{2019}", "copy": "\u{00A9}",
    ]

    /// Kapitlets text som webbvyn ser den: allt i body utom skript och stilar, med tecknen avkodade.
    static func plainText(ofChapterAt url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        var html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        for expression in removals {
            html = expression.stringByReplacingMatches(in: html, range: NSRange(location: 0, length: (html as NSString).length),
                                                       withTemplate: "")
        }
        guard let entity = entity else { return html }
        let source = html as NSString
        var output = ""
        var position = 0
        for match in entity.matches(in: html, range: NSRange(location: 0, length: source.length)) {
            output += source.substring(with: NSRange(location: position, length: match.range.location - position))
            let name = source.substring(with: match.range(at: 1))
            var replacement: String?
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                replacement = UInt32(name.dropFirst(2), radix: 16).flatMap { Unicode.Scalar($0) }.map { String(Character($0)) }
            } else if name.hasPrefix("#") {
                replacement = UInt32(name.dropFirst()).flatMap { Unicode.Scalar($0) }.map { String(Character($0)) }
            } else {
                replacement = namedEntities[name]
            }
            output += replacement ?? source.substring(with: match.range)
            position = NSMaxRange(match.range)
        }
        output += source.substring(from: position)
        return output
    }
}
