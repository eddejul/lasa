import Foundation

/// Ett synonympar som användaren har markerat som fel. Det döljs bara i den här appen.
struct HiddenPair: Hashable {
    let language: WordLanguage
    let lemma: String
    let synonym: String
}

/// Ett ord som har slagits upp i en bok.
struct SavedWord {
    let id: Int
    let word: String
    let lemma: String
    let language: WordLanguage
    let sentence: String
    let book: String
    /// Sidans plats i filen, från 0.
    let pageIndex: Int
    let lookups: Int
    let date: Date
    /// O7: betydelsen som valts när ordet sparades (id ur ordboken), tom om ingen valts.
    var senseID = ""
}

/// D3-1: allt som sparas om ett ord, raden i `saved_words` och i `reviews`, så att en borttagning kan
/// ångras med samma id, bok, betydelse, mening och repetition.
struct SavedWordRecord: Equatable {
    struct Review: Equatable {
        var due: Double
        var interval: Double
        var ease: Double
        var reps: Int
        var lapses: Int
        var introduced: Double
        var updated: Double
    }

    var id: Int
    var word: String
    var lemma: String
    var language: String
    var sentence: String
    var book: String
    var page: Int
    var lookups: Int
    var created: Double
    var updated: Double
    var bookID: String
    var senseID: String
    /// Repetitionen, eller nil om ordet aldrig har repeterats.
    var review: Review?
}

/// Sparade ord och dolda synonympar, i en egen liten databas under Application Support.
/// Ordboken i appen ändras aldrig, så det användaren gör ligger här. Fas 6 synkar den här datan.
/// Används bara från huvudtråden.
final class UserWords {

    static let shared = UserWords()

    /// Skickas när sparade ord eller deras repetition har ändrats (O4: strecken i texten ritas om).
    static let didChange = Notification.Name("UserWordsDidChange")

    private let db: SQLiteDatabase?
    private(set) var hiddenPairs: Set<HiddenPair> = []

    /// Namnet i felmeddelanden.
    private static let name = "Sparade ord"

    /// Databasens versioner, en trappa. Steg 1 är tabellerna som de var före G8, så en befintlig databas
    /// (version 0) får bara versionsnumret. Lägg nya steg sist, till exempel `ALTER TABLE ... ADD COLUMN`.
    static let migrations: [String] = [
        """
            CREATE TABLE IF NOT EXISTS saved_words (
                id INTEGER PRIMARY KEY,
                word TEXT NOT NULL,
                lemma TEXT NOT NULL,
                language TEXT NOT NULL,
                sentence TEXT NOT NULL,
                book TEXT NOT NULL,
                page INTEGER NOT NULL,
                lookups INTEGER NOT NULL DEFAULT 1,
                created REAL NOT NULL,
                updated REAL NOT NULL,
                UNIQUE (lemma, language)
            );
            CREATE TABLE IF NOT EXISTS hidden_pairs (
                language TEXT NOT NULL,
                lemma TEXT NOT NULL,
                synonym TEXT NOT NULL,
                created REAL NOT NULL,
                PRIMARY KEY (language, lemma, synonym)
            );
            CREATE TABLE IF NOT EXISTS reviews (
                lemma TEXT NOT NULL,
                language TEXT NOT NULL,
                due REAL NOT NULL,
                interval REAL NOT NULL DEFAULT 0,
                ease REAL NOT NULL DEFAULT 2.5,
                reps INTEGER NOT NULL DEFAULT 0,
                lapses INTEGER NOT NULL DEFAULT 0,
                introduced REAL NOT NULL,
                updated REAL NOT NULL,
                PRIMARY KEY (lemma, language)
            );
            CREATE TABLE IF NOT EXISTS deleted_words (
                lemma TEXT NOT NULL,
                language TEXT NOT NULL,
                deleted REAL NOT NULL,
                PRIMARY KEY (lemma, language)
            );
            """,
        // Steg 2 (G3): bokens id i bokregistret, utöver titeln. Fylls i för gamla ord när böckerna flyttas
        // till id:t, och för nya ord när de sparas. Synken skickar fortfarande bara titeln.
        """
            ALTER TABLE saved_words ADD COLUMN book_id TEXT NOT NULL DEFAULT '';
            """,
        // Steg 3 (O7): betydelsen som valts för ordet (sense_id i ordboken), tom när ingen valts.
        // Den följer inte med i synken ännu.
        """
            ALTER TABLE saved_words ADD COLUMN sense_id TEXT NOT NULL DEFAULT '';
            """,
    ]

