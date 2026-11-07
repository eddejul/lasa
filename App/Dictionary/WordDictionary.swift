import Foundation
import NaturalLanguage

/// Språket som ett ord slås upp i.
enum WordLanguage: String {
    case swedish = "sv"
    case english = "en"

    var name: String {
        switch self {
        case .swedish: return "svenska"
        case .english: return "engelska"
        }
    }

    var other: WordLanguage {
        self == .swedish ? .english : .swedish
    }
}

struct Synonym: Hashable {
    let word: String
    /// Synlex-betyget 3 till 5 för svenska. Saknas för engelska (WordNet har inga betyg).
    let score: Double?
}

/// En betydelse med sina synonymer. Engelska betydelser har en kort definition.
struct WordSense {
    let id: String
    let definition: String?
    let synonyms: [Synonym]
}

struct Translation {
    let text: String
    let comment: String
}

/// Ett uppslagsord: grundform och ordklass, med synonymer per betydelse och (för engelska) översättningar.
struct WordEntry {
    let lemma: String
    let pos: String
    let posName: String
    let senses: [WordSense]
    let translations: [Translation]

    var hasContent: Bool {
        !senses.isEmpty || !translations.isEmpty
    }

    var synonymCount: Int {
        senses.reduce(0) { $0 + $1.synonyms.count }
    }
}

/// Svaret på ett uppslag.
struct WordLookup {
    /// Ordet som det stod i texten.
    let word: String
    /// Normaliserat: gemener, utan skiljetecken runt om.
    let key: String
    let language: WordLanguage
    let entries: [WordEntry]
    /// Sammansatt ord som inte finns i ordboken, delat i förled och efterled. Efterledet slås upp.
    let compound: (head: String, tail: String)?
    /// Ordet finns också i det andra språkets tabell, så att man kan byta.
    let otherLanguageAvailable: Bool

    var isEmpty: Bool {
        entries.isEmpty
    }
}

/// Ordboken: en SQLite-fil som byggs av tools/dictionary/build.py och ligger i appen.
///
/// Logiken här ska vara densamma som i tools/dictionary/lookup.py, som testrapporten använder.
/// Ändras den ena ska den andra ändras också. Används bara från huvudtråden.
final class WordDictionary {

    static let fileName = "lasa-ordbok"

    /// Ordboken, eller nil om filen saknas i appen.
    static let shared: WordDictionary? = {
        guard let url = Bundle.main.url(forResource: fileName, withExtension: "sqlite") else { return nil }
        return try? WordDictionary(url: url)
    }()

    static let maxSenses = 8
    static let maxSynonyms = 12
    static let maxTranslations = 8

    private static let swedishPosNames = [
        "nn": "substantiv", "vb": "verb", "av": "adjektiv", "ab": "adverb", "pp": "preposition",
        "pn": "pronomen", "kn": "konjunktion", "sn": "subjunktion", "in": "interjektion",
        "nl": "räkneord", "al": "artikel", "ie": "infinitivmärke",
    ]
    private static let englishPosNames = [
        "n": "substantiv", "v": "verb", "a": "adjektiv", "r": "adverb", "pp": "preposition",
        "pn": "pronomen", "kn": "konjunktion", "in": "interjektion", "rg": "räkneord",
        "article": "artikel", "abbrev": "förkortning", "pc": "particip", "ie": "infinitivmärke",
    ]
    private static let swedishPosOrder = ["vb", "nn", "av", "ab", "pp", "kn", "sn", "pn", "nl", "in", "al", "ie"]
    private static let englishPosOrder = ["v", "n", "a", "r"]

    /// Engelska böjningar, som WordNets morphy: (ändelse, ersättning, ordklass).
    private static let englishRules: [(String, String, String)] = [
        ("s", "", "n"), ("ses", "s", "n"), ("xes", "x", "n"), ("zes", "z", "n"), ("ches", "ch", "n"),
        ("shes", "sh", "n"), ("men", "man", "n"), ("ies", "y", "n"),
        ("s", "", "v"), ("ies", "y", "v"), ("es", "e", "v"), ("es", "", "v"), ("ed", "e", "v"),
        ("ed", "", "v"), ("ing", "e", "v"), ("ing", "", "v"),
        ("er", "", "a"), ("est", "", "a"), ("er", "e", "a"), ("est", "e", "a"), ("ier", "y", "a"), ("iest", "y", "a"),
    ]

