import CryptoKit
import UIKit

/// Import av böcker i bakgrunden (G10). Filen läses och flyttas eller kopieras på en egen tråd, med
/// förlopp i biblioteket, och kontrollsumman räknas i samma läsning. Filer i iCloud Drive hämtas ordentligt
/// genom `NSFileCoordinator` innan de läses. Ett upptaget namn ger frågan Ersätt eller Behåll båda (G3).
@MainActor
final class BookImporter {

    static let shared = BookImporter()

    /// En import som pågår, till raden i biblioteket.
    struct Job: Equatable {
        let id: UUID
        let name: String
        var fraction: Double
    }

    private(set) var jobs: [Job] = []
    /// Anropas när en import börjar, går framåt eller är klar.
    var onChange: (() -> Void)?

    private init() {}

    /// Lägger in filerna en i taget. `move` betyder att filen är en kopia som systemet redan gjort (från
    /// dokumentväljaren eller Inkorgen), så den flyttas i stället för att kopieras en gång till.
    /// `completion` får böckerna som lagts in (eller som redan fanns).
    func start(_ urls: [URL], move: Bool, presenter: UIViewController, completion: @escaping ([Book]) -> Void) {
        let items = urls.map { (url: $0, job: Job(id: UUID(), name: $0.lastPathComponent, fraction: 0)) }
        jobs.append(contentsOf: items.map { $0.job })
        onChange?()
        Task { @MainActor [weak self, weak presenter] in
            var books: [Book] = []
            var failed: [String] = []
            for item in items {
                guard let self = self else { return }
                do {
                    if let book = try await self.importOne(item.url, job: item.job.id, move: move, presenter: presenter) {
                        books.append(book)
                    }
                } catch {
                    AppLog.shared.write("Importen av \(item.url.lastPathComponent) misslyckades: \(error.localizedDescription)")
                    failed.append(item.url.lastPathComponent)
                }
                self.jobs.removeAll { $0.id == item.job.id }
                self.onChange?()
            }
            if !failed.isEmpty, let presenter = presenter {
                Self.showMessage(on: presenter, title: "Några filer kunde inte läggas till",
                                 message: failed.joined(separator: "\n"))
            }
            // Sökregistret (G11) byggs i bakgrunden för PDF:er. EPUB och text byggs när boken öppnas.
            books.forEach { SearchIndex.shared.prepare($0) }
            completion(books)
        }
    }

    // MARK: En fil

