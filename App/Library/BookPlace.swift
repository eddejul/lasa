import Foundation

/// Var en bok ligger (B4): i appens mapp Böcker (bara på iPaden) eller i den valda mappen i iCloud Drive
/// (på alla enheter). Böcker i iCloud-mappen har sökvägen "/iCloud/<sökväg i mappen>" i bokregistret. En sökväg i
/// Böcker börjar aldrig med snedstreck, så de två går aldrig ihop, och registrets matchning (G3) fungerar som förut.
enum BookPlace {

    static let cloudPrefix = "/iCloud/"

    /// Början på namnet för kopian under en flytt (dold). Kvarlämnade kopior tas bort efter en timme (L5).
    static let temporaryPrefix = ".sensus-flytt-"

    /// Filtyperna som räknas som böcker i iCloud-mappen. Annat i mappen visas inte.
    static let bookExtensions: Set<String> = ["pdf", "epub", "txt", "md", "markdown", "rtf", "html", "htm"]

    static func isCloud(_ path: String) -> Bool {
        path.hasPrefix(cloudPrefix)
    }

    /// Platshållaren för en fil i iCloud Drive som inte är hämtad (iOS 15 och 16): ".Bok.pdf.icloud".
    static func placeholder(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
    }

    /// Sant om namnet är upptaget: filen finns, eller en fil med samma namn finns i iCloud men är inte hämtad än
    /// (granskning 6, M3). Då får en kopia aldrig det namnet.
    static func isNameTaken(_ url: URL) -> Bool {
        let manager = FileManager.default
        return manager.fileExists(atPath: url.path) || manager.fileExists(atPath: placeholder(for: url).path)
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
        case upload(String)

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
            case .upload(let message):
                return "iCloud tog inte emot boken (\(message)). Kontrollera att det finns plats i iCloud. Boken ligger "
                    + "kvar där den var."
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
        // M2: samma bok kan redan ligga på den nya platsen med samma namn (den visas då inte i biblioteket). Den
        // används i stället för en kopia, om ingen annan bok i registret har den platsen.
        let target = BookPlace.path(relative, cloud: toCloud)
        let mayReuse = !BookRegistry.shared.records().contains { $0.file == target && $0.id != book.id && !$0.missing }
        moving[book.id] = book.url.lastPathComponent
        onChange?()
        AppLog.shared.write("Flyttar \(book.path) till \(toCloud ? "iCloud-mappen" : "Böcker")")

        Task { @MainActor [weak self] in
            let outcome: Result<Book, Error>
            do {
                let prepared = try await Self.copyAndVerify(source: source, relative: relative, root: destinationRoot,
                                                            expected: expected, mayReuse: mayReuse)
                let destination = try Self.place(prepared)
                if toCloud {
                    try await Self.waitForUpload(destination, created: prepared.temporary != nil)
                }
                outcome = .success(try Self.finish(book: book, record: record, destination: destination,
                                                   hash: prepared.hash, toCloud: toCloud,
                                                   created: prepared.temporary != nil))
            } catch {
                AppLog.shared.write("Flytten av \(book.path) avbröts: \(error.localizedDescription)")
                outcome = .failure(error)
            }
            self?.moving[book.id] = nil
            self?.onChange?()
            completion(outcome)
        }
    }

    /// En kontrollerad kopia under ett dolt namn bredvid den slutliga platsen. Utan `temporary` ligger samma bok
    /// redan på `destination` (M2), och ingen kopia behövs.
    private struct Prepared {
        let temporary: URL?
        let destination: URL
        /// Namnet boken skulle få, för ett nytt ledigt namn om det blir upptaget under tiden.
        let wantedName: String
        let hash: String
    }

