import Foundation

/// AI-frågor (K6b): logiken utan gränssnitt, enligt `docs/AI-FRAGOR.md`. Frågan till modellen, schemana,
/// kontrollen av svaret, frågornas id och delningen av långa kapitel. Samma regler som
/// `tools/simtest/ai-fragor/referens.py`, och XCTest (`AIQuestionsTests`) kontrollerar mot `fixtur-1.json`.
/// Ren logik (G13), går att köra utanför huvudtråden.
enum AIQuestions {

    /// Typen i de sparade svaren (`AIClient.generate(kind:)`).
    static let questionsKind = "fragor-1"
    static let compareKind = "jamfor-1"
    /// Tidsgränsen för ett kapitel, svarets längd och modellens temperatur (som i A1).
    static let timeout: TimeInterval = 90
    static let maxOutputTokens = 8192
    static let compareTimeout: TimeInterval = 40
    static let compareMaxTokens = 2048

    /// Kapitel under så många tecken får inga frågor (omslag, innehåll, tack).
    static let minimumLength = 1500
    /// Kapitel över `splitAbove` tecken delas i `ceil(längd / partLength)` lika stora delar.
    static let splitAbove = 40_000
    static let partLength = 36_000
    /// Minsta avstånd i tecken mellan två frågor i texten.
    static let minimumDistance = 400

    /// Frågetyperna i schemats ordning, med namnet i rutan.
    static let types: [(id: String, title: String)] = [
        ("huvudpoang", "Huvudpoäng"), ("egna_ord", "Med egna ord"), ("svar_mening", "Svår mening"),
        ("vems_rost", "Vems röst"), ("varfor", "Varför"), ("uppgift", "Styckets uppgift"),
        ("koppling", "Koppling bakåt"), ("skillnad", "Skillnad"), ("tillampa", "Tillämpa"), ("falla", "Fälla"),
        ("belagg", "Belägg"), ("kritisk", "Kritisk"), ("anvand", "Använd det"), ("sammanfatta", "Sammanfatta"),
        ("annan_bok", "Koppling till en annan bok"), ("verkligheten", "Till verkligheten"), ("foljder", "Följder"),
        ("gransen", "Gränsen"), ("overforing", "Överföring"), ("debatt", "Debatt"), ("syntes", "Syntes"),
    ]
    static let typeIDs: [String] = types.map { $0.id }
    /// Öppna typer: inget rätt svar, Jämför ger en kommentar.
    static let openTypes: Set<String> = ["kritisk", "anvand", "annan_bok", "verkligheten", "foljder", "gransen",
                                         "overforing", "debatt", "syntes"]
    /// Typer som inte behöver något citat ur texten.
    static let typesWithoutSource: Set<String> = ["sammanfatta", "syntes"]
    /// När frågan ställs: före läsningen, i texten (efter avsnittet) och efter kapitlet.
    static let timings = ["fore", "efter", "slut"]

    /// Rubriken i rutan: typens namn, för annan_bok "Koppling till <bok>".
    static func title(type: String, book: String = "") -> String {
        if type == "annan_bok", !book.isEmpty {
            return "Koppling till \(book)"
        }
        return types.first { $0.id == type }?.title ?? "Fråga"
    }

    // MARK: Antal frågor

    struct Count: Equatable {
        var after: Int
        var before: Int
        var connections: Int
        var end: Int
    }

    /// Som `antal()` i referens.py, för en del med `characters` tecken. `last` är bokens sista kapitel med text.
    static func count(characters: Int, last: Bool) -> Count {
        let after = min(max(Int((Double(characters) / 3500).rounded(.toNearestOrEven)), 2), 10)
        let before = characters >= 8000 ? 2 : 1
        let connections = characters >= 8000 ? 2 : 1
        return Count(after: after, before: before, connections: connections,
                     end: 1 + connections + (last ? 1 : 0))
    }

    /// Antalet för en del av ett kapitel: före läsningen bara i första delen, efter kapitlet (och
    /// kopplingarna) bara i sista delen.
    static func count(characters: Int, part: Int, parts: Int, lastChapter: Bool) -> Count {
        var result = count(characters: characters, last: lastChapter)
        if part > 1 {
            result.before = 0
        }
        if part < parts {
            result.end = 0
            result.connections = 0
        }
        return result
    }

    /// Taket efter kontrollen: efter högst antalet plus 2, fore högst 2, slut högst 4 (noll när delen inte
    /// ska ha några).
    struct Cap: Equatable {
        var before: Int
        var after: Int
        var end: Int