    /// Databasens fil, till säkerhetskopian.
    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("anvandarord.sqlite")
    }

    private convenience init() {
        self.init(fileURL: Self.fileURL)
    }

    /// En egen databasfil, till testerna. Appen använder bara `shared`.
    init(fileURL url: URL) {
        db = Self.open(at: url)
        loadHiddenPairs()
    }

    private static func open(at url: URL) -> SQLiteDatabase? {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            let db = try SQLiteDatabase(path: url.path, readOnly: false)
            // WAL: en sparning blir en snabb skrivning i loggfilen utan att vänta på disken varje gång.
            try db.executeScript("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;")
            let versions = try db.migrate(migrations)
            if versions.from != versions.to {
                AppLog.shared.write("\(url.lastPathComponent): version \(versions.from) till \(versions.to)")
            }
            return db
        } catch {
            AppLog.shared.write("\(url.lastPathComponent) gick inte att öppna: \(error)")
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
            throw SQLiteDatabase.Failure(description: "Databasen för sparade ord gick inte att öppna")
        }
        try db.replaceContents(with: url)
        try db.migrate(Self.migrations)
        loadHiddenPairs()
        changed()
    }

    /// Säger till att orden har ändrats, i nästa varv så att en skrivning hinner klart först.
    fileprivate func changed() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: UserWords.didChange, object: nil)
        }
    }

    /// Kör en skrivning i en transaktion: allt eller inget. Går det inte säger appen till.
    @discardableResult
    fileprivate func write(_ what: String, _ body: (SQLiteDatabase) throws -> Void) -> Bool {
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
    fileprivate func read(_ what: String, _ body: (SQLiteDatabase) throws -> Void) {
        guard let db = db else { return }
        do {
            try body(db)
        } catch {
            AppLog.shared.write("Sparade ord: \(what) kunde inte läsas: \(error)")
        }
    }

    // MARK: Sparade ord

    /// Sparar ett uppslaget ord. Har det slagits upp förut räknas det upp, och meningen byts mot den senaste.
    func save(word: String, lemma: String, language: WordLanguage, sentence: String, book: String, pageIndex: Int,
              bookID: String? = nil) {
        let now = Date().timeIntervalSince1970
        write("ordet") { db in
            try db.execute("""
                INSERT INTO saved_words (word, lemma, language, sentence, book, page, lookups, created, updated, book_id)
                VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?, ?)
                ON CONFLICT (lemma, language) DO UPDATE SET
                    word = excluded.word, sentence = excluded.sentence, book = excluded.book,
                    page = excluded.page, lookups = lookups + 1, updated = excluded.updated,
                    book_id = excluded.book_id
                """, [word, lemma, language.rawValue, sentence, book, pageIndex, now, now, bookID ?? ""])
            try db.execute("DELETE FROM deleted_words WHERE lemma = ? AND language = ?", [lemma, language.rawValue])
        }
        changed()
    }

    /// De sparade orden, senast uppslaget först.
    func savedWords() -> [SavedWord] {
        var words: [SavedWord] = []
        read("orden") { db in
            try db.query("""
                SELECT id, word, lemma, language, sentence, book, page, lookups, updated, sense_id
                FROM saved_words ORDER BY updated DESC
                """) { row in
                words.append(SavedWord(id: row.int(0),
                                       word: row.string(1),
                                       lemma: row.string(2),
                                       language: WordLanguage(rawValue: row.string(3)) ?? .swedish,
                                       sentence: row.string(4),
                                       book: row.string(5),
                                       pageIndex: row.int(6),
                                       lookups: row.int(7),
                                       date: Date(timeIntervalSince1970: row.double(8)),
                                       senseID: row.string(9)))
            }
        }
        return words
    }

    func delete(savedWordID id: Int) {
        write("borttagningen") { db in
            var found: (String, String)?
            try db.query("SELECT lemma, language FROM saved_words WHERE id = ?", [id]) { row in
                found = (row.string(0), row.string(1))
            }
            try db.execute("DELETE FROM saved_words WHERE id = ?", [id])
            if let found = found {
                try Self.rememberDeleted(db, lemma: found.0, language: found.1)
            }
        }
        changed()
    }

    /// Tar bort ordet och dess repetition. Svarar med allt som togs bort, så att det kan ångras (D3-1),
    /// eller nil om ordet inte var sparat eller borttagningen inte gick.
    @discardableResult
    func delete(lemma: String, language: WordLanguage) -> SavedWordRecord? {
        var removed: SavedWordRecord?
        let done = write("borttagningen") { db in
            removed = try Self.readRecord(db, lemma: lemma, language: language.rawValue)
            try db.execute("DELETE FROM saved_words WHERE lemma = ? AND language = ?", [lemma, language.rawValue])
            try Self.rememberDeleted(db, lemma: lemma, language: language.rawValue)
        }
        changed()
        return done ? removed : nil
    }

    /// D3-1: lägger tillbaka ett ord som just tagits bort (Ångra): samma id, bok, betydelse, mening och hela
    /// repetitionen, och borttagningen glöms. Har ordet sparats igen under tiden ersätts den nya raden.
    /// Ordets ändringstid blir nu, så att synken skickar ordet som levande även om borttagningen redan
    /// hunnit till servern. Repetitionens egen tid står kvar.
    @discardableResult
    func restoreDeleted(_ record: SavedWordRecord, now: Date = Date()) -> Bool {
        let done = write("ångrandet") { db in
            var deletedAt = 0.0
            try db.query("SELECT deleted FROM deleted_words WHERE lemma = ? AND language = ?",
                         [record.lemma, record.language]) { row in
                deletedAt = row.double(0)
            }
            try db.execute("DELETE FROM saved_words WHERE lemma = ? AND language = ?", [record.lemma, record.language])
            // Ett nytt ord tar nästa lediga nummer, så ett annat ord kan ha fått samma under tiden.
            // Då får ordet ett nytt nummer (null ger nästa lediga).
            var taken = false
            try db.query("SELECT 1 FROM saved_words WHERE id = ?", [record.id]) { _ in
                taken = true
            }
            var id: Any? = record.id
            if taken {
                id = nil
            }
            let updated = max(now.timeIntervalSince1970, deletedAt + 0.001, record.updated)
            try db.execute("""
                INSERT INTO saved_words (id, word, lemma, language, sentence, book, page, lookups, created, updated,
                                         book_id, sense_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [id, record.word, record.lemma, record.language, record.sentence, record.book, record.page,
                      record.lookups, record.created, updated, record.bookID, record.senseID])
            try db.execute("DELETE FROM deleted_words WHERE lemma = ? AND language = ?", [record.lemma, record.language])
            try db.execute("DELETE FROM reviews WHERE lemma = ? AND language = ?", [record.lemma, record.language])
            if let review = record.review {
                try db.execute("""
                    INSERT INTO reviews (lemma, language, due, interval, ease, reps, lapses, introduced, updated)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [record.lemma, record.language, review.due, review.interval, review.ease, review.reps,
                          review.lapses, review.introduced, review.updated])
            }
        }
        if done {
            changed()
        }
        return done
    }

    /// Allt om ett sparat ord, eller nil om det inte är sparat (till Ångra, testerna och självtestet).
    func savedWordRecord(lemma: String, language: WordLanguage) -> SavedWordRecord? {
        var found: SavedWordRecord?
        read("ordet") { db in
            found = try Self.readRecord(db, lemma: lemma, language: language.rawValue)
        }
        return found
    }

    /// När ordet togs bort, eller nil om det inte är borttaget (till testerna och självtestet).
    func deletionTime(lemma: String, language: WordLanguage) -> Double? {
        var found: Double?
        read("borttagningen") { db in
            try db.query("SELECT deleted FROM deleted_words WHERE lemma = ? AND language = ?",
                         [lemma, language.rawValue]) { row in
                found = row.double(0)
            }
        }
        return found
    }

    private static func readRecord(_ db: SQLiteDatabase, lemma: String, language: String) throws -> SavedWordRecord? {
        var found: SavedWordRecord?
        try db.query("""
            SELECT id, word, lemma, language, sentence, book, page, lookups, created, updated, book_id, sense_id
            FROM saved_words WHERE lemma = ? AND language = ?
            """, [lemma, language]) { row in
            found = SavedWordRecord(id: row.int(0), word: row.string(1), lemma: row.string(2), language: row.string(3),
                                    sentence: row.string(4), book: row.string(5), page: row.int(6),
                                    lookups: row.int(7), created: row.double(8), updated: row.double(9),
                                    bookID: row.string(10), senseID: row.string(11), review: nil)
        }
        guard var record = found else { return nil }
        try db.query("""
            SELECT due, interval, ease, reps, lapses, introduced, updated FROM reviews WHERE lemma = ? AND language = ?
            """, [lemma, language]) { row in
            record.review = SavedWordRecord.Review(due: row.double(0), interval: row.double(1), ease: row.double(2),
                                                   reps: row.int(3), lapses: row.int(4), introduced: row.double(5),
                                                   updated: row.double(6))
        }
        return record
    }

    /// Ett borttaget ord minns med tiden, så att synken (fas 6) kan ta bort det på andra enheter.
    /// Ordets repetition tas bort samtidigt.
    private static func rememberDeleted(_ db: SQLiteDatabase, lemma: String, language: String) throws {
        let now = Date().timeIntervalSince1970
        try db.execute("INSERT OR REPLACE INTO deleted_words (lemma, language, deleted) VALUES (?, ?, ?)",
                       [lemma, language, now])
        try db.execute("DELETE FROM reviews WHERE lemma = ? AND language = ?", [lemma, language])
    }

    /// O7: sparar betydelsen som valts för ett sparat ord. Ett ord som inte är sparat ändras inte.
    func setSense(lemma: String, language: WordLanguage, senseID: String) {
        write("betydelsen") { db in
            try db.execute("UPDATE saved_words SET sense_id = ? WHERE lemma = ? AND language = ?",
                           [senseID, lemma, language.rawValue])
        }
    }

    /// O7: betydelsen som valts för ordet, eller nil om ordet inte är sparat eller ingen valts.
    func senseID(lemma: String, language: WordLanguage) -> String? {
        var found: String?
        read("betydelsen") { db in
            try db.query("SELECT sense_id FROM saved_words WHERE lemma = ? AND language = ?",
                         [lemma, language.rawValue]) { row in
                found = row.string(0)
            }
        }
        return found.flatMap { $0.isEmpty ? nil : $0 }
    }

    func isSaved(lemma: String, language: WordLanguage) -> Bool {
        var found = false
        read("ett ord") { db in
            try db.query("SELECT 1 FROM saved_words WHERE lemma = ? AND language = ?", [lemma, language.rawValue]) { _ in
                found = true
            }
        }
        return found
    }

    // MARK: Fel synonym

    func hide(_ pair: HiddenPair) {
        write("den dolda synonymen") { db in
            try db.execute("INSERT OR IGNORE INTO hidden_pairs VALUES (?, ?, ?, ?)",
                           [pair.language.rawValue, pair.lemma, pair.synonym, Date().timeIntervalSince1970])
        }
        hiddenPairs.insert(pair)
    }

    func unhide(_ pair: HiddenPair) {
        write("synonymen") { db in
            try db.execute("DELETE FROM hidden_pairs WHERE language = ? AND lemma = ? AND synonym = ?",
                           [pair.language.rawValue, pair.lemma, pair.synonym])
        }
        hiddenPairs.remove(pair)
    }

    /// Läser om de dolda paren, till exempel efter en återställning.
    func loadHiddenPairs() {
        var pairs = Set<HiddenPair>()
        read("de dolda synonymerna") { db in
            try db.query("SELECT language, lemma, synonym FROM hidden_pairs") { row in
                guard let language = WordLanguage(rawValue: row.string(0)) else { return }
                pairs.insert(HiddenPair(language: language, lemma: row.string(1), synonym: row.string(2)))
            }
        }
        hiddenPairs = pairs
    }
}

