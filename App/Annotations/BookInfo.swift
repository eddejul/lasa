import Foundation

/// Bokens egna sidnummer i en PDF (K2): ett ställe som ger bokens sidnummer för en sida i filen.
/// Gå till sida, sidraden, tidslinjen, bokmärkena, anteckningsboken och citaten använder det.
///
/// Tre källor: filens egna nummer (sida 1 är 1), PDF:ens sidetiketter, eller en förskjutning där filens
/// första sida är bokens sida `first`. Med `spread` är varje sida i filen ett foto av ett helt uppslag,
/// alltså två boksidor. Ren logik utan PDFKit, så att den går att testa (G13).
struct BookPageNumbering: Equatable {

    enum Source: Equatable {
        case file
        case pdfLabels
        case offset(first: Int, spread: Bool)
    }

    let source: Source

    static let file = BookPageNumbering(source: .file)

    /// Väljer källa. `setting` är det som sparats för boken (0 automatiskt, -1 PDF:ens egna nummer, större än
    /// 0 bokens sida för filens första sida). Automatiskt: förslaget ur filnamnet, annars PDF:ens sidetiketter.
    static func resolve(first setting: Int, spread: Bool, fileName: String, pageCount: Int,
                        hasPDFLabels: Bool) -> BookPageNumbering {
        if setting > 0 {
            return BookPageNumbering(source: .offset(first: setting, spread: spread))
        }
        if setting == 0, let suggestion = suggestion(fileName: fileName, pageCount: pageCount) {
            return BookPageNumbering(source: .offset(first: suggestion.first, spread: suggestion.spread))
        }
        return BookPageNumbering(source: hasPDFLabels ? .pdfLabels : .file)
    }

    /// Förslaget ur filnamnet: ett sidintervall inom parentes, som "Lindqvist kap 3 (s63-80).pdf" eller
    /// "(s. 281–305)". Är intervallet ungefär dubbelt så långt som filens sidantal är varje sida ett uppslag.
    static func suggestion(fileName: String, pageCount: Int) -> (first: Int, last: Int, spread: Bool)? {
        let name = fileName as NSString
        let pattern = #"\(\s*[sS]\.?\s*(\d{1,4})\s*[-–—]\s*(\d{1,4})\s*\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: fileName, range: NSRange(location: 0, length: name.length)),
              let first = Int(name.substring(with: match.range(at: 1))),
              let last = Int(name.substring(with: match.range(at: 2))),
              first > 0, last >= first else {
            return nil
        }
        let range = last - first + 1
        let spread = pageCount > 0 && abs(range - 2 * pageCount) < abs(range - pageCount)
        return (first, last, spread)
    }

    /// Bokens sidor för sidan `index` (från 0) i filen, när de är kända som tal (förskjutningen).
    func bookPages(for index: Int) -> ClosedRange<Int>? {
        guard case let .offset(first, spread) = source else { return nil }
        if spread {
            let left = first + 2 * index
            return left...(left + 1)
        }
        return (first + index)...(first + index)
    }

    /// Sidnumret som står i boken, eller nil när det är samma som sidans plats i filen. `pdfLabel` är
    /// PDF:ens egen sidetikett för sidan, om den finns.
    func printed(for index: Int, pdfLabel: String?) -> String? {
        switch source {
        case .file:
            return nil
        case .pdfLabels:
            let label = pdfLabel?.trimmingCharacters(in: .whitespaces) ?? ""
            return label.isEmpty || label == String(index + 1) ? nil : label
        case .offset:
            guard let pages = bookPages(for: index) else { return nil }
            if pages.count == 1 {
                return pages.lowerBound == index + 1 ? nil : String(pages.lowerBound)
            }
            return "\(pages.lowerBound) och \(pages.upperBound)"
        }
    }

    /// Bokens sidnummer för en markering, till citat (K3) och anteckningsboken (K1). `half` är 0 för vänstra
    /// och 1 för högra sidan i ett uppslag, nil när det inte är känt (då blir det "63 f.").
    func citationPage(for index: Int, half: Int?, pdfLabel: String?) -> String {
        if let pages = bookPages(for: index) {
            if pages.count == 1 {
                return String(pages.lowerBound)
            }
            if let half = half {
                return String(pages.lowerBound + min(max(half, 0), 1))
            }
            return "\(pages.lowerBound) f."
        }
        return printed(for: index, pdfLabel: pdfLabel) ?? String(index + 1)
    }

