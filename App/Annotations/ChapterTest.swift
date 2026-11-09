import UIKit

/// Ett kort i självtestet (K7): en egen markering med ett ord bortplockat (lucktext), samma sak med fyra
/// alternativ (flerval), eller en fråga ur bokens frågefil (K6). Inget av det kräver AI eller nät.
struct ChapterTestCard: Equatable {

    enum Kind: Equatable {
        case cloze, choice, question
    }

    /// Id i schemat: `m:` plus markeringens id, `q:` plus bokens och frågans id.
    let id: String
    let book: String
    let kind: Kind
    /// Texten med luckan (`_____`), eller frågan.
    let prompt: String
    let answer: String
    /// Flerval: alternativen, rätt svar bland dem.
    let options: [String]
    /// Var kortet kommer ifrån, till exempel kapitlets namn eller bokens titel.
    let source: String
    /// K6: frågans id, så att svaret också sparas som Kan, Osäker eller Kan inte.
    let questionID: String?

    var kindTitle: String {
        switch kind {
        case .cloze: return "Lucktext"
        case .choice: return "Välj ordet"
        case .question: return "Fråga"
        }
    }
}

/// Hur korten görs (G13, ren logik): vilket ord som plockas bort, felaktiga alternativ och blandningen.
enum ChapterTestLogic {

    static let blank = "_____"
    static let maxCards = 12

    private static let wordPattern = try? NSRegularExpression(pattern: "[\\p{L}\\p{M}]+(?:['’\\-‐][\\p{L}\\p{M}]+)*")

    static func wordRanges(in text: String) -> [NSRange] {
        let ns = text as NSString
        return wordPattern?.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range) ?? []
    }

    /// Ordet som plockas bort: ett begrepp ur bokens begreppsregister (K8) om det står i markeringen, annars
    /// det längsta ordet som inte är ett småord. Nil när markeringen har färre än fyra ord.
    static func keyword(in text: String, terms: [String]) -> NSRange? {
        let ns = text as NSString
        let words = wordRanges(in: text)
        guard words.count >= 4 else { return nil }
        for term in terms.sorted(by: { $0.count > $1.count }) where term.count >= 3 {
            let found = ns.range(of: term, options: [.caseInsensitive])
            guard found.location != NSNotFound else { continue }
            // Bara hela ord: inget ordtecken precis före eller efter.
            let before = found.location > 0 ? ns.substring(with: NSRange(location: found.location - 1, length: 1)) : " "
            let afterIndex = NSMaxRange(found)
            let after = afterIndex < ns.length ? ns.substring(with: NSRange(location: afterIndex, length: 1)) : " "
            if !isLetter(before), !isLetter(after), found.length < ns.length {
                return found
            }
        }
        var best: NSRange?
        for range in words where range.length >= 4 {
            let word = ns.substring(with: range).lowercased()
            if ReviewStopWords.swedish.contains(word) || ReviewStopWords.english.contains(word) {
                continue
            }
            if range.length > (best?.length ?? 0) {
                best = range
            }
        }
        return best
    }

    private static func isLetter(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
    }

    /// Markeringens text med ordet utbytt mot en lucka.
    static func cloze(_ text: String, hiding range: NSRange) -> String {
        (text as NSString).replacingCharacters(in: range, with: blank)
    }

    /// Tre felaktiga alternativ ur samlingen (andra markeringars nyckelord och bokens begrepp): inte rätt svar,
    /// inga dubbletter, helst lika långa som svaret. Samma kort ger samma alternativ varje gång.
    static func distractors(for answer: String, pool: [String], count: Int = 3, seed: String) -> [String] {
        let wanted = answer.lowercased()
        var seen = Set<String>([wanted])
        var unique: [String] = []
        for item in pool {
            let clean = item.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = clean.lowercased()
            guard !clean.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            unique.append(clean)
        }
        let length = answer.count
        return unique.sorted { a, b in
            let da = abs(a.count - length)
            let db = abs(b.count - length)
            if da != db { return da < db }
            return BookQuestionFile.stableHash(seed + a) < BookQuestionFile.stableHash(seed + b)
        }.prefix(count).map { $0 }
    }

    /// Alternativen i en blandning som är densamma varje gång för samma kort.
    static func shuffled(_ options: [String], seed: String) -> [String] {
        options.sorted { BookQuestionFile.stableHash(seed + $0) < BookQuestionFile.stableHash(seed + $1) }
    }

    /// Korten för markeringarna (i textens ordning) och frågorna. Vartannat markeringskort blir flerval när det
    /// finns tre felaktiga alternativ. `allHighlights` är bokens alla markeringar, till alternativen.
    static func cards(highlights: [Highlight], allHighlights: [Highlight], questions: [BookQuestion], terms: [String],
                      book: String, source: String, limit: Int = maxCards) -> [ChapterTestCard] {
        var pool: [String] = terms
        for highlight in allHighlights {
            if let range = keyword(in: highlight.text, terms: terms) {
                pool.append((highlight.text as NSString).substring(with: range))
            }
        }
        var result: [ChapterTestCard] = []
        var made = 0
        for highlight in highlights.sorted(by: { ($0.section, $0.start) < ($1.section, $1.start) }) {
            let text = Citation.cleanQuote(highlight.text)
            guard let range = keyword(in: text, terms: terms) else { continue }
            let answer = (text as NSString).substring(with: range)
            let id = "m:" + highlight.id
            let wrong = distractors(for: answer, pool: pool, seed: id)
            let choice = made % 2 == 1 && wrong.count == 3
            result.append(ChapterTestCard(id: id, book: book, kind: choice ? .choice : .cloze,
                                          prompt: cloze(text, hiding: range), answer: answer,
                                          options: choice ? shuffled(wrong + [answer], seed: id) : [],
                                          source: source, questionID: nil))
            made += 1
        }
        for question in questions {
            result.append(ChapterTestCard(id: "q:\(book):\(question.id)", book: book, kind: .question,
                                          prompt: question.question,
                                          answer: question.answer.joined(separator: "\n"),
                                          options: [], source: source, questionID: question.id))
        }
        return Array(result.prefix(limit))
    }

    /// Kapitlet som avslutats när man bläddrat framåt från sida `from` till sida `to`, i en bok vars kapitel
    /// börjar på `starts` (sorterade). Nil när bläddringen inte gick över en kapitelgräns framåt.
    static func finishedChapter(from: Int, to: Int, starts: [Int]) -> Int? {
        guard to > from, !starts.isEmpty else { return nil }
        let before = starts.lastIndex { $0 <= from }
        let after = starts.lastIndex { $0 <= to }
        guard let chapter = before, let next = after, next > chapter else { return nil }
        return chapter
    }
}