// MARK: Repetition (fas 6)

/// Hur väl man kunde ordet.
enum ReviewGrade: Int, CaseIterable {
    case again, hard, good, easy

    var title: String {
        switch self {
        case .again: return "Igen"
        case .hard: return "Svårt"
        case .good: return "Bra"
        case .easy: return "Lätt"
        }
    }
}

/// Ett ord att repetera, med dess plats i schemat.
struct ReviewCard {
    let word: SavedWord
    /// Dagar till nästa gång, 0 för ett nytt ord.
    let interval: Double
    let ease: Double
    let reps: Int
    let lapses: Int
    let isNew: Bool
}

/// Nästa intervall i ett enkelt schema i stil med Anki: ett ord man kan kommer tillbaka allt mer sällan,
/// ett ord man glömt kommer tillbaka om tio minuter.
enum ReviewSchedule {

    static let newPerDay = 20
    static let minimumEase = 1.3

    static func next(_ grade: ReviewGrade, interval: Double, ease: Double, reps: Int)
        -> (interval: Double, ease: Double, reps: Int, lapse: Bool) {
        switch grade {
        case .again:
            return (10.0 / 1440.0, max(minimumEase, ease - 0.2), 0, reps > 0)
        case .hard:
            return (reps == 0 ? 1 : max(1, interval * 1.2), max(minimumEase, ease - 0.15), reps + 1, false)
        case .good:
            let days: Double = reps == 0 ? 1 : (reps == 1 ? 3 : max(interval * ease, interval + 1))
            return (days, ease, reps + 1, false)
        case .easy:
            let days: Double = reps == 0 ? 4 : max(interval * ease * 1.3, interval + 2)
            return (days, ease + 0.15, reps + 1, false)
        }
    }

