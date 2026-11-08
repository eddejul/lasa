import UIKit

/// Färgerna en markering kan ha.
enum HighlightColor: String, CaseIterable {
    case yellow
    case green
    case blue
    case pink

    var title: String {
        switch self {
        case .yellow: return "Gul"
        case .green: return "Grön"
        case .blue: return "Blå"
        case .pink: return "Rosa"
        }
    }

    /// Färgen utan genomskinlighet, till knapparna.
    var solid: UIColor {
        switch self {
        case .yellow: return UIColor(red: 1.0, green: 0.80, blue: 0.10, alpha: 1)
        case .green: return UIColor(red: 0.36, green: 0.80, blue: 0.40, alpha: 1)
        case .blue: return UIColor(red: 0.35, green: 0.62, blue: 1.0, alpha: 1)
        case .pink: return UIColor(red: 1.0, green: 0.45, blue: 0.66, alpha: 1)
        }
    }

    /// Färgen ovanpå en sidbild. Mörkt papper tål mindre färg innan texten blir svår att läsa.
    func overlay(dark: Bool) -> UIColor {
        solid.withAlphaComponent(dark ? 0.30 : 0.38)
    }

    /// Samma färg i CSS, för kapitlen i EPUB och textfiler.
    var css: String {
        switch self {
        case .yellow: return "rgba(255, 204, 26, 0.40)"
        case .green: return "rgba(92, 204, 102, 0.36)"
        case .blue: return "rgba(89, 158, 255, 0.34)"
        case .pink: return "rgba(255, 115, 168, 0.36)"
        }
    }

    /// Starkare variant, till strecket under markeringar med anteckning.
    var cssStrong: String {
        switch self {
        case .yellow: return "rgba(230, 170, 0, 0.95)"
        case .green: return "rgba(40, 160, 60, 0.95)"
        case .blue: return "rgba(40, 110, 230, 0.95)"
        case .pink: return "rgba(230, 60, 130, 0.95)"
        }
    }
}

/// En markering i en bok, med eller utan anteckning.
///
/// Platsen är `section` och ett teckenintervall i den. I en PDF är `section` sidans plats i filen och
/// intervallet gäller sidans text (`PDFPage.string`, UTF-16). I en EPUB eller textfil är `section` kapitlet
/// och intervallet gäller kapitlets text, räknad som all text i body i dokumentordning (UTF-16).
struct Highlight: Equatable {
    let id: String
    let book: String
    var section: Int
    var start: Int
    var length: Int
    var text: String
    var color: HighlightColor
    var note: String
    let created: Date
    var updated: Date
    /// Rutorna på en PDF-sida i sidans koordinater, sparade när markeringen skapas (G6), så att sidan kan
    /// vikas fram utan att PDFKit räknar fram dem. Tomt i EPUB och för markeringar som inte räknats än.
    var rects: [CGRect] = []

    var end: Int {
        start + length
    }

