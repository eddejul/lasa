import Foundation

/// En fil i biblioteket.
struct Book: Equatable {

    enum Kind {
        case pdf, epub, text, other
    }

    let url: URL
    /// Bokens id i bokregistret (G3). Markeringar, bokmärken, läsposition och sparade ord hänger på det,
    /// så att de följer med när filen byter namn eller flyttas.
    let id: String
    /// Sökvägen i Böcker, till exempel "RETA30/Bok.pdf".
    let path: String

    var title: String {
        url.deletingPathExtension().lastPathComponent
    }

    /// Undermappen i Böcker, eller nil för böcker direkt i Böcker.
    var folder: String? {
        let parts = path.split(separator: "/")
        return parts.count > 1 ? parts.dropLast().joined(separator: "/") : nil
    }

    var kind: Kind {
        switch url.pathExtension.lowercased() {
        case "pdf":
            return .pdf
        case "epub":
            return .epub
        case "txt", "md", "markdown", "rtf", "html", "htm":
            return .text
        default:
            return .other
        }
    }

    var kindLabel: String {
        switch kind {
        case .pdf: return "PDF"
        case .epub: return "EPUB"
        case .text: return "Text"
        case .other: return url.pathExtension.uppercased()
        }
    }

    var symbolName: String {
        switch kind {
        case .pdf: return "doc.richtext"
        case .epub: return "book.closed"
        case .text: return "doc.plaintext"
        case .other: return "doc"
        }
    }
}

/// Böckerna ligger i appens mapp "Böcker", också i undermappar.
/// Den syns i Filer-appen under På min iPad, Läsa, så filer kan också läggas in därifrån.
/// Läspositionen sparas under bokens id (G3), inte under filnamnet.
final class LibraryStore {

    static let shared = LibraryStore()

    let booksDirectory: URL
    private let defaults = UserDefaults.standard

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        booksDirectory = documents.appendingPathComponent("Böcker", isDirectory: true)
        try? FileManager.default.createDirectory(at: booksDirectory, withIntermediateDirectories: true)
    }

    /// Alla filer i Böcker, också i undermappar (G3), med sökvägen i Böcker som nyckel.
    func listFiles() -> (files: [BookFile], urls: [String: URL]) {
        let base = booksDirectory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: booksDirectory,
                                                              includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return ([], [:])
        }
        var files: [BookFile] = []
        var urls: [String: URL] = [:]
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory != true else { continue }
            let components = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            guard components.count > base.count, Array(components.prefix(base.count)) == base else { continue }
            let path = components.dropFirst(base.count).joined(separator: "/")
            let file = BookFile(path: path,
                                size: values?.fileSize ?? 0,
                                modified: Int(values?.contentModificationDate?.timeIntervalSince1970 ?? 0))
            files.append(file)
            urls[path] = url
        }
        return (files, urls)
    }

    /// Böckerna som känns igen direkt, och filer som behöver sin kontrollsumma först (G3).
    func scan() -> (books: [Book], pending: [BookFile], urls: [String: URL]) {
        let listed = listFiles()
        let result = BookRegistry.shared.scan(files: listed.files, urls: listed.urls)
        let books = result.books.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return (books, result.pending, listed.urls)
    }

    func allBooks() -> [Book] {
        scan().books
    }

    /// Boken för en fil i Böcker, om den är känd i registret.
    func book(at url: URL) -> Book? {
        let target = url.resolvingSymlinksInPath().standardizedFileURL.path
        return allBooks().first { $0.url.resolvingSymlinksInPath().standardizedFileURL.path == target }
    }

    /// Lägger in en fil som ligger i Böcker i registret, med kontrollsumman räknad (vid import, G10).
    /// `asNew`: filen blir en ny bok även om den ersatt en annan med samma namn (Ersätt och börja om).
    func registerFile(at url: URL, hash: String, asNew: Bool = false) -> Book? {
        let listed = listFiles()
        let target = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard let match = listed.urls.first(where: {
            $0.value.resolvingSymlinksInPath().standardizedFileURL.path == target
        }), let file = listed.files.first(where: { $0.path == match.key }) else {
            return nil
        }
        let id = asNew ? BookRegistry.shared.registerNew(file, hash: hash) : BookRegistry.shared.register(file, hash: hash)
        return Book(url: match.value, id: id, path: match.key)
    }

    func delete(_ book: Book) throws {
        try FileManager.default.removeItem(at: book.url)
        defaults.removeObject(forKey: positionKey(for: book))
        defaults.removeObject(forKey: locationKey(for: book))
        ReflowableBookLoader.removeCaches(for: book)
        // Bokens rad och markeringar finns kvar, så att de kommer tillbaka om samma fil läggs in igen.
        BookRegistry.shared.markMissing(id: book.id)
    }

    // MARK: Läsposition

    func savedPageIndex(for book: Book) -> Int {
        defaults.integer(forKey: positionKey(for: book))
    }

    func savePageIndex(_ index: Int, for book: Book) {
        defaults.set(index, forKey: positionKey(for: book))
        markPositionChanged(for: book)
    }

    private func positionKey(for book: Book) -> String {
        "bookPosition.\(book.id)"
    }

    // MARK: Läsposition i EPUB och textfiler

    /// Kapitel och andel av kapitlet, så att platsen överlever byte av typsnitt och storlek.
    func savedLocation(for book: Book) -> ReflowLocation? {
        guard let text = defaults.string(forKey: locationKey(for: book)) else { return nil }
        let parts = text.split(separator: "|")
        guard parts.count == 2, let chapter = Int(parts[0]), let progression = Double(parts[1]) else { return nil }
        return ReflowLocation(chapter: chapter, progression: progression)
    }

    func saveLocation(_ location: ReflowLocation, for book: Book) {
        defaults.set("\(location.chapter)|\(location.progression)", forKey: locationKey(for: book))
        markPositionChanged(for: book)
    }

    // MARK: Synk av läspositionen (fas 6)

    /// När läspositionen senast ändrades på den här enheten, eller kom från synken.
    func positionDate(for book: Book) -> Date? {
        let value = defaults.double(forKey: positionDateKey(for: book))
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }

    /// En läsposition från en annan enhet. Tiden följer med, så att den inte skickas tillbaka som ny.
    func applySyncedPosition(section: Int, progression: Double, date: Date, for book: Book) {
        if book.kind == .pdf {
            defaults.set(section, forKey: positionKey(for: book))
        } else {
            defaults.set("\(section)|\(progression)", forKey: locationKey(for: book))
        }
        defaults.set(date.timeIntervalSince1970, forKey: positionDateKey(for: book))
    }

    private func markPositionChanged(for book: Book) {
        defaults.set(Date().timeIntervalSince1970, forKey: positionDateKey(for: book))
    }

    private func positionDateKey(for book: Book) -> String {
        "bookPositionDate.\(book.id)"
    }

    private func locationKey(for book: Book) -> String {
        "bookLocation.\(book.id)"
    }
}