    let url: URL
    private let db: SQLiteDatabase
    private(set) var meta: [String: String] = [:]

    init(url: URL) throws {
        self.url = url
        db = try SQLiteDatabase(path: url.path, readOnly: true)
        try db.query("SELECT key, value FROM meta") { row in
            meta[row.string(0)] = row.string(1)
        }
    }

    // MARK: Normalisering

    /// Samma som normalize() i lookup.py: NFKC (ligaturen fi blir f och i), raka apostrofer,
    /// gemener, och utan skiljetecken runt ordet (men kvar inne i det, som i e-post och don't).
    static func normalize(_ word: String) -> String {
        var text = word.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{00AD}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        while let first = text.first, !(first.isLetter || first.isNumber) {
            text.removeFirst()
        }
        while let last = text.last, !(last.isLetter || last.isNumber) {
            text.removeLast()
        }
        return text
    }

    // MARK: Uppslag

    /// Slår upp ett ord ur texten. Språket väljs efter vilken tabell ordet finns i, och avgörs av
    /// meningen när det finns i båda. Oavgjort blir svenska.
    func lookup(_ word: String,
                sentence: String = "",
                rangeInSentence: NSRange? = nil,
                language forced: WordLanguage? = nil,
                hidden: Set<HiddenPair> = []) -> WordLookup? {
        let key = Self.normalize(word)
        guard !key.isEmpty else { return nil }

        let swedish = swedishLemmas(key)
        let english = englishCandidates(key)
        let inSwedish = !swedish.isEmpty
        let inEnglish = !english.isEmpty

        let language: WordLanguage
        if let forced = forced {
            language = forced
        } else if inSwedish && inEnglish {
            language = Self.guessLanguage(of: sentence)
        } else if inEnglish {
            language = .english
        } else {
            language = .swedish
        }

        switch language {
        case .swedish:
            var lemmas = swedish
            var compound: (head: String, tail: String)?
            if lemmas.isEmpty, let split = splitCompound(key) {
                compound = split
                lemmas = swedishLemmas(split.tail)
            }
            guard !lemmas.isEmpty else { return nil }
            let entries = lemmas
                .map { swedishEntry(lemma: $0.lemma, pos: $0.pos, hidden: hidden) }
                .sorted { Self.swedishOrder($0, key: key).lexicographicallyPrecedes(Self.swedishOrder($1, key: key)) }
            return WordLookup(word: word, key: key, language: .swedish, entries: entries,
                              compound: compound, otherLanguageAvailable: inEnglish)
        case .english:
            guard !english.isEmpty else { return nil }
            let preferred = Self.englishPos(of: word, in: sentence, range: rangeInSentence)
            var entries = english.map { englishEntry(lemma: $0.lemma, pos: $0.pos, hidden: hidden) }
            let withContent = entries.filter(\.hasContent)
            if !withContent.isEmpty {
                entries = withContent
            }
            entries.sort {
                Self.englishOrder($0, key: key, preferred: preferred)
                    .lexicographicallyPrecedes(Self.englishOrder($1, key: key, preferred: preferred))
            }
            return WordLookup(word: word, key: key, language: .english, entries: entries,
                              compound: nil, otherLanguageAvailable: inSwedish)
        }
    }

    // MARK: Svenska

    private func swedishLemmas(_ key: String) -> [(lemma: String, pos: String)] {
        var result: [(lemma: String, pos: String)] = []
        try? db.query("SELECT lemma, pos FROM sv_forms WHERE form = ?", [key]) { row in
            result.append((row.string(0), row.string(1)))
        }
        return result
    }

