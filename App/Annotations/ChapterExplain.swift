import UIKit

/// Förklara kapitlet för appen (A2, Feynmantekniken): efter ett kapitel förklarar man kapitlet med egna ord,
/// skrivet eller dikterat med tangentbordets mikrofon. Utan AI visar appen vilka av ens begrepp (K8) och
/// nyckelorden ur ens markeringar i kapitlet som kom med och vilka som saknas. Med AI (`AIClient`, A1) svarar
/// Gemini vad som stämmer, vad som saknas och vad som är fel, och varje punkt pekar på en av ens egna
/// markeringar. Bara förklaringen, kapitlets rubrik, bokens titel och markeringarnas text skickas, aldrig
/// kapitlets text. Förklaringen och svaret sparas i `chapter_explanations` (steg 12) och syns i anteckningsboken.

// MARK: Underlaget

/// Ett ord som förklaringen jämförs med: ett begrepp ur begreppsregistret eller nyckelordet i en markering.
struct ChapterExplainItem: Equatable {
    enum Kind: String {
        case concept, keyword
    }

    let term: String
    let kind: Kind
    /// Markeringen ordet kommer ur, eller tomt.
    let highlight: String
}

/// Kapitlet som ska förklaras: dess markeringar (med korta id till Gemini) och orden att jämföra med.
struct ChapterExplainMaterial: Equatable {
    struct Mark: Equatable {
        /// Id i frågan till Gemini: M1, M2 och så vidare.
        let ref: String
        /// Markeringens id i markeringar.sqlite.
        let id: String
        let text: String
    }

    let book: String
    let bookTitle: String
    /// Kapitlets första avsnitt (PDF: sidan, EPUB: kapitlet), till anteckningsboken.
    let section: Int
    let chapter: String
    let marks: [Mark]
    let items: [ChapterExplainItem]

    func mark(id: String) -> Mark? {
        marks.first { $0.id == id }
    }
}

/// Vilka ord som kom med i förklaringen och vilka som saknas.
struct ChapterCoverage: Equatable {
    let covered: [ChapterExplainItem]
    let missing: [ChapterExplainItem]
}

/// Ren logik för A2 (G13): underlaget, jämförelsen och frågan till Gemini.
enum ChapterExplainLogic {

    static let maxMarks = 30
    static let maxMarkLength = 400
    static let maxMarksTotal = 6000
    static let maxItems = 24
    /// Förklaringen kortas till så här många tecken i frågan.
    static let maxExplanation = 4000

    /// Underlaget för ett kapitel: markeringarna i textens ordning och orden att jämföra med, begreppen först.
    /// Ett begrepp hör till kapitlet när det skapades ur en markering där eller står i någon av dem.
    static func material(book: String, bookTitle: String, section: Int, chapter: String, highlights: [Highlight],
                         concepts: [Concept]) -> ChapterExplainMaterial {
        let sorted = highlights.sorted { ($0.section, $0.start) < ($1.section, $1.start) }
        let cleaned = sorted.map { (highlight: $0, text: Citation.cleanQuote($0.text)) }
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let ids = Set(cleaned.map { $0.highlight.id })
        var items: [ChapterExplainItem] = []
        var seen = Set<String>()
        func add(_ term: String, _ kind: ChapterExplainItem.Kind, _ highlight: String) {
            let clean = term.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = clean.lowercased()
            guard !clean.isEmpty, !seen.contains(key) else { return }
            seen.insert(key)
            items.append(ChapterExplainItem(term: clean, kind: kind, highlight: highlight))
        }
        let markWords = cleaned.map { (id: $0.highlight.id, words: words($0.text)) }
        for concept in concepts {
            if ids.contains(concept.highlight) {
                add(concept.term, .concept, concept.highlight)
            } else if let hit = markWords.first(where: { mentions(concept.term, words: $0.words) }) {
                add(concept.term, .concept, hit.id)
            }
        }
        let terms = ChapterTestLogic.sortedTerms(concepts.map(\.term))
        for entry in cleaned {
            guard let range = ChapterTestLogic.keyword(in: entry.text, sortedTerms: terms) else { continue }
            add((entry.text as NSString).substring(with: range), .keyword, entry.highlight.id)
        }
        var marks: [ChapterExplainMaterial.Mark] = []
        var total = 0
        for entry in cleaned {
            guard marks.count < maxMarks else { break }
            let text = String(PassageText.collapse(entry.text).prefix(maxMarkLength))
            guard total + text.count <= maxMarksTotal else { break }
            total += text.count
            marks.append(ChapterExplainMaterial.Mark(ref: "M\(marks.count + 1)", id: entry.highlight.id, text: text))
        }
        return ChapterExplainMaterial(book: book, bookTitle: bookTitle, section: section, chapter: chapter,
                                      marks: marks, items: Array(items.prefix(maxItems)))
    }

