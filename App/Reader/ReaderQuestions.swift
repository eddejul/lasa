import UIKit
import UniformTypeIdentifiers

/// En prick i marginalen (K6), som bladen ritar. `anchorY` är höjden i bladets koordinater.
struct QuestionDotPlacement {
    let id: String
    let number: Int
    let status: QuestionStatus?
    let anchorY: CGFloat
}

/// Var prickarna står (K6). Ren logik (G13): i den yttre marginalen när den rymmer pricken, annars precis
/// innanför textens eller sidans kant, och utspridda så att de inte ligger på varandra.
enum QuestionDotLayout {

    static let size: CGFloat = 22
    static let smallSize: CGFloat = 18

    /// Prickens mitt i sidled. `contentMinX` och `contentMaxX` är sidans (PDF) eller textens (EPUB) kanter i
    /// bladet, `width` bladets bredd. Den yttre marginalen är till vänster på vänstersidan i ett uppslag,
    /// annars till höger.
    static func centerX(contentMinX: CGFloat, contentMaxX: CGFloat, width: CGFloat, outerIsLeft: Bool) -> (x: CGFloat, size: CGFloat) {
        let margin = outerIsLeft ? contentMinX : width - contentMaxX
        if margin >= size + 8 {
            let inset = min(margin / 2, size)
            return (outerIsLeft ? contentMinX - inset : contentMaxX + inset, size)
        }
        // Smal marginal: en mindre prick så långt ut som det går, delvis över sidans egen kant.
        let half = smallSize / 2 + 2
        return (outerIsLeft ? half : width - half, smallSize)
    }

    /// Höjderna, i samma ordning, utspridda med minst `gap` mellan sig och inom `top` och `bottom`.
    static func spread(_ ys: [CGFloat], gap: CGFloat, top: CGFloat, bottom: CGFloat) -> [CGFloat] {
        guard !ys.isEmpty else { return [] }
        let order = ys.indices.sorted { ys[$0] < ys[$1] }
        var placed = [CGFloat](repeating: 0, count: ys.count)
        var previous = -CGFloat.greatestFiniteMagnitude
        for index in order {
            let y = max(min(max(ys[index], top), bottom), previous + gap)
            placed[index] = y
            previous = y
        }
        // Gick de sista förbi nederkanten: skjut upp dem igen.
        var next = CGFloat.greatestFiniteMagnitude
        for index in order.reversed() {
            let y = min(placed[index], bottom, next - gap)
            placed[index] = y
            next = y
        }
        return placed
    }
}

/// Pricken: en liten numrerad cirkel i temats färger. Obesvarad har en ring, besvarad fylls i svarets färg.
final class QuestionDotView: UIView {

    let id: String
    private let label = UILabel()

    init(placement: QuestionDotPlacement, size: CGFloat) {
        id = placement.id
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
        isUserInteractionEnabled = false
        let palette = Theme.current
        layer.cornerRadius = size / 2
        label.text = String(placement.number)
        label.font = .systemFont(ofSize: size * 0.5, weight: .semibold)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        label.frame = bounds.insetBy(dx: 2, dy: 2)
        addSubview(label)
        switch placement.status {
        case nil:
            backgroundColor = palette.page
            layer.borderWidth = 1.5
            layer.borderColor = palette.accent.cgColor
            label.textColor = palette.accent
        case .known?:
            backgroundColor = palette.success
            label.textColor = palette.page
        case .unsure?:
            backgroundColor = palette.warning
            label.textColor = palette.page
        case .unknown?:
            backgroundColor = palette.ribbon
            label.textColor = palette.page
        }
        isAccessibilityElement = true
        accessibilityLabel = "Fråga \(placement.number)" + (placement.status.map { ", \($0.title)" } ?? "")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    /// Lägger prickarna i `host` och svarar med deras rutor per fråga (till tryck och rutans pil).
    static func layout(_ placements: [QuestionDotPlacement], in host: UIView, contentMinX: CGFloat, contentMaxX: CGFloat,
                       top: CGFloat, bottom: CGFloat, outerIsLeft: Bool) -> [String: CGRect] {
        guard !placements.isEmpty else { return [:] }
        let column = QuestionDotLayout.centerX(contentMinX: contentMinX, contentMaxX: contentMaxX,
                                               width: host.bounds.width, outerIsLeft: outerIsLeft)
        let half = column.size / 2
        let ys = QuestionDotLayout.spread(placements.map(\.anchorY), gap: column.size + 4,
                                          top: top + half, bottom: max(top + half, bottom - half))
        var frames: [String: CGRect] = [:]
        for (placement, y) in zip(placements, ys) {
            let dot = QuestionDotView(placement: placement, size: column.size)
            dot.center = CGPoint(x: column.x, y: y)
            host.addSubview(dot)
            frames[placement.id] = dot.frame
        }
        return frames
    }
}

/// Bokens frågor i läsaren (K6), gemensamt för PDF- och EPUB-läsaren (G12): frågefilen, var citaten står,
/// svaren, rutan med frågan och fliken Frågor i Innehåll. Bara från huvudtråden.
@MainActor
final class ReaderQuestions {

