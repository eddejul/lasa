import UIKit

/// Rutan med en AI-fråga (K6b), också för frågefilens frågor med typ eller källa: typens namn, frågan, Ditt
/// svar, Visa svaret och Kan, Osäker och Kan inte. Varken platsen eller källan syns innan svaret visas. Efter
/// Visa svaret: punkterna, Ur boken med källan och Visa i boken. Jämför med mitt svar när det finns en nyckel
/// och något skrivet. Det skrivna svaret sparas när rutan stängs.
final class AIQuestionCardViewController: UIViewController, UITextViewDelegate {

    private let question: BookQuestion
    private let book: String
    private var status: QuestionStatus?
    private let onStatus: (QuestionStatus) -> Void
    private let onShowInBook: (BookQuestion) -> Void
    private let stack = UIStackView()
    private let textView = UITextView()
    private let placeholder = UILabel()
    private let compareButton = UIButton(type: .system)
    private let compareStatus = UILabel()
    private let feedbackStack = UIStackView()
    private let showButton = UIButton(type: .system)
    private let answerStack = UIStackView()
    private var statusButtons: [QuestionStatus: UIButton] = [:]
    private var savedAnswer = ""
    private var suggested: QuestionStatus?
    private var isComparing = false
    /// Självtestet: Jämförs senaste svar.
    private(set) var lastFeedback: [String: Any]?