    /// Kopierar boken till ett dolt namn i målmappen (så att biblioteket inte ser den halvfärdig), läser kopian
    /// från disken igen och jämför kontrollsumman med bokens. Körs i bakgrunden. Ett namn räknas som upptaget
    /// också när en fil med det namnet finns i iCloud men inte är hämtad (M3), och då får kopian ett nytt namn.
    private static func copyAndVerify(source: URL, relative: String, root: URL, expected: String,
                                      mayReuse: Bool) async throws -> Prepared {
        try await Task.detached(priority: .userInitiated) { () throws -> Prepared in
            let manager = FileManager.default
            let wanted = root.appendingPathComponent(relative)
            let directory = wanted.deletingLastPathComponent()
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            if mayReuse, !expected.isEmpty, manager.fileExists(atPath: wanted.path), SyncFiles.isDownloaded(wanted),
               let size = (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
               (try? wanted.resourceValues(forKeys: [.fileSizeKey]))?.fileSize == size,
               let existing = try? BookImporter.hashFile(wanted, progress: { _ in }), existing == expected {
                return Prepared(temporary: nil, destination: wanted, wantedName: wanted.lastPathComponent,
                                hash: existing)
            }
            let destination = BookPlace.isNameTaken(wanted)
                ? BookImporter.freeName(for: wanted.lastPathComponent, in: directory) : wanted
            let temporary = directory.appendingPathComponent(BookPlace.temporaryPrefix + "\(UUID().uuidString.prefix(8))-"
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
                return Prepared(temporary: temporary, destination: destination, wantedName: wanted.lastPathComponent,
                                hash: reread)
            } catch {
                try? manager.removeItem(at: temporary)
                if error is Failure {
                    throw error
                }
                throw Failure.copy(error.localizedDescription)
            }
        }.value
    }

    /// Byter den kontrollerade kopians namn till det slutliga, genom filkoordineringen (M3). Har namnet blivit
    /// upptaget under tiden (en fil från en annan enhet, också en som inte är hämtad) väljs ett nytt ledigt namn.
    /// Inget skrivs över: `moveItem` ersätter aldrig en fil som finns. Ger den slutliga platsen.
    private static func place(_ prepared: Prepared) throws -> URL {
        guard let temporary = prepared.temporary else { return prepared.destination }
        let manager = FileManager.default
        var destination = prepared.destination
        for _ in 0..<3 {
            var coordinationError: NSError?
            var moveError: Error?
            var taken = false
            var placed: URL?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: destination, options: [.forReplacing],
                                                             error: &coordinationError) { target in
                if BookPlace.isNameTaken(target) {
                    taken = true
                    return
                }
                do {
                    try manager.moveItem(at: temporary, to: target)
                    placed = target
                } catch {
                    moveError = error
                }
            }
            if let placed = placed {
                return placed
            }
            if taken, coordinationError == nil {
                AppLog.shared.write("Namnet \(destination.lastPathComponent) blev upptaget under flytten, ett nytt väljs")
                destination = BookImporter.freeName(for: prepared.wantedName, in: destination.deletingLastPathComponent())
                continue
            }
            try? manager.removeItem(at: temporary)
            throw Failure.copy((coordinationError ?? moveError).map { $0.localizedDescription } ?? "okänt fel")
        }
        try? manager.removeItem(at: temporary)
        throw Failure.copy("inget ledigt namn hittades.")
    }

    /// L10: väntar högst tolv sekunder på att iCloud tar emot boken. Ett uppladdningsfel (till exempel fullt iCloud)
    /// avbryter flytten: kopian tas bort (om den är ny) och originalet ligger kvar. Är boken inte uppladdad efter
    /// tolv sekunder fortsätter flytten, och det står i loggen.
    private static func waitForUpload(_ url: URL, created: Bool) async throws {
        let problem = await Task.detached(priority: .utility) { () -> String? in
            SyncFiles.uploadProblem(url, wait: 12)
        }.value
        guard let message = problem else { return }
        AppLog.shared.write("iCloud tog inte emot \(url.lastPathComponent): \(message)")
        if created {
            try? BookPlace.removeCoordinated(url)
        }
        throw Failure.upload(message)
    }

    /// Tar bort originalet och flyttar bokens rad i registret. Allt på huvudtråden i ett svep. Går originalet inte
    /// att ta bort tas kopian bort (om den är ny) och boken ligger kvar. Avbryts appen mitt i känns boken igen på
    /// kontrollsumman nästa gång (G3, M2).
    private static func finish(book: Book, record: BookRecord, destination: URL, hash: String, toCloud: Bool,
                               created: Bool) throws -> Book {
        let manager = FileManager.default
        do {
            if BookPlace.isCloud(book.path) {
                try BookPlace.removeCoordinated(book.url)
            } else {
                try manager.removeItem(at: book.url)
            }
        } catch {
            if created {
                if toCloud {
                    try? BookPlace.removeCoordinated(destination)
                } else {
                    try? manager.removeItem(at: destination)
                }
            }
            throw Failure.removeOriginal(error.localizedDescription)
        }
        let root = toCloud ? SyncFolder.shared.url : LibraryStore.shared.booksDirectory
        let base = (root ?? destination.deletingLastPathComponent())
            .resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let components = destination.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let inside = components.count > base.count ? components.dropFirst(base.count).joined(separator: "/")
            : destination.lastPathComponent
        let values = try? destination.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        var moved = record
        moved.file = BookPlace.path(inside, cloud: toCloud)
        moved.title = (destination.lastPathComponent as NSString).deletingPathExtension
        moved.sha256 = hash
        moved.size = values?.fileSize ?? record.size
        moved.modified = Int(values?.contentModificationDate?.timeIntervalSince1970 ?? Double(record.modified))
        moved.missing = false
        BookRegistry.shared.save([moved])
        // M1: biblioteket ser den nya platsen direkt, utan att vänta på nästa läsning av iCloud-mappen.
        if toCloud {
            LibraryStore.shared.noteCloudChange(added: BookFile(path: moved.file, size: moved.size, modified: moved.modified),
                                                url: destination)
        } else {
            LibraryStore.shared.noteCloudChange(removed: book.path)
        }
        AppLog.shared.write("Flyttad: \(book.path) heter nu \(moved.file), kontrollsumman stämmer"
                            + (created ? "" : " (samma bok fanns redan där)"))
        moveQuestionFile(from: book.url, to: destination)
        return Book(url: destination, id: book.id, path: moved.file)
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
        guard !BookPlace.isNameTaken(target) else {
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