    /// EPUB: citatens span i webbvyn får id `fraga:` plus frågans id, och textens kolumn ett eget id.
    static let markPrefix = "fraga:"
    static let textColumnID = "fraga-kolumn"

    let book: Book
    let bookKey: String
    private(set) var questions: [BookQuestion] = []
    private(set) var places: [String: QuestionPlace] = [:]
    private(set) var statuses: [String: QuestionStatus] = [:]
    private(set) var fileURL: URL?
    private(set) var problem: String?
    /// Sant när citaten har letats upp (eller när det inte finns någon fil).
    private(set) var isLocated = false
    /// Anropas när frågorna eller svaren har ändrats, så att läsaren ritar om prickarna.
    var onChange: (() -> Void)?
    private var task: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init(book: Book, bookKey: String) {
        self.book = book
        self.bookKey = bookKey
        statuses = QuestionStore.shared.statuses(book: bookKey)
        observers.append(NotificationCenter.default.addObserver(forName: QuestionStore.didChange, object: nil,
                                                                queue: .main) { [weak self] note in
            let book = note.object as? String
            Task { @MainActor [weak self] in
                guard let self = self, book == self.bookKey else { return }
                self.statuses = QuestionStore.shared.statuses(book: self.bookKey)
                self.onChange?()
            }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        task?.cancel()
    }

    /// Prickarna syns: inställningen är på och boken har frågor.
    var showsDots: Bool {
        QuestionsSetting.isEnabled && !questions.isEmpty
    }

    /// Läser frågefilen och letar upp citaten i bakgrunden. `chapterTitles` är kapitlens rubriker (EPUB och
    /// text), tomt för PDF.
    func load(search: BookSearch, chapterTitles: [String], sectionCount: Int) {
        task?.cancel()
        isLocated = false
        problem = nil
        fileURL = BookQuestionFile.url(for: book)
        guard let url = fileURL else {
            questions = []
            places = [:]
            isLocated = true
            onChange?()
            return
        }
        do {
            questions = try BookQuestionFile.parse(Data(contentsOf: url))
        } catch {
            questions = []
            problem = "Frågefilen kunde inte läsas: \(error)"
            AppLog.shared.write("Frågor (K6): \(url.lastPathComponent) kunde inte läsas: \(error)")
        }
        let list = questions
        let hints = list.map { BookQuestionFile.hint(for: $0, chapterTitles: chapterTitles, sectionCount: sectionCount) }
        let isPDF = chapterTitles.isEmpty
        guard !list.isEmpty else {
            places = [:]
            isLocated = true
            onChange?()
            return
        }
        task = Task { @MainActor [weak self] in
            let started = CACurrentMediaTime()
            let hits = await search.locate(list.map(\.quote), hints: hints)
            guard let self = self, !Task.isCancelled else { return }
            var found: [String: QuestionPlace] = [:]
            for (index, question) in list.enumerated() {
                if index < hits.count, let hit = hits[index] {
                    found[question.id] = QuestionPlace(section: hit.section, start: hit.start, length: hit.length,
                                                       y: question.y)
                } else if isPDF, let page = hints[index] {
                    // En fotad sida utan text: pricken står på sidan, på höjden `y`.
                    found[question.id] = QuestionPlace(section: page, start: 0, length: 0, y: question.y ?? 0.08)
                }
            }
            self.places = found
            self.isLocated = true
            AppLog.shared.write("Frågor (K6): \(found.count) av \(list.count) placerade på "
                                + "\(Int((CACurrentMediaTime() - started) * 1000)) ms")
            self.onChange?()
        }
    }

    func question(id: String) -> BookQuestion? {
        questions.first { $0.id == id }
    }

    func place(of id: String) -> QuestionPlace? {
        places[id]
    }

    /// Frågorna i ett avsnitt (en PDF-sida eller ett kapitel), i textens ordning.
    func questions(inSection section: Int) -> [BookQuestion] {
        questions.filter { places[$0.id]?.section == section }
            .sorted { (places[$0.id]?.start ?? 0, $0.number) < (places[$1.id]?.start ?? 0, $1.number) }
    }

    /// Avsnitten där frågor står, till K7 (kapitlets frågor i testet).
    func sections() -> Set<Int> {
        Set(places.values.map(\.section))
    }

    func setStatus(_ status: QuestionStatus, for id: String) {
        statuses[id] = status
        QuestionStore.shared.setStatus(status, question: id, book: bookKey)
    }

    /// Prickens nummer och svaret, till bladen. Nil när prickarna inte ska synas.
    func info(for id: String) -> (number: Int, status: QuestionStatus?)? {
        guard showsDots, let question = question(id: id) else { return nil }
        return (question.number, statuses[id])
    }

    /// EPUB och text: citaten i ett kapitel som markeringar utan färg, så att webbvyn ger deras rutor.
    func markArguments(forChapter chapter: Int) -> [[String: Any]] {
        guard showsDots else { return [] }
        return questions(inSection: chapter).compactMap { question in
            guard let place = places[question.id], place.length > 0 else { return nil }
            return ["id": Self.markPrefix + question.id, "start": place.start, "length": place.length,
                    "text": question.quote, "color": "fraga", "note": false]
        }
    }

    // MARK: Rutan med frågan

    /// Visar frågan vid pricken. Svaret ligger bakom ett tryck, och Kan, Osäker och Kan inte sparar hur det gick.
    func presentCard(for id: String, from presenter: UIViewController, sourceView: UIView, sourceRect: CGRect) {
        guard presenter.presentedViewController == nil, let question = question(id: id) else { return }
        let card = QuestionCardViewController(question: question, status: statuses[id]) { [weak self] status in
            self?.setStatus(status, for: id)
        }
        let navigation = UINavigationController(rootViewController: card)
        if presenter.traitCollection.horizontalSizeClass == .regular {
            navigation.modalPresentationStyle = .popover
            navigation.popoverPresentationController?.sourceView = sourceView
            navigation.popoverPresentationController?.sourceRect = sourceRect
            navigation.popoverPresentationController?.permittedArrowDirections = [.left, .right, .up, .down]
            navigation.popoverPresentationController?.backgroundColor = Theme.current.surface
        } else {
            navigation.modalPresentationStyle = .pageSheet
            if let sheet = navigation.sheetPresentationController {
                sheet.detents = [.medium(), .large()]
            }
        }
        presenter.present(navigation, animated: true)
    }

    // MARK: Fliken Frågor

    /// Fliken Frågor i Innehåll. `placeLabel` ger stället (sida eller kapitel), `onSelect` hoppar dit.
    func makeList(placeLabel: @escaping (QuestionPlace) -> String,
                  onSelect: @escaping (BookQuestion, QuestionPlace) -> Void) -> QuestionListViewController {
        let list = QuestionListViewController(questions: self, placeLabel: placeLabel)
        list.onSelect = onSelect
        return list
    }
}

/// Rutan med en fråga (K6): numret och rubriken, frågan, Visa svaret och Kan, Osäker och Kan inte.
final class QuestionCardViewController: UIViewController {

    private let question: BookQuestion
    private var status: QuestionStatus?
    private let onStatus: (QuestionStatus) -> Void
    private let stack = UIStackView()
    private let answerLabel = UILabel()
    private let showButton = UIButton(type: .system)
    private var statusButtons: [QuestionStatus: UIButton] = [:]

    init(question: BookQuestion, status: QuestionStatus?, onStatus: @escaping (QuestionStatus) -> Void) {
        self.question = question
        self.status = status
        self.onStatus = onStatus
        super.init(nibName: nil, bundle: nil)
        title = "Fråga \(question.number)"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    /// Självtestet: om svaret syns.
    var showsAnswer: Bool {
        !answerLabel.isHidden
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let palette = Theme.current
        view.backgroundColor = palette.surface
        view.tintColor = palette.accent
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Klar", style: .done, target: self,
                                                            action: #selector(close))
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20),
        ])

        if !question.title.isEmpty {
            let title = UILabel()
            title.text = question.title
            title.font = Theme.serif(.title3, weight: .semibold)
            title.textColor = palette.ink
            title.numberOfLines = 0
            stack.addArrangedSubview(title)
        }
        let text = UILabel()
        text.text = question.question
        text.font = Theme.serif(.body, size: 19)
        text.textColor = palette.ink
        text.numberOfLines = 0
        stack.addArrangedSubview(text)

        let quote = UILabel()
        quote.text = question.quote.isEmpty ? nil : "\u{201D}\(question.quote)\u{201D}"
        quote.font = Theme.serif(.footnote).withSymbolicTraits(.traitItalic)
        quote.textColor = palette.inkSoft
        quote.numberOfLines = 3
        quote.isHidden = question.quote.isEmpty
        stack.addArrangedSubview(quote)

        var showConfiguration = UIButton.Configuration.tinted()
        showConfiguration.title = question.answer.isEmpty ? "Inget svar i filen" : "Visa svaret"
        showConfiguration.cornerStyle = .large
        showButton.configuration = showConfiguration
        showButton.isEnabled = !question.answer.isEmpty
        showButton.addAction(UIAction { [weak self] _ in self?.revealAnswer() }, for: .touchUpInside)
        stack.addArrangedSubview(showButton)

        answerLabel.text = question.answer.count == 1
            ? question.answer[0]
            : question.answer.map { "\u{2022} " + $0 }.joined(separator: "\n")
        answerLabel.font = .preferredFont(forTextStyle: .body)
        answerLabel.adjustsFontForContentSizeCategory = true
        answerLabel.textColor = palette.ink
        answerLabel.numberOfLines = 0
        answerLabel.isHidden = true
        stack.addArrangedSubview(answerLabel)

        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 8
        row.distribution = .fillEqually
        let colors: [QuestionStatus: UIColor] = [.unknown: palette.ribbon, .unsure: palette.warning, .known: palette.success]
        for option in QuestionStatus.allCases {
            var configuration = UIButton.Configuration.tinted()
            configuration.title = option.title
            configuration.baseForegroundColor = colors[option]
            configuration.baseBackgroundColor = colors[option]
            configuration.cornerStyle = .large
            let button = UIButton(configuration: configuration)
            button.addAction(UIAction { [weak self] _ in self?.choose(option) }, for: .touchUpInside)
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            statusButtons[option] = button
            row.addArrangedSubview(button)
        }
        stack.addArrangedSubview(row)
        updateStatusButtons()

        let width: CGFloat = 380
        let fitting = stack.systemLayoutSizeFitting(CGSize(width: width - 40, height: 0),
                                                    withHorizontalFittingPriority: .required,
                                                    verticalFittingPriority: .fittingSizeLevel)
        preferredContentSize = CGSize(width: width, height: min(ceil(fitting.height) + 36 + 140, 620))
    }

