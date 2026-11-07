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
/// Böckerna känns igen på filnamnet, som läspositionen. Inget raderas på riktigt: en borttagen rad får
/// `deleted = 1` och en ny ändringstid, så att synken i fas 6 kan föra borttagningen vidare.
/// Används bara från huvudtråden.
final class AnnotationStore {

    static let shared = AnnotationStore()

    /// Skickas när något har ändrats. `object` är bokens nyckel.
    static let didChange = Notification.Name("AnnotationStoreDidChange")

    private let db: SQLiteDatabase?

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let path = support.appendingPathComponent("markeringar.sqlite").path
        db = try? SQLiteDatabase(path: path, readOnly: false)
        try? db?.executeScript("""
            PRAGMA journal_mode = WAL;
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
            """)
    }

    /// Nyckeln som en bok sparas under.
    static func key(for book: Book) -> String {
        book.url.lastPathComponent
    }

    // MARK: Markeringar

    /// Bokens markeringar i läsordning.
    func highlights(book: String) -> [Highlight] {
        var result: [Highlight] = []
        try? db?.query("""
            SELECT id, book, section, start, length, text, color, note, created, updated
            FROM highlights WHERE book = ? AND deleted = 0 ORDER BY section, start
            """, [book]) { row in
            result.append(Self.highlight(from: row))
        }
        return result
    }

    func highlights(book: String, section: Int) -> [Highlight] {
        var result: [Highlight] = []
        try? db?.query("""
            SELECT id, book, section, start, length, text, color, note, created, updated
            FROM highlights WHERE book = ? AND section = ? AND deleted = 0 ORDER BY start
            """, [book, section]) { row in
            result.append(Self.highlight(from: row))
        }
        return result
    }

    func highlight(id: String) -> Highlight? {
        var result: Highlight?
        try? db?.query("""
            SELECT id, book, section, start, length, text, color, note, created, updated
            FROM highlights WHERE id = ? AND deleted = 0
            """, [id]) { row in
            result = Self.highlight(from: row)
        }
        return result
    }

    /// Lägger till en markering. Överlappar den markeringar på samma ställe slås de ihop till en,
    /// med den nya färgen och alla anteckningar kvar.
    @discardableResult
    func addHighlight(book: String, section: Int, start: Int, length: Int, text: String,
                      color: HighlightColor, textProvider: ((Int, Int) -> String?)? = nil) -> Highlight {
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
            markDeleted(table: "highlights", id: old.id, at: now)
        }
        var mergedText = text
        if !overlapping.isEmpty, newStart != start || newEnd != start + length {
            mergedText = textProvider?(newStart, newEnd - newStart) ?? text
        }
        let highlight = Highlight(id: UUID().uuidString,
                                  book: book,
                                  section: section,
                                  start: newStart,
                                  length: newEnd - newStart,
                                  text: mergedText,
                                  color: color,
                                  note: notes.joined(separator: "\n\n"),
                                  created: now,
                                  updated: now)
        insert(highlight)
        notify(book)
        return highlight
    }

    func update(_ highlight: Highlight) {
        var changed = highlight
        changed.updated = Date()
        insert(changed)
        notify(highlight.book)
    }

    func delete(_ highlight: Highlight) {
        markDeleted(table: "highlights", id: highlight.id, at: Date())
        notify(highlight.book)
    }

    private func insert(_ highlight: Highlight) {
        try? db?.execute("""
            INSERT OR REPLACE INTO highlights (id, book, section, start, length, text, color, note, created, updated, deleted)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
            """, [highlight.id, highlight.book, highlight.section, highlight.start, highlight.length, highlight.text,
                  highlight.color.rawValue, highlight.note, highlight.created.timeIntervalSince1970,
                  highlight.updated.timeIntervalSince1970])
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
                  updated: Date(timeIntervalSince1970: row.double(9)))
    }

    // MARK: Bokmärken

    func bookmarks(book: String) -> [Bookmark] {
        var result: [Bookmark] = []
        try? db?.query("""
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
        return result
    }

    @discardableResult
    func addBookmark(book: String, section: Int, progression: Double, label: String) -> Bookmark {
        let now = Date()
        let bookmark = Bookmark(id: UUID().uuidString, book: book, section: section,
                                progression: progression, label: label, created: now, updated: now)
        try? db?.execute("""
            INSERT INTO bookmarks (id, book, section, progression, label, created, updated, deleted)
            VALUES (?, ?, ?, ?, ?, ?, ?, 0)
            """, [bookmark.id, book, section, progression, label,
                  now.timeIntervalSince1970, now.timeIntervalSince1970])
        notify(book)
        return bookmark
    }

    func delete(_ bookmark: Bookmark) {
        markDeleted(table: "bookmarks", id: bookmark.id, at: Date())
        notify(bookmark.book)
    }

    // MARK: Gemensamt

    /// Antalet markeringar och bokmärken i alla böcker. Används av självtestet för att se att de överlever en omstart.
    func totalCounts() -> (highlights: Int, notes: Int, bookmarks: Int) {
        var highlights = 0
        var notes = 0
        var bookmarks = 0
        try? db?.query("SELECT COUNT(*), SUM(CASE WHEN note <> '' THEN 1 ELSE 0 END) FROM highlights WHERE deleted = 0") { row in
            highlights = row.int(0)
            notes = row.int(1)
        }
        try? db?.query("SELECT COUNT(*) FROM bookmarks WHERE deleted = 0") { row in
            bookmarks = row.int(0)
        }
        return (highlights, notes, bookmarks)
    }

    private func markDeleted(table: String, id: String, at date: Date) {
        // Tabellnamnet kommer bara härifrån, aldrig från användaren.
        try? db?.execute("UPDATE \(table) SET deleted = 1, updated = ? WHERE id = ?", [date.timeIntervalSince1970, id])
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
