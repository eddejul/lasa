import Foundation
import PDFKit

/// Sökregistret (G11). Varje boks text sparas en gång i `sokregister.sqlite`, i bakgrunden när boken lagts in
/// eller öppnats, så att en sökning inte behöver ta fram hela bokens text med PDFKit eller läsa alla kapitel igen.
///
/// Nyckeln är bokens id i bokregistret (G3) och en version som räknas ur filen (storlek och ändringstid), så att
/// en ny version av boken ger ett nytt register. Varje avsnitt (PDF-sida, eller kapitel i EPUB och text) sparas
/// två gånger: originalet ordagrant i UTF-16, och den vikta texten (`FoldedText`) som SQLite letar i. Med FTS5
/// och trigram letar SQLite upp avsnitten med ett index, annars med `instr` i den vanliga tabellen. Träffarna
/// räknas sedan fram ur originalet med samma kod som förut, så registret avgör bara vilka avsnitt som läses, och
/// träffarnas platser blir exakt desamma som när texten tas fram direkt.
///
/// Registret är härlett och byggs om när det saknas, så det ligger i en egen databas med en egen trappa (G8),
/// utanför säkerhetskopian. Databasen används bara på registrets egen kö. Anropa inte metoderna från den kön.
final class SearchIndex {

    struct Key: Equatable {
        /// Bokens id i bokregistret.
        let book: String
        /// Ändras när filen ändras (en ny version av boken) eller när texten tas fram på ett nytt sätt.
        let version: String
        /// Filnamnet, bara till loggen.
        let name: String

        /// Nyckeln för en bok. `chapters` är antalet kapitel för EPUB och text, nil för PDF.
        static func make(for book: Book, chapters: Int?) -> Key {
            let values = try? book.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            let modified = Int(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
            var parts = ["v\(SearchIndex.formatVersion)", "\(size)", "\(modified)",
                         ProcessInfo.processInfo.operatingSystemVersionString]
            if let chapters = chapters {
                parts += ["kapitel \(chapters)", "uppackning \(ReflowableBookLoader.formatVersion)"]
            }
            return Key(book: book.id, version: parts.joined(separator: "|"), name: book.url.lastPathComponent)
        }
    }

    enum Mode: String {
        case fts = "FTS5 med trigram"
        case plain = "vanlig tabell"
    }

    /// Vad SQLite kan, till självtestet och loggen.
    struct Details {
        var sqliteVersion = ""
        var fts5 = false
        var trigram = false
        var mode = Mode.plain
    }

    static let shared = SearchIndex(path: fileURL.path)

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sokregister.sqlite")
    }

    /// Höj när texten som sparas tas fram på ett annat sätt (PDFKit-utdraget, `BookSearch.plainText`,
    /// `FoldedText`), så att alla register byggs om.
    static let formatVersion = 1

    /// Databasens trappa (G8). Lägg nya steg sist. FTS5-tabellen ligger utanför trappan, eftersom den inte
    /// finns i alla SQLite-byggen: den skapas när databasen öppnas, om SQLite kan.
    static let migrations: [String] = [
        """
            CREATE TABLE IF NOT EXISTS books (
                book TEXT PRIMARY KEY,
                version TEXT NOT NULL,
                sections INTEGER NOT NULL,
                built REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS sections (
                id INTEGER PRIMARY KEY,
                book TEXT NOT NULL,
                section INTEGER NOT NULL,
                original BLOB NOT NULL,
                folded TEXT NOT NULL
            );
            CREATE UNIQUE INDEX IF NOT EXISTS sections_book ON sections (book, section);
            """,
    ]

    private let path: String
    private let queue = DispatchQueue(label: "se.edvin.lasa.sokregister", qos: .userInitiated)
    private let buildQueue = DispatchQueue(label: "se.edvin.lasa.sokregister.bygge", qos: .utility)
    // Bara på `queue`.
    private var db: SQLiteDatabase?
    private var opened = false
    private var details = Details()

    init(path: String) {
        self.path = path
    }

    // MARK: Frågor

    /// Vad SQLite kan och hur registret söker.
    var info: Details {
        queue.sync {
            _ = database()
            return details
        }
    }