        func limit(_ timing: String) -> Int {
            switch timing {
            case "fore": return before
            case "efter": return after
            default: return end
            }
        }
    }

    static func cap(for count: Count) -> Cap {
        Cap(before: count.before > 0 ? 2 : 0, after: count.after + 2, end: count.end > 0 ? 4 : 0)
    }

    private static func countText(_ number: Int) -> String {
        number == 1 ? "1 fråga" : "\(number) frågor"
    }

    // MARK: Frågan till modellen

    struct PromptBook {
        let title: String
        let author: String
    }

    struct PromptChapter {
        let title: String
        let part: Int
        let parts: Int
        let text: String
        let isLast: Bool
    }

    struct PreviousChapter: Equatable {
        let title: String
        let summary: String
    }

    struct OtherBook: Equatable {
        let title: String
        let summary: String
        let concepts: [String]
    }

    /// Frågan, tecken för tecken som `bygg_prompt` i referens.py. `count` är antalet för delen.
    static func prompt(book: PromptBook, chapter: PromptChapter, previous: [PreviousChapter], others: [OtherBook],
                       count: Count) -> String {
        let author = book.author.isEmpty ? "" : ", av \(book.author)"
        let partLine = chapter.parts > 1 ? " (del \(chapter.part) av \(chapter.parts))" : ""
        let previousLines = previous.suffix(12).map { "- \($0.title): \($0.summary)" }.joined(separator: "\n")
        let otherLines = others.prefix(5).map { other -> String in
            var line = "- \(other.title): \(other.summary)"
            if !other.concepts.isEmpty {
                line += " Begrepp: " + other.concepts.prefix(8).joined(separator: ", ") + "."
            }
            return line
        }.joined(separator: "\n")
        let lineB: String
        if count.before > 0 {
            lineB = "b) \(countText(count.before)) med \"nar\": \"fore\": det viktigaste läsaren ska ha i huvudet medan hen läser. \"plats\" lämnas tom."
        } else {
            lineB = "b) Inga frågor med \"nar\": \"fore\"."
        }
        let lineC: String
        if count.end > 0 {
            let synthesis = chapter.isLast
                ? " Det här är bokens sista kapitel: lägg till en fråga av typen syntes om hur bokens viktigaste idéer hänger ihop."
                : ""
            lineC = "c) \(countText(count.end)) med \"nar\": \"slut\": en av typen sammanfatta, och \(countText(count.connections)) som kräver större kopplingar än texten, av typerna annan_bok, verkligheten, foljder, gransen, overforing eller debatt. annan_bok och debatt mellan böcker får bara gälla böckerna i listan ovan, med titeln exakt som där i \"bok\"."
                + synthesis + " \"plats\" lämnas tom."
        } else {
            lineC = "c) Inga frågor med \"nar\": \"slut\"."
        }
        return [
            "Du gör frågor som hjälper en läsare att förstå och minnas en bok. Läsaren svarar ur minnet, med egna ord, efter att ha läst avsnittet.",
            "",
            "Bok: \(book.title)\(author)",
            "Kapitel: \(chapter.title)\(partLine)",
            "",
            "Tidigare kapitel i boken:",
            previousLines.isEmpty ? "Inga." : previousLines,
            "",
            "Andra böcker som läsaren har läst:",
            otherLines.isEmpty ? "Inga." : otherLines,
            "",
            "Gör så här.",
            "1. \"sammanfattning\": kapitlets huvudpoäng i högst tre meningar.",
            "2. \"begrepp\": högst åtta viktiga begrepp eller namn ur kapitlet, skrivna som i texten.",
            "3. \"fragor\":",
            "a) \(countText(count.after)) med \"nar\": \"efter\", spridda jämnt över hela texten. Varje fråga gäller ett avsnitt. \"plats\" är 4 till 10 ord som står ordagrant i avsnittets sista mening, så att frågan visas när avsnittet är läst.",
            lineB,
            lineC,
            "4. Välj typ efter vad avsnittet bär: ett begrepp ger egna_ord eller skillnad, ett argument varfor eller belagg, en återgiven åsikt vems_rost, ett svårt ställe svar_mening. Blanda typerna.",
            "5. Skriv frågan med andra ord än boken. Upprepa aldrig fem ord i rad ur texten.",
            "6. \"svar\": två eller tre korta kärnpunkter med egna ord, som ett bra svar innehåller. För en öppen fråga (\"oppen\": true): vad boken säger som läsaren kan ställa sitt svar mot.",
            "7. \"kalla\": 5 till 30 ord som står ordagrant i texten, där svaret står. Kopiera tecken för tecken, utan att ändra, korta eller översätta. Lämna \"kalla\" tom bara när svaret inte står i texten.",
            "8. Skriv frågor, svar och sammanfattning på svenska, även när boken är på ett annat språk. \"plats\", \"kalla\" och \"begrepp\" står på bokens språk, precis som i texten.",
            "9. Fråga inte efter sidnummer, årtal, namn eller detaljer som inte hjälper förståelsen.",
            "",
            "Kapitlets text:",
            "<text>",
            chapter.text,
            "</text>",
        ].joined(separator: "\n")
    }