    /// "10 min", "1 dag", "3 dagar", "2 veckor", "4 mån".
    static func label(days: Double) -> String {
        if days < 1 {
            return "\(max(1, Int((days * 1440).rounded()))) min"
        }
        let whole = Int(days.rounded())
        if whole < 14 {
            return whole == 1 ? "1 dag" : "\(whole) dagar"
        }
        if whole < 60 {
            return "\(Int((days / 7).rounded())) veckor"
        }
        if whole < 365 {
            return "\(Int((days / 30).rounded())) mån"
        }
        let years = days / 365
        return years < 1.5 ? "1 år" : String(format: "%.1f år", years).replacingOccurrences(of: ".", with: ",")
    }
}

extension UserWords {

    /// Orden att repetera nu: först de som är på tur, sedan nya ord (äldst först), högst 20 nya per dag.
    func reviewQueue(now: Date = Date(), limit: Int = 200) -> [ReviewCard] {
        let all = savedWords()
        var states: [String: (due: Double, interval: Double, ease: Double, reps: Int, lapses: Int)] = [:]
        var introducedToday = 0
        let startOfDay = Calendar.current.startOfDay(for: now).timeIntervalSince1970
        read("repetitionen") { db in
            try db.query("SELECT lemma, language, due, interval, ease, reps, lapses, introduced FROM reviews") { row in
                states[row.string(1) + "|" + row.string(0)] = (row.double(2), row.double(3), row.double(4),
                                                               row.int(5), row.int(6))
                if row.double(7) >= startOfDay {
                    introducedToday += 1
                }
            }
        }
        let current = now.timeIntervalSince1970
        var due: [(Double, ReviewCard)] = []
        var fresh: [ReviewCard] = []
        for word in all {
            if let state = states[word.language.rawValue + "|" + word.lemma] {
                if state.due <= current {
                    due.append((state.due, ReviewCard(word: word, interval: state.interval, ease: state.ease,
                                                      reps: state.reps, lapses: state.lapses, isNew: false)))
                }
            } else {
                fresh.append(ReviewCard(word: word, interval: 0, ease: 2.5, reps: 0, lapses: 0, isNew: true))
            }
        }
        let newAllowed = max(0, ReviewSchedule.newPerDay - introducedToday)
        let cards = due.sorted { $0.0 < $1.0 }.map { $0.1 } + Array(fresh.reversed().prefix(newAllowed))
        return Array(cards.prefix(limit))
    }

