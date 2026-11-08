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
        for word in words {
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
                found[item.key] = forms.filter { $0.count >= 3 }.sorted()
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