/// Schemat för korten (K7): tabellen `study_cards` i markeringar.sqlite (steg 11, följer med i
/// säkerhetskopian). Samma schema som orden (`ReviewSchedule`). Bara från huvudtråden.
final class StudyCardStore {

    static let shared = StudyCardStore()
    /// Nya kort per dag i Dagens markeringar.
    static let newPerDay = 10
    static let dailyLimit = 20

    struct State: Equatable {
        var due: Double
        var interval: Double
        var ease: Double
        var reps: Int
        var lapses: Int
        var introduced: Double
    }

    private init() {}

    func states() -> [String: State] {
        var result: [String: State] = [:]
        AnnotationStore.shared.readBooks { db in
            try db.query("SELECT id, due, interval, ease, reps, lapses, introduced FROM study_cards") { row in
                result[row.string(0)] = State(due: row.double(1), interval: row.double(2), ease: row.double(3),
                                              reps: row.int(4), lapses: row.int(5), introduced: row.double(6))
            }
        }
        return result
    }

    /// Sparar hur det gick och räknar ut nästa gång. Svarar med antalet dagar till nästa gång.
    @discardableResult
    func record(_ grade: ReviewGrade, for card: ChapterTestCard, now: Date = Date()) -> Double {
        let state = states()[card.id]
        let next = ReviewSchedule.next(grade, interval: state?.interval ?? 0, ease: state?.ease ?? 2.5,
                                       reps: state?.reps ?? 0)
        let current = now.timeIntervalSince1970
        let kind: String
        switch card.kind {
        case .question: kind = "fraga"
        case .choice, .cloze: kind = "markering"
        }
        AnnotationStore.shared.writeBooks("självtestets kort") { db in
            try db.execute("""
                INSERT INTO study_cards (id, book, kind, due, interval, ease, reps, lapses, introduced, updated)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET due = excluded.due, interval = excluded.interval, ease = excluded.ease,
                    reps = excluded.reps, lapses = excluded.lapses, updated = excluded.updated
                """, [card.id, card.book, kind, current + next.interval * 86_400, next.interval, next.ease, next.reps,
                      (state?.lapses ?? 0) + (next.lapse ? 1 : 0), current, current])
        }
        return next.interval
    }