    private func importOne(_ source: URL, job: UUID, move: Bool, presenter: UIViewController?) async throws -> Book? {
        let library = LibraryStore.shared
        let booksPath = library.booksDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        let sourcePath = source.resolvingSymlinksInPath().standardizedFileURL.path
        // Filen ligger redan i Böcker, till exempel öppnad från Filer. Den kopieras inte.
        if sourcePath.hasPrefix(booksPath + "/") {
            if let book = library.scan().books.first(where: {
                $0.url.resolvingSymlinksInPath().standardizedFileURL.path == sourcePath
            }) {
                return book
            }
            let hash = try await Self.inBackground { try Self.hashFile(source) { _ in } }
            if let book = await resolveVersion(at: source, hash: hash, presenter: presenter) {
                return book
            }
            return library.registerFile(at: source, hash: hash)
        }

        let name = source.lastPathComponent
        let started = CACurrentMediaTime()
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("Import", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(name)
        defer {
            try? FileManager.default.removeItem(at: temporary.deletingLastPathComponent())
        }
        let hash = try await Self.inBackground { [weak self] in
            try Self.transfer(from: source, to: temporary, move: move) { fraction in
                Task { @MainActor in
                    self?.update(job, fraction: fraction)
                }
            }
        }
        let size = (try? temporary.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        AppLog.shared.write("Import av \(name): \(size / 1_048_576) MB på "
                            + "\(Int(((CACurrentMediaTime() - started) * 1000).rounded())) ms (\(move ? "flyttad" : "kopierad"))")

        // Samma innehåll finns redan: öppna den boken i stället för att lägga in en kopia.
        if let existing = BookRegistry.shared.presentBook(withHash: hash),
           let book = library.scan().books.first(where: { $0.id == existing.id }) {
            if let presenter = presenter {
                Self.showMessage(on: presenter, title: "Boken finns redan",
                                 message: "\(name) finns redan i biblioteket som \(book.path).")
            }
            return book
        }

        var destination = library.booksDirectory.appendingPathComponent(name)
        var replaceKeeping: Bool?
        if FileManager.default.fileExists(atPath: destination.path) {
            let choice = await ask(about: name, presenter: presenter)
            switch choice {
            case .cancel:
                return nil
            case .keepBoth:
                destination = Self.freeName(for: name, in: library.booksDirectory)
            case .replaceKeepingMarks:
                replaceKeeping = true
            case .replaceStartingOver:
                replaceKeeping = false
            }
        }
        if let keep = replaceKeeping {
            let old = library.scan().books.first { $0.path == name }
            // Granskningens fynd 7: bytet görs på en gång, och misslyckas det ligger den gamla filen kvar.
            // Granskning 2, N5: den nya filen kan i ovanliga fall få en annan adress, den som returneras gäller.
            let replaced = try FileManager.default.replaceItemAt(destination, withItemAt: temporary) ?? destination
            if !keep, let old = old {
                // Den gamla bokens rad och markeringar finns kvar, men den nya filen blir en ny bok.
                BookRegistry.shared.markMissing(id: old.id)
            }
            return library.registerFile(at: replaced, hash: hash, asNew: !keep)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        if let book = await resolveVersion(at: destination, hash: hash, presenter: presenter) {
            return book
        }
        return library.registerFile(at: destination, hash: hash)
    }

    /// Granskning 2, N2: liknar filen en bok vars fil saknas (en platshållare från gamla appen, en borttagen bok
    /// med samma namn, eller ett liknande namn) frågas Ny version av boken, i stället för att filen tyst tar över
    /// den bokens markeringar. Behåll ger filen bokens id, Nej gör den till en ny bok. Nil: ingen fråga.
    private func resolveVersion(at url: URL, hash: String, presenter: UIViewController?) async -> Book? {
        guard let file = LibraryStore.shared.bookFile(at: url),
              let question = BookRegistry.shared.importQuestion(for: file, hash: hash) else { return nil }
        let keep = await askVersion(question, presenter: presenter)
        AppLog.shared.write("Import av \(file.path) liknar \(question.record.file) (filen saknas): "
                            + (keep ? "behåller markeringarna" : "ny bok"))
        if keep {
            BookRegistry.shared.answer(question, keep: true)
            return LibraryStore.shared.book(at: url)
        }
        return LibraryStore.shared.registerFile(at: url, hash: hash, asNew: true)
    }

    private func askVersion(_ question: BookRegistry.VersionQuestion, presenter: UIViewController?) async -> Bool {
        if SelfTest.isActive, let answer = Self.selfTestKeepVersion {
            return answer
        }
        // Utan någon att fråga blir filen en ny bok: inget tas över tyst.
        guard let presenter = presenter else { return false }
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: "Ny version av boken", message: question.message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Behåll markeringarna", style: .default) { _ in
                continuation.resume(returning: true)
            })
            alert.addAction(UIAlertAction(title: "Nej, börja om", style: .default) { _ in
                continuation.resume(returning: false)
            })
            Self.topmost(from: presenter).present(alert, animated: true)
        }
    }

    /// Självtestet: svaret på frågan Ny version vid import, utan att trycka.
    static var selfTestKeepVersion: Bool?

    private func update(_ job: UUID, fraction: Double) {
        guard let index = jobs.firstIndex(where: { $0.id == job }) else { return }
        jobs[index].fraction = fraction
        onChange?()
    }

    // MARK: Upptaget namn

    enum Choice {
        case replaceKeepingMarks, replaceStartingOver, keepBoth, cancel
    }