    /// O4: repetitionens intervall i dagar per ord (nyckel språk|grundform).
    func reviewIntervals() -> [String: Double] {
        var result: [String: Double] = [:]
        read("repetitionens intervall") { db in
            try db.query("SELECT lemma, language, interval FROM reviews") { row in
                result[row.string(1) + "|" + row.string(0)] = row.double(2)
            }
        }
        return result
    }

    /// Antalet ord på tur och nya ord som kan tas i dag, till knappen Repetera.
    func reviewCount(now: Date = Date()) -> Int {
        reviewQueue(now: now).count
    }

    /// Sparar hur det gick och räknar ut nästa gång. Svarar med antalet dagar till nästa gång.
    @discardableResult
    func record(_ grade: ReviewGrade, for card: ReviewCard, now: Date = Date()) -> Double {
        let next = ReviewSchedule.next(grade, interval: card.interval, ease: card.ease, reps: card.reps)
        let current = now.timeIntervalSince1970
        write("repetitionen") { db in
            try db.execute("""
                INSERT INTO reviews (lemma, language, due, interval, ease, reps, lapses, introduced, updated)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (lemma, language) DO UPDATE SET
                    due = excluded.due, interval = excluded.interval, ease = excluded.ease, reps = excluded.reps,
                    lapses = excluded.lapses, updated = excluded.updated
                """, [card.word.lemma, card.word.language.rawValue, current + next.interval * 86_400, next.interval,
                      next.ease, next.reps, card.lapses + (next.lapse ? 1 : 0), current, current])
        }
        changed()
        return next.interval
    }
}