    var hasNote: Bool {
        !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Ett bokmärke. I en PDF är `section` sidan. I en EPUB eller textfil är det kapitlet, och `progression`
/// är hur långt in i kapitlet (0 till 1), så att bokmärket överlever byte av typsnitt och storlek.
struct Bookmark: Equatable {
    let id: String
    let book: String
    var section: Int
    var progression: Double
    var label: String
    let created: Date
    var updated: Date
}

/// Markeringar, anteckningar och bokmärken, i en egen databas under Application Support.
///
/// Böckerna känns igen på sitt id i bokregistret (G3), som läspositionen. Inget raderas på riktigt: en borttagen rad får
/// `deleted = 1` och en ny ändringstid, så att synken i fas 6 kan föra borttagningen vidare.
/// Används bara från huvudtråden.
final class AnnotationStore {

    static let shared = AnnotationStore()

    /// Skickas när något har ändrats. `object` är bokens nyckel.
    static let didChange = Notification.Name("AnnotationStoreDidChange")

    private let db: SQLiteDatabase?

    /// Namnet i felmeddelanden.
    private static let name = "Markeringarna"

    /// Databasens versioner, en trappa. Steg 1 är tabellerna som de var före G8, så en befintlig databas
    /// (version 0) får bara versionsnumret. Lägg nya steg sist, till exempel `ALTER TABLE ... ADD COLUMN`.
    static let migrations: [String] = [
        """
            CREATE TABLE IF NOT EXISTS highlights (
                id TEXT PRIMARY KEY,
                book TEXT NOT NULL,
                section INTEGER NOT NULL,
                start INTEGER NOT NULL,
                length INTEGER NOT NULL,
                text TEXT NOT NULL,
                color TEXT NOT NULL,
                note TEXT NOT NULL DEFAULT '',
                created REAL NOT NULL,
                updated REAL NOT NULL,
                deleted INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS highlights_book ON highlights (book, section);
            CREATE TABLE IF NOT EXISTS bookmarks (
                id TEXT PRIMARY KEY,
                book TEXT NOT NULL,
                section INTEGER NOT NULL,
                progression REAL NOT NULL,
                label TEXT NOT NULL,
                created REAL NOT NULL,
                updated REAL NOT NULL,
                deleted INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS bookmarks_book ON bookmarks (book, section);
            """,
        // Steg 2 (G3): bokregistret. Böckerna får ett eget id, och markeringar, bokmärken och läsposition
        // flyttas från filnamnet till id:t av `LegacyBookMigration` när appen startar.
        """
            CREATE TABLE IF NOT EXISTS books (
                id TEXT PRIMARY KEY,
                sha256 TEXT NOT NULL DEFAULT '',
                file TEXT NOT NULL,
                title TEXT NOT NULL,
                size INTEGER NOT NULL DEFAULT 0,
                modified INTEGER NOT NULL DEFAULT 0,
                added REAL NOT NULL,
                missing INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS books_file ON books (file);
            CREATE INDEX IF NOT EXISTS books_sha ON books (sha256);
            CREATE TABLE IF NOT EXISTS meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            """,
        // Steg 3 (G6): markeringens rutor på PDF-sidan, som JSON. Synken skickar dem inte.
        """
            ALTER TABLE highlights ADD COLUMN rects TEXT NOT NULL DEFAULT '';
            """,
        // Steg 4 (B1, B2): bokens titel och författare ur filen, läsarens egna, omslaget (filnamnet i cachen,
        // och sidan läsaren valt i en PDF), andel läst, Markera som läst och var man är.
        """
            ALTER TABLE books ADD COLUMN book_title TEXT NOT NULL DEFAULT '';
            ALTER TABLE books ADD COLUMN author TEXT NOT NULL DEFAULT '';
            ALTER TABLE books ADD COLUMN custom_title TEXT NOT NULL DEFAULT '';
            ALTER TABLE books ADD COLUMN custom_author TEXT NOT NULL DEFAULT '';
            ALTER TABLE books ADD COLUMN cover TEXT NOT NULL DEFAULT '';
            ALTER TABLE books ADD COLUMN cover_page INTEGER NOT NULL DEFAULT -1;
            ALTER TABLE books ADD COLUMN meta_key TEXT NOT NULL DEFAULT '';
            ALTER TABLE books ADD COLUMN progress REAL NOT NULL DEFAULT 0;
            ALTER TABLE books ADD COLUMN finished INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE books ADD COLUMN chapter TEXT NOT NULL DEFAULT '';
            ALTER TABLE books ADD COLUMN page INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE books ADD COLUMN pages INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE books ADD COLUMN chapter_left INTEGER NOT NULL DEFAULT -1;
            """,
        // Steg 5 (B3): kurserna och vilka böcker man lagt i dem. En undermapp i Böcker blir en kurs (`folder`).
        // Ingen synk än, synken byggs om till iCloud Drive (F1).
        """
            CREATE TABLE IF NOT EXISTS courses (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                color TEXT NOT NULL DEFAULT '',
                folder TEXT NOT NULL DEFAULT '',
                added REAL NOT NULL,
                deleted INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS course_books (
                course TEXT NOT NULL,
                book TEXT NOT NULL,
                added REAL NOT NULL,
                PRIMARY KEY (course, book)
            );
            """,
        // Steg 6 (K2, K3): bokens egna sidnummer i en PDF och bokinfon till citaten, en rad per bok.
        """
            CREATE TABLE IF NOT EXISTS book_info (
                book TEXT PRIMARY KEY,
                page_first INTEGER NOT NULL DEFAULT 0,
                page_spread INTEGER NOT NULL DEFAULT 0,
                author TEXT NOT NULL DEFAULT '',
                year TEXT NOT NULL DEFAULT '',
                title TEXT NOT NULL DEFAULT '',
                publisher TEXT NOT NULL DEFAULT '',
                place TEXT NOT NULL DEFAULT '',
                updated REAL NOT NULL DEFAULT 0
            );
            """,
        // Steg 7 (K10): läsloggen, en rad per dag, bok och läst sida med tiden på sidan och platsen i boken
        // (0 till 1, tidslinjens skala). Dagen i lokal tid. Ingen synk.
        """
            CREATE TABLE IF NOT EXISTS reading_log (
                day TEXT NOT NULL,
                book TEXT NOT NULL,
                page TEXT NOT NULL,
                position REAL NOT NULL DEFAULT 0,
                seconds REAL NOT NULL DEFAULT 0,
                PRIMARY KEY (day, book, page)
            );
            CREATE INDEX IF NOT EXISTS reading_log_book ON reading_log (book);
            """,
        // Steg 8 (K12): anteckningarna bredvid texten, en per bok och sida (PDF) eller kapitel (EPUB och text).
        """
            CREATE TABLE IF NOT EXISTS page_notes (
                book TEXT NOT NULL,
                section INTEGER NOT NULL,
                text TEXT NOT NULL DEFAULT '',
                created REAL NOT NULL,
                updated REAL NOT NULL,
                deleted INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (book, section)
            );
            """,
        // Steg 9 (K8): begreppsregistret, begrepp och definition per bok, och markeringen det skapades från.
        """
            CREATE TABLE IF NOT EXISTS concepts (
                id TEXT PRIMARY KEY,
                book TEXT NOT NULL,
                term TEXT NOT NULL,
                definition TEXT NOT NULL DEFAULT '',
                highlight TEXT NOT NULL DEFAULT '',
                created REAL NOT NULL,
                updated REAL NOT NULL,
                deleted INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS concepts_book ON concepts (book);
            """,
    ]

    /// Databasens fil, till säkerhetskopian.
    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("markeringar.sqlite")
    }

    private init() {
        db = Self.open()
    }

    private static func open() -> SQLiteDatabase? {
        let url = fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            let db = try SQLiteDatabase(path: url.path, readOnly: false)
            try db.executeScript("PRAGMA journal_mode = WAL;")
            let versions = try db.migrate(migrations)
            if versions.from != versions.to {
                AppLog.shared.write("markeringar.sqlite: version \(versions.from) till \(versions.to)")
            }
            return db
        } catch {
            AppLog.shared.write("markeringar.sqlite gick inte att öppna: \(error)")
            return nil
        }
    }