    /// Sant när registret finns för just den här versionen av boken.
    func isReady(_ key: Key) -> Bool {
        queue.sync {
            guard let db = database() else { return false }
            return Self.isReady(key, in: db)
        }
    }

    /// Avsnitten där den vikta söktexten kan stå, i ordning. Nil om registret inte är klart eller inte kunde
    /// läsas: då söker man direkt i boken. `plain` tvingar fram den vanliga tabellen (till självtestet).
    func sections(_ key: Key, containing query: String, plain: Bool = false) -> [Int]? {
        queue.sync {
            guard let db = database(), Self.isReady(key, in: db) else { return nil }
            var sections: [Int] = []
            do {
                if details.mode == .fts, !plain, let phrase = Self.ftsPhrase(query) {
                    try db.query("SELECT section FROM sections WHERE book = ? AND id IN "
                                 + "(SELECT rowid FROM sections_fts WHERE sections_fts MATCH ?) ORDER BY section",
                                 [key.book, phrase]) { sections.append($0.int(0)) }
                } else {
                    try db.query("SELECT section FROM sections WHERE book = ? AND instr(folded, ?) > 0 ORDER BY section",
                                 [key.book, query]) { sections.append($0.int(0)) }
                }
            } catch {
                AppLog.shared.write("Sökregistret kunde inte läsas: \(error)")
                return nil
            }
            return sections
        }
    }

    /// Avsnittets text, exakt som när den togs fram ur boken.
    func original(_ key: Key, section: Int) -> NSString? {
        queue.sync {
            guard let db = database() else { return nil }
            var text: NSString?
            try? db.query("SELECT original FROM sections WHERE book = ? AND section = ?", [key.book, section]) { row in
                text = Self.decode(row.data(0))
            }
            return text
        }
    }

    /// Avsnitten som har text, till självtestet.
    func storedSections(_ key: Key) -> [Int] {
        queue.sync {
            var sections: [Int] = []
            try? database()?.query("SELECT section FROM sections WHERE book = ? ORDER BY section", [key.book]) {
                sections.append($0.int(0))
            }
            return sections
        }
    }

    /// Gör bokens register gammalt, så att det byggs om (till självtestet).
    func invalidate(book: String) {
        queue.sync {
            _ = try? database()?.execute("UPDATE books SET version = 'gammal' WHERE book = ?", [book])
        }
    }

    /// Tar bort bokens register, till exempel när boken tas bort. Det byggs om om boken läggs in igen.
    func remove(book: String) {
        queue.async { [weak self] in
            guard let db = self?.database() else { return }
            try? db.transaction {
                try db.execute("DELETE FROM sections WHERE book = ?", [book])
                try db.execute("DELETE FROM books WHERE book = ?", [book])
            }
        }
    }

    /// Vid minnesvarning: SQLite släpper sitt eget minne för databasen.
    func releaseMemory() {
        queue.async { [weak self] in
            _ = try? self?.db?.executeScript("PRAGMA shrink_memory;")
        }
    }

    // MARK: Bygget

