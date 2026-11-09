import Foundation

/// Var en bok ligger (B4): i appens mapp Böcker (bara på iPaden) eller i den valda mappen i iCloud Drive
/// (på alla enheter). Böcker i iCloud-mappen har sökvägen "/iCloud/<sökväg i mappen>" i bokregistret. En sökväg i
/// Böcker börjar aldrig med snedstreck, så de två går aldrig ihop, och registrets matchning (G3) fungerar som förut.
enum BookPlace {

    static let cloudPrefix = "/iCloud/"

    /// Filtyperna som räknas som böcker i iCloud-mappen. Annat i mappen visas inte.
    static let bookExtensions: Set<String> = ["pdf", "epub", "txt", "md", "markdown", "rtf", "html", "htm"]

    static func isCloud(_ path: String) -> Bool {
        path.hasPrefix(cloudPrefix)
    }

    /// Sökvägen inne i sin mapp, utan "/iCloud/".
    static func relative(_ path: String) -> String {
        isCloud(path) ? String(path.dropFirst(cloudPrefix.count)) : path
    }

    /// Sökvägen för en fil med `relative` i iCloud-mappen eller i Böcker.
    static func path(_ relative: String, cloud: Bool) -> String {
        cloud ? cloudPrefix + relative : relative
    }

    /// Tar bort en fil genom filkoordineringen (iCloud Drive).
    static func removeCoordinated(_ url: URL) throws {
        var coordinationError: NSError?
        var removeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [.forDeleting],
                                                         error: &coordinationError) { target in
            do {
                try FileManager.default.removeItem(at: target)
            } catch {
                removeError = error
            }
        }
        if let error = coordinationError ?? removeError {
            throw error
        }
    }
}

/// Flytten av en bok mellan Böcker och iCloud-mappen (B4). Kopian görs först och kontrolleras mot bokens
/// kontrollsumma, och originalet tas bort först sedan. Bokens id i registret följer med, och därmed
/// markeringar, bokmärken, läsposition och sparade ord (G3).
@MainActor
final class BookMover {

    static let shared = BookMover()

    /// Böckerna som flyttas just nu (namnen), till raden i biblioteket.
    private(set) var moving: [String: String] = [:]
    /// Anropas när en flytt börjar eller är klar.
    var onChange: (() -> Void)?

    enum Failure: LocalizedError {
        case noFolder
        case noRegistry
        case busy
        case mismatch
        case copy(String)
        case removeOriginal(String)

        var errorDescription: String? {
            switch self {
            case .noFolder:
                return "Ingen iCloud-mapp går att nå. Välj mappen under Inställningar, Synk."
            case .noRegistry:
                return "Bokregistret gick inte att öppna, så boken flyttas inte."
            case .busy:
                return "Boken flyttas redan."
            case .mismatch:
                return "Kopian blev inte likadan som boken (kontrollsumman stämmer inte). Boken ligger kvar där den var."
            case .copy(let message):
                return "Boken kunde inte kopieras: \(message) Den ligger kvar där den var."
            case .removeOriginal(let message):
                return "Kopian är klar, men originalet kunde inte tas bort: \(message) Boken ligger kvar där den var."
            }
        }
    }

    private init() {}

    /// Flyttar boken till iCloud-mappen (`toCloud`) eller till Böcker. `completion` får boken på sin nya plats.
    func move(_ book: Book, toCloud: Bool, completion: @escaping (Result<Book, Error>) -> Void) {
        guard BookPlace.isCloud(book.path) != toCloud else {
            completion(.success(book))
            return
        }
        guard BookRegistry.shared.isAvailable, let record = BookRegistry.shared.record(id: book.id) else {
            completion(.failure(Failure.noRegistry))
            return
        }
        guard moving[book.id] == nil else {
            completion(.failure(Failure.busy))
            return
        }
        let destinationRoot: URL
        if toCloud {
            guard let cloud = SyncFolder.shared.url else {
                completion(.failure(Failure.noFolder))
                return
            }
            destinationRoot = cloud
        } else {
            destinationRoot = LibraryStore.shared.booksDirectory
        }
        let relative = BookPlace.relative(book.path)
        let source = book.url
        let expected = record.sha256
        moving[book.id] = book.url.lastPathComponent
        onChange?()
        AppLog.shared.write("Flyttar \(book.path) till \(toCloud ? "iCloud-mappen" : "Böcker")")

        Task { @MainActor [weak self] in
            let outcome: Result<Book, Error>
            do {
                let prepared = try await Self.copyAndVerify(source: source, relative: relative, root: destinationRoot,
                                                            expected: expected)
                outcome = .success(try Self.finish(book: book, record: record, prepared: prepared, toCloud: toCloud))
            } catch {
                AppLog.shared.write("Flytten av \(book.path) avbröts: \(error.localizedDescription)")
                outcome = .failure(error)
            }
            self?.moving[book.id] = nil
            self?.onChange?()
            completion(outcome)
        }
    }

    /// En kontrollerad kopia under ett dolt namn bredvid den slutliga platsen.
    private struct Prepared {
        let temporary: URL
        let destination: URL
        let hash: String
    }

