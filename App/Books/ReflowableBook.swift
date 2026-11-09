import CryptoKit
import Foundation

/// Fel när en EPUB eller textfil öppnas. Texterna visas för användaren.
enum BookError: LocalizedError {
    case notAnArchive
    case damagedArchive
    case unsupportedArchive
    case notAnEPUB
    case drm
    case empty
    case unreadableText

    var errorDescription: String? {
        switch self {
        case .notAnArchive:
            return "Filen är inte en EPUB. En EPUB är en zipfil, och den här gick inte att packa upp."
        case .damagedArchive:
            return "Filen verkar vara skadad. Prova att lägga in den igen."
        case .unsupportedArchive:
            return "Filen är packad på ett sätt som appen inte kan läsa än."
        case .notAnEPUB:
            return "Filen saknar beskrivningen av innehållet som alla EPUB-filer ska ha (container.xml och OPF)."
        case .drm:
            return "Boken är kopieringsskyddad (DRM). Sådana böcker går bara att läsa i appen där de köptes."
        case .empty:
            return "Boken innehåller inga kapitel att visa."
        case .unreadableText:
            return "Texten i filen gick inte att läsa."
        }
    }
}

/// Var man läser i en EPUB eller textfil: kapitlet och hur långt in i kapitlet (0 till 1).
/// Andelen överlever byte av typsnitt, storlek och skärmläge.
struct ReflowLocation: Equatable {
    var chapter: Int
    var progression: Double
}

/// En EPUB eller textfil som är uppackad och klar att visas: kapitlen i läsordning och innehållsförteckningen.
struct ReflowableBook {

    struct Chapter {
        let url: URL
        /// Storleken i byte. Används för att räkna ut hur långt in i boken man är.
        let weight: Int
        var title: String?
    }

    struct TOCEntry {
        let title: String
        let level: Int
        let chapter: Int
        let fragment: String?
    }

    let title: String
    /// Namnet på bokens mapp i cachen. Ändras när filen ändras.
    let identifier: String
    /// Mappen som webbvyn får läsa i.
    let rootDirectory: URL
    let chapters: [Chapter]
    let toc: [TOCEntry]
    let isPlainText: Bool
    private let chapterByPath: [String: Int]

    init(title: String,
         identifier: String,
         rootDirectory: URL,
         chapters: [Chapter],
         toc: [TOCEntry],
         isPlainText: Bool) {
        self.title = title
        self.identifier = identifier
        self.rootDirectory = rootDirectory
        self.chapters = chapters
        self.toc = toc
        self.isPlainText = isPlainText
        var byPath: [String: Int] = [:]
        for (index, chapter) in chapters.enumerated() where byPath[Self.pathKey(for: chapter.url)] == nil {
            byPath[Self.pathKey(for: chapter.url)] = index
        }
        self.chapterByPath = byPath
    }

    static func pathKey(for url: URL) -> String {
        URL(fileURLWithPath: url.path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Kapitlet som en länk pekar på (utan ankare), om det finns i boken.
    func chapterIndex(for url: URL) -> Int? {
        guard url.isFileURL else { return nil }
        return chapterByPath[Self.pathKey(for: url)]
    }

    var totalWeight: Int {
        max(chapters.reduce(0) { $0 + $1.weight }, 1)
    }

    /// Andelen av boken (0 till 1) vid en plats.
    func fraction(at location: ReflowLocation) -> Double {
        guard location.chapter >= 0, location.chapter < chapters.count else { return 0 }
        let before = chapters.prefix(location.chapter).reduce(0) { $0 + $1.weight }
        let inside = Double(chapters[location.chapter].weight) * min(max(location.progression, 0), 1)
        return (Double(before) + inside) / Double(totalWeight)
    }

    /// Platsen vid en andel av boken, för reglaget.
    func location(atFraction fraction: Double) -> ReflowLocation {
        let target = min(max(fraction, 0), 1) * Double(totalWeight)
        var passed = 0.0
        for (index, chapter) in chapters.enumerated() {
            let weight = Double(chapter.weight)
            if passed + weight >= target || index == chapters.count - 1 {
                let progression = weight > 0 ? (target - passed) / weight : 0
                return ReflowLocation(chapter: index, progression: min(max(progression, 0), 0.999))
            }
            passed += weight
        }
        return ReflowLocation(chapter: 0, progression: 0)
    }

    /// Kapitlets namn i innehållsförteckningen, eller den närmaste rubriken före.
    func title(ofChapter chapter: Int) -> String? {
        if chapter >= 0, chapter < chapters.count, let title = chapters[chapter].title {
            return title
        }
        return toc.last { $0.chapter <= chapter }?.title
    }
}

/// Packar upp eller gör om en bok i appens cache. Körs i bakgrunden.
enum ReflowableBookLoader {

    /// Höj när uppackningen eller omvandlingen ändras, så att gamla uppackade böcker görs om.
    static let formatVersion = 1

    static var cacheRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Uppackade böcker", isDirectory: true)
    }

    static func load(_ book: Book) throws -> ReflowableBook {
        let identifier = self.identifier(for: book)
        let directory = cacheRoot.appendingPathComponent(identifier, isDirectory: true)
        switch book.kind {
        case .epub:
            return try EPUBBookReader.open(book, directory: directory, identifier: identifier)
        default:
            return try TextBookConverter.open(book, directory: directory, identifier: identifier)
        }
    }

    /// Bokens namn i cachen: filnamnet plus en kort kontrollsumma av namn, storlek och ändringsdatum.
    static func identifier(for book: Book) -> String {
        let values = try? book.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? 0
        let date = Int(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        var source = "\(book.url.lastPathComponent)|\(size)|\(date)|\(formatVersion)"
        // P4: en txt-fil bredvid sin PDF görs om sida för sida, så att gamla sidantal och kapitel inte används.
        if PDFTextCompanion.pdfURL(forText: book.url) != nil {
            source += "|sidor"
        }
        let digest = SHA256.hash(data: Data(source.utf8))
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return safeName(book.title) + "-" + hex
    }

    /// Tar bort uppackade kopior och sparade sidantal för en bok som tas bort.
    static func removeCaches(for book: Book) {
        let prefix = safeName(book.title) + "-"
        let fileManager = FileManager.default
        let folders = [cacheRoot, PageCountStore.directory]
        for folder in folders {
            let items = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
            for item in items where item.hasPrefix(prefix) {
                try? fileManager.removeItem(at: folder.appendingPathComponent(item))
            }
        }
    }

    private static func safeName(_ title: String) -> String {
        let cleaned = title.unicodeScalars.map { scalar -> String in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "_"
        }.joined()
        return String(cleaned.prefix(40))
    }
}

/// Sidantal per kapitel, sparade per layout (typsnitt, storlek, skärmstorlek), så att hela bokens
/// sidnummer kan visas när varje kapitel har mätts en gång.
struct PageCountStore {

    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sidantal", isDirectory: true)
    }

    private let url: URL
    private var table: [String: [String: Int]] = [:]

    init(identifier: String) {
        let directory = Self.directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent(identifier + ".json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: [String: Int]].self, from: data) {
            table = decoded
        }
    }

    func count(chapter: Int, key: String) -> Int? {
        table[key]?[String(chapter)]
    }

    mutating func set(_ count: Int, chapter: Int, key: String) {
        guard table[key]?[String(chapter)] != count else { return }
        if table[key] == nil, table.count >= 8 {
            table.removeAll()
        }
        table[key, default: [:]][String(chapter)] = count
        if let data = try? JSONEncoder().encode(table) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
