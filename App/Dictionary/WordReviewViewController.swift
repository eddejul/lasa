import UIKit

/// Repetera sparade ord som kort: ordet och meningen där det stod, sedan svaret ur ordboken.
/// Man säger själv hur väl man kunde det, och ordet kommer tillbaka efter ett schema (fas 6).
final class WordReviewViewController: UIViewController {

    private var queue: [ReviewCard] = []
    private var index = 0
    private var reviewed = 0
    private var revealed = false

    private let progressLabel = UILabel()
    private let card = UIView()
    private let wordLabel = UILabel()
    private let languageLabel = UILabel()
    private let sentenceLabel = UILabel()
    private let answerLabel = UILabel()
    private let showButton = UIButton(configuration: .filled())
    private let gradeStack = UIStackView()
    private var gradeButtons: [ReviewGrade: UIButton] = [:]
    private let doneLabel = UILabel()

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "Repetera"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.largeTitleDisplayMode = .never

        progressLabel.font = .preferredFont(forTextStyle: .subheadline)
        progressLabel.textColor = .secondaryLabel
        progressLabel.textAlignment = .center

        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 16

        wordLabel.font = UIFont.preferredFont(forTextStyle: .largeTitle).withSymbolicTraits(.traitBold)
        wordLabel.adjustsFontForContentSizeCategory = true
        wordLabel.textAlignment = .center
        wordLabel.numberOfLines = 0
        languageLabel.font = .preferredFont(forTextStyle: .footnote)
        languageLabel.textColor = .secondaryLabel
        languageLabel.textAlignment = .center
        sentenceLabel.numberOfLines = 0
        sentenceLabel.textAlignment = .center
        answerLabel.numberOfLines = 0
        answerLabel.textAlignment = .center
        answerLabel.font = .preferredFont(forTextStyle: .title3)

        let cardStack = UIStackView(arrangedSubviews: [wordLabel, languageLabel, sentenceLabel, answerLabel])
        cardStack.axis = .vertical
        cardStack.spacing = 14
        cardStack.setCustomSpacing(4, after: wordLabel)
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cardStack)

        var showConfiguration = UIButton.Configuration.filled()
        showConfiguration.title = "Visa svaret"
        showConfiguration.cornerStyle = .large
        showConfiguration.buttonSize = .large
        showButton.configuration = showConfiguration
        showButton.addAction(UIAction { [weak self] _ in self?.reveal() }, for: .touchUpInside)

        gradeStack.axis = .horizontal
        gradeStack.spacing = 10
        gradeStack.distribution = .fillEqually
        let colors: [ReviewGrade: UIColor] = [.again: .systemRed, .hard: .systemOrange, .good: .systemGreen, .easy: .systemBlue]
        for grade in ReviewGrade.allCases {
            var configuration = UIButton.Configuration.tinted()
            configuration.title = grade.title
            configuration.baseForegroundColor = colors[grade]
            configuration.baseBackgroundColor = colors[grade]
            configuration.cornerStyle = .large
            configuration.titleAlignment = .center
            let button = UIButton(configuration: configuration)
            button.addAction(UIAction { [weak self] _ in self?.grade(grade) }, for: .touchUpInside)
            gradeButtons[grade] = button
            gradeStack.addArrangedSubview(button)
        }

        doneLabel.numberOfLines = 0
        doneLabel.textAlignment = .center
        doneLabel.font = .preferredFont(forTextStyle: .title3)
        doneLabel.textColor = .secondaryLabel
        doneLabel.isHidden = true

        let stack = UIStackView(arrangedSubviews: [progressLabel, card, showButton, gradeStack, doneLabel])
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            cardStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 28),
            cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -28),
            cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
            cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),

            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor),
            gradeStack.heightAnchor.constraint(equalToConstant: 64),
        ])
        let preferredWidth = stack.widthAnchor.constraint(equalToConstant: 560)
        preferredWidth.priority = .defaultHigh
        preferredWidth.isActive = true

        queue = UserWords.shared.reviewQueue()
        show()
    }

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

    // MARK: Korten

    private func show() {
        revealed = false
        guard index < queue.count else {
            card.isHidden = true
            showButton.isHidden = true
            gradeStack.isHidden = true
            doneLabel.isHidden = false
            progressLabel.text = nil
            doneLabel.text = reviewed == 0
                ? "Inga ord att repetera just nu.\nOrd du slår upp i böckerna hamnar här."
                : "Klart för i dag.\nDu repeterade \(reviewed) ord."
            return
        }
        let current = queue[index]
        let word = current.word
        progressLabel.text = "\(queue.count - index) kvar" + (current.isNew ? ", nytt ord" : "")
        wordLabel.text = word.lemma
        languageLabel.text = word.language == .english ? "engelska" : "svenska"
        sentenceLabel.attributedText = Self.sentence(word.sentence, highlighting: word.word)
        sentenceLabel.isHidden = word.sentence.isEmpty || word.sentence == word.word
        answerLabel.text = nil
        answerLabel.isHidden = true
        showButton.isHidden = false
        gradeStack.isHidden = true
        for grade in ReviewGrade.allCases {
            let days = ReviewSchedule.next(grade, interval: current.interval, ease: current.ease, reps: current.reps).interval
            var configuration = gradeButtons[grade]?.configuration
            configuration?.subtitle = ReviewSchedule.label(days: days)
            gradeButtons[grade]?.configuration = configuration
        }
    }

    func reveal() {
        guard index < queue.count, !revealed else { return }
        revealed = true
        answerLabel.text = Self.answer(for: queue[index].word)
        answerLabel.isHidden = false
        showButton.isHidden = true
        gradeStack.isHidden = false
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
        show()
    }

    /// Svaret ur ordboken: översättningen för engelska ord, betydelsen och synonymerna för svenska.
    /// Har en betydelse valts när ordet sparades (O7) visas bara den, annars den första.
    static func answer(for word: SavedWord) -> String {
        guard let lookup = WordDictionary.shared?.lookup(word.lemma, sentence: word.sentence, language: word.language,
                                                         hidden: UserWords.shared.hiddenPairs),
              let first = lookup.entries.first else {
            return "Ordboken har inget svar för ordet."
        }
        let chosen = WordText.sense(withID: word.senseID, in: lookup.entries)
        let entry = chosen?.entry ?? first
        let shown = chosen?.sense ?? entry.senses.first
        var lines: [String] = []
        if word.language == .english {
            let translation = WordText.translationLine(entry)
            lines.append(translation.isEmpty ? "Ingen svensk översättning i ordboken." : translation)
            if let definition = shown?.definition {
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
        return lines.isEmpty ? "Ordboken har inget svar för ordet." : lines.joined(separator: "\n\n")
    }

    /// Meningen med ordet i fetstil.
    private static func sentence(_ text: String, highlighting word: String) -> NSAttributedString {
        let font = UIFont.preferredFont(forTextStyle: .body)
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel])
        let range = (text as NSString).range(of: word, options: [.caseInsensitive])
        if range.location != NSNotFound {
            result.addAttributes([.font: font.withSymbolicTraits(.traitBold), .foregroundColor: UIColor.label], range: range)
        }
        return result
    }
}
