import CoreGraphics
import Foundation

/// Bokens egna sidnummer i en PDF (K2): ett ställe som ger bokens sidnummer för en sida i filen.
/// Gå till sida, sidraden, tidslinjen, bokmärkena, anteckningsboken och citaten använder det.
///
/// Källorna: filens egna nummer (sida 1 är 1), PDF:ens sidetiketter, eller en förskjutning där filens
/// första sida är bokens sida `first`. Med `spread` är varje sida i filen ett foto av ett helt uppslag,
/// alltså två boksidor. Filens nummer räknas bara som bokens när läsaren sagt det (`fileConfirmed`):
/// annars får citaten ingen sida (granskning 4, D4-1). Ren logik utan PDFKit, så att den går att testa (G13).
struct BookPageNumbering: Equatable {

    enum Source: Equatable {
        /// Filens nummer, och bokens sidnummer är inte inställt. Citaten får ingen sida.
        case file
        /// Läsaren har sagt att filens nummer är bokens (Filens sidnummer är bokens).
        case fileConfirmed
        case pdfLabels
        case offset(first: Int, spread: Bool)
    }

    let source: Source

    static let file = BookPageNumbering(source: .file)

    /// Det sparade sättet i `book_info.page_first`: 0 inte valt än, -1 filens nummer är bokens,
    /// -2 PDF:ens sidetiketter, större än 0 bokens sida för filens första sida.
    static let notChosen = 0
    static let fileNumbers = -1
    static let labelNumbers = -2

    /// Väljer källa ur det sparade sättet. Inte valt än: förslaget ur filnamnet när sidantalet stämmer
    /// (D4-4), annars PDF:ens sidetiketter, annars filens nummer utan att de räknas som bokens. Läsaren sparar
    /// det automatiska valet första gången boken öppnas (`automaticSetting`, D4-6).
    static func resolve(first setting: Int, spread: Bool, fileName: String, pageCount: Int,
                        hasPDFLabels: Bool) -> BookPageNumbering {
        if setting > 0 {
            return BookPageNumbering(source: .offset(first: setting, spread: spread))
        }
        if setting == fileNumbers {
            return BookPageNumbering(source: .fileConfirmed)
        }
        if setting == labelNumbers {
            return BookPageNumbering(source: hasPDFLabels ? .pdfLabels : .file)
        }
        if let suggestion = suggestion(fileName: fileName, pageCount: pageCount), suggestion.matches {
            return BookPageNumbering(source: .offset(first: suggestion.first, spread: suggestion.spread))
        }
        return BookPageNumbering(source: hasPDFLabels ? .pdfLabels : .file)
    }

    /// D4-6: det som sparas i `book_info` första gången boken öppnas, så att ett nytt filnamn inte räknar om
    /// sidnumren tyst. Nil: inget säkert val, bokens sidnummer får ställas in.
    static func automaticSetting(fileName: String, pageCount: Int, hasPDFLabels: Bool) -> (first: Int, spread: Bool)? {
        if let suggestion = suggestion(fileName: fileName, pageCount: pageCount), suggestion.matches {
            return (suggestion.first, suggestion.spread)
        }
        return hasPDFLabels ? (labelNumbers, false) : nil
    }

    /// Antalet bilder som ett uppslag från `first` till `last` kräver, med jämn sida till vänster (D4-2).
    static func spreadCount(first: Int, last: Int) -> Int {
        let start = spreadStart(first)
        let end = last % 2 == 1 ? last : last + 1
        return (end - start + 1) / 2
    }

    /// Förslaget ur filnamnet: ett sidintervall inom parentes, som "Lindqvist kap 3 (s63-80).pdf" eller
    /// "(s. 281–305)". `matches` när filens sidantal är exakt intervallets (eller antalet uppslag, D4-4): bara
    /// då används förslaget utan att läsaren bekräftar det.
    static func suggestion(fileName: String, pageCount: Int) -> (first: Int, last: Int, spread: Bool, matches: Bool)? {
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
        let single = pageCount == range
        let spreads = pageCount == spreadCount(first: first, last: last)
        let spread = !single && (spreads || (pageCount > 0 && abs(range - 2 * pageCount) < abs(range - pageCount)))
        return (first, last, spread, single || spreads)
    }

