import Foundation

/// En bok i bokregistret (G3): ett eget id som aldrig ändras, och det som gör att boken känns igen
/// på innehållet: kontrollsumman (SHA-256, samma som synken använder), filens plats i Böcker, titel,
/// storlek och ändringstid. Markeringar, bokmärken, läsposition och sparade ord hänger på `id`.
struct BookRecord: Equatable {
    let id: String
    /// SHA-256 av filens innehåll, gemener hex. Tom tills den räknats (böcker från före G3 räknas i bakgrunden).
    var sha256: String
    /// Sökvägen i Böcker med snedstreck, till exempel "RETA30/Bok.pdf".
    var file: String
    var title: String
    var size: Int
    /// Filens ändringstid i hela sekunder.
    var modified: Int
    var added: Double
    /// Filen finns inte längre. Raden finns kvar, så att markeringarna kommer tillbaka om filen läggs in igen.
    var missing: Bool
}

/// En fil i Böcker, som den ser ut på disken just nu.
struct BookFile: Equatable {
    /// Sökvägen i Böcker med snedstreck.
    let path: String
    let size: Int
    let modified: Int

    var name: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    var title: String {
        (name as NSString).deletingPathExtension
    }

    var fileExtension: String {
        (name as NSString).pathExtension.lowercased()
    }
}

/// Vad registret gör med en fil. Ren logik utan databas eller filer, så att den går att testa (G13).
enum BookMatch: Equatable {
    /// Filen är känd: samma plats och samma storlek och ändringstid, eller samma kontrollsumma.
    case known(id: String)
    /// Kontrollsumman behövs för att avgöra vad filen är.
    case needsHash
    /// En ny bok.
    case new
    /// Samma innehåll som en bok vars fil inte finns längre: filen har bytt namn eller flyttats.
    case moved(id: String)
    /// Samma plats men nytt innehåll, eller ett liknande namn som en bok som inte finns längre:
    /// en ny version av boken. Frågan Ny version av boken, behåll markeringarna? ställs.
    case newVersion(id: String)
}

enum BookMatcher {

    /// Bestämmer vad en fil är. `hash` är filens kontrollsumma om den är räknad. `present` är platserna
    /// för alla filer som finns i Böcker just nu.
    static func match(_ file: BookFile, hash: String?, records: [BookRecord], present: Set<String>) -> BookMatch {
        // Samma plats. En rad vars fil finns används före en rad som markerats som borta.
        let atPath = records.filter { $0.file == file.path }.sorted { !$0.missing && $1.missing }
        if let record = atPath.first {
            if record.size == file.size, record.modified == file.modified {
                return .known(id: record.id)
            }
            guard let hash = hash else { return .needsHash }
            if record.sha256.isEmpty || record.sha256 == hash {
                // Samma innehåll, eller en bok från före G3 som inte hunnit räknas: samma bok.
                return .known(id: record.id)
            }
            return .newVersion(id: record.id)
        }

        // Ny plats. Finns det böcker vars filer saknas kan filen vara en av dem med nytt namn.
        let absent = records.filter { !present.contains($0.file) }
        guard !absent.isEmpty else { return .new }
        guard let hash = hash else { return .needsHash }
        if let same = absent.first(where: { $0.sha256 == hash }) {
            return .moved(id: same.id)
        }
        if let similar = absent.first(where: { isSimilar($0, to: file) }) {
            return .newVersion(id: similar.id)
        }
        return .new
    }

    /// Liknande namn: samma filtyp och samma titel om man bortser från skiftläge, skiljetecken, siffror och
    /// ord som "OCR", "ny" och "version". "Bok.pdf" och "Bok (OCR) 2.pdf" liknar varandra.
    static func isSimilar(_ record: BookRecord, to file: BookFile) -> Bool {
        let recordExtension = (record.file as NSString).pathExtension.lowercased()
        guard recordExtension == file.fileExtension else { return false }
        let a = normalizedTitle(record.title)
        let b = normalizedTitle(file.title)
        guard a.count >= 4, b.count >= 4 else { return a == b && !a.isEmpty }
        return a == b
    }

    static func normalizedTitle(_ title: String) -> String {
        let ignored: Set<String> = ["ocr", "ny", "nya", "version", "ver", "v", "kopia", "copy", "final", "slutlig"]
        let words = title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !ignored.contains($0) && !$0.allSatisfy(\.isNumber) }
            // "v2", "v3": versionsnummer.
            .filter { !($0.count > 1 && $0.hasPrefix("v") && $0.dropFirst().allSatisfy(\.isNumber)) }
        return words.joined(separator: " ")
    }
}

/// Bokregistret: tabellen `books` i markeringar.sqlite (G3). Används bara från huvudtråden.
final class BookRegistry {

    static let shared = BookRegistry()