    /// Det Jämför skickar om en fråga: frågan, svarspunkterna, källan och om frågan är öppen.
    struct CompareQuestion {
        let question: String
        let answer: [String]
        let source: String
        let isOpen: Bool
    }

    /// Frågan när läsarens svar jämförs, som `bygg_jamfor` i referens.py. Kapitlets text skickas aldrig med.
    static func comparePrompt(_ question: CompareQuestion, myAnswer: String) -> String {
        let points = question.answer.map { "- \($0)" }.joined(separator: "\n")
        let source = question.source.isEmpty ? "Inget citat." : "\"\(question.source)\""
        let ending: String
        if question.isOpen {
            ending = "Frågan är öppen och har inget rätt svar. Skriv i \"kommentar\" om resonemanget håller och vad boken säger, och lämna \"fel\" tom om inget strider mot boken. Säg tydligt när något i kommentaren kommer från dig och inte från boken."
        } else {
            ending = "Lista i \"med\" det läsaren fick med, i \"saknas\" det som saknas och i \"fel\" det som strider mot boken. \"kommentar\" är en mening."
        }
        return [
            "Du bedömer en läsares svar på en fråga om en bok. Bedöm innehållet, inte orden: samma sak med andra ord räknas som rätt. Var vänlig och konkret, och skriv på svenska.",
            "",
            "Fråga: \(question.question)",
            "Ett bra svar innehåller:",
            points.isEmpty ? "- (inga punkter)" : points,
            "Ur boken: \(source)",
            "Läsarens svar: \(myAnswer.trimmingCharacters(in: .whitespacesAndNewlines))",
            "",
            ending,
        ].joined(separator: "\n")
    }

    // MARK: Schemana

