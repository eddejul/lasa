import UIKit

/// U6: svaret ur ordboken som repetitionen visar, och om ordboken har något svar alls. Ord utan svar hamnar
/// inte i kön (`UserWords.reviewQueue`) och räknas inte på kortet Repetera.
enum ReviewAnswers {

    static let missing = "Ordboken har inget svar för ordet."

    /// Om ordet har ett svar, per språk, grundform och vald betydelse. Ordboken ändras inte medan appen kör, så
    /// svaret sparas i minnet: kön räknas varje gång biblioteket visas. Glöms när ett synonympar döljs.
    private static var known: [String: Bool] = [:]

    /// Svarets rader: för engelska ord översättningen och definitionen, för svenska definitionen och liknande
    /// ord. Har en betydelse valts när ordet sparades (O7) visas bara den, annars den första. Tomt när ordboken
    /// inte har något svar. `sentence` väljer ordklassen för engelska ord, tom är snabbast (ingen språkmodell).
    static func lines(for word: SavedWord, sentence: String) -> [String] {
        guard let lookup = WordDictionary.shared?.lookup(word.lemma, sentence: sentence, language: word.language,
                                                         hidden: UserWords.shared.hiddenPairs),
              let first = lookup.entries.first else {
            return []
        }
        let chosen = WordText.sense(withID: word.senseID, in: lookup.entries)
        let entry = chosen?.entry ?? first
        let shown = chosen?.sense ?? entry.senses.first
        var lines: [String] = []
        if word.language == .english {
            let translation = WordText.translationLine(entry)
            let definition = shown?.definition
            guard !translation.isEmpty || definition != nil else { return [] }
            lines.append(translation.isEmpty ? "Ingen svensk översättning i ordboken." : translation)
            if let definition = definition {
                lines.append(definition)
            }
        } else if let sense = shown {
            if let definition = sense.definition {
                lines.append(definition)
            }
            let synonyms = WordText.synonymLine(sense)
            if !synonyms.isEmpty {
                lines.append("Liknande ord: " + synonyms)
            }
        }
        return lines
    }

    /// Om ordboken har ett svar för ordet. Saknas ordboken räknas alla ord som besvarade, så att kön inte
    /// töms av ett fel i bygget.
    static func exists(for word: SavedWord) -> Bool {
        guard WordDictionary.shared != nil else { return true }
        let key = word.language.rawValue + "|" + word.lemma + "|" + word.senseID + "|" + word.sentence
        if let found = known[key] {
            return found
        }
        // Granskning 5, L1: samma svar som kortet visar (`shownLines`). Utan meningen först, det är snabbast. Bara
        // när det inte ger något svar prövas meningen, som kan välja en annan ordklass för ett engelskt ord.
        let found = !shownLines(for: word, fastFirst: true).isEmpty
        known[key] = found
        return found
    }

    /// Svaret som kortet visar: med ordets mening, och utan den när meningen inte ger något svar. Tomt bara när
    /// ordboken inte har något svar alls, och då kommer ordet inte heller med i kön.
    static func shownLines(for word: SavedWord, fastFirst: Bool = false) -> [String] {
        if fastFirst || word.sentence.isEmpty {
            let fast = lines(for: word, sentence: "")
            return fast.isEmpty && !word.sentence.isEmpty ? lines(for: word, sentence: word.sentence) : fast
        }
        let withSentence = lines(for: word, sentence: word.sentence)
        return withSentence.isEmpty ? lines(for: word, sentence: "") : withSentence
    }

    static func forget() {
        known.removeAll()
    }
}

/// Repetera sparade ord som kort (fas 6, U6): en tunn framstegslinje överst, ett papperskort med ordet stort,
/// meningen och källan under, och svaret som tonas fram när man trycker på kortet. Betygen ligger längst ner där
/// tummarna når, med när ordet kommer igen under varje. Filtret överst väljer alla ord, en bok eller en kurs.
/// Ingen tid för omgången någonstans, bara antal ord (Edvins beslut).
final class WordReviewViewController: UIViewController {

    /// Filtret sparas mellan gångerna (`ReviewFilter.storage`).
    static let filterKey = "review.filter"

    private var queue: [ReviewCard] = []
    private var index = 0
    private var reviewed = 0
    private var revealed = false
    private(set) var filter: ReviewFilter
    private var books: [(id: String, title: String)] = []
    private var courses: [Course] = []