    /// Orden i en text, med små bokstäver.
    static func words(_ text: String) -> [String] {
        let ns = text as NSString
        let locale = Locale(identifier: "sv_SE")
        return ChapterTestLogic.wordRanges(in: text).map { ns.substring(with: $0).lowercased(with: locale) }
    }

    /// Om ett begrepp eller ord finns bland orden. Böjningar och sammansättningar räknas (kunskap i kunskapen,
    /// metoden i metod, ethos i ethosargument). Ett begrepp med flera ord kräver alla ord på minst tre bokstäver.
    static func mentions(_ term: String, words: [String]) -> Bool {
        let parts = Self.words(term)
        guard !parts.isEmpty else { return false }
        let long = parts.filter { $0.count >= 3 }
        let needed = long.isEmpty ? parts : long
        return needed.allSatisfy { part in words.contains { matches(part, word: $0) } }
    }

    /// Samma ord, eller samma början (ordet minus två bokstäver, minst fyra).
    static func matches(_ term: String, word: String) -> Bool {
        if term == word {
            return true
        }
        guard term.count >= 4 else { return false }
        let stem = max(4, term.count >= 6 ? term.count - 2 : 4)
        return word.count >= stem && word.hasPrefix(String(term.prefix(stem)))
    }

    static func coverage(_ items: [ChapterExplainItem], explanation: String) -> ChapterCoverage {
        let found = words(explanation)
        var covered: [ChapterExplainItem] = []
        var missing: [ChapterExplainItem] = []
        for item in items {
            if mentions(item.term, words: found) {
                covered.append(item)
            } else {
                missing.append(item)
            }
        }
        return ChapterCoverage(covered: covered, missing: missing)
    }

    // MARK: Frågan till Gemini

    /// Frågetypen i de sparade svaren. Höj versionen när frågan eller schemat ändras.
    static let kind = "kapitel-1"

    /// Schemat: tre listor med punkter, varje punkt med text och id för en markering ur listan.
    static func schema(refs: [String]) -> [String: Any] {
        var mark: [String: Any] = ["type": "string"]
        if !refs.isEmpty {
            mark["enum"] = refs
        }
        let point: [String: Any] = [
            "type": "object",
            "properties": ["text": ["type": "string"], "mark": mark] as [String: Any],
            "required": ["text", "mark"],
        ]
        let list: [String: Any] = ["type": "array", "items": point]
        return [
            "type": "object",
            "properties": ["correct": list, "missing": list, "wrong": list] as [String: Any],
            "required": ["correct", "missing", "wrong"],
        ]
    }

    /// Frågan: bokens titel, kapitlets rubrik, markeringarna med id och förklaringen. Aldrig kapitlets text.
    static func prompt(material: ChapterExplainMaterial, explanation: String) -> String {
        let own = String(explanation.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxExplanation))
        var lines = [
            "Du hjälper en svensk student som har läst ett kapitel i en kursbok och förklarat det med egna ord.",
            "Bok: \(material.bookTitle)",
        ]
        let chapter = material.chapter.trimmingCharacters(in: .whitespacesAndNewlines)
        if !chapter.isEmpty {
            lines.append("Kapitel: \(chapter)")
        }
        lines += ["", "Studentens egna markeringar i kapitlet, med id:"]
        for mark in material.marks {
            lines.append("[\(mark.ref)] \"\(mark.text)\"")
        }
        lines += [
            "",
            "Studentens förklaring:",
            "\"\"\"",
            own,
            "\"\"\"",
            "",
            "Du har inte kapitlets text, bara markeringarna. Jämför förklaringen med markeringarna och svara på svenska.",
            "correct: det i förklaringen som stämmer med markeringarna.",
            "missing: viktiga saker i markeringarna som förklaringen inte tar upp.",
            "wrong: det i förklaringen som strider mot markeringarna. Tom lista om inget är fel.",
            "Varje punkt: text är en kort mening till studenten, mark är id för markeringen punkten bygger på, "
                + "exakt som i listan (till exempel M2). Peka bara på markeringar i listan.",
            "Högst fyra punkter per lista. Hitta inte på något som markeringarna inte säger. Skriv utan tankstreck.",
            "Svara bara med JSON enligt schemat.",
        ]
        return lines.joined(separator: "\n")
    }
}

