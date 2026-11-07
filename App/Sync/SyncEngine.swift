import CryptoKit
import Foundation

/// Böckernas id i synken: SHA-256 av filens innehåll (gemener, hex). Samma fil får samma id på iPaden och
/// i Windows-appen, oavsett filnamn. Räknas en gång per fil och sparas med filens namn, storlek och ändringstid.
enum BookIdentity {

    private static let cacheKey = "bookIdentity.cache"

    /// Filnamn till id för böckerna. Filer som inte räknats förut räknas i bakgrunden.
    @MainActor
    static func ids(for books: [Book]) async -> [String: String] {
        var cache = UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: String] ?? [:]
        var result: [String: String] = [:]
        var missing: [(name: String, signature: String, url: URL)] = []
        for book in books {
            let signature = Self.signature(of: book)
            if let id = cache[signature] {
                result[book.url.lastPathComponent] = id
            } else {
                missing.append((book.url.lastPathComponent, signature, book.url))
            }
        }
        if !missing.isEmpty {
            let urls = missing.map { $0.url }
            let computed = await Task.detached(priority: .utility) { () -> [String?] in
                urls.map { BookIdentity.hash(of: $0) }
            }.value
            for (item, id) in zip(missing, computed) {
                guard let id = id else { continue }
                cache[item.signature] = id
                result[item.name] = id
            }
            // Bara böcker som finns kvar sparas.
            let current = Set(books.map { Self.signature(of: $0) })
            cache = cache.filter { current.contains($0.key) }
            UserDefaults.standard.set(cache, forKey: cacheKey)
        }
        return result
    }

    private static func signature(of book: Book) -> String {
        let values = try? book.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? 0
        let date = Int(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        return "\(book.url.lastPathComponent)|\(size)|\(date)"
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

/// Tider i synken: ISO 8601 i UTC med millisekunder, som Supabase lagrar som timestamptz.
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

    /// Läser en tid ur ett svar. Supabase skriver mikrosekunder, som formatteraren inte klarar, så de kortas.
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

    var summary: String {
        "\(books) böcker, \(pushed) ändringar skickade, \(pulled) hämtade"
    }
}

/// Synken (fas 6): läsposition, markeringar, bokmärken och sparade ord mellan iPaden och Windows-appen,
/// via Edvins eget Supabase-projekt.
///
/// Varje rad har en ändringstid. Den nyaste vinner, rad för rad (och för ett sparat ord: ordet och
/// repetitionen var för sig). Borttaget skickas som en rad med `deleted`, så att det försvinner överallt.
/// Allt läses och jämförs varje gång, det är små mängder. Böcker som inte finns på enheten hoppas över
/// och kommer med när boken läggs in.
@MainActor
final class SyncEngine {

    static let shared = SyncEngine()
    static let didFinish = Notification.Name("SyncEngineDidFinish")

    private(set) var isRunning = false
    private(set) var lastError: String?
    private(set) var lastReport: SyncReport?
    private var lastAttempt: Date?
    private static let lastSyncKey = "sync.last"

    private init() {}

    var lastSync: Date? {
        let value = UserDefaults.standard.double(forKey: Self.lastSyncKey)
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }

    /// Synkar i bakgrunden om man är inloggad, högst en gång i minuten. Används när appen öppnas och
    /// när man stänger en bok.
    func syncSoon() {
        guard SyncClient.shared.isSignedIn, !isRunning else { return }
        if let last = lastAttempt, Date().timeIntervalSince(last) < 60 {
            return
        }
        Task { @MainActor in
            _ = try? await self.sync()
        }
    }

    @discardableResult
    func sync() async throws -> SyncReport {
        guard !isRunning else { return lastReport ?? SyncReport() }
        isRunning = true
        lastAttempt = Date()
        defer {
            isRunning = false
            NotificationCenter.default.post(name: Self.didFinish, object: nil)
        }
        do {
            let report = try await run()
            lastReport = report
            lastError = nil
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastSyncKey)
            return report
        } catch {
            lastError = error.localizedDescription
            AppLog.shared.write("Synken misslyckades: \(error.localizedDescription)")
            throw error
        }
    }

    private func run() async throws -> SyncReport {
        let client = SyncClient.shared
        guard client.isSignedIn, let user = client.userID else { throw SyncClient.Failure.notSignedIn }
        let books = LibraryStore.shared.allBooks().filter { $0.kind != .other }
        let ids = await BookIdentity.ids(for: books)
        var report = SyncReport()
        report.books = ids.count
        try await syncPositions(books: books, ids: ids, user: user, report: &report)
        try await syncHighlights(ids: ids, user: user, report: &report)
        try await syncBookmarks(ids: ids, user: user, report: &report)
        try await syncWords(user: user, report: &report)
        return report
    }

    // MARK: Läsposition

    private func syncPositions(books: [Book], ids: [String: String], user: String, report: inout SyncReport) async throws {
        let remote = try await SyncClient.shared.rows(in: "positions")
        var remoteByBook: [String: [String: Any]] = [:]
        for row in remote {
            if let id = row["book_id"] as? String {
                remoteByBook[id] = row
            }
        }
        var push: [[String: Any]] = []
        for book in books {
            guard let id = ids[book.url.lastPathComponent] else { continue }
            let kind = book.kind == .pdf ? "pdf" : "reflow"
            let local = LibraryStore.shared.positionDate(for: book)?.timeIntervalSince1970
            let row = remoteByBook[id]
            let remoteDate = SyncTime.seconds(row?["updated_at"])
            if let row = row, let remoteDate = remoteDate, SyncTime.newer(remoteDate, than: local),
               (row["kind"] as? String) == kind {
                LibraryStore.shared.applySyncedPosition(section: Self.int(row["section"]),
                                                        progression: Self.double(row["progression"]) ?? 0,
                                                        date: Date(timeIntervalSince1970: remoteDate),
                                                        for: book)
                report.pulled += 1
            } else if let local = local, SyncTime.newer(local, than: remoteDate) {
                var section = 0
                var progression = 0.0
                if book.kind == .pdf {
                    section = LibraryStore.shared.savedPageIndex(for: book)
                } else if let location = LibraryStore.shared.savedLocation(for: book) {
                    section = location.chapter
                    progression = location.progression
                }
                push.append(["user_id": user, "book_id": id, "title": book.title, "kind": kind, "section": section,
                             "progression": progression, "updated_at": SyncTime.string(local)])
            }
        }
        if !push.isEmpty {
            try await SyncClient.shared.upsert(push, into: "positions", onConflict: "user_id,book_id")
            report.pushed += push.count
        }
    }

    // MARK: Markeringar och bokmärken

    private func syncHighlights(ids: [String: String], user: String, report: inout SyncReport) async throws {
        let remote = try await SyncClient.shared.rows(in: "highlights")
        let fileForID = Dictionary(ids.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        var remoteByID: [String: [String: Any]] = [:]
        for row in remote {
            if let id = (row["id"] as? String)?.lowercased() {
                remoteByID[id] = row
            }
        }
        var push: [[String: Any]] = []
        var seen = Set<String>()
        for (highlight, deleted) in AnnotationStore.shared.highlightsForSync() {
            let key = highlight.id.lowercased()
            seen.insert(key)
            guard let bookID = ids[highlight.book] else { continue }
            let row = remoteByID[key]
            let remoteDate = SyncTime.seconds(row?["updated_at"])
            let localDate = highlight.updated.timeIntervalSince1970
            if let row = row, SyncTime.newer(remoteDate, than: localDate),
               let incoming = Self.highlight(from: row, id: highlight.id, book: highlight.book) {
                AnnotationStore.shared.applySynced(incoming.0, deleted: incoming.1)
                report.pulled += 1
            } else if SyncTime.newer(localDate, than: remoteDate) {
                push.append(Self.row(highlight, deleted: deleted, bookID: bookID, user: user))
            }
        }
        for (key, row) in remoteByID where !seen.contains(key) {
            guard let bookID = row["book_id"] as? String, let file = fileForID[bookID],
                  let incoming = Self.highlight(from: row, id: key, book: file) else { continue }
            AnnotationStore.shared.applySynced(incoming.0, deleted: incoming.1)
            report.pulled += 1
        }
        if !push.isEmpty {
            try await SyncClient.shared.upsert(push, into: "highlights", onConflict: "id")
            report.pushed += push.count
        }
    }

    private func syncBookmarks(ids: [String: String], user: String, report: inout SyncReport) async throws {
        let remote = try await SyncClient.shared.rows(in: "bookmarks")
        let fileForID = Dictionary(ids.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        var remoteByID: [String: [String: Any]] = [:]
        for row in remote {
            if let id = (row["id"] as? String)?.lowercased() {
                remoteByID[id] = row
            }
        }
        var push: [[String: Any]] = []
        var seen = Set<String>()
        for (bookmark, deleted) in AnnotationStore.shared.bookmarksForSync() {
            let key = bookmark.id.lowercased()
            seen.insert(key)
            guard let bookID = ids[bookmark.book] else { continue }
            let row = remoteByID[key]
            let remoteDate = SyncTime.seconds(row?["updated_at"])
            let localDate = bookmark.updated.timeIntervalSince1970
            if let row = row, SyncTime.newer(remoteDate, than: localDate),
               let incoming = Self.bookmark(from: row, id: bookmark.id, book: bookmark.book) {
                AnnotationStore.shared.applySynced(incoming.0, deleted: incoming.1)
                report.pulled += 1
            } else if SyncTime.newer(localDate, than: remoteDate) {
                push.append([
                    "id": key, "user_id": user, "book_id": bookID, "section": bookmark.section,
                    "progression": bookmark.progression, "label": bookmark.label,
                    "created_at": SyncTime.string(bookmark.created.timeIntervalSince1970),
                    "updated_at": SyncTime.string(localDate), "deleted": deleted,
                ])
            }
        }
        for (key, row) in remoteByID where !seen.contains(key) {
            guard let bookID = row["book_id"] as? String, let file = fileForID[bookID],
                  let incoming = Self.bookmark(from: row, id: key, book: file) else { continue }
            AnnotationStore.shared.applySynced(incoming.0, deleted: incoming.1)
            report.pulled += 1
        }
        if !push.isEmpty {
            try await SyncClient.shared.upsert(push, into: "bookmarks", onConflict: "id")
            report.pushed += push.count
        }
    }

    private static func row(_ highlight: Highlight, deleted: Bool, bookID: String, user: String) -> [String: Any] {
        [
            "id": highlight.id.lowercased(), "user_id": user, "book_id": bookID, "section": highlight.section,
            "start": highlight.start, "length": highlight.length, "text": highlight.text,
            "color": highlight.color.rawValue, "note": highlight.note,
            "created_at": SyncTime.string(highlight.created.timeIntervalSince1970),
            "updated_at": SyncTime.string(highlight.updated.timeIntervalSince1970), "deleted": deleted,
        ]
    }

    private static func highlight(from row: [String: Any], id: String, book: String) -> (Highlight, Bool)? {
        guard let updated = SyncTime.seconds(row["updated_at"]) else { return nil }
        let created = SyncTime.seconds(row["created_at"]) ?? updated
        let highlight = Highlight(id: id, book: book, section: int(row["section"]), start: int(row["start"]),
                                  length: int(row["length"]), text: row["text"] as? String ?? "",
                                  color: HighlightColor(rawValue: row["color"] as? String ?? "") ?? .yellow,
                                  note: row["note"] as? String ?? "",
                                  created: Date(timeIntervalSince1970: created),
                                  updated: Date(timeIntervalSince1970: updated))
        return (highlight, bool(row["deleted"]))
    }

    private static func bookmark(from row: [String: Any], id: String, book: String) -> (Bookmark, Bool)? {
        guard let updated = SyncTime.seconds(row["updated_at"]) else { return nil }
        let created = SyncTime.seconds(row["created_at"]) ?? updated
        let bookmark = Bookmark(id: id, book: book, section: int(row["section"]),
                                progression: double(row["progression"]) ?? 0, label: row["label"] as? String ?? "",
                                created: Date(timeIntervalSince1970: created),
                                updated: Date(timeIntervalSince1970: updated))
        return (bookmark, bool(row["deleted"]))
    }

    // MARK: Sparade ord och repetition

    private func syncWords(user: String, report: inout SyncReport) async throws {
        let remoteRows = try await SyncClient.shared.rows(in: "saved_words")
        var remote: [String: SyncWord] = [:]
        for row in remoteRows {
            if let word = Self.word(from: row) {
                remote[word.key] = word
            }
        }
        var local: [String: SyncWord] = [:]
        for word in UserWords.shared.wordsForSync() {
            local[word.key] = word
        }
        var push: [[String: Any]] = []
        for key in Set(remote.keys).union(local.keys) {
            let mine = local[key]
            let theirs = remote[key]
            let wordFromRemote = theirs != nil && SyncTime.newer(theirs?.updated, than: mine?.updated)
            let wordFromLocal = mine != nil && !wordFromRemote && SyncTime.newer(mine?.updated, than: theirs?.updated)
            let reviewFromRemote = SyncTime.newer(theirs?.reviewUpdated, than: mine?.reviewUpdated)
            let reviewFromLocal = !reviewFromRemote && SyncTime.newer(mine?.reviewUpdated, than: theirs?.reviewUpdated)
            guard var merged = (wordFromRemote ? theirs : mine) ?? theirs else { continue }
            let reviewSource = reviewFromRemote ? theirs : (reviewFromLocal ? mine : (wordFromRemote ? theirs : mine))
            if merged.deleted {
                merged.due = nil
                merged.interval = nil
                merged.ease = nil
                merged.reps = nil
                merged.lapses = nil
                merged.reviewUpdated = nil
            } else if let source = reviewSource {
                merged.due = source.due
                merged.interval = source.interval
                merged.ease = source.ease
                merged.reps = source.reps
                merged.lapses = source.lapses
                merged.reviewUpdated = source.reviewUpdated
            }
            if wordFromRemote || (reviewFromRemote && !merged.deleted) {
                UserWords.shared.applySynced(merged)
                report.pulled += 1
            }
            if wordFromLocal || (reviewFromLocal && !merged.deleted) || (theirs == nil && mine != nil) {
                push.append(Self.row(merged, user: user))
            }
        }
        if !push.isEmpty {
            try await SyncClient.shared.upsert(push, into: "saved_words", onConflict: "user_id,lemma,language")
            report.pushed += push.count
        }
    }

    private static func row(_ word: SyncWord, user: String) -> [String: Any] {
        [
            "user_id": user, "lemma": word.lemma, "language": word.language, "word": word.word,
            "sentence": word.sentence, "book": word.book, "page": word.page, "lookups": word.lookups,
            "created_at": SyncTime.string(word.created), "updated_at": SyncTime.string(word.updated),
            "deleted": word.deleted,
            "due": word.due.map { $0 as Any } ?? NSNull(),
            "interval": word.interval.map { $0 as Any } ?? NSNull(),
            "ease": word.ease.map { $0 as Any } ?? NSNull(),
            "reps": word.reps.map { $0 as Any } ?? NSNull(),
            "lapses": word.lapses.map { $0 as Any } ?? NSNull(),
            "review_updated_at": word.reviewUpdated.map { SyncTime.string($0) as Any } ?? NSNull(),
        ]
    }

    private static func word(from row: [String: Any]) -> SyncWord? {
        guard let lemma = row["lemma"] as? String, let language = row["language"] as? String,
              let updated = SyncTime.seconds(row["updated_at"]) else { return nil }
        var word = SyncWord(lemma: lemma, language: language)
        word.word = row["word"] as? String ?? lemma
        word.sentence = row["sentence"] as? String ?? ""
        word.book = row["book"] as? String ?? ""
        word.page = int(row["page"])
        word.lookups = max(int(row["lookups"]), 1)
        word.created = SyncTime.seconds(row["created_at"]) ?? updated
        word.updated = updated
        word.deleted = bool(row["deleted"])
        word.due = double(row["due"])
        word.interval = double(row["interval"])
        word.ease = double(row["ease"])
        word.reps = (row["reps"] as? NSNumber)?.intValue
        word.lapses = (row["lapses"] as? NSNumber)?.intValue
        word.reviewUpdated = SyncTime.seconds(row["review_updated_at"])
        return word
    }

    // MARK: Tolkning

    private static func int(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? Int(value as? String ?? "") ?? 0
    }

    private static func double(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap { Double($0) }
    }

    private static func bool(_ value: Any?) -> Bool {
        (value as? NSNumber)?.boolValue ?? false
    }
}