    private let filterButton = UIButton(type: .system)
    private let countLabel = UILabel()
    private let progressTrack = UIView()
    private let progressFill = UIView()
    private let card = UIView()
    private let wordLabel = UILabel()
    private let kindLabel = UILabel()
    private let sentenceLabel = UILabel()
    private let sourceLabel = UILabel()
    private let rule = UIView()
    private let answerArea = UIView()
    private let answerStack = UIStackView()
    private let answerLabel = UILabel()
    private let detailLabel = UILabel()
    private let hintLabel = UILabel()
    private let showButton = UIButton(type: .system)
    private let gradeStack = UIStackView()
    private var gradeButtons: [ReviewGrade: UIButton] = [:]
    private var gradeDays: [ReviewGrade: Double] = [:]
    private let doneLabel = UILabel()

    init() {
        filter = ReviewFilter(storage: UserDefaults.standard.string(forKey: Self.filterKey) ?? "")
        super.init(nibName: nil, bundle: nil)
        title = "Repetera"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never

        filterButton.showsMenuAsPrimaryAction = true
        filterButton.accessibilityHint = "Välj alla ord, en bok eller en kurs"
        countLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        countLabel.textAlignment = .right
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        progressTrack.layer.cornerRadius = 2
        progressTrack.clipsToBounds = true
        progressTrack.addSubview(progressFill)
        progressFill.layer.cornerRadius = 2

        card.layer.cornerRadius = 20
        card.layer.borderWidth = 1
        card.layer.shadowOpacity = 0.08
        card.layer.shadowRadius = 14
        card.layer.shadowOffset = CGSize(width: 0, height: 6)
        card.isAccessibilityElement = false
        card.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(cardTapped)))

        wordLabel.textAlignment = .center
        wordLabel.numberOfLines = 2
        wordLabel.adjustsFontSizeToFitWidth = true
        wordLabel.minimumScaleFactor = 0.5
        wordLabel.accessibilityTraits = .header
        kindLabel.font = .systemFont(ofSize: 14)
        kindLabel.textAlignment = .center
        sentenceLabel.numberOfLines = 5
        sentenceLabel.lineBreakMode = .byTruncatingTail
        sentenceLabel.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        sourceLabel.font = .systemFont(ofSize: 13)
        sourceLabel.textAlignment = .center
        sourceLabel.numberOfLines = 1

        answerLabel.font = .systemFont(ofSize: 22)
        answerLabel.textAlignment = .center
        answerLabel.numberOfLines = 4
        answerLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 16)
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 4
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        answerStack.axis = .vertical
        answerStack.spacing = 10
        answerStack.addArrangedSubview(answerLabel)
        answerStack.addArrangedSubview(detailLabel)
        answerStack.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.text = "Tryck på kortet för att se svaret"
        hintLabel.font = .systemFont(ofSize: 15)
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 2
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        answerArea.addSubview(answerStack)
        answerArea.addSubview(hintLabel)

        let content = UIStackView(arrangedSubviews: [wordLabel, kindLabel, sentenceLabel, sourceLabel, rule, answerArea])
        content.axis = .vertical
        content.spacing = 6
        content.setCustomSpacing(20, after: kindLabel)
        content.setCustomSpacing(10, after: sentenceLabel)
        content.setCustomSpacing(20, after: sourceLabel)
        content.setCustomSpacing(20, after: rule)
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)

        showButton.addAction(UIAction { [weak self] _ in self?.reveal() }, for: .touchUpInside)
        gradeStack.axis = .horizontal
        gradeStack.spacing = 10
        gradeStack.distribution = .fillEqually
        for grade in ReviewGrade.allCases {
            let button = UIButton(type: .system)
            button.addAction(UIAction { [weak self] _ in self?.grade(grade) }, for: .touchUpInside)
            gradeButtons[grade] = button
            gradeStack.addArrangedSubview(button)
        }

        doneLabel.numberOfLines = 0
        doneLabel.textAlignment = .center
        doneLabel.isHidden = true

        for subview in [filterButton, countLabel, progressTrack, card, showButton, gradeStack, doneLabel] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }

        // En spalt i mitten, högst 560 punkter bred. Kortet ligger mitt i ytan mellan framstegslinjen och
        // betygen, och knapparna längst ner där tummarna når.
        let column = UILayoutGuide()
        let space = UILayoutGuide()
        view.addLayoutGuide(column)
        view.addLayoutGuide(space)
        let safe = view.safeAreaLayoutGuide
        let preferredWidth = column.widthAnchor.constraint(equalToConstant: 560)
        preferredWidth.priority = .defaultHigh
        let centered = card.centerYAnchor.constraint(equalTo: space.centerYAnchor)
        centered.priority = .defaultHigh
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: safe.topAnchor),
            column.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            column.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
            column.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor),
            preferredWidth,

            filterButton.topAnchor.constraint(equalTo: column.topAnchor, constant: 12),
            filterButton.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            filterButton.heightAnchor.constraint(equalToConstant: 34),
            filterButton.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -12),
            countLabel.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            countLabel.centerYAnchor.constraint(equalTo: filterButton.centerYAnchor),
            progressTrack.topAnchor.constraint(equalTo: filterButton.bottomAnchor, constant: 12),
            progressTrack.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            progressTrack.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            progressTrack.heightAnchor.constraint(equalToConstant: 4),

            gradeStack.bottomAnchor.constraint(equalTo: column.bottomAnchor, constant: -16),
            gradeStack.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            gradeStack.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            gradeStack.heightAnchor.constraint(equalToConstant: 64),
            showButton.topAnchor.constraint(equalTo: gradeStack.topAnchor),
            showButton.bottomAnchor.constraint(equalTo: gradeStack.bottomAnchor),
            showButton.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            showButton.trailingAnchor.constraint(equalTo: column.trailingAnchor),

            space.topAnchor.constraint(equalTo: progressTrack.bottomAnchor),
            space.bottomAnchor.constraint(equalTo: gradeStack.topAnchor),
            space.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            space.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            card.topAnchor.constraint(greaterThanOrEqualTo: space.topAnchor, constant: 20),
            card.bottomAnchor.constraint(lessThanOrEqualTo: space.bottomAnchor, constant: -20),
            card.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            centered,
            doneLabel.centerYAnchor.constraint(equalTo: space.centerYAnchor),
            doneLabel.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 12),
            doneLabel.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -12),

            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 32),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -28),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
            rule.heightAnchor.constraint(equalToConstant: 1),
            answerStack.topAnchor.constraint(equalTo: answerArea.topAnchor),
            answerStack.bottomAnchor.constraint(equalTo: answerArea.bottomAnchor),
            answerStack.leadingAnchor.constraint(equalTo: answerArea.leadingAnchor),
            answerStack.trailingAnchor.constraint(equalTo: answerArea.trailingAnchor),
            answerArea.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            hintLabel.centerYAnchor.constraint(equalTo: answerArea.centerYAnchor),
            hintLabel.leadingAnchor.constraint(equalTo: answerArea.leadingAnchor),
            hintLabel.trailingAnchor.constraint(equalTo: answerArea.trailingAnchor),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: Theme.didChange, object: nil)
        loadQueue()
        applyTheme()
        show()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutProgress()
        card.layer.shadowPath = UIBezierPath(roundedRect: card.bounds, cornerRadius: 20).cgPath
    }

    // MARK: Självtestet

    /// Självtestet: visar bara det här ordet, med svaret framme.
    func showOnlyForTest(_ word: SavedWord) {
        queue = [ReviewCard(word: word, interval: 0, ease: 2.5, reps: 0, lapses: 0, isNew: true)]
        index = 0
        show()
        reveal()
    }

    /// Används av självtestet.
    var currentWord: String? {
        index < queue.count ? queue[index].word.lemma : nil
    }

    var remaining: Int {
        max(0, queue.count - index)
    }

    /// Självtestet: filtrets titel, intervallen under betygen och texten till höger om filtret.
    var summaryForTest: String {
        let grades = ReviewGrade.allCases.map { "\($0.title) \(gradeDays[$0].map(ReviewSchedule.label(days:)) ?? "")" }
        return "filter \(filterTitle), \(countLabel.text ?? ""), \(grades.joined(separator: ", "))"
    }

    /// Självtestet: valen i filtret.
    var filterChoicesForTest: [String] {
        ["Alla ord"] + books.map { "bok " + $0.title } + courses.map { "kurs " + $0.name }
    }

    // MARK: Filtret

    /// Böckerna och kurserna som har sparade ord. Ett sparat filter för en bok eller kurs utan ord visar alla.
    private func loadQueue() {
        let words = UserWords.shared.savedWords()
            .filter { !ReviewStopWords.contains(word: $0.word, language: $0.language) }
        let wordBooks = Set(words.map(\.bookID).filter { !$0.isEmpty })
        let records = BookRegistry.shared.records()
        let titles = Dictionary(records.map { ($0.id, $0.displayTitle) }, uniquingKeysWith: { first, _ in first })
        books = wordBooks.map { id in
            (id: id, title: titles[id] ?? words.first(where: { $0.bookID == id })?.book ?? "Bok")
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let paths = records.map { (id: $0.id, path: $0.file) }
        let allCourses = CourseStore.shared.courses()
        let explicit = CourseStore.shared.membership()
        courses = allCourses.filter { course in
            let inCourse = ReviewLogic.books(for: .course(course.id), records: paths, courses: allCourses,
                                             explicit: explicit) ?? []
            return !inCourse.isDisjoint(with: wordBooks)
        }
        switch filter {
        case .book(let id) where !books.contains(where: { $0.id == id }):
            filter = .all
        case .course(let id) where !courses.contains(where: { $0.id == id }):
            filter = .all
        default:
            break
        }
        let chosen = ReviewLogic.books(for: filter, records: paths, courses: allCourses, explicit: explicit)
        queue = UserWords.shared.reviewQueue(books: chosen)
        index = 0
        updateFilterMenu()
    }

    private var filterTitle: String {
        switch filter {
        case .all: return "Alla ord"
        case .book(let id): return books.first { $0.id == id }?.title ?? "Boken"
        case .course(let id): return courses.first { $0.id == id }?.name ?? "Kursen"
        }
    }

    /// Visar ord ur en bok, en kurs eller alla. Valet sparas till nästa gång.
    func setFilter(_ filter: ReviewFilter) {
        guard filter != self.filter else { return }
        self.filter = filter
        UserDefaults.standard.set(filter.storage, forKey: Self.filterKey)
        reviewed = 0
        loadQueue()
        applyFilterButtonStyle()
        show(animated: true)
    }

    private func updateFilterMenu() {
        let all = UIAction(title: "Alla ord", image: UIImage(systemName: "rectangle.stack"),
                           state: filter == .all ? .on : .off) { [weak self] _ in
            self?.setFilter(.all)
        }
        var children: [UIMenuElement] = [all]
        if !books.isEmpty {
            children.append(UIMenu(title: "Böcker", options: .displayInline, children: books.map { book in
                UIAction(title: book.title, image: UIImage(systemName: "book"),
                         state: filter == .book(book.id) ? .on : .off) { [weak self] _ in
                    self?.setFilter(.book(book.id))
                }
            }))
        }
        if !courses.isEmpty {
            children.append(UIMenu(title: "Kurser", options: .displayInline, children: courses.map { course in
                UIAction(title: course.name, image: UIImage(systemName: "graduationcap"),
                         state: filter == .course(course.id) ? .on : .off) { [weak self] _ in
                    self?.setFilter(.course(course.id))
                }
            }))
        }
        filterButton.menu = UIMenu(title: "Visa ord ur", children: children)
        filterButton.accessibilityLabel = "Filter, \(filterTitle)"
    }

    // MARK: Temat (U1)

    @objc private func themeChanged() {
        applyTheme()
    }

    private func applyTheme() {
        guard isViewLoaded else { return }
        let palette = Theme.current
        view.backgroundColor = palette.canvas
        countLabel.textColor = palette.inkSoft
        progressTrack.backgroundColor = palette.rule
        progressFill.backgroundColor = palette.accent
        card.backgroundColor = palette.surface
        card.layer.borderColor = palette.rule.cgColor
        card.layer.shadowColor = palette.ink.cgColor
        wordLabel.font = Theme.serif(.largeTitle, size: 44, weight: .semibold)
        wordLabel.textColor = palette.ink
        kindLabel.textColor = palette.inkSoft
        sourceLabel.textColor = palette.inkFaint
        rule.backgroundColor = palette.rule
        answerLabel.textColor = palette.ink
        detailLabel.textColor = palette.inkSoft
        hintLabel.textColor = palette.inkFaint
        doneLabel.font = Theme.serif(.title2, size: 22)
        doneLabel.textColor = palette.inkSoft

        var showStyle = UIButton.Configuration.filled()
        showStyle.attributedTitle = AttributedString("Visa svaret", attributes: AttributeContainer(
            [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 17, weight: .semibold)]))
        showStyle.baseBackgroundColor = palette.accent
        showStyle.baseForegroundColor = palette.surface
        showStyle.cornerStyle = .fixed
        showStyle.background.cornerRadius = 14
        showButton.configuration = showStyle
        applyFilterButtonStyle()
        if index < queue.count {
            let word = queue[index].word
            sentenceLabel.attributedText = Self.sentence(word.sentence, highlighting: word.word, palette: palette)
        }
        styleGradeButtons()
    }

    private func applyFilterButtonStyle() {
        let palette = Theme.current
        var configuration = UIButton.Configuration.plain()
        configuration.attributedTitle = AttributedString(filterTitle, attributes: AttributeContainer(
            [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 15, weight: .semibold)]))
        configuration.image = UIImage(systemName: "chevron.down",
                                      withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        configuration.imagePlacement = .trailing
        configuration.imagePadding = 6
        configuration.baseForegroundColor = palette.ink
        configuration.background.backgroundColor = palette.surfaceSunk
        configuration.cornerStyle = .fixed
        configuration.background.cornerRadius = 17
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 12)
        configuration.titleLineBreakMode = .byTruncatingTail
        filterButton.configuration = configuration
    }

    /// Färgen för varje betyg ur temat: Igen som bandet, Svårt som varningen, Bra som klart och Lätt som accenten.
    private static func color(for grade: ReviewGrade, palette: Palette) -> UIColor {
        switch grade {
        case .again: return palette.ribbon
        case .hard: return palette.warning
        case .good: return palette.success
        case .easy: return palette.accent
        }
    }

    private func styleGradeButtons() {
        let palette = Theme.current
        for grade in ReviewGrade.allCases {
            let color = Self.color(for: grade, palette: palette)
            var configuration = UIButton.Configuration.plain()
            configuration.attributedTitle = AttributedString(grade.title, attributes: AttributeContainer(
                [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 17, weight: .semibold)]))
            if let days = gradeDays[grade] {
                configuration.attributedSubtitle = AttributedString(ReviewSchedule.label(days: days),
                    attributes: AttributeContainer(
                        [NSAttributedString.Key.font: UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)]))
            }
            configuration.titleAlignment = .center
            configuration.titlePadding = 3
            configuration.baseForegroundColor = color
            configuration.background.backgroundColor = color.withAlphaComponent(palette.isDark ? 0.24 : 0.14)
            configuration.cornerStyle = .fixed
            configuration.background.cornerRadius = 14
            gradeButtons[grade]?.configuration = configuration
            gradeButtons[grade]?.accessibilityLabel = grade.title
            gradeButtons[grade]?.accessibilityValue = gradeDays[grade].map { "igen om " + ReviewSchedule.label(days: $0) }
        }
    }

    // MARK: Korten

    /// Andelen av omgången som är klar, i linjen överst.
    private var progress: CGFloat {
        let total = reviewed + remaining
        return total == 0 ? (reviewed > 0 ? 1 : 0) : CGFloat(reviewed) / CGFloat(total)
    }

    private func layoutProgress() {
        let width = progressTrack.bounds.width * progress
        progressFill.frame = CGRect(x: 0, y: 0, width: width, height: progressTrack.bounds.height)
    }

    private func updateProgress(animated: Bool) {
        countLabel.text = ReviewLogic.remainingText(remaining)
        countLabel.isHidden = queue.isEmpty && reviewed == 0
        if animated {
            UIView.animate(withDuration: 0.25) { self.layoutProgress() }
        } else {
            layoutProgress()
        }
    }

    private func show(animated: Bool = false) {
        revealed = false
        updateProgress(animated: animated)
        guard index < queue.count else {
            showDone()
            return
        }
        let current = queue[index]
        let word = current.word
        let palette = Theme.current
        card.isHidden = false
        doneLabel.isHidden = true
        showButton.isHidden = false
        gradeStack.isHidden = true
        for grade in ReviewGrade.allCases {
            gradeDays[grade] = ReviewSchedule.next(grade, interval: current.interval, ease: current.ease,
                                                   reps: current.reps).interval
        }
        styleGradeButtons()
        let fill = { [self] in
            wordLabel.text = word.lemma
            kindLabel.text = (word.language == .english ? "engelska" : "svenska") + (current.isNew ? ", nytt ord" : "")
            sentenceLabel.attributedText = Self.sentence(word.sentence, highlighting: word.word, palette: palette)
            sentenceLabel.isHidden = word.sentence.isEmpty || word.sentence == word.word
            sourceLabel.text = Self.source(for: word)
            sourceLabel.isHidden = sourceLabel.text?.isEmpty ?? true
            let lines = ReviewAnswers.shownLines(for: word)
            answerLabel.text = lines.first ?? ReviewAnswers.missing
            detailLabel.text = lines.dropFirst().joined(separator: "\n")
            detailLabel.isHidden = lines.count < 2
            answerStack.alpha = 0
            hintLabel.alpha = 1
        }
        if animated && !UIAccessibility.isReduceMotionEnabled {
            UIView.transition(with: card, duration: 0.22, options: [.transitionCrossDissolve, .allowUserInteraction],
                              animations: fill)
        } else {
            fill()
        }
        UIAccessibility.post(notification: .screenChanged, argument: wordLabel)
    }

    private func showDone() {
        card.isHidden = true
        showButton.isHidden = true
        gradeStack.isHidden = true
        doneLabel.isHidden = false
        if reviewed > 0 {
            doneLabel.text = "Klart för i dag.\nDu repeterade \(reviewed) ord."
        } else if filter == .all {
            doneLabel.text = "Inga ord att repetera just nu.\nOrd du slår upp i böckerna hamnar här."
        } else {
            doneLabel.text = "Inga ord att repetera i \(filterTitle) just nu.\nVälj Alla ord i filtret överst."
        }
    }

    @objc private func cardTapped() {
        reveal()
    }

    func reveal() {
        guard index < queue.count, !revealed else { return }
        revealed = true
        showButton.isHidden = true
        gradeStack.isHidden = false
        let animations = {
            self.answerStack.alpha = 1
            self.hintLabel.alpha = 0
        }
        if UIAccessibility.isReduceMotionEnabled {
            animations()
        } else {
            UIView.animate(withDuration: 0.25, delay: 0, options: [.allowUserInteraction], animations: animations)
        }
        UIAccessibility.post(notification: .layoutChanged, argument: answerLabel)
    }

    func grade(_ grade: ReviewGrade) {
        guard index < queue.count, revealed else { return }
        let card = queue[index]
        UserWords.shared.record(grade, for: card)
        reviewed += 1
        if grade == .again {
            // Ordet kommer igen i slutet av omgången.
            queue.append(ReviewCard(word: card.word, interval: 10.0 / 1440.0, ease: max(1.3, card.ease - 0.2),
                                    reps: 0, lapses: card.lapses + 1, isNew: false))
        }
        index += 1
        Haptics.shared.wordTapped()
        show(animated: true)
    }

    /// Svaret ur ordboken som en text, till självtestet.
    static func answer(for word: SavedWord) -> String {
        let lines = ReviewAnswers.shownLines(for: word)
        return lines.isEmpty ? ReviewAnswers.missing : lines.joined(separator: "\n\n")
    }

    /// Källan under meningen: bokens titel i biblioteket och sidan, "Retorikens grunder, s. 88".
    private static func source(for word: SavedWord) -> String {
        let title = word.bookID.isEmpty ? word.book : (BookRegistry.shared.record(id: word.bookID)?.displayTitle ?? word.book)
        guard !title.isEmpty else { return "" }
        return "\(title), s. \(word.pageIndex + 1)"
    }

    /// Meningen i New York kursiv, med ordet i bläck och understruket.
    private static func sentence(_ text: String, highlighting word: String, palette: Palette) -> NSAttributedString {
        let font = Theme.serif(.title3, size: 19).withSymbolicTraits(.traitItalic)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 3
        paragraph.lineBreakMode = .byTruncatingTail
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: palette.inkSoft,
                                                                          .paragraphStyle: paragraph])
        let range = (text as NSString).range(of: word, options: [.caseInsensitive])
        if range.location != NSNotFound {
            result.addAttributes([.foregroundColor: palette.ink,
                                  .underlineStyle: NSUnderlineStyle.thick.rawValue,
                                  .underlineColor: palette.accent], range: range)
        }
        return result
    }
}