    func revealAnswer() {
        guard answerLabel.isHidden, !question.answer.isEmpty else { return }
        answerLabel.alpha = 0
        answerLabel.isHidden = false
        showButton.isHidden = true
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.25) {
            self.answerLabel.alpha = 1
        }
    }

    func choose(_ option: QuestionStatus) {
        status = option
        updateStatusButtons()
        onStatus(option)
        Haptics.shared.wordTapped()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self = self, !SelfTest.isActive else { return }
            self.dismiss(animated: true)
        }
    }

    private func updateStatusButtons() {
        for (option, button) in statusButtons {
            var configuration = button.configuration
            let chosen = option == status
            configuration?.image = chosen ? UIImage(systemName: "checkmark") : nil
            configuration?.imagePadding = 4
            button.configuration = configuration
            button.accessibilityTraits = chosen ? [.button, .selected] : .button
        }
    }

    @objc private func close() {
        dismiss(animated: true)
    }
}

/// Fliken Frågor i Innehåll (K6): bokens frågor i ordning med stället och svaret. Utan frågefil visas hur
/// en läggs till, och Välj frågefil lägger en vald fil bredvid boken.
final class QuestionListViewController: UITableViewController, UIDocumentPickerDelegate {

    var onSelect: ((BookQuestion, QuestionPlace) -> Void)?
    private let questions: ReaderQuestions
    private let placeLabel: (QuestionPlace) -> String
    private static let cellID = "question"