    /// Databasens version, till självtestet och loggen.
    var schemaVersion: Int {
        (try? db?.userVersion()) ?? -1
    }

    /// Ersätter allt med en säkerhetskopia (G1). En äldre kopia uppdateras till dagens version.
    func restore(from url: URL) throws {
        guard let db = db else {
            throw SQLiteDatabase.Failure(description: "Markeringarnas databas gick inte att öppna")
        }
        try db.replaceContents(with: url)
        try db.migrate(Self.migrations)
        // Kopian har sitt eget bokregister (eller inget, om den är från före G3). Böckerna läses in på nytt.
        BookRegistry.shared.reset()
        CourseStore.shared.reset()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    // MARK: Bokregistret (G3)

    /// Databasen, för bokregistret och flytten av gamla nycklar. Används bara från huvudtråden.
    var database: SQLiteDatabase? {
        db
    }

    func readBooks(_ body: (SQLiteDatabase) throws -> Void) {
        read("bokregistret", body)
    }

    @discardableResult
    func writeBooks(_ what: String, _ body: (SQLiteDatabase) throws -> Void) -> Bool {
        write(what, body)
    }

    /// Kör en skrivning i en transaktion: allt eller inget. Går det inte säger appen till.
    @discardableResult
    private func write(_ what: String, _ body: (SQLiteDatabase) throws -> Void) -> Bool {
        guard let db = db else {
            SaveProblems.report(Self.name, detail: "\(what): databasen gick inte att öppna")
            return false
        }
        do {
            try db.transaction { try body(db) }
            return true
        } catch {
            SaveProblems.report(Self.name, detail: "\(what): \(error)")
            return false
        }
    }

    /// En läsning. Ett fel hamnar i loggen, och svaret blir tomt.
    private func read(_ what: String, _ body: (SQLiteDatabase) throws -> Void) {
        guard let db = db else { return }
        do {
            try body(db)
        } catch {
            AppLog.shared.write("Markeringar: \(what) kunde inte läsas: \(error)")
        }
    }

    /// Nyckeln som en bok sparas under: bokens id i bokregistret (G3). Före G3 var det filnamnet.
    static func key(for book: Book) -> String {
        book.id
    }

    // MARK: Markeringar

    /// Bokens markeringar i läsordning.
    func highlights(book: String) -> [Highlight] {
        var result: [Highlight] = []
        read("bokens markeringar") { db in
            try db.query("""
                SELECT id, book, section, start, length, text, color, note, created, updated, rects
                FROM highlights WHERE book = ? AND deleted = 0 ORDER BY section, start
                """, [book]) { row in
                result.append(Self.highlight(from: row))
            }
        }
        return result
    }

    func highlights(book: String, section: Int) -> [Highlight] {
        var result: [Highlight] = []
        read("sidans markeringar") { db in
            try db.query("""
                SELECT id, book, section, start, length, text, color, note, created, updated, rects
                FROM highlights WHERE book = ? AND section = ? AND deleted = 0 ORDER BY start
                """, [book, section]) { row in
                result.append(Self.highlight(from: row))
            }
        }
        return result
    }

    func highlight(id: String) -> Highlight? {
        var result: Highlight?
        read("en markering") { db in
            try db.query("""
                SELECT id, book, section, start, length, text, color, note, created, updated, rects
                FROM highlights WHERE id = ? AND deleted = 0
                """, [id]) { row in
                result = Self.highlight(from: row)
            }
        }
        return result
    }

    /// Lägger till en markering. Överlappar den markeringar på samma ställe slås de ihop till en,
    /// med den nya färgen och alla anteckningar kvar.
    @discardableResult
    func addHighlight(book: String, section: Int, start: Int, length: Int, text: String,
                      color: HighlightColor, textProvider: ((Int, Int) -> String?)? = nil,
                      rectsProvider: ((Int, Int) -> [CGRect])? = nil) -> Highlight {
        let now = Date()
        var newStart = start
        var newEnd = start + length
        var notes: [String] = []
        let overlapping = highlights(book: book, section: section).filter { $0.start < newEnd && $0.end > newStart }
        for old in overlapping {
            newStart = min(newStart, old.start)
            newEnd = max(newEnd, old.end)
            if old.hasNote {
                notes.append(old.note)
            }
        }
        var mergedText = text
        if !overlapping.isEmpty, newStart != start || newEnd != start + length {
            mergedText = textProvider?(newStart, newEnd - newStart) ?? text
        }
        let highlight = Highlight(id: UUID().uuidString.lowercased(),
                                  book: book,
                                  section: section,
                                  start: newStart,
                                  length: newEnd - newStart,
                                  text: mergedText,
                                  color: color,
                                  note: notes.joined(separator: "\n\n"),
                                  created: now,
                                  updated: now,
                                  rects: rectsProvider?(newStart, newEnd - newStart) ?? [])
        // De gamla markeringarna tas bort och den nya läggs till i samma transaktion, så att en krasch
        // emellan inte tappar markeringen med dess anteckningar.
        write("markeringen") { db in
            for old in overlapping {
                try Self.markDeleted(db, table: "highlights", id: old.id, at: now)
            }
            try Self.insert(highlight, into: db)
        }
        notify(book)
        return highlight
    }

    func update(_ highlight: Highlight) {
        var changed = highlight
        changed.updated = Date()
        write("markeringen") { db in
            try Self.insert(changed, into: db)
        }
        notify(highlight.book)
    }

    func delete(_ highlight: Highlight) {
        write("borttagningen") { db in
            try Self.markDeleted(db, table: "highlights", id: highlight.id, at: Date())
        }
        notify(highlight.book)
    }

    private static func insert(_ highlight: Highlight, into db: SQLiteDatabase) throws {
        try db.execute("""
            INSERT OR REPLACE INTO highlights (id, book, section, start, length, text, color, note, created, updated,
                                               deleted, rects)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)
            """, [highlight.id, highlight.book, highlight.section, highlight.start, highlight.length, highlight.text,
                  highlight.color.rawValue, highlight.note, highlight.created.timeIntervalSince1970,
                  highlight.updated.timeIntervalSince1970, RectsJSON.encode(highlight.rects)])
    }

    /// En ny version av boken (G3): de sparade rutorna kan ha flyttat sig, så de räknas om från den nya filen.
    func clearRects(book: String) {
        write("markeringarnas rutor") { db in
            try db.execute("UPDATE highlights SET rects = '' WHERE book = ?", [book])
        }
    }

    /// Sparar rutor som räknats fram efteråt (G6). Ändringstiden rörs inte, så synken skickar inget nytt.
    func setRects(_ rects: [CGRect], forHighlight id: String) {
        write("markeringens rutor") { db in
            try db.execute("UPDATE highlights SET rects = ? WHERE id = ?", [RectsJSON.encode(rects), id])
        }
    }

    private static func highlight(from row: SQLiteDatabase.Row) -> Highlight {
        Highlight(id: row.string(0),
                  book: row.string(1),
                  section: row.int(2),
                  start: row.int(3),
                  length: row.int(4),
                  text: row.string(5),
                  color: HighlightColor(rawValue: row.string(6)) ?? .yellow,
                  note: row.string(7),
                  created: Date(timeIntervalSince1970: row.double(8)),
                  updated: Date(timeIntervalSince1970: row.double(9)),
                  rects: RectsJSON.decode(row.string(10)))
    }

    // MARK: Bokmärken

    func bookmarks(book: String) -> [Bookmark] {
        var result: [Bookmark] = []
        read("bokmärkena") { db in
            try db.query("""
                SELECT id, book, section, progression, label, created, updated
                FROM bookmarks WHERE book = ? AND deleted = 0 ORDER BY section, progression
                """, [book]) { row in
                result.append(Bookmark(id: row.string(0),
                                       book: row.string(1),
                                       section: row.int(2),
                                       progression: row.double(3),
                                       label: row.string(4),
                                       created: Date(timeIntervalSince1970: row.double(5)),
                                       updated: Date(timeIntervalSince1970: row.double(6))))
            }
        }
        return result
    }

    @discardableResult
    func addBookmark(book: String, section: Int, progression: Double, label: String) -> Bookmark {
        let now = Date()
        let bookmark = Bookmark(id: UUID().uuidString.lowercased(), book: book, section: section,
                                progression: progression, label: label, created: now, updated: now)
        write("bokmärket") { db in
            try db.execute("""
                INSERT INTO bookmarks (id, book, section, progression, label, created, updated, deleted)
                VALUES (?, ?, ?, ?, ?, ?, ?, 0)
                """, [bookmark.id, book, section, progression, label,
                      now.timeIntervalSince1970, now.timeIntervalSince1970])
        }
        notify(book)
        return bookmark
    }

    func delete(_ bookmark: Bookmark) {
        write("borttagningen") { db in
            try Self.markDeleted(db, table: "bookmarks", id: bookmark.id, at: Date())
        }
        notify(bookmark.book)
    }

    /// Ångra en borttagning (granskning 2, N7): samma rad syns igen, med ny ändringstid för synken.
    func undelete(_ bookmark: Bookmark) {
        write("ångra borttagningen") { db in
            try db.execute("UPDATE bookmarks SET deleted = 0, updated = ? WHERE id = ?",
                           [Date().timeIntervalSince1970, bookmark.id])
        }
        notify(bookmark.book)
    }

    // MARK: Gemensamt

    /// Antalet markeringar och bokmärken i alla böcker. Används av självtestet för att se att de överlever en omstart.
    func totalCounts() -> (highlights: Int, notes: Int, bookmarks: Int) {
        var highlights = 0
        var notes = 0
        var bookmarks = 0
        read("antalen") { db in
            try db.query("SELECT COUNT(*), SUM(CASE WHEN note <> '' THEN 1 ELSE 0 END) FROM highlights WHERE deleted = 0") { row in
                highlights = row.int(0)
                notes = row.int(1)
            }
            try db.query("SELECT COUNT(*) FROM bookmarks WHERE deleted = 0") { row in
                bookmarks = row.int(0)
            }
        }
        return (highlights, notes, bookmarks)
    }

    private static func markDeleted(_ db: SQLiteDatabase, table: String, id: String, at date: Date) throws {
        // Tabellnamnet kommer bara härifrån, aldrig från användaren.
        try db.execute("UPDATE \(table) SET deleted = 1, updated = ? WHERE id = ?", [date.timeIntervalSince1970, id])
    }

    private func notify(_ book: String) {
        NotificationCenter.default.post(name: Self.didChange, object: book)
    }
}

/// Små inställningar för läsaren som gäller alla böcker.
enum ReaderSettings {