    /// Det finns redan en bok med samma namn: Ersätt (med eller utan markeringarna) eller Behåll båda.
    private func ask(about name: String, presenter: UIViewController?) async -> Choice {
        guard let presenter = presenter else { return .keepBoth }
        if SelfTest.isActive, let answer = Self.selfTestAnswer {
            return answer
        }
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: "Det finns redan en bok som heter \(name)",
                                          message: "Ersätt den, eller behåll båda? Ersätter du den kan markeringar, "
                                            + "anteckningar och läsposition följa med till den nya filen.",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Ersätt och behåll markeringarna", style: .default) { _ in
                continuation.resume(returning: .replaceKeepingMarks)
            })
            alert.addAction(UIAlertAction(title: "Ersätt och börja om", style: .destructive) { _ in
                continuation.resume(returning: .replaceStartingOver)
            })
            alert.addAction(UIAlertAction(title: "Behåll båda", style: .default) { _ in
                continuation.resume(returning: .keepBoth)
            })
            alert.addAction(UIAlertAction(title: "Avbryt", style: .cancel) { _ in
                continuation.resume(returning: .cancel)
            })
            Self.topmost(from: presenter).present(alert, animated: true)
        }
    }

    /// Självtestet: svaret på frågan om ett upptaget namn, utan att trycka.
    static var selfTestAnswer: Choice?

    /// "Bok 2.pdf", "Bok 3.pdf" och så vidare: första lediga namnet.
    nonisolated static func freeName(for name: String, in directory: URL) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var number = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            let url = directory.appendingPathComponent(candidate)
            if !FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            number += 1
        }
    }

    private static func topmost(from controller: UIViewController) -> UIViewController {
        var top: UIViewController = controller.navigationController ?? controller
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    private static func showMessage(on presenter: UIViewController, title: String, message: String) {
        // Självtestet loggar i stället för att visa en ruta som ingen kan trycka bort.
        if SelfTest.isActive {
            SelfTest.log("Importen säger: \(title). \(message)")
            return
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        topmost(from: presenter).present(alert, animated: true)
    }

    // MARK: Filerna (bakgrunden)

    private static func inBackground<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            try work()
        }.value
    }

    /// Hämtar filen (iCloud Drive) genom filkoordinering, flyttar eller kopierar den till `destination` och
    /// räknar kontrollsumman i samma läsning. Körs i bakgrunden.
    nonisolated static func transfer(from source: URL, to destination: URL, move: Bool,
                                     progress: @escaping (Double) -> Void) throws -> String {
        let accessing = source.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                source.stopAccessingSecurityScopedResource()
            }
        }
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var result: Result<String, Error> = .failure(CocoaError(.fileReadUnknown))
        var coordinationError: NSError?
        // En fil i iCloud Drive som inte är nedladdad hämtas av systemet innan blocket körs.
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: source, options: [],
                                                         error: &coordinationError) { readable in
            result = Result {
                if move, (try? manager.moveItem(at: readable, to: destination)) != nil {
                    return try hashFile(destination, progress: progress)
                }
                return try copyAndHash(from: readable, to: destination, progress: progress)
            }
        }
        if let error = coordinationError {
            throw error
        }
        return try result.get()
    }

    /// Kopierar i bitar om en megabyte och räknar SHA-256 under tiden: filen läses en gång.
    nonisolated static func copyAndHash(from source: URL, to destination: URL,
                                        progress: (Double) -> Void) throws -> String {
        let manager = FileManager.default
        let total = max((try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0, 1)
        guard manager.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        defer {
            try? input.close()
            try? output.close()
        }
        var hasher = SHA256()
        var done = 0
        var reported = 0.0
        while true {
            let chunk = try autoreleasepool { () throws -> Data in
                try input.read(upToCount: 1 << 20) ?? Data()
            }
            if chunk.isEmpty {
                break
            }
            hasher.update(data: chunk)
            try output.write(contentsOf: chunk)
            done += chunk.count
            let fraction = Double(done) / Double(total)
            if fraction - reported >= 0.02 {
                reported = fraction
                progress(min(fraction, 1))
            }
        }
        progress(1)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 av en fil som redan ligger på plats, med förlopp.
    nonisolated static func hashFile(_ url: URL, progress: (Double) -> Void) throws -> String {
        let total = max((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0, 1)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var done = 0
        var reported = 0.0
        while true {
            let chunk = try autoreleasepool { () throws -> Data in
                try handle.read(upToCount: 1 << 20) ?? Data()
            }
            if chunk.isEmpty {
                break
            }
            hasher.update(data: chunk)
            done += chunk.count
            let fraction = Double(done) / Double(total)
            if fraction - reported >= 0.02 {
                reported = fraction
                progress(min(fraction, 1))
            }
        }
        progress(1)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
