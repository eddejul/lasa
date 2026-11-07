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
    /// Hur vanligt ordet är på Zipf-skalan (wordfreq). Vanliga ord ligger runt 4 till 6.
    let frequency: Double

    var isRare: Bool {
        frequency < WordDictionary.rareFrequency
    }
}

/// En betydelse: en kort definition (engelska alltid, svenska när Folkets lexikon har en) och synonymer,
/// vanliga först.
struct WordSense {
    let id: String
    let definition: String?
    let synonyms: [Synonym]

    /// Synonymerna som visas direkt. Resten finns bakom Visa fler.
    var topSynonyms: [Synonym] {
        Array(synonyms.prefix(WordDictionary.topSynonyms))
    }
}

struct Translation {
    let text: String
    let comment: String
}

/// Ett uppslagsord: grundform och ordklass, med betydelser och (för engelska) svensk översättning.
struct WordEntry {
    let lemma: String
    let pos: String
    let posName: String
    let senses: [WordSense]
    let translations: [Translation]
    /// Saknar ordet egen översättning är den lånad från en synonym med samma betydelse, till exempel
    /// "exceedingly", som får "ytterst" från "extremely". Då står synonymen här.
    let translationVia: String?

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

    /// Ordboken, eller nil om filen saknas i appen eller är av en äldre version.
    static let shared: WordDictionary? = {
        guard let url = Bundle.main.url(forResource: WordDictionary.fileName, withExtension: "sqlite"),
              let dictionary = try? WordDictionary(url: url),
              (Int(dictionary.meta["schema_version"] ?? "") ?? 0) >= WordDictionary.schemaVersion else {
            return nil
        }
        return dictionary
    }()

    /// Samma som SCHEMA_VERSION i build.py.
    static let schemaVersion = 2

    static let maxSenses = 8
    static let maxSynonyms = 12
    static let maxTranslations = 6
    static let topSynonyms = 5
    /// Ord under den här vanligheten märks som ovanliga och visas sist (RARE_ZIPF i lookup.py).
    static let rareFrequency = 2.0
    /// Hur mycket vanligheten väger mot Synlex-betyget när svenska synonymer sorteras.
    static let swedishFrequencyWeight = 0.5
    /// Översättningar ur Folkets svensk-engelska del har rank från och med det här.
    static let reversedRank = 500
    /// Engelska ord utan egen översättning lånar den från en synonym i någon av de första betydelserna.
    static let borrowSenses = 3

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

    // MARK: Synonymernas ordning

    /// Vanliga först, sorterade med `key`. Ovanliga sist, sorterade på samma sätt.
    private static func ordered(_ synonyms: [Synonym], by areInOrder: (Synonym, Synonym) -> Bool) -> [Synonym] {
        let common = synonyms.filter { !$0.isRare }.sorted(by: areInOrder)
        let rare = synonyms.filter(\.isRare).sorted(by: areInOrder)
        return common + rare
    }

    /// Svenska: Synlex-betyget plus vanligheten, så att vanliga och nära synonymer kommer först.
    private static func swedishSynonymOrder(_ a: Synonym, _ b: Synonym) -> Bool {
        let first = (a.score ?? 0) + swedishFrequencyWeight * a.frequency
        let second = (b.score ?? 0) + swedishFrequencyWeight * b.frequency
        return first != second ? first > second : a.word < b.word
    }