    private var cache: [BookRecord]?
    /// Vad flytten av gamla nycklar gjorde, till självtestet och loggen.
    private(set) var lastMigrationSummary: String?

    private init() {}

    private var store: AnnotationStore {
        AnnotationStore.shared
    }

    // MARK: Läsa

    func records() -> [BookRecord] {
        if let cache = cache {
            return cache
        }
        var result: [BookRecord] = []
        store.readBooks { db in
            try db.query("SELECT id, sha256, file, title, size, modified, added, missing FROM books") { row in
                result.append(BookRecord(id: row.string(0), sha256: row.string(1), file: row.string(2),
                                         title: row.string(3), size: row.int(4), modified: row.int(5),
                                         added: row.double(6), missing: row.int(7) != 0))
            }
        }
        cache = result
        return result
    }

    func record(id: String) -> BookRecord? {
        records().first { $0.id == id }
    }

    // MARK: Skriva

    /// Sparar rader i en transaktion. Nya rader läggs till, befintliga skrivs över.
    @discardableResult
    func save(_ changed: [BookRecord]) -> Bool {
        guard !changed.isEmpty else { return true }
        let ok = store.writeBooks("bokregistret") { db in
            for record in changed {
                try Self.insert(record, into: db)
            }
        }
        cache = nil
        return ok
    }

