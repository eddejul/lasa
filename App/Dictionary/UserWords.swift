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
        try? db?.execute("DELETE FROM saved_words WHERE id = ?", [id])
    }

    func delete(lemma: String, language: WordLanguage) {
        try? db?.execute("DELETE FROM saved_words WHERE lemma = ? AND language = ?", [lemma, language.rawValue])
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