// MARK: Svaret

/// Geminis svar: punkter som pekar på egna markeringar. En punkt som pekar på en markering som inte finns i
/// listan visas inte (samma princip som ordknappen), den räknas bara i `dropped`.
struct ChapterFeedback: Equatable {

    enum Kind: String, CaseIterable {
        case correct, missing, wrong

        var title: String {
            switch self {
            case .correct: return "Stämmer"
            case .missing: return "Saknas"
            case .wrong: return "Fel"
            }
        }
    }

    struct Point: Equatable {
        let kind: Kind
        let text: String
        /// Markeringens id.
        let highlight: String
        /// Markeringens text när svaret kom, så att punkten går att läsa även om markeringen ändras.
        let quote: String
    }

    let points: [Point]
    let dropped: Int

    static let maxPerKind = 6

    init(points: [Point], dropped: Int = 0) {
        self.points = points
        self.dropped = dropped
    }

    init(json: [String: Any], marks: [ChapterExplainMaterial.Mark]) {
        var byRef: [String: ChapterExplainMaterial.Mark] = [:]
        for mark in marks {
            byRef[mark.ref.uppercased()] = mark
        }
        var points: [Point] = []
        var dropped = 0
        for kind in Kind.allCases {
            var made = 0
            for item in (json[kind.rawValue] as? [[String: Any]]) ?? [] {
                let text = ((item["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let ref = ((item["mark"] as? String) ?? "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "[]() \"").union(.whitespacesAndNewlines))
                    .uppercased()
                guard !text.isEmpty, let mark = byRef[ref], made < Self.maxPerKind else {
                    dropped += 1
                    continue
                }
                made += 1
                points.append(Point(kind: kind, text: String(text.prefix(400)), highlight: mark.id, quote: mark.text))
            }
        }
        self.points = points
        self.dropped = dropped
    }

    /// Punkterna som JSON-text, till databasen.
    static func encode(_ points: [Point]) -> String {
        let list = points.map { ["kind": $0.kind.rawValue, "text": $0.text, "mark": $0.highlight, "quote": $0.quote] }
        guard !list.isEmpty, let data = try? JSONSerialization.data(withJSONObject: list),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    static func decode(_ text: String) -> [Point] {
        guard let data = text.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return [] }
        return list.compactMap { item in
            guard let kind = Kind(rawValue: item["kind"] ?? ""), let text = item["text"], !text.isEmpty else { return nil }
            return Point(kind: kind, text: text, highlight: item["mark"] ?? "", quote: item["quote"] ?? "")
        }
    }
}

// MARK: Det sparade

/// En förklaring med egna ord, med jämförelsen och Geminis svar.
struct ChapterExplanation: Equatable {
    let id: String
    let book: String
    var section: Int
    var chapter: String
    var text: String
    /// Orden som kom med och som saknades, med `b:` för begrepp och `n:` för nyckelord.
    var covered: [String]
    var missing: [String]
    var feedback: [ChapterFeedback.Point]
    var model: String
    let created: Date
    var updated: Date

    /// En rad till anteckningsboken: hur jämförelsen och svaret gick.
    var summary: String {
        var parts: [String] = []
        if !covered.isEmpty || !missing.isEmpty {
            parts.append("\(covered.count) av \(covered.count + missing.count) ord kom med")
        }
        if !feedback.isEmpty {
            let counts = ChapterFeedback.Kind.allCases.compactMap { kind -> String? in
                let count = feedback.filter { $0.kind == kind }.count
                return count == 0 ? nil : "\(kind.title.lowercased()) \(count)"
            }
            parts.append("Gemini: " + counts.joined(separator: ", "))
        }
        return parts.joined(separator: ". ")
    }

    static func codes(_ items: [ChapterExplainItem]) -> [String] {
        items.map { ($0.kind == .concept ? "b:" : "n:") + $0.term }
    }

    static func item(code: String) -> ChapterExplainItem {
        if code.hasPrefix("b:") {
            return ChapterExplainItem(term: String(code.dropFirst(2)), kind: .concept, highlight: "")
        }
        return ChapterExplainItem(term: code.hasPrefix("n:") ? String(code.dropFirst(2)) : code, kind: .keyword,
                                  highlight: "")
    }
}

/// Förklaringarna i tabellen `chapter_explanations` i markeringar.sqlite (steg 12, följer med i
/// säkerhetskopian med resten av databasen). Inget raderas: borttaget får `deleted = 1`. Ingen synk.
/// Används bara från huvudtråden.
final class ChapterExplanationStore {

