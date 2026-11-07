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
}

/// Sparade ord och dolda synonympar, i en egen liten databas under Application Support.
/// Ordboken i appen ändras aldrig, så det användaren gör ligger här. Fas 6 synkar den här datan.
/// Används bara från huvudtråden.
final class UserWords {

    static let shared = UserWords()

    private let db: SQLiteDatabase?
    private(set) var hiddenPairs: Set<HiddenPair> = []

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let path = support.appendingPathComponent("anvandarord.sqlite").path
        db = try? SQLiteDatabase(path: path, readOnly: false)
        try? db?.executeScript("""
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
            """)
        loadHiddenPairs()
    }

    // MARK: Sparade ord

    /// Sparar ett uppslaget ord. Har det slagits upp förut räknas det upp, och meningen byts mot den senaste.
    func save(word: String, lemma: String, language: WordLanguage, sentence: String, book: String, pageIndex: Int) {
        let now = Date().timeIntervalSince1970
        try? db?.execute("""
            INSERT INTO saved_words (word, lemma, language, sentence, book, page, lookups, created, updated)
            VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?)
            ON CONFLICT (lemma, language) DO UPDATE SET
                word = excluded.word, sentence = excluded.sentence, book = excluded.book,
                page = excluded.page, lookups = lookups + 1, updated = excluded.updated
            """, [word, lemma, language.rawValue, sentence, book, pageIndex, now, now])
        try? db?.execute("DELETE FROM deleted_words WHERE lemma = ? AND language = ?", [lemma, language.rawValue])
    }

    /// De sparade orden, senast uppslaget först.
    func savedWords() -> [SavedWord] {
        var words: [SavedWord] = []
        try? db?.query("""
            SELECT id, word, lemma, language, sentence, book, page, lookups, updated
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
                                   date: Date(timeIntervalSince1970: row.double(8))))
        }
        return words
    }

    func delete(savedWordID id: Int) {
        var found: (String, String)?
        try? db?.query("SELECT lemma, language FROM saved_words WHERE id = ?", [id]) { row in
            found = (row.string(0), row.string(1))
        }
        try? db?.execute("DELETE FROM saved_words WHERE id = ?", [id])
        if let found = found {
            rememberDeleted(lemma: found.0, language: found.1)
        }
    }

    func delete(lemma: String, language: WordLanguage) {
        try? db?.execute("DELETE FROM saved_words WHERE lemma = ? AND language = ?", [lemma, language.rawValue])
        rememberDeleted(lemma: lemma, language: language.rawValue)
    }

    /// Ett borttaget ord minns med tiden, så att synken (fas 6) kan ta bort det på andra enheter.
    /// Ordets repetition tas bort samtidigt.
    private func rememberDeleted(lemma: String, language: String) {
        let now = Date().timeIntervalSince1970
        try? db?.execute("INSERT OR REPLACE INTO deleted_words (lemma, language, deleted) VALUES (?, ?, ?)",
                         [lemma, language, now])
        try? db?.execute("DELETE FROM reviews WHERE lemma = ? AND language = ?", [lemma, language])
    }

    func isSaved(lemma: String, language: WordLanguage) -> Bool {
        var found = false
        try? db?.query("SELECT 1 FROM saved_words WHERE lemma = ? AND language = ?", [lemma, language.rawValue]) { _ in
            found = true
        }
        return found
    }

    // MARK: Fel synonym

    func hide(_ pair: HiddenPair) {
        try? db?.execute("INSERT OR IGNORE INTO hidden_pairs VALUES (?, ?, ?, ?)",
                         [pair.language.rawValue, pair.lemma, pair.synonym, Date().timeIntervalSince1970])
        hiddenPairs.insert(pair)
    }

    func unhide(_ pair: HiddenPair) {
        try? db?.execute("DELETE FROM hidden_pairs WHERE language = ? AND lemma = ? AND synonym = ?",
                         [pair.language.rawValue, pair.lemma, pair.synonym])
        hiddenPairs.remove(pair)
    }

    private func loadHiddenPairs() {
        var pairs = Set<HiddenPair>()
        try? db?.query("SELECT language, lemma, synonym FROM hidden_pairs") { row in
            guard let language = WordLanguage(rawValue: row.string(0)) else { return }
            pairs.insert(HiddenPair(language: language, lemma: row.string(1), synonym: row.string(2)))
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
        try? reviewDatabase?.query("SELECT lemma, language, due, interval, ease, reps, lapses, introduced FROM reviews") { row in
            states[row.string(1) + "|" + row.string(0)] = (row.double(2), row.double(3), row.double(4),
                                                           row.int(5), row.int(6))
            if row.double(7) >= startOfDay {
                introducedToday += 1
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

    /// Antalet ord på tur och nya ord som kan tas i dag, till knappen Repetera.
    func reviewCount(now: Date = Date()) -> Int {
        reviewQueue(now: now).count
    }

    /// Sparar hur det gick och räknar ut nästa gång. Svarar med antalet dagar till nästa gång.
    @discardableResult
    func record(_ grade: ReviewGrade, for card: ReviewCard, now: Date = Date()) -> Double {
        let next = ReviewSchedule.next(grade, interval: card.interval, ease: card.ease, reps: card.reps)
        let current = now.timeIntervalSince1970
        try? reviewDatabase?.execute("""
            INSERT INTO reviews (lemma, language, due, interval, ease, reps, lapses, introduced, updated)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (lemma, language) DO UPDATE SET
                due = excluded.due, interval = excluded.interval, ease = excluded.ease, reps = excluded.reps,
                lapses = excluded.lapses, updated = excluded.updated
            """, [card.word.lemma, card.word.language.rawValue, current + next.interval * 86_400, next.interval,
                  next.ease, next.reps, card.lapses + (next.lapse ? 1 : 0), current, current])
        return next.interval
    }

    /// Databasen, för repetitionen i den här filen.
    fileprivate var reviewDatabase: SQLiteDatabase? {
        db
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
        try? db?.query("SELECT word, lemma, language, sentence, book, page, lookups, created, updated FROM saved_words") { row in
            let word = SyncWord(lemma: row.string(1), language: row.string(2), word: row.string(0),
                                sentence: row.string(3), book: row.string(4), page: row.int(5), lookups: row.int(6),
                                created: row.double(7), updated: row.double(8))
            words[word.key] = word
        }
        try? db?.query("SELECT lemma, language, deleted FROM deleted_words") { row in
            let key = row.string(1) + "|" + row.string(0)
            if let existing = words[key], existing.updated >= row.double(2) {
                return
            }
            words[key] = SyncWord(lemma: row.string(0), language: row.string(1), created: row.double(2),
                                  updated: row.double(2), deleted: true)
        }
        try? db?.query("SELECT lemma, language, due, interval, ease, reps, lapses, updated FROM reviews") { row in
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
        return Array(words.values)
    }

    /// Sparar ett ord från en annan enhet med dess egna tider, eller tar bort det.
    func applySynced(_ word: SyncWord) {
        if word.deleted {
            try? db?.execute("DELETE FROM saved_words WHERE lemma = ? AND language = ?", [word.lemma, word.language])
            try? db?.execute("DELETE FROM reviews WHERE lemma = ? AND language = ?", [word.lemma, word.language])
            try? db?.execute("INSERT OR REPLACE INTO deleted_words (lemma, language, deleted) VALUES (?, ?, ?)",
                             [word.lemma, word.language, word.updated])
            return
        }
        try? db?.execute("""
            INSERT INTO saved_words (word, lemma, language, sentence, book, page, lookups, created, updated)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (lemma, language) DO UPDATE SET
                word = excluded.word, sentence = excluded.sentence, book = excluded.book, page = excluded.page,
                lookups = excluded.lookups, created = excluded.created, updated = excluded.updated
            """, [word.word, word.lemma, word.language, word.sentence, word.book, word.page, word.lookups,
                  word.created, word.updated])
        try? db?.execute("DELETE FROM deleted_words WHERE lemma = ? AND language = ?", [word.lemma, word.language])
        if let due = word.due, let reviewUpdated = word.reviewUpdated {
            try? db?.execute("""
                INSERT INTO reviews (lemma, language, due, interval, ease, reps, lapses, introduced, updated)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (lemma, language) DO UPDATE SET
                    due = excluded.due, interval = excluded.interval, ease = excluded.ease, reps = excluded.reps,
                    lapses = excluded.lapses, updated = excluded.updated
                """, [word.lemma, word.language, due, word.interval ?? 0, word.ease ?? 2.5, word.reps ?? 0,
                      word.lapses ?? 0, reviewUpdated, reviewUpdated])
        }
    }
}