    private func swedishEntry(lemma: String, pos: String, hidden: Set<HiddenPair>) -> WordEntry {
        var grouped: [String: [Synonym]] = [:]
        try? db.query("SELECT sense_id, synonym, score FROM sv_synonyms WHERE lemma = ? AND pos = ?",
                      [lemma, pos]) { row in
            let synonym = row.string(1)
            guard !hidden.contains(HiddenPair(language: .swedish, lemma: lemma, synonym: synonym)) else { return }
            grouped[row.string(0), default: []].append(Synonym(word: synonym, score: row.double(2)))
        }
        let senses = grouped.keys
            .sorted { Self.senseNumber($0) < Self.senseNumber($1) }
            .prefix(Self.maxSenses)
            .map { id -> WordSense in
                let synonyms = grouped[id, default: []]
                    .sorted { ($0.score ?? 0, $1.word) > ($1.score ?? 0, $0.word) }
                return WordSense(id: id, definition: nil, synonyms: Array(synonyms.prefix(Self.maxSynonyms)))
            }
        return WordEntry(lemma: lemma, pos: pos, posName: Self.swedishPosNames[pos] ?? "",
                         senses: senses, translations: [])
    }

    /// lämna..2 ger 2. Par utan känd betydelse (tom sense_id) kommer sist.
    private static func senseNumber(_ id: String) -> Int {
        guard let range = id.range(of: "..", options: .backwards), let number = Int(id[range.upperBound...]) else {
            return 10_000
        }
        return number
    }

    /// Samma ordning som lookup.py: ord med synonymer först, grundformen själv, flest synonymer, ordklass.
    private static func swedishOrder(_ entry: WordEntry, key: String) -> [Int] {
        [entry.senses.isEmpty ? 1 : 0,
         normalize(entry.lemma) == key ? 0 : 1,
         -entry.synonymCount,
         swedishPosOrder.firstIndex(of: entry.pos) ?? 99]
    }

    /// Sammansatta ord som inte finns i SALDO, som kurslitteraturläsning: kurslitteratur + läsning.
    /// Det längsta efterledet som finns, med ett förled som också finns (eventuellt med foge-s), vinner.
    private func splitCompound(_ key: String) -> (head: String, tail: String)? {
        let characters = Array(key)
        guard characters.count >= 7 else { return nil }
        for split in 3..<(characters.count - 3) {
            let head = String(characters[..<split])
            let tail = String(characters[split...])
            guard !swedishLemmas(tail).isEmpty else { continue }
            if !swedishLemmas(head).isEmpty {
                return (head, tail)
            }
            if head.hasSuffix("s"), head.count > 3, !swedishLemmas(String(head.dropLast())).isEmpty {
                return (head, tail)
            }
        }
        return nil
    }

    // MARK: Engelska

    private func englishForms(_ key: String) -> [(lemma: String, pos: String)] {
        var result: [(lemma: String, pos: String)] = []
        try? db.query("SELECT lemma, pos FROM en_forms WHERE form = ?", [key]) { row in
            result.append((row.string(0), row.string(1)))
        }
        return result
    }

    /// (grundform, ordklass) för en engelsk form: först formtabellen, sedan böjningsreglerna.
    private func englishCandidates(_ key: String) -> [(lemma: String, pos: String)] {
        var found: [(lemma: String, pos: String)] = []
        func add(_ rows: [(lemma: String, pos: String)], pos: String? = nil) {
            for row in rows where pos == nil || row.pos == pos {
                if !found.contains(where: { $0.lemma == row.lemma && $0.pos == row.pos }) {
                    found.append(row)
                }
            }
        }

        add(englishForms(key))
        var base = key
        if key.hasSuffix("'s") {
            base = String(key.dropLast(2))
            add(englishForms(base))
        }
        for (suffix, replacement, pos) in Self.englishRules {
            guard base.hasSuffix(suffix), base.count > suffix.count + 1 else { continue }
            let stem = String(base.dropLast(suffix.count)) + replacement
            var rows = englishForms(stem)
            let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
            if !rows.contains(where: { $0.pos == pos }), replacement.isEmpty, stem.count > 2,
               let last = stem.last, stem.dropLast().last == last, !vowels.contains(last) {
                // stopped, stopping, bigger: dubbelteckning. Bara om formen utan den inte redan finns (filled).
                rows = englishForms(String(stem.dropLast()))
            }
            add(rows, pos: pos)
        }
        return found
    }