    static let shared = ChapterExplanationStore()

    private init() {}

    private static let columns = "id, book, section, chapter, text, covered, missing, feedback, model, created, updated"

    private static func lines(_ list: [String]) -> String {
        list.joined(separator: "\n")
    }

    private static func list(_ text: String) -> [String] {
        text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    private static func record(_ row: SQLiteDatabase.Row) -> ChapterExplanation {
        ChapterExplanation(id: row.string(0), book: row.string(1), section: row.int(2), chapter: row.string(3),
                           text: row.string(4), covered: list(row.string(5)), missing: list(row.string(6)),
                           feedback: ChapterFeedback.decode(row.string(7)), model: row.string(8),
                           created: Date(timeIntervalSince1970: row.double(9)),
                           updated: Date(timeIntervalSince1970: row.double(10)))
    }

    /// Bokens förklaringar, äldst först.
    func explanations(book: String) -> [ChapterExplanation] {
        var result: [ChapterExplanation] = []
        AnnotationStore.shared.readBooks { db in
            try db.query("SELECT \(Self.columns) FROM chapter_explanations WHERE book = ? AND deleted = 0 "
                         + "ORDER BY created", [book]) { row in
                result.append(Self.record(row))
            }
        }
        return result
    }

    func explanation(id: String) -> ChapterExplanation? {
        var result: ChapterExplanation?
        AnnotationStore.shared.readBooks { db in
            try db.query("SELECT \(Self.columns) FROM chapter_explanations WHERE id = ? AND deleted = 0", [id]) { row in
                result = Self.record(row)
            }
        }
        return result
    }

    @discardableResult
    func save(_ explanation: ChapterExplanation) -> Bool {
        let saved = AnnotationStore.shared.writeBooks("förklaringen av kapitlet") { db in
            try db.execute("""
                INSERT INTO chapter_explanations (id, book, section, chapter, text, covered, missing, feedback, model,
                    created, updated, deleted)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
                ON CONFLICT(id) DO UPDATE SET section = excluded.section, chapter = excluded.chapter,
                    text = excluded.text, covered = excluded.covered, missing = excluded.missing,
                    feedback = excluded.feedback, model = excluded.model, updated = excluded.updated, deleted = 0
                """, [explanation.id, explanation.book, explanation.section, explanation.chapter, explanation.text,
                      Self.lines(explanation.covered), Self.lines(explanation.missing),
                      ChapterFeedback.encode(explanation.feedback), explanation.model,
                      explanation.created.timeIntervalSince1970, Date().timeIntervalSince1970])
        }
        NotificationCenter.default.post(name: AnnotationStore.didChange, object: explanation.book)
        return saved
    }

    func delete(id: String, book: String) {
        AnnotationStore.shared.writeBooks("borttagningen av förklaringen") { db in
            try db.execute("UPDATE chapter_explanations SET deleted = 1, updated = ? WHERE id = ?",
                           [Date().timeIntervalSince1970, id])
        }
        NotificationCenter.default.post(name: AnnotationStore.didChange, object: book)
    }
}

// MARK: Rutan

/// Rutan Förklara kapitlet: ett textfält (tangentbordets mikrofon dikterar), Jämför med mina markeringar och
/// Fråga Gemini. Förklaringen sparas när den jämförs och när rutan stängs. Öppnad ur anteckningsboken visar
/// den en sparad förklaring utan att något skickas.
final class ChapterExplainViewController: UIViewController, UITextViewDelegate {

    private let material: ChapterExplainMaterial?
    private var record: ChapterExplanation?
    private let book: String
    private let chapterTitle: String
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let textView = UITextView()
    private let placeholder = UILabel()
    private let resultStack = UIStackView()
    private let aiStack = UIStackView()
    private let messageLabel = UILabel()

    /// Till självtestet: läget, jämförelsen, svaret och frågan.
    private(set) var stateText = "skriver"
    private(set) var lastCoverage: ChapterCoverage?
    private(set) var lastFeedback: ChapterFeedback?
    private(set) var lastFailure: AIClient.Failure?
    private(set) var lastPrompt: String?
    private(set) var lastWasCached = false
    /// Självtestet väntar på svaret från Gemini.
    var onFinished: (() -> Void)?