    /// D4-2: i en tryckt bok står jämna sidor till vänster. Ett uppslag som visar sida `first` har därför
    /// vänstersidan `first` om den är jämn, annars `first - 1`.
    static func spreadStart(_ first: Int) -> Int {
        first % 2 == 0 ? first : first - 1
    }

    /// D4-7: vilken halva av ett uppslag en markering ligger på (0 vänster, 1 höger), räknat i sidans visade
    /// koordinater. Rutorna sparas i PDF-sidans egna koordinater, så sidans rotation vänds först. Nil när rutorna
    /// ligger på båda halvorna eller över mitten: då blir citatets sida "N f.".
    static func spreadHalf(rects: [CGRect], bounds: CGRect, rotation: Int) -> Int? {
        guard !rects.isEmpty else { return nil }
        let turned = ((rotation % 360) + 360) % 360
        var halves = Set<Int>()
        for rect in rects {
            let vertical = turned == 90 || turned == 270
            let low = vertical ? rect.minY : rect.minX
            let high = vertical ? rect.maxY : rect.maxX
            let mid = vertical ? bounds.midY : bounds.midX
            if low < mid, high > mid {
                return nil
            }
            // 90 grader medurs: sidans överkant (högt y) hamnar till höger. 180 och 270 vänder höger och vänster.
            var right = low >= mid
            if turned == 180 || turned == 270 {
                right.toggle()
            }
            halves.insert(right ? 1 : 0)
        }
        return halves.count == 1 ? halves.first : nil
    }

    /// Bokens sidor för sidan `index` (från 0) i filen, när de är kända som tal (förskjutningen).
    func bookPages(for index: Int) -> ClosedRange<Int>? {
        guard case let .offset(first, spread) = source else { return nil }
        if spread {
            let left = Self.spreadStart(first) + 2 * index
            // Sida 1 står ensam till höger, det finns ingen sida 0.
            return left <= 0 ? 1...1 : left...(left + 1)
        }
        return (first + index)...(first + index)
    }