    static func insert(_ record: BookRecord, into db: SQLiteDatabase) throws {
        try db.execute("""
            INSERT OR REPLACE INTO books (id, sha256, file, title, size, modified, added, missing)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, [record.id, record.sha256, record.file, record.title, record.size, record.modified,
                  record.added, record.missing ? 1 : 0])
    }

    /// En ny bok med ett nytt id.
    static func makeRecord(for file: BookFile, hash: String) -> BookRecord {
        BookRecord(id: UUID().uuidString.lowercased(), sha256: hash, file: file.path, title: file.title,
                   size: file.size, modified: file.modified, added: Date().timeIntervalSince1970, missing: false)
    }

    /// Kontrollsumman för en bok, när den räknats (för synken och böcker från före G3).
    func setHash(_ hash: String, for id: String) {
        guard var record = self.record(id: id), record.sha256 != hash else { return }
        record.sha256 = hash
        save([record])
    }

    /// Glömmer det som lästs in, till exempel efter en återställning från säkerhetskopian.
    func reset() {
        cache = nil
    }

    // MARK: Filerna i Böcker

    /// Läser Böcker (med undermappar) och ger varje fil som går att känna igen ett id. Nya böcker läggs in
    /// i registret direkt när inget behöver räknas. Filer som behöver sin kontrollsumma kommer i `pending`,
    /// de räknas av `resolve`. Gamla nycklar flyttas till id:t första gången (se `migrateLegacyIfNeeded`).
    func scan(files: [BookFile], urls: [String: URL]) -> (books: [Book], pending: [BookFile]) {
        let present = Set(files.map(\.path))
        var records = self.records()
        var books: [Book] = []
        var pending: [BookFile] = []
        var changed: [BookRecord] = []
        for file in files {
            guard let url = urls[file.path] else { continue }
            switch BookMatcher.match(file, hash: nil, records: records, present: present) {
            case .known(let id):
                if var record = records.first(where: { $0.id == id }), record.missing || record.title != file.title {
                    record.missing = false
                    record.title = file.title
                    changed.append(record)
                }
                books.append(Book(url: url, id: id, path: file.path))
            case .new:
                let record = Self.makeRecord(for: file, hash: "")
                records.append(record)
                changed.append(record)
                books.append(Book(url: url, id: record.id, path: file.path))
            case .needsHash, .moved, .newVersion:
                pending.append(file)
            }
        }
        // Filer som inte finns längre markeras som borta. Raderna och markeringarna finns kvar.
        for record in records where !record.missing && !present.contains(record.file)
            && !changed.contains(where: { $0.id == record.id }) {
            var gone = record
            gone.missing = true
            changed.append(gone)
        }
        save(changed)
        migrateLegacyIfNeeded()
        return (books, pending)
    }

    /// En fråga om en ny version av en bok, som läsaren svarar på i biblioteket.
    struct VersionQuestion {
        let file: BookFile
        let hash: String
        let record: BookRecord
    }

    /// Räknar kontrollsumman för filerna som behöver den (i bakgrunden) och lägger in dem: flyttade och
    /// omdöpta böcker får sitt gamla id, nya böcker ett nytt. Nya versioner av en bok blir frågor.
    @MainActor
    func resolve(_ files: [BookFile], urls: [String: URL]) async -> [VersionQuestion] {
        let targets = files.compactMap { file in urls[file.path].map { (file, $0) } }
        let hashes = await Task.detached(priority: .userInitiated) { () -> [String: String] in
            var result: [String: String] = [:]
            for (file, url) in targets {
                if let hash = BookIdentity.hash(of: url) {
                    result[file.path] = hash
                }
            }
            return result
        }.value
        var records = self.records()
        let present = Set(LibraryStore.shared.listFiles().files.map(\.path))
        var changed: [BookRecord] = []
        var questions: [VersionQuestion] = []
        for (file, _) in targets {
            guard let hash = hashes[file.path] else { continue }
            switch BookMatcher.match(file, hash: hash, records: records, present: present) {
            case .known(let id), .moved(let id):
                guard var record = records.first(where: { $0.id == id }) else { continue }
                if record.file != file.path {
                    AppLog.shared.write("Bok känd på innehållet: \(record.file) heter nu \(file.path)")
                }
                record.file = file.path
                record.title = file.title
                record.sha256 = hash
                record.size = file.size
                record.modified = file.modified
                record.missing = false
                records.removeAll { $0.id == id }
                records.append(record)
                changed.append(record)
            case .new:
                let record = Self.makeRecord(for: file, hash: hash)
                records.append(record)
                changed.append(record)
            case .newVersion(let id):
                if let record = records.first(where: { $0.id == id }) {
                    questions.append(VersionQuestion(file: file, hash: hash, record: record))
                }
            case .needsHash:
                break
            }
        }
        save(changed)
        return questions
    }

    /// Svaret på frågan om en ny version. Behåll: filen tar över bokens id, med markeringar och läsposition.
    /// Annars blir filen en ny bok, och den gamla raden (med sina markeringar) markeras som borta.
    func answer(_ question: VersionQuestion, keep: Bool) {
        let file = question.file
        var changed: [BookRecord] = []
        if keep {
            var record = question.record
            record.file = file.path
            record.title = file.title
            record.sha256 = question.hash
            record.size = file.size
            record.modified = file.modified
            record.missing = false
            changed.append(record)
            AppLog.shared.write("Ny version av \(question.record.file) behåller markeringarna: \(file.path)")
        } else {
            var old = question.record
            old.missing = true
            changed.append(old)
            changed.append(Self.makeRecord(for: file, hash: question.hash))
            AppLog.shared.write("Ny version av \(question.record.file) blev en ny bok: \(file.path)")
        }
        save(changed)
    }

    /// Lägger in en fil som just importerats och vars kontrollsumma redan är räknad (G10).
    /// En fil med samma innehåll som en bok som inte finns längre får dess id tillbaka.
    func register(_ file: BookFile, hash: String) -> String {
        let present = Set(LibraryStore.shared.listFiles().files.map(\.path))
        let records = self.records()
        switch BookMatcher.match(file, hash: hash, records: records, present: present) {
        case .known(let id), .moved(let id):
            if var record = records.first(where: { $0.id == id }) {
                record.file = file.path
                record.title = file.title
                record.sha256 = hash
                record.size = file.size
                record.modified = file.modified
                record.missing = false
                save([record])
            }
            return id
        case .newVersion(let id):
            // Samma plats: filen har ersatts, och frågan ställdes vid importen. Den tar över bokens id.
            if var record = records.first(where: { $0.id == id }), record.file == file.path {
                record.sha256 = hash
                record.size = file.size
                record.modified = file.modified
                record.title = file.title
                record.missing = false
                save([record])
                return id
            }
            let record = Self.makeRecord(for: file, hash: hash)
            save([record])
            return record.id
        case .new, .needsHash:
            let record = Self.makeRecord(for: file, hash: hash)
            save([record])
            return record.id
        }
    }

    /// Lägger in en fil som en ny bok, även om en annan bok haft samma plats (Ersätt och börja om).
    func registerNew(_ file: BookFile, hash: String) -> String {
        let record = Self.makeRecord(for: file, hash: hash)
        save([record])
        return record.id
    }

    /// Boken med en viss kontrollsumma vars fil finns, till exempel för Den här boken finns redan.
    func presentBook(withHash hash: String) -> BookRecord? {
        records().first { !$0.missing && $0.sha256 == hash }
    }

    func markMissing(id: String) {
        guard var record = self.record(id: id) else { return }
        record.missing = true
        save([record])
    }

    // MARK: Flytten av gamla nycklar (G3)

    /// Första gången efter uppdateringen: läsposition, markeringar och bokmärken som sparats under filnamnet
    /// flyttas till bokens id, och sparade ord får bokens id. Precis innan görs en säkerhetskopia.
    /// Flytten går att köra om utan skada.
    func migrateLegacyIfNeeded() {
        guard let db = store.database else { return }
        let records = self.records().filter { !$0.missing }
        // Utan böcker finns inget att flytta till. Klart-markeringen sätts först när böckerna lästs in.
        guard !records.isEmpty else { return }
        let defaults = UserDefaults.standard
        do {
            if try LegacyBookMigration.isDone(db) {
                LegacyBookMigration.removeLeftovers(records: records, defaults: defaults)
                return
            }
            if LegacyBookMigration.hasWork(db: db, records: records, defaults: defaults) {
                // Säkerhetskopian före flytten. Går den inte att göra flyttas ingenting den här gången.
                guard Backup.makeBeforeMigration() else {
                    AppLog.shared.write("Flytten till bokens id väntar: säkerhetskopian gick inte att spara")
                    return
                }
            }
            let result = try LegacyBookMigration.run(db: db, records: records, defaults: defaults)
            UserWords.shared.linkBooks(records.map { (id: $0.id, title: $0.title) })
            lastMigrationSummary = result.summary
            AppLog.shared.write("Flytten till bokens id: \(result.summary)")
        } catch {
            SaveProblems.report("Markeringarna", detail: "flytten till bokens id: \(error)")
        }
    }
}

/// Flytten från filnamn till bokens id (G3), som ren logik mot en databas och en UserDefaults,
/// så att den kan provas med påhittade gamla data i självtestet och i XCTest.
enum LegacyBookMigration {

    /// Nycklarna i UserDefaults: gamla (filnamnet) och nya (bokens id).
    static let keyPairs: [(old: String, new: String)] = [
        ("position.", "bookPosition."),
        ("location.", "bookLocation."),
        ("positionDate.", "bookPositionDate."),
    ]

    private static let doneKey = "legacy_book_keys_moved"

    struct Result: Equatable {
        var highlights = 0
        var bookmarks = 0
        var keys = 0

        var summary: String {
            "\(highlights) markeringar, \(bookmarks) bokmärken och \(keys) läspositionsnycklar flyttade"
        }
    }

    static func isDone(_ db: SQLiteDatabase) throws -> Bool {
        var done = false
        try db.query("SELECT value FROM meta WHERE key = ?", [doneKey]) { row in
            done = row.string(0) == "1"
        }
        return done
    }

    /// Sant om något finns att flytta.
    static func hasWork(db: SQLiteDatabase, records: [BookRecord], defaults: UserDefaults) -> Bool {
        for record in records {
            for pair in keyPairs where defaults.object(forKey: pair.old + record.file) != nil {
                return true
            }
        }
        var count = 0
        for record in records {
            for table in ["highlights", "bookmarks"] {
                try? db.query("SELECT COUNT(*) FROM \(table) WHERE book = ?", [record.file]) { row in
                    count += row.int(0)
                }
            }
        }
        return count > 0
    }

    /// Flyttar allt för böckerna i `records`. Värden i UserDefaults kopieras först (ett nytt värde som redan
    /// finns skrivs inte över), sedan flyttas raderna i databasen och klart-markeringen sätts i samma
    /// transaktion, sist tas de gamla nycklarna bort. Avbryts flytten någonstans går den att köra om.
    @discardableResult
    static func run(db: SQLiteDatabase, records: [BookRecord], defaults: UserDefaults) throws -> Result {
        var result = Result()
        for record in records {
            for pair in keyPairs {
                let oldKey = pair.old + record.file
                guard let value = defaults.object(forKey: oldKey) else { continue }
                let newKey = pair.new + record.id
                if defaults.object(forKey: newKey) == nil {
                    defaults.set(value, forKey: newKey)
                }
                result.keys += 1
            }
        }
        try db.transaction { () throws -> Void in
            for record in records {
                var highlights = 0
                var bookmarks = 0
                try db.query("SELECT COUNT(*) FROM highlights WHERE book = ?", [record.file]) { highlights = $0.int(0) }
                try db.query("SELECT COUNT(*) FROM bookmarks WHERE book = ?", [record.file]) { bookmarks = $0.int(0) }
                // Ändringstiden rörs inte: synken ser samma rader som förut, nu via id:t.
                try db.execute("UPDATE highlights SET book = ? WHERE book = ?", [record.id, record.file])
                try db.execute("UPDATE bookmarks SET book = ? WHERE book = ?", [record.id, record.file])
                result.highlights += highlights
                result.bookmarks += bookmarks
            }
            try db.execute("INSERT OR REPLACE INTO meta (key, value) VALUES (?, '1')", [doneKey])
        }
        removeLeftovers(records: records, defaults: defaults)
        return result
    }

    /// Tar bort gamla nycklar som redan finns under bokens id.
    static func removeLeftovers(records: [BookRecord], defaults: UserDefaults) {
        for record in records {
            for pair in keyPairs {
                let oldKey = pair.old + record.file
                if defaults.object(forKey: oldKey) != nil, defaults.object(forKey: pair.new + record.id) != nil {
                    defaults.removeObject(forKey: oldKey)
                }
            }
        }
    }
}
