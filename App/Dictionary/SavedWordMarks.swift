import Foundation

/// O4: sparade ord får ett streck under sig i texten. Övar och kan har olika streck. Ordstatusen (O3) valdes
/// bort, så kan härleds ur repetitionen: ett ord vars intervall är minst tre veckor räknas som kan.
///
/// Böjningsformerna tas ur ordboken i bakgrunden med en egen anslutning (formtabellernas nyckel är formen,
/// så formerna för en grundform letas upp i ett intervall av former med samma början), engelska reguljära
/// böjningar räknas fram. Resultatet är en tabell från form (gemener) till ett id, som PDF-läsaren matchar i
/// sidans text och EPUB-läsaren skickar till webbvyns skript. Används bara från huvudtråden.
final class SavedWordMarks {

    static let shared = SavedWordMarks()

    /// Skickas när formerna har räknats om, så att läsarna ritar om strecken.
    static let didChange = Notification.Name("SavedWordMarksDidChange")

    /// Id:n för strecken bland markeringarna på sidorna: `ord:` plus språk och grundform.
    static let idPrefix = "ord:"
    /// Intervallet (dagar) från vilket ett ord räknas som kan.
    static let knownInterval = 21.0
    private static let enabledKey = "reader.savedWordMarks"

    /// Av- och påval i Aa, från början på.
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    /// Form (gemener) till `w:` eller `k:` (övar eller kan) plus id (språk|grundform). Tom när av.
    var forms: [String: String] {
        isEnabled ? current : [:]
    }

    private(set) var version = 0
    private var current: [String: String] = [:]
    /// Formerna per språk|grundform, så att bara nya ord behöver letas upp.
    private var cache: [String: [String]] = [:]
    private var pending = false
    private var running = false
    private let queue = DispatchQueue(label: "se.edvin.lasa.ordstreck", qos: .utility)
    private var dictionary: WordDictionary?

    private init() {
        NotificationCenter.default.addObserver(forName: UserWords.didChange, object: nil, queue: .main) { _ in
            SavedWordMarks.shared.refresh()
        }
    }

    static func isWordID(_ id: String) -> Bool {
        id.hasPrefix(idPrefix)
    }

    /// Språk och grundform ur ett id.
    static func word(fromID id: String) -> (language: WordLanguage, lemma: String)? {
        let body = id.hasPrefix(idPrefix) ? String(id.dropFirst(idPrefix.count)) : id
        guard let bar = body.firstIndex(of: "|"),
              let language = WordLanguage(rawValue: String(body[..<bar])) else { return nil }
        return (language, String(body[body.index(after: bar)...]))
    }

    /// Räknar om formerna i bakgrunden. Flera anrop i rad ger en omräkning.
    func refresh() {
        guard !running else {
            pending = true
            return
        }
        running = true
        pending = false
        let words = UserWords.shared.savedWords()
        let intervals = UserWords.shared.reviewIntervals()
        var wanted: [(key: String, language: WordLanguage, lemma: String, word: String)] = []
        var status: [String: String] = [:]
        for word in words where !SavedWordMatcher.isFunctionWord(WordDictionary.normalize(word.lemma)) {
            let key = word.language.rawValue + "|" + word.lemma
            status[key] = (intervals[key] ?? 0) >= Self.knownInterval ? "k" : "w"
            wanted.append((key, word.language, word.lemma, word.word))
        }
        let known = cache
        let missing = wanted.filter { known[$0.key] == nil }
        let url = WordDictionary.shared?.url
        let opened = dictionary
        queue.async {
            let reader = opened ?? url.flatMap { try? WordDictionary(url: $0) }
            var found: [String: [String]] = [:]
            for item in missing {
                var forms = Set([WordDictionary.normalize(item.lemma), WordDictionary.normalize(item.word)])
                if let reader = reader {
                    forms.formUnion(reader.forms(ofLemma: item.lemma, language: item.language))
                }
                if item.language == .english {
                    forms.formUnion(SavedWordMatcher.englishForms(of: WordDictionary.normalize(item.lemma)))
                }
                found[item.key] = forms.filter { $0.count >= 3 && !SavedWordMatcher.isFunctionWord($0) }.sorted()
            }
            DispatchQueue.main.async {
                self.dictionary = reader
                for (key, forms) in found {
                    self.cache[key] = forms
                }
                var table: [String: String] = [:]
                for item in wanted {
                    guard let mark = status[item.key] else { continue }
                    for form in self.cache[item.key] ?? [] where table[form] == nil {
                        table[form] = mark + ":" + item.key
                    }
                }
                let changed = table != self.current
                self.current = table
                self.running = false
                if changed {
                    self.version += 1
                    NotificationCenter.default.post(name: Self.didChange, object: nil)
                }
                if self.pending {
                    self.refresh()
                }
            }
        }
    }
}

/// Matchningen av sparade ord i en text (ren logik, testad i XCTest). Används av PDF-läsaren på
/// renderingskön och har samma ordmönster som `applyWords` i webbvyns skript.
enum SavedWordMatcher {