    /// Sidan i filen (från 0) för ett sidnummer som skrivits i Gå till sida: bokens nummer först, annars
    /// sidans plats i filen.
    func index(forTyped text: String, pageCount: Int, pdfLabel: (Int) -> String?) -> Int? {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, pageCount > 0 else { return nil }
        switch source {
        case let .offset(first, spread):
            if let number = Int(typed), number >= first {
                let index = spread ? (number - first) / 2 : number - first
                if index < pageCount {
                    return index
                }
            }
        case .pdfLabels:
            for index in 0..<pageCount {
                if let label = pdfLabel(index)?.trimmingCharacters(in: .whitespaces),
                   label.caseInsensitiveCompare(typed) == .orderedSame {
                    return index
                }
            }
        case .file:
            break
        }
        if let number = Int(typed), number >= 1, number <= pageCount {
            return number - 1
        }
        return nil
    }

    /// Om Gå till sida ska be om bokens nummer.
    var usesBookNumbers: Bool {
        source != .file
    }

    /// Kort beskrivning till rutan Bokens sidnummer.
    var summary: String {
        switch source {
        case .file:
            return "Nu används filens egna sidnummer."
        case .pdfLabels:
            return "Nu används sidnumren som står i PDF:en."
        case let .offset(first, spread):
            return spread
                ? "Nu är filens första sida bokens sidor \(first) och \(first + 1), två boksidor per bild."
                : "Nu är filens första sida bokens sida \(first)."
        }
    }
}

/// Det som sparas per bok för sidnummer (K2) och citat (K3), i tabellen `book_info` i markeringar.sqlite
/// (steg 6 i trappan). Följer med i säkerhetskopian, eftersom hela databasen kopieras.
struct BookInfo: Equatable {
    /// 0 automatiskt, -1 PDF:ens egna nummer, större än 0 bokens sida för filens första sida.
    var pageFirst = 0
    var pageSpread = false
    /// Bokinfo till citaten. Tomma fält fylls i från bokens titel och författare (B1) eller EPUB:en.
    var author = ""
    var year = ""
    var title = ""
    var publisher = ""
    var place = ""
}

/// Läser och sparar `BookInfo`. Används bara från huvudtråden, som `AnnotationStore`.
final class BookInfoStore {

    static let shared = BookInfoStore()

    /// Skickas när en boks info ändrats. `object` är bokens id.
    static let didChange = Notification.Name("BookInfoStoreDidChange")

    private init() {}

    func info(book: String) -> BookInfo {
        var result = BookInfo()
        AnnotationStore.shared.readBooks { db in
            try db.query("""
                SELECT page_first, page_spread, author, year, title, publisher, place FROM book_info WHERE book = ?
                """, [book]) { row in
                result = BookInfo(pageFirst: row.int(0), pageSpread: row.int(1) != 0, author: row.string(2),
                                  year: row.string(3), title: row.string(4), publisher: row.string(5),
                                  place: row.string(6))
            }
        }
        return result
    }

    @discardableResult
    func save(_ info: BookInfo, book: String) -> Bool {
        let ok = AnnotationStore.shared.writeBooks("bokinfon") { db in
            try db.execute("""
                INSERT INTO book_info (book, page_first, page_spread, author, year, title, publisher, place, updated)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(book) DO UPDATE SET page_first = excluded.page_first, page_spread = excluded.page_spread,
                    author = excluded.author, year = excluded.year, title = excluded.title,
                    publisher = excluded.publisher, place = excluded.place, updated = excluded.updated
                """, [book, info.pageFirst, info.pageSpread ? 1 : 0, info.author, info.year, info.title,
                      info.publisher, info.place, Date().timeIntervalSince1970])
        }
        NotificationCenter.default.post(name: Self.didChange, object: book)
        return ok
    }

    /// Sidnumreringen för en bok utan läsarens PDF-dokument, till anteckningsboken och exporten. PDF:ens
    /// egna sidetiketter läses inte här, så en bok som bara har sådana får filens nummer.
    func numbering(for book: Book, pageCount: Int) -> BookPageNumbering {
        guard book.kind == .pdf else { return .file }
        let info = info(book: book.id)
        return BookPageNumbering.resolve(first: info.pageFirst, spread: info.pageSpread,
                                         fileName: book.url.lastPathComponent, pageCount: pageCount,
                                         hasPDFLabels: false)
    }
}