    /// Bygger registret i bakgrunden om det saknas eller är gammalt. `delay` låter boken öppnas först.
    func prepare(_ key: Key, source: BookSearch.Source, delay: TimeInterval = 0) {
        buildQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.buildIfNeeded(key, source: source)
        }
    }

    /// Bygger registret för en bok som just lagts in. Bara PDF: EPUB och text byggs när boken öppnas, eftersom
    /// kapitlen packas upp av läsaren och två uppackningar av samma bok inte får gå samtidigt.
    func prepare(_ book: Book) {
        guard book.kind == .pdf else { return }
        prepare(Key.make(for: book, chapters: nil), source: .pdf(book.url), delay: 2)
    }

    /// Bygger nu, på byggkön, och svarar när det är klart (till självtestet och testerna).
    func build(_ key: Key, source: BookSearch.Source) async -> Bool {
        await withCheckedContinuation { continuation in
            buildQueue.async { [weak self] in
                continuation.resume(returning: self?.buildIfNeeded(key, source: source) ?? false)
            }
        }
    }

    /// Sparar avsnittens text för en version av boken och ersätter det som fanns. Avsnitt utan text får saknas.
    func store(_ key: Key, sectionCount: Int, texts: [(section: Int, text: NSString)]) throws {
        // Texten viks och kodas utanför registrets kö, så att en sökning inte väntar på det.
        let rows = texts.map { item -> (Int, Data, String) in
            (item.section, Self.encode(item.text), Self.prefilterText(FoldedText(item.text).text))
        }
        try queue.sync {
            guard let db = database() else {
                throw SQLiteDatabase.Failure(description: "sokregister.sqlite gick inte att öppna")
            }
            try db.transaction {
                try db.execute("DELETE FROM sections WHERE book = ?", [key.book])
                for (section, original, folded) in rows {
                    try db.execute("INSERT INTO sections (book, section, original, folded) VALUES (?, ?, ?, ?)",
                                   [key.book, section, original, folded])
                }
                try db.execute("INSERT OR REPLACE INTO books (book, version, sections, built) VALUES (?, ?, ?, ?)",
                               [key.book, key.version, sectionCount, Date().timeIntervalSince1970])
            }
        }
    }

    /// På byggkön.
    @discardableResult
    private func buildIfNeeded(_ key: Key, source: BookSearch.Source) -> Bool {
        guard !isReady(key) else { return false }
        let started = CFAbsoluteTimeGetCurrent()
        guard let extracted = Self.extract(source) else {
            AppLog.shared.write("Sökregistret för \(key.name): boken kunde inte läsas")
            return false
        }
        do {
            try store(key, sectionCount: extracted.count, texts: extracted.texts)
            let milliseconds = Int(((CFAbsoluteTimeGetCurrent() - started) * 1000).rounded())
            AppLog.shared.write("Sökregistret byggt för \(key.name): \(extracted.texts.count) av \(extracted.count) "
                                + "avsnitt med text, \(milliseconds) ms")
            return true
        } catch {
            AppLog.shared.write("Sökregistret för \(key.name) kunde inte sparas: \(error)")
            return false
        }
    }

    /// Bokens text per avsnitt, på samma sätt som `BookSearch` tar fram den när den söker direkt i boken.
    /// PDF:en öppnas med ett eget dokument, som släpps när texten är framme.
    static func extract(_ source: BookSearch.Source) -> (count: Int, texts: [(section: Int, text: NSString)])? {
        var texts: [(section: Int, text: NSString)] = []
        switch source {
        case .pdf(let url):
            guard let document = PDFDocument(url: url) else { return nil }
            let count = document.pageCount
            for index in 0..<count {
                autoreleasepool {
                    if let string = document.page(at: index)?.string, !string.isEmpty {
                        texts.append((index, string as NSString))
                    }
                }
            }
            return (count, texts)
        case .chapters(let urls):
            for (index, url) in urls.enumerated() {
                autoreleasepool {
                    let text = BookSearch.plainText(ofChapterAt: url) as NSString
                    if text.length > 0 {
                        texts.append((index, text))
                    }
                }
            }
            return (urls.count, texts)
        }
    }

    // MARK: Ren logik (testad i XCTest)

    /// Texten som UTF-16, tecken för tecken. Allt kommer tillbaka exakt, även NUL och ensamma surrogattecken,
    /// så att träffarnas platser blir desamma som i texten ur boken.
    static func encode(_ text: NSString) -> Data {
        let length = text.length
        guard length > 0 else { return Data() }
        var units = [unichar](repeating: 0, count: length)
        text.getCharacters(&units, range: NSRange(location: 0, length: length))
        return units.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func decode(_ data: Data) -> NSString {
        let count = data.count / MemoryLayout<unichar>.size
        guard count > 0 else { return "" }
        var units = [unichar](repeating: 0, count: count)
        _ = units.withUnsafeMutableBufferPointer { data.copyBytes(to: $0) }
        return NSString(characters: units, length: count)
    }

    /// Den vikta texten som SQLite letar i. Tecknet NUL skulle klippa texten när den skickas till SQLite, så det
    /// byts mot U+FFFD. Ingen söktext innehåller NUL, så inget avsnitt med en träff kan falla bort.
    static func prefilterText(_ folded: NSString) -> String {
        (folded as String).replacingOccurrences(of: "\u{0}", with: "\u{FFFD}")
    }

    /// Söktexten som en fras för FTS5. Trigram behöver minst tre tecken, kortare söktexter letas med `instr`.
    static func ftsPhrase(_ query: String) -> String? {
        guard query.unicodeScalars.count >= 3 else { return nil }
        return "\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: Databasen, på `queue`

    private static func isReady(_ key: Key, in db: SQLiteDatabase) -> Bool {
        var ready = false
        try? db.query("SELECT version FROM books WHERE book = ?", [key.book]) { row in
            ready = row.string(0) == key.version
        }
        return ready
    }

    private func database() -> SQLiteDatabase? {
        if opened {
            return db
        }
        opened = true
        do {
            if path != ":memory:" {
                try? FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
            }
            let db = try SQLiteDatabase(path: path, readOnly: false)
            try db.executeScript("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;")
            let versions = try db.migrate(Self.migrations)
            if versions.from != versions.to {
                AppLog.shared.write("sokregister.sqlite: version \(versions.from) till \(versions.to)")
            }
            var found = Details()
            try db.query("SELECT sqlite_version()") { found.sqliteVersion = $0.string(0) }
            found.fts5 = Self.probe(db, "fts5(x)")
            found.trigram = found.fts5 && Self.probe(db, "fts5(x, tokenize = 'trigram')")
            if found.trigram, Self.setUpFTS(db) {
                found.mode = .fts
            } else {
                // Utan FTS5 får inga utlösare peka på FTS-tabellen, då skulle varje sparning misslyckas.
                try? db.executeScript("DROP TRIGGER IF EXISTS sections_ai; DROP TRIGGER IF EXISTS sections_ad;")
            }
            details = found
            self.db = db
            // Om iPadens SQLite har FTS5 med trigram syns här (provat bara i simulatorn).
            AppLog.shared.write("Sökregistret: SQLite \(found.sqliteVersion), söker med \(found.mode.rawValue)")
        } catch {
            AppLog.shared.write("sokregister.sqlite gick inte att öppna: \(error)")
        }
        return db
    }

    /// Provar att skapa en tillfällig virtuell tabell.
    private static func probe(_ db: SQLiteDatabase, _ module: String) -> Bool {
        do {
            try db.executeScript("CREATE VIRTUAL TABLE temp.lasa_prov USING \(module); DROP TABLE temp.lasa_prov;")
            return true
        } catch {
            try? db.executeScript("DROP TABLE IF EXISTS temp.lasa_prov;")
            return false
        }
    }

    /// FTS5-indexet över den vikta texten, med utlösare som håller det i takt med tabellen.
    private static func setUpFTS(_ db: SQLiteDatabase) -> Bool {
        do {
            var existed = false
            try db.query("SELECT 1 FROM sqlite_master WHERE name = 'sections_fts'") { _ in existed = true }
            try db.transaction {
                try db.executeScript("""
                    CREATE VIRTUAL TABLE IF NOT EXISTS sections_fts USING fts5(
                        folded, content = 'sections', content_rowid = 'id', tokenize = 'trigram');
                    CREATE TRIGGER IF NOT EXISTS sections_ai AFTER INSERT ON sections BEGIN
                        INSERT INTO sections_fts (rowid, folded) VALUES (new.id, new.folded);
                    END;
                    CREATE TRIGGER IF NOT EXISTS sections_ad AFTER DELETE ON sections BEGIN
                        INSERT INTO sections_fts (sections_fts, rowid, folded) VALUES ('delete', old.id, old.folded);
                    END;
                    """)
                if !existed {
                    // Avsnitt som sparades utan index (till exempel före en uppdatering) kommer med.
                    try db.executeScript("INSERT INTO sections_fts (sections_fts) VALUES ('rebuild');")
                }
            }
            return true
        } catch {
            AppLog.shared.write("Sökregistret: FTS5-indexet kunde inte skapas, söker i den vanliga tabellen: \(error)")
            return false
        }
    }
}