// MARK: Synk (fas 6)

/// Ett sparat ord som det skickas mellan enheterna, med repetitionen.
struct SyncWord: Equatable {
    var lemma: String
    var language: String
    var word = ""
    var sentence = ""
    var book = ""
    var page = 0
    var lookups = 1
    var created: Double = 0
    var updated: Double = 0
    var deleted = false
    var due: Double?
    var interval: Double?
    var ease: Double?
    var reps: Int?
    var lapses: Int?
    var reviewUpdated: Double?

    var key: String {
        language + "|" + lemma
    }
}

extension UserWords {

    /// Alla sparade och borttagna ord, med repetitionen.
    func wordsForSync() -> [SyncWord] {
        var words: [String: SyncWord] = [:]
        read("orden till synken") { db in
            try db.query("SELECT word, lemma, language, sentence, book, page, lookups, created, updated FROM saved_words") { row in
                let word = SyncWord(lemma: row.string(1), language: row.string(2), word: row.string(0),
                                    sentence: row.string(3), book: row.string(4), page: row.int(5), lookups: row.int(6),
                                    created: row.double(7), updated: row.double(8))
                words[word.key] = word
            }
            try db.query("SELECT lemma, language, deleted FROM deleted_words") { row in
                let key = row.string(1) + "|" + row.string(0)
                if let existing = words[key], existing.updated >= row.double(2) {
                    return
                }
                words[key] = SyncWord(lemma: row.string(0), language: row.string(1), created: row.double(2),
                                      updated: row.double(2), deleted: true)
            }
            try db.query("SELECT lemma, language, due, interval, ease, reps, lapses, updated FROM reviews") { row in
                let key = row.string(1) + "|" + row.string(0)
                guard var word = words[key], !word.deleted else { return }
                word.due = row.double(2)
                word.interval = row.double(3)
                word.ease = row.double(4)
                word.reps = row.int(5)
                word.lapses = row.int(6)
                word.reviewUpdated = row.double(7)
                words[key] = word
            }
        }
        return Array(words.values)
    }