    /// Engelska: WordNet har inga betyg, så vanligast först.
    private static func englishSynonymOrder(_ a: Synonym, _ b: Synonym) -> Bool {
        a.frequency != b.frequency ? a.frequency > b.frequency : a.word < b.word
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
        var synonyms: [String: [Synonym]] = [:]
        try? db.query("SELECT sense_id, synonym, score, freq FROM sv_synonyms WHERE lemma = ? AND pos = ?",
                      [lemma, pos]) { row in
            let synonym = row.string(1)
            guard !hidden.contains(HiddenPair(language: .swedish, lemma: lemma, synonym: synonym)) else { return }
            synonyms[row.string(0), default: []].append(Synonym(word: synonym, score: row.double(2),
                                                                 frequency: row.double(3)))
        }
        var definitions: [String: String] = [:]
        var loose: [String] = []
        try? db.query("SELECT sense_id, definition FROM sv_definitions WHERE lemma = ? AND pos = ? ORDER BY rank",
                      [lemma, pos]) { row in
            let sense = row.string(0)
            let definition = row.string(1)
            if !sense.isEmpty {
                if definitions[sense] == nil {
                    definitions[sense] = definition
                }
            } else if !loose.contains(definition) {
                loose.append(definition)
            }
        }

        // Betydelser med nummer först (synonymer och definition ihop), sedan lösa definitioner,
        // sist synonymer utan känd betydelse. Samma ordning som sv_entry i lookup.py.
        let numbered = Set(synonyms.keys).union(definitions.keys).filter { !$0.isEmpty }
            .sorted { Self.senseNumber($0) < Self.senseNumber($1) }
        var senses = numbered.map { id in
            WordSense(id: id,
                      definition: definitions[id],
                      synonyms: Array(Self.ordered(synonyms[id] ?? [], by: Self.swedishSynonymOrder).prefix(Self.maxSynonyms)))
        }
        for (index, definition) in loose.enumerated() {
            // En lös definition på ett ord med en enda betydelse hör till den.
            if senses.count == 1, senses[0].definition == nil {
                senses[0] = WordSense(id: senses[0].id, definition: definition, synonyms: senses[0].synonyms)
                continue
            }
            senses.append(WordSense(id: "definition..\(index)", definition: definition, synonyms: []))
        }
        if let unknown = synonyms[""], !unknown.isEmpty {
            senses.append(WordSense(id: "", definition: nil,
                                    synonyms: Array(Self.ordered(unknown, by: Self.swedishSynonymOrder).prefix(Self.maxSynonyms))))
        }
        return WordEntry(lemma: lemma, pos: pos, posName: Self.swedishPosNames[pos] ?? "",
                         senses: Array(senses.prefix(Self.maxSenses)), translations: [], translationVia: nil)
    }

    /// lämna..2 ger 2. Par utan känd betydelse (tom sense_id) kommer sist.
    private static func senseNumber(_ id: String) -> Int {
        guard let range = id.range(of: "..", options: .backwards), let number = Int(id[range.upperBound...]) else {
            return 10_000
        }
        return number
    }

    /// Samma ordning som lookup.py: ord med innehåll först, grundformen själv, flest synonymer, ordklass.
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

    /// Folkets egna översättningar först. Finns inga används de omvända ur den svensk-engelska delen.
    private func englishTranslations(lemma: String, pos: String) -> [Translation] {
        var direct: [Translation] = []
        var reversed: [Translation] = []
        try? db.query("SELECT sv, comment, rank FROM en_sv WHERE en_lemma = ? AND pos = ? ORDER BY rank",
                      [Self.normalize(lemma), pos]) { row in
            let translation = Translation(text: row.string(0), comment: row.string(1))
            if row.int(2) < Self.reversedRank {
                direct.append(translation)
            } else {
                reversed.append(translation)
            }
        }
        var seen = Set<String>()
        let unique = (direct.isEmpty ? reversed : direct).filter { seen.insert($0.text).inserted }
        return Array(unique.prefix(Self.maxTranslations))
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
            try? db.query("SELECT lemma, freq FROM en_synset_members WHERE synset_id = ? ORDER BY rank",
                          [sense.id]) { row in
                let member = row.string(0)
                guard member.lowercased() != lemma.lowercased(),
                      !hidden.contains(HiddenPair(language: .english, lemma: lemma, synonym: member)) else { return }
                members.append(Synonym(word: member, score: nil, frequency: row.double(1)))
            }
            let ordered = Self.ordered(members, by: Self.englishSynonymOrder)
            return WordSense(id: sense.id, definition: sense.definition, synonyms: Array(ordered.prefix(Self.maxSynonyms)))
        }

