import Foundation

/// Var man är i en bok och hur långt man läst (B1, B2). Läsarna skickar den när sidan byts, och den sparas
/// i bokregistret. Ingen tid kvar (Edvins beslut): bara kapitel, sida och sidor kvar.
struct ReadingStatus: Equatable {
    /// Hur långt man läst, 0 till 1.
    var progress: Double
    /// Kapitlets namn, tomt om boken saknar kapitel.
    var chapter: String = ""
    /// Sidan i hela boken (från 1), 0 när den inte är känd (EPUB innan alla kapitel mätts).
    var page: Int = 0
    /// Bokens sidantal, 0 när det inte är känt.
    var pages: Int = 0
    /// Sidor kvar i kapitlet, -1 när det inte är känt.
    var chapterLeft: Int = -1
}

/// En bok som biblioteket visar den: titel, författare, andel läst, när den lästes senast och kurser.
struct LibraryItem: Equatable {
    let book: Book
    let title: String
    let author: String
    let progress: Double
    let finished: Bool
    /// När boken lades in (sekunder sedan 1970).
    let added: Double
    /// När läspositionen senast ändrades (sekunder sedan 1970), 0 om boken aldrig öppnats.
    let lastRead: Double
    let chapter: String
    let page: Int
    let pages: Int
    let chapterLeft: Int
    /// Kurserna boken ligger i (B3), som kursernas id.
    var courses: Set<String> = []

    init(book: Book, record: BookRecord?, lastRead: Double, courses: Set<String> = []) {
        self.book = book
        title = record?.displayTitle ?? BookRecord.cleanedTitle(book.title)
        author = record?.displayAuthor ?? ""
        progress = record?.progress ?? 0
        finished = record?.isFinished ?? false
        added = record?.added ?? 0
        self.lastRead = lastRead
        chapter = record?.chapter ?? ""
        page = record?.page ?? 0
        pages = record?.pages ?? 0
        chapterLeft = record?.chapterLeft ?? -1
        self.courses = courses
    }

    /// Påbörjad: öppnad eller med något läst, men inte utläst.
    var isReading: Bool {
        !finished && (progress > 0 || lastRead > 0)
    }

    var isUnread: Bool {
        !finished && progress <= 0 && lastRead <= 0
    }
}

/// Sorteringen i biblioteket.
enum LibrarySort: String, CaseIterable {
    case recent, title, added

    var title: String {
        switch self {
        case .recent: return "Senast läst"
        case .title: return "Titel"
        case .added: return "Tillagd"
        }
    }
}

/// Filtret i biblioteket.
enum LibraryFilter: String, CaseIterable {
    case all, reading, unread, finished

    var title: String {
        switch self {
        case .all: return "Alla"
        case .reading: return "Pågående"
        case .unread: return "Olästa"
        case .finished: return "Utlästa"
        }
    }
}

/// Bibliotekets logik utan vyer, så att den går att testa (XCTest).
enum LibraryLogic {

    static func filter(_ items: [LibraryItem], _ filter: LibraryFilter) -> [LibraryItem] {
        switch filter {
        case .all: return items
        case .reading: return items.filter(\.isReading)
        case .unread: return items.filter(\.isUnread)
        case .finished: return items.filter(\.finished)
        }
    }

    static func sort(_ items: [LibraryItem], by sort: LibrarySort) -> [LibraryItem] {
        func byTitle(_ a: LibraryItem, _ b: LibraryItem) -> Bool {
            let order = a.title.localizedStandardCompare(b.title)
            return order == .orderedSame ? a.book.path < b.book.path : order == .orderedAscending
        }
        switch sort {
        case .title:
            return items.sorted(by: byTitle)
        case .added:
            return items.sorted { $0.added != $1.added ? $0.added > $1.added : byTitle($0, $1) }
        case .recent:
            // Senast lästa först. Böcker som aldrig öppnats efter dem, nyast tillagda först.
            return items.sorted { a, b in
                if a.lastRead != b.lastRead { return a.lastRead > b.lastRead }
                if a.added != b.added { return a.added > b.added }
                return byTitle(a, b)
            }
        }
    }

    /// Sökning på titel, författare och mapp, utan hänsyn till skiftläge och accenter.
    static func search(_ items: [LibraryItem], _ text: String) -> [LibraryItem] {
        let words = text.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return items }
        return items.filter { item in
            let haystack = [item.title, item.author, item.book.folder ?? "", item.book.title]
                .joined(separator: " ")
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "sv_SE"))
            return words.allSatisfy { word in
                haystack.contains(word.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                               locale: Locale(identifier: "sv_SE")))
            }
        }
    }

    /// Fortsätt läsa (B2): boken som lästes senast och inte är utläst.
    static func continueReading(_ items: [LibraryItem]) -> LibraryItem? {
        items.filter { $0.lastRead > 0 && !$0.finished }.max { $0.lastRead < $1.lastRead }
    }

    /// "Sida 45 av 312, 267 sidor kvar", eller "28 %, 4 sidor kvar i kapitlet". Aldrig tid (Edvins beslut).
    static func statusLine(_ item: LibraryItem) -> String {
        let percent = "\(Int((item.progress * 100).rounded(.down))) %"
        if item.pages > 0, item.page > 0 {
            let left = max(item.pages - item.page, 0)
            let leftText = left == 0 ? "sista sidan" : left == 1 ? "1 sida kvar" : "\(left) sidor kvar"
            return "Sida \(item.page) av \(item.pages), \(leftText)"
        }
        if item.chapterLeft >= 0 {
            let leftText = item.chapterLeft == 0 ? "sista sidan i kapitlet"
                : item.chapterLeft == 1 ? "1 sida kvar i kapitlet" : "\(item.chapterLeft) sidor kvar i kapitlet"
            return "\(percent), \(leftText)"
        }
        return "\(percent) läst"
    }

    /// Antalet kolumner i rutnätet: två på iPhone, tre i stående och fyra till fem i liggande på iPad.
    static func columns(width: CGFloat, landscape: Bool) -> Int {
        if width < 500 { return 2 }
        if !landscape { return width >= 980 ? 4 : 3 }
        return width >= 900 ? 5 : 4
    }
}