    /// `SCHEMA_FRAGOR` i referens.py (`responseJsonSchema`).
    static var questionSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "sammanfattning": ["type": "string"],
                "begrepp": ["type": "array", "items": ["type": "string"]],
                "fragor": ["type": "array", "items": [
                    "type": "object",
                    "properties": [
                        "typ": ["type": "string", "enum": typeIDs],
                        "nar": ["type": "string", "enum": timings],
                        "fraga": ["type": "string"],
                        "svar": ["type": "array", "items": ["type": "string"]],
                        "oppen": ["type": "boolean"],
                        "plats": ["type": "string"],
                        "kalla": ["type": "string"],
                        "bok": ["type": "string"],
                    ] as [String: Any],
                    "required": ["typ", "nar", "fraga", "svar", "oppen", "plats", "kalla"],
                ] as [String: Any]] as [String: Any],
            ] as [String: Any],
            "required": ["sammanfattning", "begrepp", "fragor"],
        ]
    }

    /// `SCHEMA_JAMFOR` i referens.py.
    static var compareSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "med": ["type": "array", "items": ["type": "string"]],
                "saknas": ["type": "array", "items": ["type": "string"]],
                "fel": ["type": "array", "items": ["type": "string"]],
                "omdome": ["type": "string", "enum": ["bra", "delvis", "saknas_mycket"]],
                "kommentar": ["type": "string"],
            ] as [String: Any],
            "required": ["med", "saknas", "fel", "omdome", "kommentar"],
        ]
    }

    // MARK: Hitta i texten

    /// Tecknen som byts mot raka i reservmatchningen, ett tecken mot ett (`LOSA` i referens.py).
    static let looseMap: [unichar: unichar] = {
        var map: [unichar: unichar] = [:]
        for unit in "\u{2018}\u{2019}\u{201A}\u{201B}\u{2032}\u{00B4}`".utf16 {
            map[unit] = 0x27
        }
        for unit in "\u{201C}\u{201D}\u{201E}\u{201F}\u{2033}\u{00AB}\u{00BB}".utf16 {
            map[unit] = 0x22
        }
        for unit in "\u{2013}\u{2014}\u{2012}\u{2015}\u{2212}".utf16 {
            map[unit] = 0x2D
        }
        return map
    }()

    fileprivate static func loosened(_ text: NSString) -> NSString {
        var units = [unichar](repeating: 0, count: text.length)
        text.getCharacters(&units, range: NSRange(location: 0, length: text.length))
        for index in units.indices {
            if let replacement = looseMap[units[index]] {
                units[index] = replacement
            }
        }
        return NSString(characters: units, length: units.count)
    }

    /// Den vikta texten utan mellanslag i början och slutet (`fraga_vikt`): bara vanliga mellanslag tas bort.
    static func foldedQuery(_ text: String) -> String {
        let folded = FoldedText(text as NSString).text as String
        var scalars = Substring(folded)
        while scalars.first == " " {
            scalars = scalars.dropFirst()
        }
        while scalars.last == " " {
            scalars = scalars.dropLast()
        }
        return String(scalars)
    }

    /// Texten att leta i, vikt en gång strikt och en gång med raka citattecken och streck.
    struct Haystack {
        let strict: FoldedText
        let loose: FoldedText

        init(_ text: NSString) {
            strict = FoldedText(text)
            loose = FoldedText(AIQuestions.loosened(text))
        }
    }

    /// Var ett citat står i texten (UTF-16): början och slutet (exklusivt) av första träffen, eller nil.
    /// Först strikt, sedan med typografiska citattecken och streck som raka i båda texterna.
    static func find(_ quote: String, in text: NSString) -> NSRange? {
        find(quote, in: Haystack(text))
    }

    static func find(_ quote: String, in haystack: Haystack) -> NSRange? {
        for loose in [false, true] {
            let folded = loose ? haystack.loose : haystack.strict
            let needle = loose ? (loosened(quote as NSString) as String) : quote
            let query = foldedQuery(needle) as NSString
            guard query.length >= 2 else { return nil }
            let found = folded.text.range(of: query as String, options: [.literal])
            if found.location != NSNotFound, found.length > 0 {
                let start = folded.map[found.location]
                let end = folded.map[NSMaxRange(found) - 1] + 1
                return NSRange(location: start, length: end - start)
            }
        }
        return nil
    }

    /// Orden i den vikta texten: följder av bokstäver och siffror, allt annat skiljer.
    static func words(_ text: String) -> [String] {
        let folded = FoldedText(text as NSString).text as String
        var result: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars {
            if isWordScalar(scalar) {
                current.append(scalar)
            } else if !current.isEmpty {
                result.append(String(current))
                current = String.UnicodeScalarView()
            }
        }
        if !current.isEmpty {
            result.append(String(current))
        }
        return result
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    private static func ngrams(_ words: [String], length: Int) -> Set<String> {
        guard words.count >= length else { return [] }
        var result = Set<String>()
        for start in 0...(words.count - length) {
            result.insert(words[start..<(start + length)].joined(separator: "\u{1}"))
        }
        return result
    }

    /// Sant när frågan innehåller sex ord i rad ur texten.
    static func isCopied(_ question: String, textGrams: Set<String>, length: Int = 6) -> Bool {
        !ngrams(words(question), length: length).isDisjoint(with: textGrams)
    }

    // MARK: Id

    /// Frågans id: `"ai" + base36(FNV-1a 64 över "<bok>|<kapitel>|<del>|<nar>|<fråga>")`.
    static func questionID(book: String, chapter: String, part: Int, timing: String, question: String) -> String {
        "ai" + String(BookQuestionFile.stableHash("\(book)|\(chapter)|\(part)|\(timing)|\(question)"), radix: 36)
    }

    // MARK: Kontrollen

    /// En fråga som behölls, med platsen i delens text (UTF-16, slutet av träffen) för frågorna i texten.
    struct Kept: Equatable {
        let id: String
        let number: Int
        let type: String
        let timing: String
        let question: String
        let answer: [String]
        let isOpen: Bool
        /// Modellens plats (efter), annars tom.
        let anchor: String
        let source: String
        let book: String
        /// Efter: platsens början och slut i texten. Nil för före och efter kapitlet.
        let anchorRange: NSRange?
        /// Källans början och slut i texten, nil när källan är tom.
        let sourceRange: NSRange?

        var position: Int? {
            anchorRange.map { NSMaxRange($0) }
        }
    }

    struct Dropped: Equatable {
        let number: Int
        let question: String
        let reason: String
    }

    struct CheckResult {
        let kept: [Kept]
        let dropped: [Dropped]

        /// Raden i loggen: `k3: 6 av 13 behölls (plats 1, kalla 1, ...)`.
        func logLine(chapter: String) -> String {
            var counts: [String: Int] = [:]
            var order: [String] = []
            for item in dropped {
                if counts[item.reason] == nil {
                    order.append(item.reason)
                }
                counts[item.reason, default: 0] += 1
            }
            let total = kept.count + dropped.count
            let reasons = order.map { "\($0) \(counts[$0] ?? 0)" }.joined(separator: ", ")
            return "AI-frågor \(chapter): \(kept.count) av \(total) behölls" + (reasons.isEmpty ? "" : " (\(reasons))")
        }
    }

    private static func string(_ value: Any?) -> String {
        if let text = value as? String {
            return text
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return ""
    }

    private static func trimmed(_ value: Any?) -> String {
        string(value).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func truthy(_ value: Any?) -> Bool {
        if let flag = value as? Bool {
            return flag
        }
        if let number = value as? NSNumber {
            return number.doubleValue != 0
        }
        if let text = value as? String {
            return !text.isEmpty
        }
        return false
    }

    /// Reglerna i docs/AI-FRAGOR.md, som `kontrollera` i referens.py. `text` är delens text, `otherTitles`
    /// de andra böckernas titlar.
    static func check(answer: [String: Any], text: String, book: String, chapter: String, part: Int,
                      otherTitles: [String], cap: Cap) -> CheckResult {
        let source = Haystack(text as NSString)
        let textGrams = ngrams(words(text), length: 6)
        let titles = Set(otherTitles.map(foldedQuery))
        let items = (answer["fragor"] as? [Any]) ?? []
        var kept: [Kept] = []
        var dropped: [Dropped] = []
        for (number, item) in items.enumerated() {
            let entry = (item as? [String: Any]) ?? [:]
            let type = trimmed(entry["typ"])
            let timing = trimmed(entry["nar"])
            let question = trimmed(entry["fraga"])
            let rawAnswer: [Any]
            if let list = entry["svar"] as? [Any] {
                rawAnswer = list
            } else if let single = entry["svar"] as? String {
                rawAnswer = [single]
            } else {
                rawAnswer = []
            }
            let answerLines = rawAnswer.map { trimmed($0) }.filter { !$0.isEmpty }
            let isOpen = truthy(entry["oppen"]) || openTypes.contains(type)
            let anchor = trimmed(entry["plats"])
            var quote = trimmed(entry["kalla"])
            let otherBook = trimmed(entry["bok"])
            func drop(_ reason: String) {
                dropped.append(Dropped(number: number, question: question, reason: reason))
            }
            guard typeIDs.contains(type), timings.contains(timing) else {
                drop("typ")
                continue
            }
            guard question.unicodeScalars.count >= 8 else {
                drop("fraga")
                continue
            }
            guard !answerLines.isEmpty || isOpen else {
                drop("svar")
                continue
            }
            var anchorRange: NSRange?
            if timing == "efter" {
                anchorRange = anchor.isEmpty ? nil : find(anchor, in: source)
                guard anchorRange != nil else {
                    drop("plats")
                    continue
                }
            }
            let needsSource = !isOpen && !typesWithoutSource.contains(type)
            var sourceRange: NSRange?
            if !quote.isEmpty {
                sourceRange = find(quote, in: source)
                if sourceRange == nil {
                    if needsSource {
                        drop("kalla")
                        continue
                    }
                    quote = ""
                }
            } else if needsSource {
                drop("kalla")
                continue
            }
            if isCopied(question, textGrams: textGrams) {
                drop("kopierad")
                continue
            }
            if type == "annan_bok" || (type == "debatt" && !otherBook.isEmpty) {
                guard titles.contains(foldedQuery(otherBook)) else {
                    drop("bok")
                    continue
                }
            }
            kept.append(Kept(id: "", number: number, type: type, timing: timing, question: question,
                             answer: answerLines, isOpen: isOpen, anchor: timing == "efter" ? anchor : "",
                             source: quote, book: otherBook, anchorRange: anchorRange, sourceRange: sourceRange))
        }
        // Frågorna i texten i textens ordning, med avstånd.
        let inText = kept.filter { $0.timing == "efter" }
            .sorted { ($0.position ?? 0, $0.number) < ($1.position ?? 0, $1.number) }
        var keptInText: [Kept] = []
        var latest: Int?
        for item in inText {
            let position = item.position ?? 0
            if let previous = latest, position - previous < minimumDistance {
                dropped.append(Dropped(number: item.number, question: item.question, reason: "avstand"))
                continue
            }
            keptInText.append(item)
            latest = position
        }
        let ordered = kept.filter { $0.timing == "fore" } + keptInText + kept.filter { $0.timing == "slut" }
        var counted: [String: Int] = ["fore": 0, "efter": 0, "slut": 0]
        var result: [Kept] = []
        for item in ordered {
            if counted[item.timing, default: 0] >= cap.limit(item.timing) {
                dropped.append(Dropped(number: item.number, question: item.question, reason: "tak"))
                continue
            }
            counted[item.timing, default: 0] += 1
            result.append(Kept(id: questionID(book: book, chapter: chapter, part: part, timing: item.timing,
                                              question: item.question),
                               number: item.number, type: item.type, timing: item.timing, question: item.question,
                               answer: item.answer, isOpen: item.isOpen, anchor: item.anchor, source: item.source,
                               book: item.book, anchorRange: item.anchorRange, sourceRange: item.sourceRange))
        }
        dropped.sort { $0.number < $1.number }
        return CheckResult(kept: result, dropped: dropped)
    }

    /// Sammanfattningen och begreppen ur modellens svar.
    static func summary(of answer: [String: Any]) -> String {
        trimmed(answer["sammanfattning"])
    }

    static func concepts(of answer: [String: Any]) -> [String] {
        ((answer["begrepp"] as? [Any]) ?? []).map { trimmed($0) }.filter { !$0.isEmpty }
    }

    /// Sant när svaret går att läsa: ett objekt med listan `fragor`.
    static func isReadable(_ answer: [String: Any]) -> Bool {
        answer["fragor"] is [Any]
    }

    // MARK: Delningen av långa kapitel

    /// Delarna (UTF-16) av ett kapitel. Upp till `splitAbove` tecken en del, annars `ceil(längd / partLength)`
    /// lika stora delar, delade vid närmaste tomma rad, annars radbrytning, annars mellanslag.
    static func parts(of text: NSString) -> [NSRange] {
        let length = text.length
        guard length > splitAbove else {
            return [NSRange(location: 0, length: length)]
        }
        let count = Int((Double(length) / Double(partLength)).rounded(.up))
        var cuts: [Int] = [0]
        let window = partLength / 4
        for index in 1..<count {
            let target = length * index / count
            let low = max(cuts[cuts.count - 1] + 1, target - window)
            let high = min(length - 1, target + window)
            var cut = target
            if low < high {
                for separator in ["\n\n", "\n", " "] {
                    if let found = nearest(separator, to: target, in: text, low: low, high: high) {
                        cut = found
                        break
                    }
                }
            }
            if cut > cuts[cuts.count - 1], cut < length {
                cuts.append(cut)
            }
        }
        cuts.append(length)
        return zip(cuts, cuts.dropFirst()).map { NSRange(location: $0, length: $1 - $0) }
    }

    /// Positionen efter den förekomst av `separator` inom `low..<high` som ligger närmast `target`.
    private static func nearest(_ separator: String, to target: Int, in text: NSString, low: Int, high: Int) -> Int? {
        var best: Int?
        var range = NSRange(location: low, length: high - low)
        while range.length > 0 {
            let found = text.range(of: separator, options: [.literal], range: range)
            guard found.location != NSNotFound else { break }
            let cut = NSMaxRange(found)
            if best == nil || abs(cut - target) < abs(best! - target) {
                best = cut
            }
            let next = found.location + 1
            range = NSRange(location: next, length: max(0, low + (high - low) - next))
        }
        return best
    }

    // MARK: Kapitlets nyckel

    /// `k<plats från 0>` för EPUB och text.
    static func chapterKey(chapter: Int) -> String {
        "k\(chapter)"
    }

    /// `p<första sidan>-<sista sidan>` (från 1) för PDF.
    static func chapterKey(firstPage: Int, lastPage: Int) -> String {
        "p\(firstPage)-\(lastPage)"
    }

    /// Kapitlets ordning i boken ur nyckeln: kapitlet eller första sidan.
    static func order(ofChapterKey key: String) -> Int {
        if key.hasPrefix("k") {
            return Int(key.dropFirst()) ?? 0
        }
        if key.hasPrefix("p"), let first = key.dropFirst().split(separator: "-").first {
            return Int(first) ?? 0
        }
        return 0
    }
}