    init(questions: ReaderQuestions, placeLabel: @escaping (QuestionPlace) -> String) {
        self.questions = questions
        self.placeLabel = placeLabel
        super.init(style: .plain)
        title = "Frågor"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    /// Självtestet: antalet rader.
    var count: Int {
        questions.questions.count
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.cellID)
        updateEmptyState()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
        updateEmptyState()
    }

    private func updateEmptyState() {
        guard questions.questions.isEmpty else {
            tableView.backgroundView = nil
            tableView.separatorStyle = .singleLine
            return
        }
        let name = BookQuestionFile.target(for: questions.book).lastPathComponent
        let label = UILabel()
        label.text = (questions.problem.map { $0 + "\n\n" } ?? "")
            + "Boken har inga frågor än. Lägg en fil som heter \(name) i samma mapp som boken (Filer, På min iPad, "
            + "Sensus, Böcker), eller välj en frågefil nedan."
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .body)
        var configuration = UIButton.Configuration.tinted()
        configuration.title = "Välj frågefil"
        configuration.cornerStyle = .large
        let button = UIButton(configuration: configuration)
        button.addAction(UIAction { [weak self] _ in self?.chooseFile() }, for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [label, button])
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        let background = UIView()
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -28),
        ])
        tableView.backgroundView = background
        tableView.separatorStyle = .none
    }

    private func chooseFile() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json], asCopy: true)
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let target = BookQuestionFile.target(for: questions.book)
        do {
            let data = try Data(contentsOf: url)
            let parsed = try BookQuestionFile.parse(data)
            guard !parsed.isEmpty else {
                throw BookQuestionFile.Failure(description: "Filen har inga frågor med citat eller sida")
            }
            try data.write(to: target, options: .atomic)
            AppLog.shared.write("Frågor (K6): frågefil vald, \(parsed.count) frågor")
            questions.onChange?()
            NotificationCenter.default.post(name: QuestionsSetting.didChange, object: nil)
        } catch {
            let alert = UIAlertController(title: "Frågefilen kunde inte användas", message: "\(error)",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        questions.questions.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellID, for: indexPath)
        let question = questions.questions[indexPath.row]
        var content = UIListContentConfiguration.subtitleCell()
        content.text = "\(question.number). " + (question.title.isEmpty ? question.question : question.title)
        content.textProperties.numberOfLines = 2
        var detail: [String] = []
        if let place = questions.place(of: question.id) {
            detail.append(placeLabel(place))
        } else if questions.isLocated {
            detail.append("Citatet hittades inte i boken")
        }
        if let status = questions.statuses[question.id] {
            detail.append(status.title)
        }
        content.secondaryText = detail.joined(separator: ", ")
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content
        cell.accessoryType = questions.place(of: question.id) == nil ? .none : .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let question = questions.questions[indexPath.row]
        guard let place = questions.place(of: question.id) else { return }
        onSelect?(question, place)
    }
}
