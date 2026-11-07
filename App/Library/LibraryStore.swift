import Foundation

/// En fil i biblioteket.
struct Book: Equatable {

    enum Kind {
        case pdf, epub, text, other
    }

    let url: URL

    var title: String {
        url.deletingPathExtension().lastPathComponent
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

/// Böckerna ligger i appens mapp "Böcker".
/// Den syns i Filer-appen under På min iPad, Läsa, så filer kan också läggas in därifrån.
final class LibraryStore {

    static let shared = LibraryStore()

    let booksDirectory: URL
    private let defaults = UserDefaults.standard

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        booksDirectory = documents.appendingPathComponent("Böcker", isDirectory: true)
        try? FileManager.default.createDirectory(at: booksDirectory, withIntermediateDirectories: true)
    }

    func allBooks() -> [Book] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: booksDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls
            .filter { url in
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                return !isDirectory
            }
            .map { Book(url: $0) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Kopierar in en fil i biblioteket. Finns en fil med samma namn ersätts den.
    @discardableResult
    func importFile(at source: URL) throws -> Book {
        let accessing = source.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                source.stopAccessingSecurityScopedResource()
            }
        }

        let destination = booksDirectory.appendingPathComponent(source.lastPathComponent)

        // Filen ligger redan i biblioteket, till exempel öppnad direkt från Filer-appen.
        let sourcePath = source.standardizedFileURL.resolvingSymlinksInPath().path
        let destinationPath = destination.standardizedFileURL.resolvingSymlinksInPath().path
        if sourcePath == destinationPath {
            return Book(url: destination)
        }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
        return Book(url: destination)
    }

    func delete(_ book: Book) throws {
        try FileManager.default.removeItem(at: book.url)
        defaults.removeObject(forKey: positionKey(for: book))
        defaults.removeObject(forKey: locationKey(for: book))
        ReflowableBookLoader.removeCaches(for: book)
    }

    // MARK: Läsposition

    func savedPageIndex(for book: Book) -> Int {
        defaults.integer(forKey: positionKey(for: book))
    }

    func savePageIndex(_ index: Int, for book: Book) {
        defaults.set(index, forKey: positionKey(for: book))
    }

    private func positionKey(for book: Book) -> String {
        "position.\(book.url.lastPathComponent)"
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
    }

    private func locationKey(for book: Book) -> String {
        "location.\(book.url.lastPathComponent)"
    }
}