    var savedRecord: ChapterExplanation? {
        record
    }

    init(material: ChapterExplainMaterial) {
        self.material = material
        book = material.book
        chapterTitle = material.chapter
        super.init(nibName: nil, bundle: nil)
        title = "Förklara kapitlet"
    }

    /// En sparad förklaring, ur anteckningsboken. Inget skickas.
    init(saved: ChapterExplanation) {
        material = nil
        record = saved
        book = saved.book
        chapterTitle = saved.chapter
        super.init(nibName: nil, bundle: nil)
        title = "Min förklaring"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    /// Visar rutan i ett ark (formSheet på iPad).
    static func present(material: ChapterExplainMaterial, from presenter: UIViewController) {
        guard presenter.presentedViewController == nil else { return }
        let controller = ChapterExplainViewController(material: material)
        let navigation = UINavigationController(rootViewController: controller)
        Theme.style(navigation.navigationBar)
        navigation.modalPresentationStyle = presenter.traitCollection.userInterfaceIdiom == .pad ? .formSheet : .pageSheet
        presenter.present(navigation, animated: true)
        AppLog.shared.write("A2: Förklara kapitlet öppnad, \(material.marks.count) markeringar, "
                            + "\(material.items.count) ord att jämföra")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let palette = Theme.current
        view.backgroundColor = palette.canvas
        view.tintColor = palette.accent
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Klar", style: .done, target: self,
                                                            action: #selector(close))
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.keyboardDismissMode = .interactive
        view.addSubview(scroll)
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        let width = stack.widthAnchor.constraint(equalToConstant: 560)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            scroll.contentLayoutGuide.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.centerXAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20),
            width,
        ])