    /// Nästa intervall för ett kort och ett betyg, till knapparna.
    func preview(_ grade: ReviewGrade, for card: ChapterTestCard, states: [String: State]) -> Double {
        let state = states[card.id]
        return ReviewSchedule.next(grade, interval: state?.interval ?? 0, ease: state?.ease ?? 2.5,
                                   reps: state?.reps ?? 0).interval
    }

    /// Dagens markeringar: kort ur markeringarna i alla böcker som är på tur, sedan nya (högst tio om dagen),
    /// högst tjugo. Lucktext och flerval om vartannat.
    func todaysCards(now: Date = Date()) -> [ChapterTestCard] {
        let highlights = AnnotationStore.shared.highlightsForSync().filter { !$0.1 }.map(\.0)
        guard !highlights.isEmpty else { return [] }
        var titles: [String: String] = [:]
        for record in BookRegistry.shared.records() {
            titles[record.id] = record.displayTitle
        }
        var cards: [ChapterTestCard] = []
        for (book, list) in Dictionary(grouping: highlights, by: \.book) {
            let terms = ConceptStore.shared.concepts(book: book).map(\.term)
            cards += ChapterTestLogic.cards(highlights: list, allHighlights: list, questions: [], terms: terms,
                                            book: book, source: titles[book] ?? "", limit: 400)
        }
        let states = self.states()
        let current = now.timeIntervalSince1970
        let midnight = Calendar.current.startOfDay(for: now).timeIntervalSince1970
        let introducedToday = states.filter { $0.key.hasPrefix("m:") && $0.value.introduced >= midnight }.count
        let due = cards.filter { (states[$0.id]?.due ?? .greatestFiniteMagnitude) <= current }
            .sorted { (states[$0.id]?.due ?? 0) < (states[$1.id]?.due ?? 0) }
        let fresh = cards.filter { states[$0.id] == nil }
            .sorted { BookQuestionFile.stableHash($0.id) < BookQuestionFile.stableHash($1.id) }
        return Array((due + fresh.prefix(max(0, Self.newPerDay - introducedToday))).prefix(Self.dailyLimit))
    }
}

/// Raden som erbjuder testet när sista sidan i ett kapitel vänts (K7): Testa och ett kryss som hoppar över.
/// Ligger ovanpå läsaren som raden Ångra och försvinner av sig själv. Rör inte sidans placering.
@MainActor
final class ChapterTestOffer: UIView {

    private(set) static weak var current: ChapterTestOffer?
    private var onStart: (() -> Void)?