    init(question: BookQuestion, status: QuestionStatus?, book: String, onStatus: @escaping (QuestionStatus) -> Void,
         onShowInBook: @escaping (BookQuestion) -> Void) {
        self.question = question
        self.status = status
        self.book = book
        self.onStatus = onStatus
        self.onShowInBook = onShowInBook
        super.init(nibName: nil, bundle: nil)
        title = question.timing == "fore" ? "Före läsningen" : question.timing == "slut" ? "Efter kapitlet" : "Fråga"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    /// Självtestet: om svaret syns och vad rutan visar.
    var showsAnswer: Bool {
        !answerStack.isHidden
    }

    var showsCompare: Bool {
        !compareButton.isHidden
    }

    var visibleText: String {
        var parts: [String] = []
        func collect(_ view: UIView) {
            guard !view.isHidden else { return }
            if let label = view as? UILabel, let text = label.text, !text.isEmpty {
                parts.append(text)
            } else if let button = view as? UIButton, let text = button.configuration?.title ?? button.title(for: .normal) {
                parts.append("[\(text)]")
            }
            view.subviews.forEach(collect)
        }
        collect(stack)
        return parts.joined(separator: " | ")
    }

    var suggestedStatus: QuestionStatus? {
        suggested
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
        scroll.keyboardDismissMode = .interactive
        view.addSubview(scroll)
        stack.axis = .vertical
        stack.spacing = 12
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

        let heading = makeLabel(question.heading, font: .systemFont(ofSize: 13, weight: .semibold), color: palette.inkSoft)
        stack.addArrangedSubview(heading)
        let text = makeLabel(question.question, font: Theme.serif(.body, size: 19), color: palette.ink)
        stack.addArrangedSubview(text)

        // Ditt svar: flera rader, går att diktera med tangentbordets mikrofon.
        let stored = QuestionStore.shared.myAnswer(question: question.id, book: book)
        savedAnswer = stored.text
        stack.addArrangedSubview(makeLabel("Ditt svar", font: .systemFont(ofSize: 15, weight: .semibold), color: palette.ink))
        textView.text = stored.text
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = palette.ink
        textView.backgroundColor = palette.page
        textView.layer.cornerRadius = 10
        textView.layer.borderWidth = 1
        textView.layer.borderColor = palette.rule.cgColor
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 6, bottom: 10, right: 6)
        textView.isScrollEnabled = false
        textView.delegate = self
        textView.accessibilityLabel = "Ditt svar"
        textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        placeholder.text = "Skriv eller diktera ditt svar"
        placeholder.font = .preferredFont(forTextStyle: .body)
        placeholder.textColor = palette.inkFaint
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        textView.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.topAnchor.constraint(equalTo: textView.topAnchor, constant: 10),
            placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 11),
        ])
        stack.addArrangedSubview(textView)

        var compareConfiguration = UIButton.Configuration.tinted()
        compareConfiguration.title = "Jämför med mitt svar"
        compareConfiguration.cornerStyle = .large
        compareButton.configuration = compareConfiguration
        compareButton.addAction(UIAction { [weak self] _ in self?.compare() }, for: .touchUpInside)
        stack.addArrangedSubview(compareButton)
        compareStatus.font = .preferredFont(forTextStyle: .footnote)
        compareStatus.textColor = palette.inkSoft
        compareStatus.numberOfLines = 0
        compareStatus.isHidden = true
        stack.addArrangedSubview(compareStatus)
        feedbackStack.axis = .vertical
        feedbackStack.spacing = 6
        feedbackStack.isHidden = true
        stack.addArrangedSubview(feedbackStack)

        var showConfiguration = UIButton.Configuration.tinted()
        showConfiguration.title = question.answer.isEmpty && question.source.isEmpty ? "Inget svar" : "Visa svaret"
        showConfiguration.cornerStyle = .large
        showButton.configuration = showConfiguration
        showButton.isEnabled = !(question.answer.isEmpty && question.source.isEmpty)
        showButton.addAction(UIAction { [weak self] _ in self?.revealAnswer() }, for: .touchUpInside)
        stack.addArrangedSubview(showButton)

        // Svaret: punkterna, Ur boken med källan och Visa i boken. Dolt tills Visa svaret.
        answerStack.axis = .vertical
        answerStack.spacing = 8
        answerStack.isHidden = true
        if !question.answer.isEmpty {
            // Egen rubrik, så att punkterna inte flyter ihop med Jämförs kommentar ovanför.
            answerStack.addArrangedSubview(makeLabel(question.isOpen ? "Boken säger:" : "Ett bra svar innehåller:",
                                                     font: .systemFont(ofSize: 13, weight: .semibold),
                                                     color: palette.inkSoft))
            let points = question.answer.count == 1 ? question.answer[0]
                : question.answer.map { "\u{2022} " + $0 }.joined(separator: "\n")
            answerStack.addArrangedSubview(makeLabel(points, font: .preferredFont(forTextStyle: .body), color: palette.ink))
        }
        if !question.source.isEmpty {
            answerStack.addArrangedSubview(makeLabel("Ur boken:", font: .systemFont(ofSize: 13, weight: .semibold),
                                                     color: palette.inkSoft))
            let quote = makeLabel(question.source, font: Theme.serif(.callout).withSymbolicTraits(.traitItalic),
                                  color: palette.inkSoft)
            answerStack.addArrangedSubview(quote)
            let show = UIButton(type: .system)
            var configuration = UIButton.Configuration.plain()
            configuration.title = "Visa i boken"
            configuration.image = UIImage(systemName: "arrow.turn.down.right")
            configuration.imagePadding = 6
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)
            show.configuration = configuration
            show.contentHorizontalAlignment = .leading
            show.addAction(UIAction { [weak self] _ in self?.showInBook() }, for: .touchUpInside)
            answerStack.addArrangedSubview(show)
        }
        stack.addArrangedSubview(answerStack)

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
        if question.isAI {
            stack.addArrangedSubview(makeLabel("Gjord med AI", font: .preferredFont(forTextStyle: .caption2),
                                               color: palette.inkFaint))
        }
        if let feedback = Self.decode(stored.feedback) {
            showFeedback(feedback)
        }
        updateStatusButtons()
        updateCompareButton()
        updateSize()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        saveAnswer()
    }

    private func makeLabel(_ text: String, font: UIFont, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = font
        label.textColor = color
        label.numberOfLines = 0
        return label
    }

    private func updateSize() {
        let width: CGFloat = 420
        let fitting = stack.systemLayoutSizeFitting(CGSize(width: width - 40, height: 0),
                                                    withHorizontalFittingPriority: .required,
                                                    verticalFittingPriority: .fittingSizeLevel)
        preferredContentSize = CGSize(width: width, height: min(ceil(fitting.height) + 36, 680))
    }

    func textViewDidChange(_ textView: UITextView) {
        updateCompareButton()
    }

    private func updateCompareButton() {
        let written = !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        placeholder.isHidden = !textView.text.isEmpty
        compareButton.isHidden = !(AIClient.hasKey && written)
        compareButton.isEnabled = !isComparing
    }

    /// Sparar det skrivna svaret när det har ändrats.
    func saveAnswer() {
        let text = textView.text ?? ""
        guard text != savedAnswer else { return }
        savedAnswer = text
        QuestionStore.shared.setMyAnswer(text, question: question.id, book: book)
    }

    /// Självtestet: skriver ett svar som om det dikterats.
    func setAnswerForSelfTest(_ text: String) {
        textView.text = text
        updateCompareButton()
        updateSize()
    }

    func revealAnswer() {
        guard answerStack.isHidden else { return }
        answerStack.alpha = 0
        answerStack.isHidden = false
        showButton.isHidden = true
        updateSize()
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.25) {
            self.answerStack.alpha = 1
        }
    }

    func choose(_ option: QuestionStatus) {
        status = option
        updateStatusButtons()
        saveAnswer()
        onStatus(option)
        Haptics.shared.wordTapped()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self = self, !SelfTest.isActive else { return }
            self.dismiss(animated: true)
        }
    }

    private func showInBook() {
        saveAnswer()
        onShowInBook(question)
    }

    private func updateStatusButtons() {
        for (option, button) in statusButtons {
            var configuration = button.configuration
            let chosen = option == status
            configuration?.image = chosen ? UIImage(systemName: "checkmark") : nil
            configuration?.imagePadding = 4
            // Jämförs förslag syns som en markerad knapp, men Edvin väljer själv.
            configuration?.subtitle = option == suggested && !chosen ? "Förslag" : nil
            configuration?.background.strokeWidth = option == suggested ? 2 : 0
            let stroke = configuration?.baseForegroundColor
            configuration?.background.strokeColor = stroke
            button.configuration = configuration
            button.accessibilityTraits = chosen ? [.button, .selected] : .button
            button.accessibilityHint = option == suggested ? "Förslaget efter jämförelsen" : nil
        }
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    // MARK: Jämför (K6b)

    /// Jämför med mitt svar: frågan, punkterna, källan och svaret skickas, aldrig kapitlets text.
    func compare() {
        let text = (textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isComparing else { return }
        saveAnswer()
        isComparing = true
        updateCompareButton()
        compareStatus.text = "Jämför med Gemini"
        compareStatus.isHidden = false
        let prompt = AIQuestions.comparePrompt(
            AIQuestions.CompareQuestion(question: question.question, answer: question.answer, source: question.source,
                                        isOpen: question.isOpen),
            myAnswer: text)
        AIClient.generate(kind: AIQuestions.compareKind, prompt: prompt, schema: AIQuestions.compareSchema,
                          maxTokens: AIQuestions.compareMaxTokens, timeout: AIQuestions.compareTimeout) { [weak self] result in
            guard let self = self else { return }
            self.isComparing = false
            switch result {
            case .success(let answer):
                self.compareStatus.isHidden = true
                self.showFeedback(answer.json)
                let json = (try? JSONSerialization.data(withJSONObject: answer.json, options: [.sortedKeys]))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                QuestionStore.shared.setFeedback(json, myAnswer: self.textView.text ?? "", question: self.question.id,
                                                 book: self.book)
                AppLog.shared.write("AI-frågor: Jämför, omdöme \(answer.json["omdome"] as? String ?? "inget")"
                                    + (answer.cached ? " (sparat svar)" : ""))
            case .failure(let failure):
                self.compareStatus.text = failure.errorDescription
                AppLog.shared.write("AI-frågor: Jämför gick inte, \(failure.errorDescription ?? "fel")")
            }
            self.updateCompareButton()
            self.updateSize()
        }
    }

    private static func decode(_ text: String) -> [String: Any]? {
        guard !text.isEmpty, let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json
    }

    /// Med (grön), Saknas (gul), Fel (röd) och kommentaren. En öppen fråga får bara kommentaren och Fel.
    private func showFeedback(_ json: [String: Any]) {
        lastFeedback = json
        let palette = Theme.current
        feedbackStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        func list(_ key: String) -> [String] {
            ((json[key] as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        var groups: [(title: String, color: UIColor, items: [String])] = []
        if !question.isOpen {
            groups.append(("Med", palette.success, list("med")))
            groups.append(("Saknas", palette.warning, list("saknas")))
        }
        groups.append(("Fel", palette.ribbon, list("fel")))
        for group in groups where !group.items.isEmpty {
            let title = makeLabel(group.title, font: .systemFont(ofSize: 13, weight: .semibold), color: group.color)
            feedbackStack.addArrangedSubview(title)
            let items = makeLabel(group.items.map { "\u{2022} " + $0 }.joined(separator: "\n"),
                                  font: .preferredFont(forTextStyle: .callout), color: palette.ink)
            feedbackStack.addArrangedSubview(items)
        }
        let comment = (json["kommentar"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !comment.isEmpty {
            feedbackStack.addArrangedSubview(makeLabel(comment, font: .preferredFont(forTextStyle: .callout),
                                                       color: palette.inkSoft))
        }
        feedbackStack.isHidden = feedbackStack.arrangedSubviews.isEmpty
        switch json["omdome"] as? String {
        case "bra": suggested = .known
        case "delvis": suggested = .unsure
        case "saknas_mycket": suggested = .unknown
        default: suggested = nil
        }
        updateStatusButtons()
    }
}

/// Raden Läs för att ta reda på (K6b): överst när första sidan i ett kapitel med frågor före läsningen visas.
/// Visa öppnar kapitlets frågor före läsningen, Stäng tar bort raden. Försvinner av sig själv.
@MainActor
final class BeforeReadingBanner: UIView {

    private(set) static weak var current: BeforeReadingBanner?
    private var onShow: (() -> Void)?

    @discardableResult
    static func show(question: String, in host: UIView, onShow: @escaping () -> Void) -> BeforeReadingBanner {
        current?.removeFromSuperview()
        let banner = BeforeReadingBanner(question: question, onShow: onShow)
        banner.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            banner.topAnchor.constraint(equalTo: host.safeAreaLayoutGuide.topAnchor, constant: 56),
            banner.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, constant: -32),
            banner.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
        ])
        current = banner
        banner.alpha = 0
        UIView.animate(withDuration: 0.2) { banner.alpha = 1 }
        UIAccessibility.post(notification: .announcement, argument: "Läs för att ta reda på: \(question)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak banner] in
            guard !SelfTest.isActive else { return }
            banner?.hide()
        }
        return banner
    }

    private init(question: String, onShow: @escaping () -> Void) {
        self.onShow = onShow
        super.init(frame: .zero)
        let palette = Theme.current
        backgroundColor = palette.surface
        layer.cornerRadius = 18
        layer.borderWidth = 1
        layer.borderColor = palette.rule.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = palette.isDark ? 0.4 : 0.15
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 2)
        let title = UILabel()
        title.text = "Läs för att ta reda på"
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = palette.inkSoft
        let text = UILabel()
        text.text = question
        text.font = Theme.serif(.subheadline)
        text.textColor = palette.ink
        text.numberOfLines = 2
        text.lineBreakMode = .byTruncatingTail
        let texts = UIStackView(arrangedSubviews: [title, text])
        texts.axis = .vertical
        texts.spacing = 2
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let show = UIButton(type: .system)
        show.setTitle("Visa", for: .normal)
        show.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        show.tintColor = palette.accent
        show.addAction(UIAction { [weak self] _ in self?.showTapped() }, for: .touchUpInside)
        let close = UIButton(type: .system)
        close.setTitle("Stäng", for: .normal)
        close.titleLabel?.font = .systemFont(ofSize: 15)
        close.tintColor = palette.inkSoft
        close.addAction(UIAction { [weak self] _ in self?.hide() }, for: .touchUpInside)
        let row = UIStackView(arrangedSubviews: [texts, show, close])
        row.spacing = 14
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    /// Visa (också från självtestet).
    func showTapped() {
        let show = onShow
        onShow = nil
        hide()
        show?()
    }

    func hide() {
        guard superview != nil else { return }
        UIView.animate(withDuration: 0.2, animations: { self.alpha = 0 }, completion: { _ in
            self.removeFromSuperview()
        })
    }
}

/// Kapitlets frågor före läsningen, utan svar (K6b): det man ska ha i huvudet medan man läser.
final class BeforeReadingViewController: UIViewController {

    private let questions: [BookQuestion]

    init(questions: [BookQuestion]) {
        self.questions = questions
        super.init(nibName: nil, bundle: nil)
        title = "Läs för att ta reda på"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let palette = Theme.current
        view.backgroundColor = palette.surface
        view.tintColor = palette.accent
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Klar", style: .done, target: self,
                                                            action: #selector(close))
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (index, question) in questions.enumerated() {
            let label = UILabel()
            label.text = questions.count > 1 ? "\(index + 1). \(question.question)" : question.question
            label.font = Theme.serif(.body, size: 19)
            label.textColor = palette.ink
            label.numberOfLines = 0
            stack.addArrangedSubview(label)
        }
        let note = UILabel()
        note.text = "Svaren finns i fliken Frågor och i självtestet efter kapitlet. Gjord med AI."
        note.font = .preferredFont(forTextStyle: .footnote)
        note.textColor = palette.inkFaint
        note.numberOfLines = 0
        stack.addArrangedSubview(note)
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
        let fitting = stack.systemLayoutSizeFitting(CGSize(width: 380, height: 0),
                                                    withHorizontalFittingPriority: .required,
                                                    verticalFittingPriority: .fittingSizeLevel)
        preferredContentSize = CGSize(width: 420, height: min(ceil(fitting.height) + 40, 520))
    }

    @objc private func close() {
        dismiss(animated: true)
    }
}