    /// Sidnumret som står i boken, eller nil när det är samma som sidans plats i filen. `pdfLabel` är
    /// PDF:ens egen sidetikett för sidan, om den finns.
    func printed(for index: Int, pdfLabel: String?) -> String? {
        switch source {
        case .file, .fileConfirmed:
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
    /// och 1 för högra sidan i ett uppslag, nil när det inte är känt (då blir det "63 f."). Nil när bokens
    /// sidnummer inte är inställt: då påstår citatet ingen sida (D4-1).
    func citationPage(for index: Int, half: Int?, pdfLabel: String?) -> String? {
        switch source {
        case .file:
            return nil
        case .fileConfirmed:
            return String(index + 1)
        case .pdfLabels:
            return printed(for: index, pdfLabel: pdfLabel) ?? String(index + 1)
        case .offset:
            guard let pages = bookPages(for: index) else { return nil }
            if pages.count == 1 {
                return String(pages.lowerBound)
            }
            if let half = half {
                return String(pages.lowerBound + min(max(half, 0), 1))
            }
            return "\(pages.lowerBound) f."
        }
    }

    /// Sidan i filen (från 0) för ett sidnummer som skrivits i Gå till sida: bokens nummer först, annars
    /// sidans plats i filen.
    func index(forTyped text: String, pageCount: Int, pdfLabel: (Int) -> String?) -> Int? {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, pageCount > 0 else { return nil }
        switch source {
        case let .offset(first, spread):
            let start = spread ? Self.spreadStart(first) : first
            if let number = Int(typed), number >= start {
                let index = spread ? (number - start) / 2 : number - first
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
        case .file, .fileConfirmed:
            break
        }
        if let number = Int(typed), number >= 1, number <= pageCount {
            return number - 1
        }
        return nil
    }

    /// Om Gå till sida ska be om bokens nummer.
    var usesBookNumbers: Bool {
        source != .file && source != .fileConfirmed
    }

    /// Kort beskrivning till rutan Bokens sidnummer.
    var summary: String {
        switch source {
        case .file:
            return "Bokens sidnummer är inte inställt. Sidraden visar filens sidnummer, och citaten får ingen sida."
        case .fileConfirmed:
            return "Filens sidnummer används som bokens."
        case .pdfLabels:
            return "Nu används sidnumren som står i PDF:en."
        case let .offset(first, spread):
            let left = Self.spreadStart(first)
            return spread
                ? "Nu visar filens första bild bokens sidor \(left) och \(left + 1) (jämn sida till vänster), två boksidor per bild."
                : "Nu är filens första sida bokens sida \(first)."
        }
    }
}

/// Förslag ur sidornas text (D4-1): tryckta sidnummer överst eller nederst på sidorna i PDF:ens textlager.
/// Bara ett förslag som läsaren bekräftar i Bokens sidnummer, det skrivs aldrig in av sig självt.
enum PrintedPageNumbers {

    /// Fristående tal (1 till 4 siffror) först eller sist på sidans två första och två sista rader.
    static func candidates(in text: String) -> [Int] {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return [] }
        var edges = Array(lines.prefix(2))
        edges += lines.suffix(2)
        var result: [Int] = []
        for line in edges where line.count <= 90 {
            let words = line.split(separator: " ")
            for word in [words.first, words.last].compactMap({ $0 }) {
                if word.count <= 4, word.allSatisfy(\.isNumber), let number = Int(word), number > 0, !result.contains(number) {
                    result.append(number)
                }
            }
        }
        return result
    }

    /// Bokens sida för filens första sida, ur talen på varje sida (index i filen). Minst tre sidor och minst
    /// hälften av sidorna med tal ska ge samma förskjutning.
    static func firstPage(_ pages: [(index: Int, numbers: [Int])]) -> (first: Int, votes: Int)? {
        var votes: [Int: Int] = [:]
        var pagesWithNumbers = 0
        for page in pages where !page.numbers.isEmpty {
            pagesWithNumbers += 1
            for first in Set(page.numbers.map { $0 - page.index }) where first >= 1 {
                votes[first, default: 0] += 1
            }
        }
        guard let best = votes.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }),
              best.value >= 3, best.value * 2 >= pagesWithNumbers else {
            return nil
        }
        return (best.key, best.value)
    }
}

/// Det som sparas per bok för sidnummer (K2) och citat (K3), i tabellen `book_info` i markeringar.sqlite
/// (steg 6 i trappan). Följer med i säkerhetskopian, eftersom hela databasen kopieras.
struct BookInfo: Equatable {
    /// Sättet för sidnumren: se `BookPageNumbering.notChosen`, `fileNumbers` och `labelNumbers`, eller större
    /// än 0 för bokens sida för filens första sida.
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

    /// Sidnumreringen för en bok utan läsarens PDF-dokument, till anteckningsboken för alla böcker och Anki
    /// (D4-5). Samma val som läsaren, eftersom läsaren sparar sitt val i `book_info` första gången boken öppnas.
    /// Nil när sidnumren bara finns i PDF:en (sidetiketterna) och inte går att räkna fram här: då visas ingen
    /// sida hellre än en annan än läsarens. Böcker med markeringar har alltid öppnats i läsaren.
    func numbering(for book: Book, pageCount: Int) -> BookPageNumbering? {
        guard book.kind == .pdf else { return nil }
        let info = info(book: book.id)
        if info.pageFirst == BookPageNumbering.labelNumbers {
            return nil
        }
        if info.pageFirst == BookPageNumbering.notChosen {
            // Läsaren har inte hittat något säkert val (annars vore det sparat): filens nummer, ingen sida i citat.
            return .file
        }
        return BookPageNumbering.resolve(first: info.pageFirst, spread: info.pageSpread,
                                         fileName: book.url.lastPathComponent, pageCount: pageCount,
                                         hasPDFLabels: false)
    }
}