    @discardableResult
    static func show(chapter: String, count: Int, in host: UIView, bottomInset: CGFloat = 96,
                     start: @escaping () -> Void) -> ChapterTestOffer {
        current?.removeFromSuperview()
        let offer = ChapterTestOffer(chapter: chapter, count: count, start: start)
        offer.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(offer)
        NSLayoutConstraint.activate([
            offer.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            offer.bottomAnchor.constraint(equalTo: host.safeAreaLayoutGuide.bottomAnchor, constant: -bottomInset),
            offer.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, constant: -32),
            offer.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
        ])
        current = offer
        offer.alpha = 0
        UIView.animate(withDuration: 0.2) { offer.alpha = 1 }
        UIAccessibility.post(notification: .announcement, argument: "Testa dig på kapitlet")
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [weak offer] in
            offer?.hide()
        }
        return offer
    }

    private init(chapter: String, count: Int, start: @escaping () -> Void) {
        onStart = start
        super.init(frame: .zero)
        let palette = Theme.current
        backgroundColor = palette.surface
        layer.cornerRadius = 22
        layer.borderWidth = 1
        layer.borderColor = palette.rule.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = palette.isDark ? 0.4 : 0.15
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 2)

        let title = UILabel()
        title.text = "Testa dig på kapitlet"
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = palette.ink
        let detail = UILabel()
        detail.text = (chapter.isEmpty ? "" : chapter + ", ") + (count == 1 ? "1 kort" : "\(count) kort")
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = palette.inkSoft
        detail.lineBreakMode = .byTruncatingMiddle
        let texts = UIStackView(arrangedSubviews: [title, detail])
        texts.axis = .vertical
        texts.spacing = 1

        let test = UIButton(type: .system)
        test.setTitle("Testa", for: .normal)
        test.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        test.tintColor = palette.accent
        test.addAction(UIAction { [weak self] _ in self?.startTapped() }, for: .touchUpInside)
        let skip = UIButton(type: .system)
        skip.setImage(UIImage(systemName: "xmark"), for: .normal)
        skip.tintColor = palette.inkSoft
        skip.accessibilityLabel = "Hoppa över"
        skip.addAction(UIAction { [weak self] _ in self?.hide() }, for: .touchUpInside)
        skip.widthAnchor.constraint(equalToConstant: 32).isActive = true

        let stack = UIStackView(arrangedSubviews: [texts, test, skip])
        stack.spacing = 14
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    /// Testa (också från självtestet).
    func startTapped() {
        let start = onStart
        onStart = nil
        hide()
        start?()
    }

    func hide() {
        guard superview != nil else { return }
        UIView.animate(withDuration: 0.2, animations: { self.alpha = 0 }, completion: { _ in
            self.removeFromSuperview()
        })
    }
}

/// Självtestet efter ett kapitel och Dagens markeringar (K7): ett kort i taget, med framstegslinje.
/// Lucktext och frågor: Visa svaret och sedan hur det gick. Flerval: tryck på ett alternativ.
final class ChapterTestViewController: UIViewController {

    private let cards: [ChapterTestCard]
    private var index = 0
    private var revealed = false
    private var right = 0
    private var answeredChoices = 0
    private var states: [String: StudyCardStore.State] = [:]

    private let progress = UIProgressView(progressViewStyle: .bar)
    private let countLabel = UILabel()
    private let card = UIView()
    private let kindLabel = UILabel()
    private let promptLabel = UILabel()
    private let sourceLabel = UILabel()
    private let answerLabel = UILabel()
    private let showButton = UIButton(type: .system)
    private let optionStack = UIStackView()
    private let gradeStack = UIStackView()
    private let nextButton = UIButton(type: .system)
    private let doneLabel = UILabel()