    private static let soundKey = "reader.pageSound"
    private static let colorKey = "reader.highlightColor"

    /// Bläddringsljud. På från början, kan stängas av i menyn Bakgrund.
    static var pageSound: Bool {
        get { UserDefaults.standard.object(forKey: soundKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: soundKey) }
    }

    /// Färgen som nya markeringar får: den som valdes senast.
    static var highlightColor: HighlightColor {
        get { UserDefaults.standard.string(forKey: colorKey).flatMap(HighlightColor.init(rawValue:)) ?? .yellow }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: colorKey) }
    }
}

// MARK: Synk (fas 6)

extension AnnotationStore {

    /// Alla markeringar, också borttagna, med flaggan för borttagen.
    func highlightsForSync() -> [(Highlight, Bool)] {
        var result: [(Highlight, Bool)] = []
        read("markeringarna till synken") { db in
            try db.query("""
                SELECT id, book, section, start, length, text, color, note, created, updated, deleted FROM highlights
                """) { row in
                result.append((Self.syncHighlight(from: row), row.int(10) != 0))
            }
        }
        return result
    }

    /// Sparar en markering från en annan enhet med dess egna tider.
    func applySynced(_ highlight: Highlight, deleted: Bool) {
        write("markeringen från synken") { db in
            try db.execute("""
                INSERT OR REPLACE INTO highlights (id, book, section, start, length, text, color, note, created, updated, deleted)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [highlight.id, highlight.book, highlight.section, highlight.start, highlight.length, highlight.text,
                      highlight.color.rawValue, highlight.note, highlight.created.timeIntervalSince1970,
                      highlight.updated.timeIntervalSince1970, deleted ? 1 : 0])
        }
        NotificationCenter.default.post(name: Self.didChange, object: highlight.book)
    }

    func bookmarksForSync() -> [(Bookmark, Bool)] {
        var result: [(Bookmark, Bool)] = []
        read("bokmärkena till synken") { db in
            try db.query("SELECT id, book, section, progression, label, created, updated, deleted FROM bookmarks") { row in
                result.append((Bookmark(id: row.string(0), book: row.string(1), section: row.int(2),
                                        progression: row.double(3), label: row.string(4),
                                        created: Date(timeIntervalSince1970: row.double(5)),
                                        updated: Date(timeIntervalSince1970: row.double(6))), row.int(7) != 0))
            }
        }
        return result
    }

    func applySynced(_ bookmark: Bookmark, deleted: Bool) {
        write("bokmärket från synken") { db in
            try db.execute("""
                INSERT OR REPLACE INTO bookmarks (id, book, section, progression, label, created, updated, deleted)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, [bookmark.id, bookmark.book, bookmark.section, bookmark.progression, bookmark.label,
                      bookmark.created.timeIntervalSince1970, bookmark.updated.timeIntervalSince1970, deleted ? 1 : 0])
        }
        NotificationCenter.default.post(name: Self.didChange, object: bookmark.book)
    }

    private static func syncHighlight(from row: SQLiteDatabase.Row) -> Highlight {
        Highlight(id: row.string(0), book: row.string(1), section: row.int(2), start: row.int(3), length: row.int(4),
                  text: row.string(5), color: HighlightColor(rawValue: row.string(6)) ?? .yellow, note: row.string(7),
                  created: Date(timeIntervalSince1970: row.double(8)), updated: Date(timeIntervalSince1970: row.double(9)))
    }
}

/// Rutor som kort JSON, `[[x,y,b,h],...]` med två decimaler (G6).
enum RectsJSON {

    static func encode(_ rects: [CGRect]) -> String {
        guard !rects.isEmpty else { return "" }
        func number(_ value: CGFloat) -> String {
            String(format: "%.2f", Double(value))
        }
        return "[" + rects.map { "[\(number($0.minX)),\(number($0.minY)),\(number($0.width)),\(number($0.height))]" }
            .joined(separator: ",") + "]"
    }

    static func decode(_ text: String) -> [CGRect] {
        guard !text.isEmpty, let data = text.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[Double]] else { return [] }
        return list.compactMap { values in
            values.count == 4 ? CGRect(x: values[0], y: values[1], width: values[2], height: values[3]) : nil
        }
    }
}