    /// Kopierar boken till ett dolt namn i målmappen (så att biblioteket inte ser den halvfärdig), läser kopian
    /// från disken igen och jämför kontrollsumman med bokens. Körs i bakgrunden.
    private static func copyAndVerify(source: URL, relative: String, root: URL, expected: String) async throws -> Prepared {
        try await Task.detached(priority: .userInitiated) { () throws -> Prepared in
            let manager = FileManager.default
            let wanted = root.appendingPathComponent(relative)
            let directory = wanted.deletingLastPathComponent()
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = manager.fileExists(atPath: wanted.path)
                ? BookImporter.freeName(for: wanted.lastPathComponent, in: directory) : wanted
            let temporary = directory.appendingPathComponent(".sensus-flytt-\(UUID().uuidString.prefix(8))-"
                                                             + destination.lastPathComponent)
            var modified: Date?
            var coordinationError: NSError?
            var copyResult: Result<String, Error> = .failure(Failure.copy("okänt fel"))
            // Läsningen hämtar filen från iCloud först om den inte är hämtad.
            NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: source, options: [],
                                                             error: &coordinationError) { readable in
                modified = (try? readable.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                copyResult = Result { try BookImporter.copyAndHash(from: readable, to: temporary) { _ in } }
            }
            do {
                if let error = coordinationError {
                    throw Failure.copy(error.localizedDescription)
                }
                let streamed = try copyResult.get()
                // Ändringstiden följer med, så att sidbilderna på disken (G5) och registrets matchning stämmer.
                if let modified = modified {
                    try? manager.setAttributes([.modificationDate: modified], ofItemAtPath: temporary.path)
                }
                let reread = try BookImporter.hashFile(temporary) { _ in }
                let target = expected.isEmpty ? streamed : expected
                guard reread == streamed, reread == target else {
                    throw Failure.mismatch
                }
                return Prepared(temporary: temporary, destination: destination, hash: reread)
            } catch {
                try? manager.removeItem(at: temporary)
                if error is Failure {
                    throw error
                }
                throw Failure.copy(error.localizedDescription)
            }
        }.value
    }

    /// Byter den kontrollerade kopians namn till det slutliga, tar bort originalet och flyttar bokens rad i
    /// registret. Allt på huvudtråden i ett svep, så att biblioteket aldrig läser in mittemellan. Går originalet
    /// inte att ta bort tas kopian bort och boken ligger kvar. Avbryts appen mitt i känns boken igen på
    /// kontrollsumman nästa gång (G3).
    private static func finish(book: Book, record: BookRecord, prepared: Prepared, toCloud: Bool) throws -> Book {
        let manager = FileManager.default
        do {
            try manager.moveItem(at: prepared.temporary, to: prepared.destination)
        } catch {
            try? manager.removeItem(at: prepared.temporary)
            throw Failure.copy(error.localizedDescription)
        }
        do {
            if BookPlace.isCloud(book.path) {
                try BookPlace.removeCoordinated(book.url)
            } else {
                try manager.removeItem(at: book.url)
            }
        } catch {
            if toCloud {
                try? BookPlace.removeCoordinated(prepared.destination)
            } else {
                try? manager.removeItem(at: prepared.destination)
            }
            throw Failure.removeOriginal(error.localizedDescription)
        }
        let root = toCloud ? SyncFolder.shared.url : LibraryStore.shared.booksDirectory
        let base = (root ?? prepared.destination.deletingLastPathComponent())
            .resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let components = prepared.destination.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let inside = components.count > base.count ? components.dropFirst(base.count).joined(separator: "/")
            : prepared.destination.lastPathComponent
        let values = try? prepared.destination.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        var moved = record
        moved.file = BookPlace.path(inside, cloud: toCloud)
        moved.title = (prepared.destination.lastPathComponent as NSString).deletingPathExtension
        moved.sha256 = prepared.hash
        moved.size = values?.fileSize ?? record.size
        moved.modified = Int(values?.contentModificationDate?.timeIntervalSince1970 ?? Double(record.modified))
        moved.missing = false
        BookRegistry.shared.save([moved])
        AppLog.shared.write("Flyttad: \(book.path) heter nu \(moved.file), kontrollsumman stämmer")
        moveQuestionFile(from: book.url, to: prepared.destination)
        return Book(url: prepared.destination, id: book.id, path: moved.file)
    }

    /// Frågefilen bredvid boken (K6, `Bok.pdf.fragor.json` eller `Bok.fragor.json`) följer med till den nya
    /// platsen och får bokens nya namn. Den kopieras först och tas bort först när kopian finns. Går det inte står
    /// det i loggen, och frågefilen ligger kvar där den var.
    private static func moveQuestionFile(from source: URL, to destination: URL) {
        let manager = FileManager.default
        let folder = source.deletingLastPathComponent()
        let names = [source.lastPathComponent + BookQuestionFile.suffix,
                     source.deletingPathExtension().lastPathComponent + BookQuestionFile.suffix]
        guard let original = names.map({ folder.appendingPathComponent($0) })
            .first(where: { manager.fileExists(atPath: $0.path) }) else { return }
        let target = destination.deletingLastPathComponent()
            .appendingPathComponent(destination.lastPathComponent + BookQuestionFile.suffix)
        guard !manager.fileExists(atPath: target.path) else {
            AppLog.shared.write("Frågefilen flyttades inte: \(target.lastPathComponent) finns redan")
            return
        }
        do {
            let data = try Data(contentsOf: original)
            try data.write(to: target, options: .atomic)
            guard (try? Data(contentsOf: target)) == data else {
                try? manager.removeItem(at: target)
                AppLog.shared.write("Frågefilen flyttades inte: kopian blev inte likadan")
                return
            }
            try BookPlace.removeCoordinated(original)
        } catch {
            AppLog.shared.write("Frågefilen flyttades inte helt: \(error.localizedDescription)")
        }
    }
}