    init(cards: [ChapterTestCard], title: String) {
        self.cards = cards
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    /// Självtestet: kortet som visas och antalet kort.
    var currentCard: ChapterTestCard? {
        index < cards.count ? cards[index] : nil
    }

    var cardCount: Int {
        cards.count
    }

    /// Anropas när testet stängs, så att biblioteket kan räkna om Dagens markeringar.
    var onClose: (() -> Void)?

    /// Visar testet i ett ark (formSheet på iPad).
    static func present(cards: [ChapterTestCard], title: String, from presenter: UIViewController,
                        onClose: (() -> Void)? = nil) {
        guard presenter.presentedViewController == nil, !cards.isEmpty else { return }
        let controller = ChapterTestViewController(cards: cards, title: title)
        controller.onClose = onClose
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = presenter.traitCollection.userInterfaceIdiom == .pad ? .formSheet : .pageSheet
        presenter.present(navigation, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let palette = Theme.current
        view.backgroundColor = palette.canvas
        view.tintColor = palette.accent
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Klar", style: .done, target: self,
                                                            action: #selector(close))
        states = StudyCardStore.shared.states()

        progress.trackTintColor = palette.rule
        progress.progressTintColor = palette.accent
        countLabel.font = .preferredFont(forTextStyle: .subheadline)
        countLabel.textColor = palette.inkSoft
        countLabel.textAlignment = .right

        card.backgroundColor = palette.surface
        card.layer.cornerRadius = 16
        card.layer.borderWidth = 1
        card.layer.borderColor = palette.rule.cgColor
        kindLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        kindLabel.textColor = palette.inkSoft
        promptLabel.font = Theme.serif(.title3, size: 21)
        promptLabel.textColor = palette.ink
        promptLabel.numberOfLines = 0
        sourceLabel.font = .preferredFont(forTextStyle: .footnote)
        sourceLabel.textColor = palette.inkFaint
        sourceLabel.numberOfLines = 1
        answerLabel.font = Theme.serif(.title3, size: 20, weight: .semibold)
        answerLabel.textColor = palette.ink
        answerLabel.numberOfLines = 0
        let cardStack = UIStackView(arrangedSubviews: [kindLabel, promptLabel, sourceLabel, answerLabel])
        cardStack.axis = .vertical
        cardStack.spacing = 12
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cardStack)

        var showConfiguration = UIButton.Configuration.filled()
        showConfiguration.title = "Visa svaret"
        showConfiguration.cornerStyle = .large
        showConfiguration.buttonSize = .large
        showConfiguration.baseBackgroundColor = palette.accent
        showConfiguration.baseForegroundColor = palette.page
        showButton.configuration = showConfiguration
        showButton.addAction(UIAction { [weak self] _ in self?.reveal() }, for: .touchUpInside)

        optionStack.axis = .vertical
        optionStack.spacing = 10
        gradeStack.axis = .horizontal
        gradeStack.spacing = 8
        gradeStack.distribution = .fillEqually

        var nextConfiguration = UIButton.Configuration.filled()
        nextConfiguration.title = "Nästa"
        nextConfiguration.cornerStyle = .large
        nextConfiguration.buttonSize = .large
        nextConfiguration.baseBackgroundColor = palette.accent
        nextConfiguration.baseForegroundColor = palette.page
        nextButton.configuration = nextConfiguration
        nextButton.addAction(UIAction { [weak self] _ in self?.advance() }, for: .touchUpInside)

        doneLabel.numberOfLines = 0
        doneLabel.textAlignment = .center
        doneLabel.font = Theme.serif(.title3)
        doneLabel.textColor = palette.inkSoft
        doneLabel.isHidden = true

        // Kortet överst, knapparna längst ner där tummarna når (som repetitionen, U6).
        let stack = UIStackView(arrangedSubviews: [progress, countLabel, card, doneLabel])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let controls = UIStackView(arrangedSubviews: [optionStack, showButton, gradeStack, nextButton])
        controls.axis = .vertical
        controls.spacing = 12
        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)
        NSLayoutConstraint.activate([
            cardStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
            cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -22),
            cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            progress.heightAnchor.constraint(equalToConstant: 3),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: controls.topAnchor, constant: -12),
            controls.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            gradeStack.heightAnchor.constraint(equalToConstant: 58),
        ])
        for column in [stack, controls] {
            NSLayoutConstraint.activate([
                column.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                column.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
                column.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
                column.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor),
            ])
            let width = column.widthAnchor.constraint(equalToConstant: 560)
            width.priority = .defaultHigh
            width.isActive = true
        }
        show()
    }

    // MARK: Korten

    private func show() {
        revealed = false
        optionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        gradeStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        progress.setProgress(cards.isEmpty ? 1 : Float(index) / Float(cards.count), animated: true)
        guard index < cards.count else {
            card.isHidden = true
            showButton.isHidden = true
            gradeStack.isHidden = true
            nextButton.isHidden = true
            optionStack.isHidden = true
            countLabel.text = nil
            doneLabel.isHidden = false
            doneLabel.text = answeredChoices > 0
                ? "Klart. Du testade \(cards.count) kort och valde rätt ord \(right) av \(answeredChoices) gånger."
                : "Klart. Du testade \(cards.count) kort."
            return
        }
        let current = cards[index]
        let left = cards.count - index
        countLabel.text = left == 1 ? "1 kvar" : "\(left) kvar"
        kindLabel.text = current.kindTitle.uppercased()
        promptLabel.text = current.prompt
        sourceLabel.text = current.source
        sourceLabel.isHidden = current.source.isEmpty
        answerLabel.text = current.kind == .question && current.answer.isEmpty ? "Inget svar i frågefilen." : current.answer
        answerLabel.isHidden = true
        nextButton.isHidden = true
        gradeStack.isHidden = true
        switch current.kind {
        case .choice:
            showButton.isHidden = true
            optionStack.isHidden = false
            for option in current.options {
                var configuration = UIButton.Configuration.tinted()
                configuration.title = option
                configuration.cornerStyle = .large
                configuration.baseForegroundColor = Theme.current.ink
                configuration.baseBackgroundColor = Theme.current.accent
                let button = UIButton(configuration: configuration)
                button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
                button.addAction(UIAction { [weak self] _ in self?.choose(option) }, for: .touchUpInside)
                optionStack.addArrangedSubview(button)
            }
        case .cloze, .question:
            showButton.isHidden = false
            optionStack.isHidden = true
        }
    }

    func reveal() {
        guard index < cards.count, !revealed else { return }
        revealed = true
        let current = cards[index]
        answerLabel.alpha = 0
        answerLabel.isHidden = false
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.25) {
            self.answerLabel.alpha = 1
        }
        showButton.isHidden = true
        gradeStack.isHidden = false
        let palette = Theme.current
        let grades: [(ReviewGrade, String, UIColor)]
        if current.kind == .question {
            grades = [(.again, QuestionStatus.unknown.title, palette.ribbon), (.hard, QuestionStatus.unsure.title, palette.warning),
                      (.good, QuestionStatus.known.title, palette.success)]
        } else {
            grades = [(.again, ReviewGrade.again.title, palette.ribbon), (.hard, ReviewGrade.hard.title, palette.warning),
                      (.good, ReviewGrade.good.title, palette.success), (.easy, ReviewGrade.easy.title, palette.accent)]
        }
        for (grade, title, color) in grades {
            var configuration = UIButton.Configuration.tinted()
            configuration.title = title
            configuration.subtitle = ReviewSchedule.label(days: StudyCardStore.shared.preview(grade, for: current, states: states))
            configuration.titleAlignment = .center
            configuration.cornerStyle = .large
            configuration.baseForegroundColor = color
            configuration.baseBackgroundColor = color
            let button = UIButton(configuration: configuration)
            button.addAction(UIAction { [weak self] _ in self?.grade(grade) }, for: .touchUpInside)
            gradeStack.addArrangedSubview(button)
        }
    }

    func grade(_ grade: ReviewGrade) {
        guard index < cards.count, revealed else { return }
        let current = cards[index]
        StudyCardStore.shared.record(grade, for: current)
        if let question = current.questionID {
            let status: QuestionStatus = grade == .again ? .unknown : (grade == .hard ? .unsure : .known)
            QuestionStore.shared.setStatus(status, question: question, book: current.book)
        }
        Haptics.shared.wordTapped()
        advance()
    }

    /// Flerval: rätt alternativ blir grönt och sparas som Bra, fel blir rött och sparas som Igen.
    func choose(_ option: String) {
        guard index < cards.count, !revealed else { return }
        revealed = true
        let current = cards[index]
        let correct = option.caseInsensitiveCompare(current.answer) == .orderedSame
        answeredChoices += 1
        if correct {
            right += 1
        }
        StudyCardStore.shared.record(correct ? .good : .again, for: current)
        let palette = Theme.current
        for case let button as UIButton in optionStack.arrangedSubviews {
            let title = button.configuration?.title ?? ""
            var configuration = button.configuration
            if title.caseInsensitiveCompare(current.answer) == .orderedSame {
                configuration?.baseBackgroundColor = palette.success
                configuration?.baseForegroundColor = palette.success
                configuration?.image = UIImage(systemName: "checkmark")
            } else if title == option {
                configuration?.baseBackgroundColor = palette.ribbon
                configuration?.baseForegroundColor = palette.ribbon
                configuration?.image = UIImage(systemName: "xmark")
            }
            configuration?.imagePadding = 6
            button.configuration = configuration
            button.isUserInteractionEnabled = false
        }
        answerLabel.text = (current.prompt as NSString).replacingOccurrences(of: ChapterTestLogic.blank, with: current.answer)
        answerLabel.font = Theme.serif(.body, size: 17)
        answerLabel.isHidden = false
        nextButton.isHidden = false
        Haptics.shared.wordTapped()
    }

    private func advance() {
        states = StudyCardStore.shared.states()
        answerLabel.font = Theme.serif(.title3, size: 20, weight: .semibold)
        index += 1
        show()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            let close = onClose
            onClose = nil
            close?()
        }
    }

    @objc private func close() {
        dismiss(animated: true)
    }
}