    /// Småord som får ett streck på nästan varje rad om de har slagits upp (det, den, var, the, with).
    /// De sparas som förut, men får inget streck.
    static let functionWords: Set<String> = [
        "och", "att", "det", "som", "en", "på", "är", "av", "för", "med", "till", "den", "har", "de", "inte",
        "om", "ett", "han", "men", "var", "jag", "sig", "från", "vi", "så", "kan", "man", "när", "år", "hon",
        "under", "också", "efter", "eller", "nu", "sin", "där", "vid", "mot", "ska", "skulle", "kommer", "ut",
        "får", "finns", "vara", "hade", "alla", "andra", "mycket", "än", "här", "då", "sedan", "över", "bara",
        "in", "blir", "upp", "även", "vad", "få", "två", "vill", "ha", "många", "hur", "mer", "går", "detta",
        "skall", "hans", "utan", "sina", "något", "allt", "fick", "måste", "mellan", "blev", "bli", "någon",
        "några", "sitt", "varit", "dem", "bland", "ta", "genom", "hela", "annat", "fram", "gör", "ingen",
        "dessa", "varje", "hennes", "deras", "vilket", "vilka", "vilken", "denna", "mig", "dig", "oss", "er",
        "honom", "henne", "dess", "vår", "våra", "mitt", "min", "mina", "din", "dina", "era", "kunna", "göra",
        "gjorde", "samma", "själv", "ju", "väl", "nog", "redan", "dock", "eftersom", "medan", "innan", "både",
        "the", "of", "and", "to", "is", "it", "you", "that", "he", "was", "for", "on", "are", "with",
        "as", "his", "they", "be", "at", "one", "have", "this", "from", "or", "had", "by", "not", "but",
        "what", "some", "we", "can", "out", "other", "were", "all", "there", "when", "up", "your", "how",
        "an", "each", "she", "which", "do", "their", "if", "will", "about", "many", "then", "them", "would",
        "so", "these", "her", "him", "has", "more", "could", "did", "no", "most", "my", "over", "than", "who",
        "may", "been", "now", "any", "its", "also", "into", "only", "our", "very", "just", "should", "those",
        "such", "where", "why", "while", "both", "being", "does", "here",
    ]

    static func isFunctionWord(_ word: String) -> Bool {
        functionWords.contains(word)
    }

    /// Ett ord: bokstäver, med apostrof eller bindestreck inne i ordet.
    private static let pattern = try? NSRegularExpression(pattern: "[\\p{L}\\p{M}]+(?:['’\\-‐‑][\\p{L}\\p{M}]+)*")

    /// Varje sparat ord i texten: platsen (UTF-16) och värdet i `forms` (`w:` eller `k:` plus id).
    static func matches(in text: String, forms: [String: String]) -> [(range: NSRange, value: String)] {
        guard !forms.isEmpty, let pattern = pattern else { return [] }
        let string = text as NSString
        var result: [(range: NSRange, value: String)] = []
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            let key = string.substring(with: match.range).lowercased().replacingOccurrences(of: "’", with: "'")
            if let value = forms[key] {
                result.append((match.range, value))
            }
        }
        return result
    }

    /// Engelska reguljära böjningar av en grundform: plural, tredje person, dåtid, ing-form och komparation.
    /// Oregelbundna former finns i ordbokens formtabell.
    static func englishForms(of lemma: String) -> Set<String> {
        guard lemma.count >= 2, !lemma.contains(" ") else { return [lemma] }
        var forms: Set<String> = [lemma]
        let vowels: Set<Character> = ["a", "e", "i", "o", "u"]
        let last = lemma.last!
        let beforeLast = lemma.dropLast().last
        let stem = String(lemma.dropLast())
        if last == "y", let before = beforeLast, !vowels.contains(before) {
            forms.formUnion([stem + "ies", stem + "ied", lemma + "ing", stem + "ier", stem + "iest"])
        } else if last == "e" {
            forms.formUnion([lemma + "s", lemma + "d", stem + "ing", lemma + "r", lemma + "st"])
        } else if ["s", "x", "z"].contains(last) || lemma.hasSuffix("ch") || lemma.hasSuffix("sh") {
            forms.formUnion([lemma + "es", lemma + "ed", lemma + "ing", lemma + "er", lemma + "est"])
        } else {
            forms.formUnion([lemma + "s", lemma + "ed", lemma + "ing", lemma + "er", lemma + "est"])
            // stop, stopped, stopping: dubbelteckning efter kort vokal.
            let chars = Array(lemma)
            if chars.count >= 3, !vowels.contains(last), last != "w", last != "y",
               vowels.contains(chars[chars.count - 2]), !vowels.contains(chars[chars.count - 3]) {
                let doubled = lemma + String(last)
                forms.formUnion([doubled + "ed", doubled + "ing", doubled + "er", doubled + "est"])
            }
        }
        return forms
    }
}