        let heading = makeLabel(chapterTitle.isEmpty ? "Kapitlet" : chapterTitle, font: Theme.serif(.title3),
                                color: palette.ink)
        stack.addArrangedSubview(heading)
        if material != nil {
            var hint = "Förklara kapitlet med egna ord, som för någon som inte har läst det. Skriv, eller tryck på "
                + "mikrofonen på tangentbordet och prata."
            if material?.items.isEmpty == true {
                hint += " Du har inga markeringar eller begrepp i kapitlet än, så appen har inget att jämföra med."
            }
            stack.addArrangedSubview(makeLabel(hint, font: .preferredFont(forTextStyle: .subheadline),
                                               color: palette.inkSoft))
        }

        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = palette.ink
        textView.backgroundColor = palette.surface
        textView.layer.cornerRadius = 12
        textView.layer.borderWidth = 1
        textView.layer.borderColor = palette.rule.cgColor
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        textView.isScrollEnabled = false
        textView.autocapitalizationType = .sentences
        textView.delegate = self
        textView.text = record?.text ?? ""
        textView.isEditable = material != nil
        textView.accessibilityLabel = "Din förklaring"
        textView.heightAnchor.constraint(greaterThanOrEqualToConstant: material != nil ? 170 : 60).isActive = true
        placeholder.text = "Kapitlet handlar om …"
        placeholder.font = .preferredFont(forTextStyle: .body)
        placeholder.textColor = palette.inkFaint
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        textView.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.topAnchor.constraint(equalTo: textView.topAnchor, constant: 12),
            placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 13),
        ])
        placeholder.isHidden = !textView.text.isEmpty || material == nil
        stack.addArrangedSubview(textView)

        if material != nil {
            let compare = filledButton("Jämför med mina markeringar") { [weak self] in
                self?.compare()
            }
            let ask = tintedButton("Fråga Gemini") { [weak self] in
                self?.ask()
            }
            let buttons = UIStackView(arrangedSubviews: [compare, ask])
            buttons.axis = traitCollection.horizontalSizeClass == .compact ? .vertical : .horizontal
            buttons.spacing = 10
            buttons.distribution = .fillEqually
            stack.addArrangedSubview(buttons)
        }
        messageLabel.numberOfLines = 0
        messageLabel.font = .preferredFont(forTextStyle: .footnote)
        messageLabel.textColor = palette.inkSoft
        messageLabel.isHidden = true
        stack.addArrangedSubview(messageLabel)

        for column in [resultStack, aiStack] {
            column.axis = .vertical
            column.spacing = 10
            stack.addArrangedSubview(column)
        }
        if material != nil {
            stack.addArrangedSubview(makeLabel(
                "Med Gemini skickas bara din förklaring, kapitlets rubrik, bokens titel och texten i dina markeringar, "
                    + "aldrig kapitlets text.",
                font: .preferredFont(forTextStyle: .caption1), color: palette.inkFaint))
        }
        if let record = record {
            if !record.covered.isEmpty || !record.missing.isEmpty {
                showCoverage(ChapterCoverage(covered: record.covered.map(ChapterExplanation.item(code:)),
                                             missing: record.missing.map(ChapterExplanation.item(code:))))
            }
            if !record.feedback.isEmpty {
                showFeedback(ChapterFeedback(points: record.feedback), cached: true, saved: true)
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Det man skrivit eller dikterat sparas också när rutan stängs utan Jämför.
        saveIfChanged()
    }

    @objc private func close() {
        saveIfChanged()
        dismiss(animated: true)
    }

    func textViewDidChange(_ textView: UITextView) {
        placeholder.isHidden = !textView.text.isEmpty
    }

    /// Självtestet skriver i fältet som om det dikterats.
    func setTextForSelfTest(_ text: String) {
        textView.text = text
        placeholder.isHidden = !text.isEmpty
    }

    private var currentText: String {
        textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveIfChanged() {
        guard material != nil, !currentText.isEmpty, currentText != record?.text else { return }
        compare(showing: false)
    }

    // MARK: Jämför

    /// Jämför förklaringen med begreppen och nyckelorden och sparar den. Ändrad text tar bort ett gammalt svar.
    func compare() {
        compare(showing: true)
    }

    private func compare(showing: Bool) {
        guard let material = material else { return }
        let text = currentText
        guard !text.isEmpty else {
            showMessage("Skriv eller diktera din förklaring först.")
            return
        }
        let coverage = ChapterExplainLogic.coverage(material.items, explanation: text)
        lastCoverage = coverage
        let now = Date()
        var current = record ?? ChapterExplanation(id: UUID().uuidString.lowercased(), book: material.book,
                                                   section: material.section, chapter: material.chapter, text: text,
                                                   covered: [], missing: [], feedback: [], model: "", created: now,
                                                   updated: now)
        if current.text != text {
            current.feedback = []
            current.model = ""
            if showing {
                clear(aiStack)
                lastFeedback = nil
            }
        }
        current.text = text
        current.covered = ChapterExplanation.codes(coverage.covered)
        current.missing = ChapterExplanation.codes(coverage.missing)
        current.updated = now
        if ChapterExplanationStore.shared.save(current) {
            record = current
        }
        if showing {
            stateText = "jämförd"
            showCoverage(coverage)
            AppLog.shared.write("A2: jämförelse \(coverage.covered.count) med, \(coverage.missing.count) saknas")
        }
    }

    // MARK: Fråga Gemini

    func ask() {
        guard let material = material else { return }
        compare()
        guard let saved = record, !currentText.isEmpty else {
            onFinished?()
            return
        }
        guard !material.marks.isEmpty else {
            showMessage("Gemini behöver dina markeringar i kapitlet att hänvisa till. Markera det viktigaste först.")
            onFinished?()
            return
        }
        stateText = "frågar"
        clear(aiStack)
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        let row = UIStackView(arrangedSubviews: [spinner, makeLabel("Frågar Gemini …", font: .preferredFont(forTextStyle: .body),
                                                                    color: Theme.current.inkSoft)])
        row.spacing = 10
        row.alignment = .center
        aiStack.addArrangedSubview(row)
        let prompt = ChapterExplainLogic.prompt(material: material, explanation: saved.text)
        lastPrompt = prompt
        let schema = ChapterExplainLogic.schema(refs: material.marks.map(\.ref))
        let asked = saved.text
        AIClient.generate(kind: ChapterExplainLogic.kind, prompt: prompt, schema: schema, maxTokens: 2048) {
            [weak self] result in
            self?.handle(result, material: material, asked: asked)
        }
    }

    private func handle(_ result: Result<AIClient.Answer, AIClient.Failure>, material: ChapterExplainMaterial,
                        asked: String) {
        defer { onFinished?() }
        switch result {
        case .success(let answer):
            let feedback = ChapterFeedback(json: answer.json, marks: material.marks)
            lastFeedback = feedback
            lastWasCached = answer.cached
            lastFailure = nil
            // Svaret sparas bara om texten inte ändrats medan Gemini svarade.
            var saved = false
            if var current = record, current.text == asked {
                current.feedback = feedback.points
                current.model = GeminiClient.model
                current.updated = Date()
                if ChapterExplanationStore.shared.save(current) {
                    record = current
                    saved = true
                }
            }
            stateText = "svar"
            showFeedback(feedback, cached: answer.cached, saved: saved)
            AppLog.shared.write("A2: \(answer.cached ? "sparat svar" : "nytt svar"), \(feedback.points.count) punkter, "
                                + "\(feedback.dropped) utan egen markering, \(AIClient.callsToday) anrop i dag")
        case .failure(let failure):
            lastFailure = failure
            stateText = "fel"
            show(failure: failure)
            AppLog.shared.write("A2: \(failure)")
        }
    }

    // MARK: Lägena

    private func clear(_ column: UIStackView) {
        for view in column.arrangedSubviews {
            column.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func showMessage(_ text: String) {
        messageLabel.text = text
        messageLabel.isHidden = false
    }

    private func showCoverage(_ coverage: ChapterCoverage) {
        messageLabel.isHidden = true
        clear(resultStack)
        let palette = Theme.current
        let total = coverage.covered.count + coverage.missing.count
        guard total > 0 else {
            resultStack.addArrangedSubview(makeLabel(
                "Inga begrepp eller markerade nyckelord i kapitlet att jämföra med. Markera det viktigaste, eller gör "
                    + "begrepp av markeringarna, så visar appen vad som kom med.",
                font: .preferredFont(forTextStyle: .subheadline), color: palette.inkSoft))
            return
        }
        resultStack.addArrangedSubview(heading("Kom med, \(coverage.covered.count) av \(total)"))
        if coverage.covered.isEmpty {
            resultStack.addArrangedSubview(makeLabel("Inget av orden än.", font: .preferredFont(forTextStyle: .subheadline),
                                                     color: palette.inkSoft))
        } else {
            resultStack.addArrangedSubview(termLabel(coverage.covered, symbol: "checkmark.circle.fill",
                                                     color: palette.success))
        }
        if !coverage.missing.isEmpty {
            resultStack.addArrangedSubview(heading("Saknas, \(coverage.missing.count)"))
            for item in coverage.missing {
                let text = NSMutableAttributedString(string: item.term, attributes: [
                    .font: UIFont.preferredFont(forTextStyle: .headline), .foregroundColor: palette.ink,
                ])
                text.append(NSAttributedString(string: item.kind == .concept ? "  begrepp" : "  ur en markering",
                                               attributes: [.font: UIFont.preferredFont(forTextStyle: .caption1),
                                                            .foregroundColor: palette.inkSoft]))
                if let quote = material?.mark(id: item.highlight)?.text, !quote.isEmpty {
                    text.append(NSAttributedString(string: "\n»\(quote.prefix(140))«", attributes: [
                        .font: Theme.serif(.footnote), .foregroundColor: palette.inkFaint,
                    ]))
                }
                let label = UILabel()
                label.attributedText = text
                label.numberOfLines = 0
                resultStack.addArrangedSubview(label)
            }
        }
    }

    private func termLabel(_ items: [ChapterExplainItem], symbol: String, color: UIColor) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        let text = NSMutableAttributedString()
        for (offset, item) in items.enumerated() {
            if offset > 0 {
                text.append(NSAttributedString(string: "   "))
            }
            if let image = UIImage(systemName: symbol)?.withTintColor(color, renderingMode: .alwaysOriginal) {
                let attachment = NSTextAttachment()
                attachment.image = image
                attachment.bounds = CGRect(x: 0, y: -2, width: 14, height: 14)
                text.append(NSAttributedString(attachment: attachment))
            }
            text.append(NSAttributedString(string: " " + item.term, attributes: [
                .font: UIFont.preferredFont(forTextStyle: .subheadline), .foregroundColor: Theme.current.ink,
            ]))
        }
        label.attributedText = text
        return label
    }

    private func showFeedback(_ feedback: ChapterFeedback, cached: Bool, saved: Bool) {
        clear(aiStack)
        let palette = Theme.current
        if feedback.points.isEmpty {
            aiStack.addArrangedSubview(makeLabel("Gemini hittade inget att peka på i dina markeringar.",
                                                 font: .preferredFont(forTextStyle: .subheadline), color: palette.inkSoft))
        }
        for kind in ChapterFeedback.Kind.allCases {
            let points = feedback.points.filter { $0.kind == kind }
            guard !points.isEmpty else { continue }
            aiStack.addArrangedSubview(heading("Gemini: " + kind.title.lowercased()))
            let color: UIColor
            switch kind {
            case .correct: color = palette.success
            case .missing: color = palette.warning
            case .wrong: color = palette.ribbon
            }
            for point in points {
                let text = NSMutableAttributedString(string: point.text, attributes: [
                    .font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: palette.ink,
                ])
                if !point.quote.isEmpty {
                    text.append(NSAttributedString(string: "\nDin markering: »\(point.quote.prefix(160))«", attributes: [
                        .font: Theme.serif(.footnote), .foregroundColor: palette.inkSoft,
                    ]))
                }
                let label = UILabel()
                label.attributedText = text
                label.numberOfLines = 0
                let bar = UIView()
                bar.backgroundColor = color
                bar.layer.cornerRadius = 1.5
                bar.widthAnchor.constraint(equalToConstant: 3).isActive = true
                let row = UIStackView(arrangedSubviews: [bar, label])
                row.spacing = 10
                row.alignment = .fill
                aiStack.addArrangedSubview(row)
            }
        }
        var lines: [String] = []
        if feedback.dropped > 0 {
            lines.append(feedback.dropped == 1
                         ? "1 punkt visas inte, eftersom den inte pekade på någon av dina markeringar."
                         : "\(feedback.dropped) punkter visas inte, eftersom de inte pekade på någon av dina markeringar.")
        }
        if material != nil {
            if saved {
                lines.append("Sparat i anteckningsboken.")
            }
            let usage = "\(AIClient.callsToday) anrop till Gemini i dag."
            lines.append(cached ? "Sparat svar, inget nytt anrop. " + usage : usage)
        }
        if !lines.isEmpty {
            aiStack.addArrangedSubview(makeLabel(lines.joined(separator: "\n"), font: .preferredFont(forTextStyle: .caption1),
                                                 color: palette.inkFaint))
        }
    }

    private func show(failure: AIClient.Failure) {
        clear(aiStack)
        let palette = Theme.current
        let icon = UIImageView(image: UIImage(systemName: failure.needsSetup ? "key" : "exclamationmark.circle"))
        icon.tintColor = failure.needsSetup ? palette.accent : palette.warning
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let message = makeLabel(failure.errorDescription ?? "", font: .preferredFont(forTextStyle: .body), color: palette.ink)
        let row = UIStackView(arrangedSubviews: [icon, message])
        row.spacing = 10
        row.alignment = .top
        aiStack.addArrangedSubview(row)
        if failure.needsSetup {
            aiStack.addArrangedSubview(plainButton(AIClient.hasKey ? "Kontrollera nyckeln" : "Ställ in Förklaring med AI") {
                [weak self] in
                self?.openGuide()
            })
        } else {
            aiStack.addArrangedSubview(plainButton("Försök igen") { [weak self] in
                self?.ask()
            })
        }
        aiStack.addArrangedSubview(makeLabel("Jämförelsen med dina markeringar fungerar utan Gemini.",
                                             font: .preferredFont(forTextStyle: .caption1), color: palette.inkFaint))
    }

    private func openGuide() {
        let guide = AIKeyGuideViewController()
        guide.onWorking = { [weak self] in
            guard let self = self else { return }
            self.navigationController?.popToViewController(self, animated: true)
            self.ask()
        }
        navigationController?.pushViewController(guide, animated: true)
    }

    // MARK: Vyerna

    private func heading(_ text: String) -> UILabel {
        let label = makeLabel(text.uppercased(with: Locale(identifier: "sv_SE")), font: .systemFont(ofSize: 12, weight: .semibold),
                              color: Theme.current.inkSoft)
        return label
    }

    private func makeLabel(_ text: String, font: UIFont, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.font = font
        label.textColor = color
        return label
    }

    private func filledButton(_ title: String, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.cornerStyle = .large
        configuration.baseBackgroundColor = Theme.current.accent
        configuration.baseForegroundColor = Theme.current.page
        let button = UIButton(configuration: configuration)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 46).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func tintedButton(_ title: String, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.tinted()
        configuration.title = title
        configuration.image = UIImage(systemName: "sparkles")
        configuration.imagePadding = 6
        configuration.cornerStyle = .large
        configuration.baseBackgroundColor = Theme.current.accent
        configuration.baseForegroundColor = Theme.current.ink
        let button = UIButton(configuration: configuration)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 46).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func plainButton(_ title: String, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.baseForegroundColor = Theme.current.accent
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)
        let button = UIButton(configuration: configuration)
        button.contentHorizontalAlignment = .leading
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }
}