        var translations = englishTranslations(lemma: lemma, pos: pos)
        var via: String?
        if translations.isEmpty {
            // Lånad översättning: exceedingly saknas i Folkets lexikon, men extremely (samma betydelse) finns.
            search: for sense in senses.prefix(Self.borrowSenses) {
                for member in sense.synonyms {
                    let borrowed = englishTranslations(lemma: member.word, pos: pos)
                    if !borrowed.isEmpty {
                        translations = Array(borrowed.prefix(4))
                        via = member.word
                        break search
                    }
                }
            }
        }
        return WordEntry(lemma: lemma, pos: pos, posName: Self.englishPosNames[pos] ?? "",
                         senses: Array(senses), translations: translations, translationVia: via)
    }

    private static func englishOrder(_ entry: WordEntry, key: String, preferred: String?) -> [Int] {
        [preferred.map { entry.pos == $0 ? 0 : 1 } ?? 0,
         entry.hasContent ? 0 : 1,
         entry.translations.isEmpty ? 1 : 0,
         normalize(entry.lemma) == key ? 0 : 1,
         englishPosOrder.firstIndex(of: entry.pos) ?? 99]
    }

    // MARK: Språk och ordklass ur meningen

    /// Språkmodellerna skapas en gång. De används under ett lås, eftersom de värms i bakgrunden.
    /// Huvudtråden väntar aldrig på låset: pågår uppvärmningen används en egen modell, som förut.
    /// (I simulatortestet tog ett uppslag 9 sekunder när huvudtråden väntade på bakgrundens lås.)
    private static let languageLock = NSLock()
    private static let recognizer = NLLanguageRecognizer()
    private static let tagger = NLTagger(tagSchemes: [.lexicalClass])
    private static var warmedUp = false

    /// Kör `body` med den gemensamma modellen om den är ledig, annars med en ny.
    private static func withShared<Model, Value>(_ shared: Model, fresh: () -> Model, wait: Bool,
                                                 _ body: (Model) -> Value) -> Value {
        if wait {
            languageLock.lock()
        } else if !languageLock.try() {
            return body(fresh())
        }
        defer { languageLock.unlock() }
        return body(shared)
    }

    /// Laddar språkmodellerna i bakgrunden, så att första uppslaget inte väntar på dem.
    /// Anropas när en bok öppnas. Gör inget andra gången.
    static func warmUpLanguageModels() {
        languageLock.lock()
        let first = !warmedUp
        warmedUp = true
        languageLock.unlock()
        guard first else { return }
        DispatchQueue.global(qos: .utility).async {
            _ = guessLanguage(of: "The book was on the table.", wait: true)
            _ = englishPos(of: "book", in: "The book was on the table.", range: nil, wait: true)
        }
    }

    /// Svenska eller engelska, efter meningen. Oavgjort, eller för lite text, blir svenska.
    static func guessLanguage(of sentence: String, wait: Bool = false) -> WordLanguage {
        withShared(recognizer, fresh: { NLLanguageRecognizer() }, wait: wait) { recognizer -> WordLanguage in
            recognizer.reset()
            recognizer.languageConstraints = [.swedish, .english]
            recognizer.processString(sentence)
            let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
            let swedish = hypotheses[.swedish] ?? 0
            let english = hypotheses[.english] ?? 0
            return english > swedish ? .english : .swedish
        }
    }

    /// Ordklassen som ordet har i meningen (n, v, a, r), så att rätt betydelse av till exempel
    /// "attribute" visas först. Fungerar bara för engelska.
    static func englishPos(of word: String, in sentence: String, range: NSRange?, wait: Bool = false) -> String? {
        guard !sentence.isEmpty else { return nil }
        let text = sentence as NSString
        var location = range?.location ?? NSNotFound
        if location == NSNotFound || location >= text.length {
            location = text.range(of: word).location
        }
        guard location != NSNotFound, let index = Range(NSRange(location: location, length: 0), in: sentence)?.lowerBound else {
            return nil
        }
        let tag = withShared(tagger, fresh: { NLTagger(tagSchemes: [.lexicalClass]) }, wait: wait) { tagger -> NLTag? in
            tagger.string = sentence
            tagger.setLanguage(.english, range: sentence.startIndex..<sentence.endIndex)
            return tagger.tag(at: index, unit: .word, scheme: .lexicalClass).0
        }
        let classes: [NLTag: String] = [.noun: "n", .verb: "v", .adjective: "a", .adverb: "r"]
        return tag.flatMap { classes[$0] }
    }

    // MARK: Om ordboken

    struct Counts {
        let swedishWords: Int
        let swedishPairs: Int
        let swedishDefinitions: Int
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
                      swedishDefinitions: count("SELECT COUNT(*) FROM sv_definitions"),
                      englishWords: count("SELECT COUNT(DISTINCT lemma) FROM en_senses"),
                      translations: count("SELECT COUNT(*) FROM en_sv"))
    }
}
