import CryptoKit
import Foundation

/// Böckernas id i synken: SHA-256 av filens innehåll (gemener, hex). Samma fil får samma id på iPaden och
/// i Windows-appen, oavsett filnamn. Sedan G3 står kontrollsumman i bokregistret. Saknas den där räknas den
/// (en gång per fil, sparad med filens namn, storlek och ändringstid) och sparas i registret.
enum BookIdentity {

    private static let cacheKey = "bookIdentity.cache"

    /// Bokens id i registret till kontrollsumman. Filer som inte räknats förut räknas i bakgrunden.
    @MainActor
    static func ids(for books: [Book]) async -> [String: String] {
        var cache = UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: String] ?? [:]
        var result: [String: String] = [:]
        var missing: [(book: Book, signature: String)] = []
        for book in books {
            if let known = BookRegistry.shared.record(id: book.id)?.sha256, !known.isEmpty {
                result[book.id] = known
                continue
            }
            let signature = Self.signature(of: book)
            if let id = cache[signature] {
                result[book.id] = id
                let file = Self.sizeAndDate(of: book)
                BookRegistry.shared.setHash(id, for: book.id, size: file.size, modified: file.modified)
            } else {
                missing.append((book, signature))
            }
        }
        if !missing.isEmpty {
            let urls = missing.map { $0.book.url }
            let computed = await Task.detached(priority: .utility) { () -> [String?] in
                urls.map { BookIdentity.hash(of: $0) }
            }.value
            for (item, id) in zip(missing, computed) {
                guard let id = id else { continue }
                // Filen kan ha ersatts medan den räknades: då stämmer inte signaturen längre.
                guard Self.signature(of: item.book) == item.signature else { continue }
                cache[item.signature] = id
                result[item.book.id] = id
                let file = Self.sizeAndDate(of: item.book)
                BookRegistry.shared.setHash(id, for: item.book.id, size: file.size, modified: file.modified)
            }
            // Bara böcker som finns kvar sparas.
            let current = Set(books.map { Self.signature(of: $0) })
            cache = cache.filter { current.contains($0.key) }
            UserDefaults.standard.set(cache, forKey: cacheKey)
        }
        return result
    }

    private static func signature(of book: Book) -> String {
        let file = sizeAndDate(of: book)
        return "\(book.url.lastPathComponent)|\(file.size)|\(file.modified)"
    }

    /// Filens storlek och ändringstid i hela sekunder, som i bokregistret.
    private static func sizeAndDate(of book: Book) -> (size: Int, modified: Int) {
        // Läses på nytt varje gång (resourceValues sparar annars värdena i URL:en).
        var url = book.url
        url.removeAllCachedResourceValues()
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return (values?.fileSize ?? 0, Int(values?.contentModificationDate?.timeIntervalSince1970 ?? 0))
    }

    /// SHA-256 av filen, läst i bitar om en megabyte.
    static func hash(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty {
                break
            }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Tider i synken: ISO 8601 i UTC med millisekunder, som i synkfilerna (F1).
enum SyncTime {

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func string(_ seconds: Double) -> String {
        formatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    /// Läser en tid ur en synkfil. Mikrosekunder (som den gamla Supabase-synken skrev) kortas till millisekunder.
    static func seconds(_ value: Any?) -> Double? {
        guard var text = value as? String, !text.isEmpty else { return nil }
        if let dot = text.firstIndex(of: ".") {
            var end = text.index(after: dot)
            while end < text.endIndex, text[end].isNumber {
                end = text.index(after: end)
            }
            let digits = text[text.index(after: dot)..<end]
            let kept = String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            text = String(text[..<dot]) + "." + kept + String(text[end...])
        }
        let date = formatter.date(from: text) ?? plain.date(from: text)
        return date?.timeIntervalSince1970
    }

    static func milliseconds(_ seconds: Double) -> Int64 {
        Int64((seconds * 1000).rounded())
    }

    /// Sant om `a` är nyare än `b`, räknat i hela millisekunder. Allt är nyare än inget.
    static func newer(_ a: Double?, than b: Double?) -> Bool {
        guard let a = a else { return false }
        guard let b = b else { return true }
        return milliseconds(a) > milliseconds(b)
    }
}

/// Vad en synk gjorde.
struct SyncReport {
    var books = 0
    var pushed = 0
    var pulled = 0
    /// Andra enheters filer som lästes.
    var devices = 0
    /// Filer som hoppades över (inte hämtade, trasiga, från en nyare version).
    var skippedFiles = 0
    /// Rader från andra enheter för böcker som inte finns här. De sparas i den egna filen och kommer med när
    /// boken läggs in.
    var waiting = 0

    var summary: String {
        var parts = ["\(books) böcker", "\(pushed) ändringar sparade i den egna filen", "\(pulled) hämtade från "
                        + (devices == 1 ? "en annan enhet" : "\(devices) andra enheter")]
        if skippedFiles > 0 {
            parts.append(skippedFiles == 1 ? "en fil hoppades över" : "\(skippedFiles) filer hoppades över")
        }
        if waiting > 0 {
            parts.append("\(waiting) väntar på böcker som inte finns här")
        }
        return parts.joined(separator: ", ")
    }
}

/// En annan enhet som synkmappen har en fil från.
struct SyncPeer: Equatable {
    let device: SyncDevice
    let written: Date?
}

/// Synken (F1): läsposition, markeringar, bokmärken och sparade ord mellan iPaden och Windows-appen, via en
/// fil per enhet i mappen "Sensus synk" i den valda mappen i iCloud Drive (`SyncFolder`).
///
/// Varje enhet skriver sin egen fil, och ingen annan skriver i den. Filen är enhetens hela sammanslagna bild:
/// de egna raderna och allt den läst från de andra, också borttaget (`deleted`). Den nyaste ändringen vinner,
/// rad för rad (`SyncMerge`). En annan enhets fil kan aldrig ta bort något genom att något saknas i den, och en
/// fil som inte går att läsa hoppas över med en rad i loggen. Allt läses och jämförs varje gång.
@MainActor
final class SyncEngine {

    static let shared = SyncEngine()
    static let didFinish = Notification.Name("SyncEngineDidFinish")

    private(set) var isRunning = false
    private(set) var lastError: String?
    private(set) var lastReport: SyncReport?
    /// De andra enheterna i synkmappen vid senaste synken.
    private(set) var peers: [SyncPeer] = []
    /// Filer som hoppades över vid senaste synken, med skälet.
    private(set) var skippedFiles: [String] = []
    private var lastAttempt: Date?
    private static let lastSyncKey = "sync.last"
    /// Nyckeln för pausen efter en återställning. Den ligger i UserDefaults, så att en omstart inte startar
    /// synken igen (granskning 2, fynd 3).
    static let pausedKey = "sync.pausedAfterRestore"
    /// Den egna filen skrivs om när något ändrats, och annars högst var sjätte timme (så att de andra ser
    /// när enheten senast synkade).
    private static let heartbeat: Double = 6 * 3600

    /// Sant efter en återställning från säkerhetskopian, tills läsaren själv startar synken igen i
    /// Inställningar: annars tar synken tillbaka nyare rader från de andra enheterna och gör återställningen ogjord.
    var isPaused: Bool {
        UserDefaults.standard.bool(forKey: Self.pausedKey)
    }

    /// Sant när en synkmapp är vald.
    var isConfigured: Bool {
        SyncFolder.shared.isChosen
    }

    /// Pausar synken efter en återställning. Den står still tills `resume()`, också efter en omstart.
    func pauseAfterRestore() {
        UserDefaults.standard.set(true, forKey: Self.pausedKey)
        AppLog.shared.write("Synken pausad efter återställningen från säkerhetskopian")
        NotificationCenter.default.post(name: Self.didFinish, object: nil)
    }

    /// Starta synken igen (Inställningar).
    func resume() {
        UserDefaults.standard.removeObject(forKey: Self.pausedKey)
        AppLog.shared.write("Synken startad igen efter pausen")
    }

    /// Till självtestet: slår på synken igen.
    func resumeForSelfTest() {
        UserDefaults.standard.removeObject(forKey: Self.pausedKey)
    }

    struct PausedError: LocalizedError {
        var errorDescription: String? {
            "Synken är pausad efter återställningen från säkerhetskopian. Starta den igen under Inställningar, Synk."
        }
    }

    enum Failure: LocalizedError {
        case noFolder
        case folder(String)
        case database
        case newerFile

        var errorDescription: String? {
            switch self {
            case .noFolder:
                return "Ingen synkmapp är vald. Välj en mapp i iCloud Drive under Inställningar, Synk."
            case .folder(let message):
                return message
            case .database:
                return "Markeringarna eller de sparade orden gick inte att öppna, så synken väntar. Inget har ändrats."
            case .newerFile:
                return "Den här enhetens synkfil är skriven av en nyare version av Sensus. Uppdatera appen, så "
                    + "synkar den igen. Filen har inte rörts."
            }
        }
    }

    private init() {}

    var lastSync: Date? {
        let value = UserDefaults.standard.double(forKey: Self.lastSyncKey)
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }

    /// Synkens läge, till raden i biblioteket (G9) och i Inställningar (U7).
    enum Status: Equatable {
        /// Ingen mapp vald.
        case off
        case paused
        case running
        /// Fungerar. Tiden för senaste lyckade synken (nil: inte synkad än).
        case ok(Date?)
        case failing(String)
    }

    var status: Status {
        guard isConfigured else { return .off }
        if isPaused {
            return .paused
        }
        if isRunning {
            return .running
        }
        if let problem = SyncFolder.shared.problem {
            return .failing(problem)
        }
        if let error = lastError {
            return .failing(error)
        }
        return .ok(lastSync)
    }

    /// Synkar i bakgrunden om en mapp är vald, högst en gång i minuten. Används när appen öppnas och
    /// när man stänger en bok.
    func syncSoon() {
        guard isConfigured, !isRunning, !isPaused else { return }
        if let last = lastAttempt, Date().timeIntervalSince(last) < 60 {
            return
        }
        Task { @MainActor in
            _ = try? await self.sync()
        }
    }

    @discardableResult
    func sync() async throws -> SyncReport {
        guard !isPaused else { throw PausedError() }
        guard !isRunning else { return lastReport ?? SyncReport() }
        isRunning = true
        lastAttempt = Date()
        NotificationCenter.default.post(name: Self.didFinish, object: nil)
        defer {
            isRunning = false
            NotificationCenter.default.post(name: Self.didFinish, object: nil)
        }
        do {
            let started = Date()
            let report = try await run()
            lastReport = report
            lastError = nil
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastSyncKey)
            AppLog.shared.write("Synken: \(report.summary) (\(Int(Date().timeIntervalSince(started) * 1000)) ms)")
            return report
        } catch {
            lastError = error.localizedDescription
            AppLog.shared.write("Synken misslyckades: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: Synken

    private func run() async throws -> SyncReport {
        guard isConfigured else { throw Failure.noFolder }
        SyncFolder.shared.refresh()
        guard let directory = SyncFolder.shared.syncDirectory else {
            throw Failure.folder(SyncFolder.shared.problem ?? Failure.noFolder.errorDescription ?? "")
        }
        guard AnnotationStore.shared.database != nil, UserWords.shared.isAvailableForSync else {
            throw Failure.database
        }
        // Kontrollsummorna för böcker som inte räknats än (i bakgrunden).
        let books = LibraryStore.shared.allBooks().filter { $0.kind != .other }
        _ = await BookIdentity.ids(for: books)

        let device = SyncFolder.shared.device
        let ownName = SyncFolder.fileName(for: device.id)
        let entries = await Task.detached(priority: .utility) { () -> [SyncFiles.Entry] in
            _ = try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return SyncFiles.readAll(in: directory, waitForDownloads: 4)
        }.value
        // Den lokala bilden tas efter läsningen och sparas utan väntan emellan, så att en markering som görs
        // medan filerna läses inte kan skrivas över av en äldre rad.
        let local = localSnapshot(device: device)

        var report = SyncReport()
        report.books = local.books
        var previousOwn: SyncSnapshot?
        var canWrite = true
        var setAsideOwn = false
        var remotes: [SyncSnapshot] = []
        var skipped: [String] = []
        for entry in entries {
            if entry.name == ownName {
                if let snapshot = entry.snapshot {
                    previousOwn = snapshot
                } else if entry.notDownloaded {
                    // Den egna filen finns i iCloud men är inte hämtad: den skrivs inte över förrän den lästs.
                    canWrite = false
                    skipped.append("\(entry.name) (den här enheten): \(entry.skipped ?? "")")
                } else if case .newerFormat = entry.error {
                    throw Failure.newerFile
                } else {
                    // Trasig eller tom: den sparas undan under ett annat namn och skrivs om.
                    setAsideOwn = true
                    skipped.append("\(entry.name) (den här enheten): \(entry.skipped ?? ""), sparad undan")
                }
                continue
            }
            if let snapshot = entry.snapshot {
                remotes.append(snapshot)
                if let reason = entry.skipped {
                    skipped.append("\(entry.name): \(reason)")
                }
            } else {
                skipped.append("\(entry.name): \(entry.skipped ?? "okänt fel")")
            }
        }
        for line in skipped {
            AppLog.shared.write("Synken hoppade över \(line)")
        }
        skippedFiles = skipped
        report.skippedFiles = entries.filter { $0.snapshot == nil }.count
        report.devices = remotes.count
        peers = remotes.map { SyncPeer(device: $0.device, written: $0.written > 0 ? Date(timeIntervalSince1970: $0.written) : nil) }
            .sorted { $0.device.name < $1.device.name }

        // Den lokala bilden först: vid lika tid vinner det som redan finns här.
        let now = Date().timeIntervalSince1970
        let merged = SyncMerge.merge([local.snapshot] + (previousOwn.map { [$0] } ?? []) + remotes,
                                     device: device, written: now)
        let changes = SyncMerge.changes(local: local.snapshot, merged: merged)
        let applied = apply(changes, local: local)
        report.pulled = applied.applied
        report.waiting = applied.waiting

        let changed = SyncMerge.changedRows(from: previousOwn, to: merged)
        report.pushed = changed
        let stale = previousOwn.map { now - $0.written > Self.heartbeat } ?? true
        if canWrite, changed > 0 || stale || setAsideOwn {
            let data = try SyncFile.encode(merged)
            let target = directory.appendingPathComponent(ownName)
            let shouldSetAside = setAsideOwn
            try await Task.detached(priority: .utility) {
                if shouldSetAside {
                    SyncFiles.setAside(target)
                }
                try SyncFiles.writeAtomically(data, to: target)
            }.value
        } else if !canWrite {
            report.pushed = 0
        }
        return report
    }

    // MARK: Den lokala bilden

    private struct Local {
        var snapshot: SyncSnapshot
        /// Bokregistrets id till kontrollsumman, och kontrollsumman till böckerna (de som finns först).
        var shaForID: [String: String]
        var idsForSHA: [String: [BookRecord]]
        /// Markeringarnas och bokmärkenas bok (registrets id), så att en ändring hamnar på samma bok.
        var highlightBooks: [String: String]
        var bookmarkBooks: [String: String]
        var books: Int
    }

    private func localSnapshot(device: SyncDevice) -> Local {
        let records = BookRegistry.shared.records()
        var shaForID: [String: String] = [:]
        var idsForSHA: [String: [BookRecord]] = [:]
        for record in records where !record.sha256.isEmpty {
            shaForID[record.id] = record.sha256
            idsForSHA[record.sha256, default: []].append(record)
        }
        for (sha, list) in idsForSHA {
            // Böcker som finns först, sedan den senast tillagda.
            idsForSHA[sha] = list.sorted { a, b in
                if a.missing != b.missing { return !a.missing }
                return a.added > b.added
            }
        }
        var snapshot = SyncSnapshot(device: device, written: Date().timeIntervalSince1970)
        let store = LibraryStore.shared
        for record in records where !record.sha256.isEmpty {
            guard let kind = Self.kind(of: record.file), let date = store.positionDate(forID: record.id) else { continue }
            let place: (section: Int, progression: Double)?
            if kind == "pdf" {
                place = store.savedPageIndex(forID: record.id).map { (section: $0, progression: 0.0) }
            } else {
                place = store.savedLocation(forID: record.id).map { (section: $0.chapter, progression: $0.progression) }
            }
            guard let place = place else { continue }
            let position = SyncPosition(bookID: record.sha256, title: record.title, kind: kind, section: place.section,
                                        progression: min(max(place.progression, 0), 1),
                                        updated: date.timeIntervalSince1970)
            snapshot.positions[record.sha256] = SyncMerge.newest(snapshot.positions[record.sha256], position, \.updated)
        }
        var highlightBooks: [String: String] = [:]
        for (highlight, deleted) in AnnotationStore.shared.highlightsForSync() {
            let id = highlight.id.lowercased()
            highlightBooks[id] = highlight.book
            guard let sha = shaForID[highlight.book] else { continue }
            let row = SyncHighlight(id: id, bookID: sha, section: highlight.section, start: highlight.start,
                                    length: highlight.length, text: highlight.text, color: highlight.color.rawValue,
                                    note: highlight.note, created: highlight.created.timeIntervalSince1970,
                                    updated: highlight.updated.timeIntervalSince1970, deleted: deleted)
            snapshot.highlights[id] = SyncMerge.newest(snapshot.highlights[id], row, \.updated)
        }
        var bookmarkBooks: [String: String] = [:]
        for (bookmark, deleted) in AnnotationStore.shared.bookmarksForSync() {
            let id = bookmark.id.lowercased()
            bookmarkBooks[id] = bookmark.book
            guard let sha = shaForID[bookmark.book] else { continue }
            let row = SyncBookmark(id: id, bookID: sha, section: bookmark.section, progression: bookmark.progression,
                                   label: bookmark.label, created: bookmark.created.timeIntervalSince1970,
                                   updated: bookmark.updated.timeIntervalSince1970, deleted: deleted)
            snapshot.bookmarks[id] = SyncMerge.newest(snapshot.bookmarks[id], row, \.updated)
        }
        for word in UserWords.shared.wordsForSync() {
            snapshot.words[word.key] = SyncMerge.mergeWord(snapshot.words[word.key], word)
        }
        let books = Set(records.filter { !$0.missing && !$0.sha256.isEmpty }.map(\.sha256)).count
        return Local(snapshot: snapshot, shaForID: shaForID, idsForSHA: idsForSHA, highlightBooks: highlightBooks,
                     bookmarkBooks: bookmarkBooks, books: books)
    }

    /// "pdf" eller "reflow" efter filens ändelse, nil för filer som inte är böcker.
    nonisolated static func kind(of file: String) -> String? {
        switch (file as NSString).pathExtension.lowercased() {
        case "pdf": return "pdf"
        case "epub", "txt", "md", "markdown", "rtf", "html", "htm": return "reflow"
        default: return nil
        }
    }

    // MARK: Spara det som kom från de andra

    private func apply(_ changes: SyncMerge.Changes, local: Local) -> (applied: Int, waiting: Int) {
        var applied = 0
        var waiting = 0
        let store = LibraryStore.shared
        for position in changes.positions {
            let targets = (local.idsForSHA[position.bookID] ?? []).filter { Self.kind(of: $0.file) == position.kind }
            guard !targets.isEmpty else {
                waiting += 1
                continue
            }
            for record in targets {
                store.applySyncedPosition(section: position.section, progression: position.progression,
                                          date: Date(timeIntervalSince1970: position.updated), forID: record.id,
                                          isPDF: position.kind == "pdf")
            }
            applied += 1
        }
        for row in changes.highlights {
            guard let book = local.highlightBooks[row.id] ?? local.idsForSHA[row.bookID]?.first?.id else {
                waiting += 1
                continue
            }
            let highlight = Highlight(id: row.id, book: book, section: row.section, start: row.start, length: row.length,
                                      text: row.text, color: HighlightColor(rawValue: row.color) ?? .yellow,
                                      note: row.note, created: Date(timeIntervalSince1970: row.created),
                                      updated: Date(timeIntervalSince1970: row.updated))
            AnnotationStore.shared.applySynced(highlight, deleted: row.deleted)
            applied += 1
        }
        for row in changes.bookmarks {
            guard let book = local.bookmarkBooks[row.id] ?? local.idsForSHA[row.bookID]?.first?.id else {
                waiting += 1
                continue
            }
            let bookmark = Bookmark(id: row.id, book: book, section: row.section, progression: row.progression,
                                    label: row.label, created: Date(timeIntervalSince1970: row.created),
                                    updated: Date(timeIntervalSince1970: row.updated))
            AnnotationStore.shared.applySynced(bookmark, deleted: row.deleted)
            applied += 1
        }
        for word in changes.words {
            UserWords.shared.applySynced(word)
            applied += 1
        }
        return (applied, waiting)
    }
}