    /// G3: sparade ord från före bokregistret får bokens id, när titeln hör till exakt en bok.
    /// Titeln (`book`) står kvar, den visas och synkas som förut. Går att köra om utan skada.
    func linkBooks(_ books: [(id: String, title: String)]) {
        var byTitle: [String: [String]] = [:]
        for book in books {
            byTitle[book.title, default: []].append(book.id)
        }
        let unique = byTitle.compactMapValues { $0.count == 1 ? $0[0] : nil }
        guard !unique.isEmpty else { return }
        write("bokens id i sparade ord") { db in
            for (title, id) in unique {
                try db.execute("UPDATE saved_words SET book_id = ? WHERE book = ? AND book_id = ''", [id, title])
            }
        }
    }

    /// Antalet sparade ord med bokens id, till självtestet.
    func linkedWordCount(bookID: String) -> Int {
        var count = 0
        read("orden med bokens id") { db in
            try db.query("SELECT COUNT(*) FROM saved_words WHERE book_id = ?", [bookID]) { count = $0.int(0) }
        }
        return count
    }

    /// Sparar ett ord från en annan enhet med dess egna tider, eller tar bort det.
    func applySynced(_ word: SyncWord) {
        write("ordet från synken") { db in
            if word.deleted {
                try db.execute("DELETE FROM saved_words WHERE lemma = ? AND language = ?", [word.lemma, word.language])
                try db.execute("DELETE FROM reviews WHERE lemma = ? AND language = ?", [word.lemma, word.language])
                try db.execute("INSERT OR REPLACE INTO deleted_words (lemma, language, deleted) VALUES (?, ?, ?)",
                               [word.lemma, word.language, word.updated])
                return
            }
            try db.execute("""
                INSERT INTO saved_words (word, lemma, language, sentence, book, page, lookups, created, updated)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (lemma, language) DO UPDATE SET
                    word = excluded.word, sentence = excluded.sentence, book = excluded.book, page = excluded.page,
                    lookups = excluded.lookups, created = excluded.created, updated = excluded.updated
                """, [word.word, word.lemma, word.language, word.sentence, word.book, word.page, word.lookups,
                      word.created, word.updated])
            try db.execute("DELETE FROM deleted_words WHERE lemma = ? AND language = ?", [word.lemma, word.language])
            if let due = word.due, let reviewUpdated = word.reviewUpdated {
                try db.execute("""
                    INSERT INTO reviews (lemma, language, due, interval, ease, reps, lapses, introduced, updated)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (lemma, language) DO UPDATE SET
                        due = excluded.due, interval = excluded.interval, ease = excluded.ease, reps = excluded.reps,
                        lapses = excluded.lapses, updated = excluded.updated
                    """, [word.lemma, word.language, due, word.interval ?? 0, word.ease ?? 2.5, word.reps ?? 0,
                          word.lapses ?? 0, reviewUpdated, reviewUpdated])
            }
        }
        changed()
    }
}