    private func englishEntry(lemma: String, pos: String, hidden: Set<HiddenPair>) -> WordEntry {
        var senseRows: [(id: String, definition: String)] = []
        try? db.query("""
            SELECT s.synset_id, d.definition FROM en_senses s JOIN en_synsets d ON d.synset_id = s.synset_id
            WHERE s.lemma = ? AND s.pos = ? ORDER BY s.rank
            """, [lemma, pos]) { row in
            senseRows.append((row.string(0), row.string(1)))
        }
        let senses = senseRows.prefix(Self.maxSenses).map { sense -> WordSense in
            var members: [Synonym] = []
            try? db.query("SELECT lemma FROM en_synset_members WHERE synset_id = ? ORDER BY rank", [sense.id]) { row in
                let member = row.string(0)
                guard member.lowercased() != lemma.lowercased(),
                      !hidden.contains(HiddenPair(language: .english, lemma: lemma, synonym: member)) else { return }
                members.append(Synonym(word: member, score: nil))
            }
            return WordSense(id: sense.id, definition: sense.definition, synonyms: Array(members.prefix(Self.maxSynonyms)))
        }

        var translations: [Translation] = []
        var seen = Set<String>()
        try? db.query("SELECT sv, comment FROM en_sv WHERE en_lemma = ? AND pos = ? ORDER BY rank",
                      [Self.normalize(lemma), pos]) { row in
            let text = row.string(0)
            guard seen.insert(text).inserted else { return }
            translations.append(Translation(text: text, comment: row.string(1)))
        }
        return WordEntry(lemma: lemma, pos: pos, posName: Self.englishPosNames[pos] ?? "",
                         senses: Array(senses), translations: Array(translations.prefix(Self.maxTranslations)))
    }

    private static func englishOrder(_ entry: WordEntry, key: String, preferred: String?) -> [Int] {
        [preferred.map { entry.pos == $0 ? 0 : 1 } ?? 0,
         entry.hasContent ? 0 : 1,
         normalize(entry.lemma) == key ? 0 : 1,
         englishPosOrder.firstIndex(of: entry.pos) ?? 99]
    }

    // MARK: Språk och ordklass ur meningen

    /// Svenska eller engelska, efter meningen. Oavgjort, eller för lite text, blir svenska.
    static func guessLanguage(of sentence: String) -> WordLanguage {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.swedish, .english]
        recognizer.processString(sentence)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
        let swedish = hypotheses[.swedish] ?? 0
        let english = hypotheses[.english] ?? 0
        return english > swedish ? .english : .swedish
    }

    /// Ordklassen som ordet har i meningen (n, v, a, r), så att rätt betydelse av till exempel
    /// "attribute" visas först. Fungerar bara för engelska.
    static func englishPos(of word: String, in sentence: String, range: NSRange?) -> String? {
        guard !sentence.isEmpty else { return nil }
        let text = sentence as NSString
        var location = range?.location ?? NSNotFound
        if location == NSNotFound || location >= text.length {
            location = text.range(of: word).location
        }
        guard location != NSNotFound, let index = Range(NSRange(location: location, length: 0), in: sentence)?.lowerBound else {
            return nil
        }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = sentence
        tagger.setLanguage(.english, range: sentence.startIndex..<sentence.endIndex)
        let (tag, _) = tagger.tag(at: index, unit: .word, scheme: .lexicalClass)
        let classes: [NLTag: String] = [.noun: "n", .verb: "v", .adjective: "a", .adverb: "r"]
        return tag.flatMap { classes[$0] }
    }

    // MARK: Om ordboken

    struct Counts {
        let swedishWords: Int
        let swedishPairs: Int
        let englishWords: Int
        let translations: Int
    }

    func counts() -> Counts {
        func count(_ sql: String) -> Int {
            var value = 0
            try? db.query(sql) { row in value = row.int(0) }
            return value
        }
        return Counts(swedishWords: count("SELECT COUNT(DISTINCT lemma) FROM sv_forms"),
                      swedishPairs: count("SELECT COUNT(*) FROM sv_synonyms"),
                      englishWords: count("SELECT COUNT(DISTINCT lemma) FROM en_senses"),
                      translations: count("SELECT COUNT(*) FROM en_sv"))
    }
}
