import SafariServices
import UIKit

/// Hur lång tid uppslagen tar, så att målet i specen (under 150 ms) går att följa på iPaden.
/// Visas under Om ordboken. Finns bara i minnet. Används bara från huvudtråden.
final class LookupStats {

    static let shared = LookupStats()

    private(set) var lookupMilliseconds: [Double] = []
    private(set) var readyMilliseconds: [Double] = []

    private init() {}

    /// `lookup`: att slå upp ordet. `ready`: från att fingret släpptes tills rutan är klar att visas.
    func record(lookup: Double, ready: Double) {
        lookupMilliseconds = Array((lookupMilliseconds + [lookup]).suffix(50))
        readyMilliseconds = Array((readyMilliseconds + [ready]).suffix(50))
    }

    var summary: String? {
        guard let lastLookup = lookupMilliseconds.last, let lastReady = readyMilliseconds.last else { return nil }
        let median = readyMilliseconds.sorted()[readyMilliseconds.count / 2]
        return "Senaste: uppslag \(Int(lastLookup.rounded())) ms, rutan klar efter \(Int(lastReady.rounded())) ms. "
            + "Mittvärde för de senaste \(readyMilliseconds.count): \(Int(median.rounded())) ms."
    }
}

/// Navigeringen i ordrutan. Säger till när rutan stängs, så att markeringen i texten kan tas bort.
final class WordPopupNavigationController: UINavigationController {

    var onDismiss: (() -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil {
            onDismiss?()
            onDismiss = nil
        }
    }
}

/// Text som rutan och listorna delar.
enum WordText {

    /// De vanliga synonymerna som visas direkt, eller de första tre om alla är ovanliga.
    static func shownSynonyms(_ sense: WordSense) -> [Synonym] {
        let common = sense.topSynonyms.filter { !$0.isRare }
        return common.isEmpty ? Array(sense.synonyms.prefix(3)) : common
    }

    static func synonymLine(_ sense: WordSense) -> String {
        shownSynonyms(sense).map(\.word).joined(separator: ", ")
    }

    static func translationLine(_ entry: WordEntry) -> String {
        entry.translations
            .map { $0.comment.isEmpty ? $0.text : "\($0.text) (\($0.comment))" }
            .joined(separator: ", ")
    }

    /// En rad som sammanfattar ett uppslagsord, till listan Även som.
    static func summary(_ entry: WordEntry) -> String? {
        if !entry.translations.isEmpty {
            return translationLine(entry)
        }
        guard let sense = entry.senses.first else { return nil }
        return sense.definition ?? synonymLine(sense)
    }

    /// O7: betydelsen med id:t bland uppslagsorden. Ett tomt id (ingen vald betydelse) ger nil.
    static func sense(withID id: String, in entries: [WordEntry]) -> (entry: WordEntry, sense: WordSense)? {
        guard !id.isEmpty else { return nil }
        for entry in entries {
            if let sense = entry.senses.first(where: { $0.id == id }) {
                return (entry, sense)
            }
        }
        return nil
    }

    /// Betydelsens text som AI-knappen får och svarar med (samma som i `GeminiClient.Candidates`).
    static func gloss(_ sense: WordSense) -> String {
        sense.definition ?? sense.synonyms.prefix(4).map(\.word).joined(separator: ", ")
    }

    /// Källraden under meningen: bok och sida.
    static func source(book: String?, pageIndex: Int?) -> String? {
        guard let book = book, !book.isEmpty else { return nil }
        guard let page = pageIndex else { return book }
        return "\(book), s. \(page + 1)"
    }
}

/// Synonymerna som knappar som radbryts (U4). Höjden räknas för `preferredMaxLayoutWidth`.
final class ChipFlowView: UIView {

    var spacing: CGFloat = 8

    var preferredMaxLayoutWidth: CGFloat = 320 {
        didSet {
            if oldValue != preferredMaxLayoutWidth {
                invalidateIntrinsicContentSize()
            }
        }
    }

    private func frames(for width: CGFloat) -> [CGRect] {
        var result: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for view in subviews {
            var size = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            size.width = min(ceil(size.width), width)
            size.height = ceil(size.height)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            result.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return result
    }

    override var intrinsicContentSize: CGSize {
        let height = frames(for: preferredMaxLayoutWidth).map(\.maxY).max() ?? 0
        return CGSize(width: UIView.noIntrinsicMetric, height: height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width > 0 ? bounds.width : preferredMaxLayoutWidth
        for (view, frame) in zip(subviews, frames(for: width)) {
            view.frame = frame
        }
        if bounds.width > 0, abs(bounds.width - preferredMaxLayoutWidth) > 0.5 {
            preferredMaxLayoutWidth = bounds.width
        }
    }
}

/// Ordkortet (U4) som visas när man släpper ett ord man har hållit på.
///
/// Ordet en gång, stort i New York, med ordklass och SV eller EN. Direkt under svaret i stor stil: för ett
/// engelskt ord den svenska översättningen, för ett svenskt ord betydelsen (när Folkets lexikon har en).
/// Sedan synonymerna som knappar (ett tryck slår upp ordet i samma ruta), meningen ur boken med ordet
/// understruket, Förklara i meningen (AI) och längst ner SO och SAOL, Sparat, Fel synonym och betydelserna.
/// Betydelserna kan väljas (O7): den valda sparas med ordet och visas sedan överst och i repetitionen.
final class WordPopupViewController: UIViewController {

    /// Var uppslaget kommer ifrån. Ord ur texten sparas automatiskt, synonymer man bläddrar till sparas inte.
    struct Context {
        let sentence: String
        let rangeInSentence: NSRange?
        let book: String?
        let pageIndex: Int?
        /// Ordet som det stod, om det inte hittades (visas i meddelandet).
        let triedWord: String
        /// Bokens id i bokregistret (G3), sparas med ordet.
        var bookID: String? = nil
        /// O4: ett tryck på ett streck visar ett ord som redan är sparat. Då sparas det inte igen.
        var savesWord = true
    }

    private enum AIState {
        case idle
        case loading
        case done(WordExplanation)
        case failed(String)
    }

    /// Kortets bredd i popovern på iPad.
    static let cardWidth: CGFloat = 360
    private static let inset: CGFloat = 20

    private var lookup: WordLookup?
    private let context: Context
    private var hiddenCount = 0
    private var aiState = AIState.idle
    var onReady: (() -> Void)?
    /// Ordet som ska sparas i Sparade ord. Det sparas först när rutan syns, så att rutan inte väntar på disken.
    private var pendingSave: (word: String, lemma: String, language: WordLanguage)?
    /// O7: betydelsen som valts för första uppslagsordet (id ur ordboken), eller nil.
    private var chosenSenseID: String?
    /// Betydelserna visas som en lista i kortet efter ett tryck på knappen längst ner.
    private var sensesExpanded = false
    /// iPhone: kortet är ett ark och har en stängknapp i stället för menyraden.
    var showsCloseButton = false

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var chipViews: [ChipFlowView] = []

    init(lookup: WordLookup?, context: Context) {
        self.lookup = lookup
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    private var entry: WordEntry? {
        lookup?.entries.first
    }

    private var language: WordLanguage {
        lookup?.language ?? .swedish
    }

    /// Betydelsen som visas överst: den valda, annars den första.
    private var shownSense: WordSense? {
        guard let entry = entry else { return nil }
        if let id = chosenSenseID, let chosen = entry.senses.first(where: { $0.id == id }) {
            return chosen
        }
        return entry.senses.first
    }

    private var palette: Palette {
        Theme.current
    }

    // MARK: Visa

    /// Visar rutan vid ordet: en popover på iPad, ett ark nerifrån på iPhone (halv höjd, kan dras upp).
    static func present(lookup: WordLookup?,
                        context: Context,
                        from presenter: UIViewController,
                        sourceView: UIView,
                        sourceRect: CGRect,
                        onReady: @escaping () -> Void,
                        onDismiss: @escaping () -> Void) {
        let popup = WordPopupViewController(lookup: lookup, context: context)
        popup.onReady = onReady
        // Ett ord som slagits upp i en bok sparas med meningen.
        if context.book != nil, context.savesWord, let lookup = lookup, let lemma = lookup.entries.first?.lemma {
            popup.pendingSave = (lookup.word, lemma, lookup.language)
        }
        let navigation = WordPopupNavigationController(rootViewController: popup)
        navigation.onDismiss = onDismiss
        // Kortet har ingen menyrad. Den döljs redan här, så att kortet inte börjar en menyrad längre ner.
        navigation.setNavigationBarHidden(true, animated: false)

        if presenter.traitCollection.userInterfaceIdiom == .pad {
            navigation.modalPresentationStyle = .popover
            if let popover = navigation.popoverPresentationController {
                popover.sourceView = sourceView
                popover.sourceRect = sourceRect
                popover.permittedArrowDirections = [.up, .down, .left, .right]
                popover.backgroundColor = Theme.current.surface
            }
        } else {
            navigation.modalPresentationStyle = .pageSheet
            if let sheet = navigation.sheetPresentationController {
                sheet.detents = [.medium(), .large()]
                sheet.prefersGrabberVisible = true
                sheet.prefersScrollingExpandsWhenScrolledToEdge = true
                sheet.preferredCornerRadius = 20
            }
            popup.showsCloseButton = true
        }
        presenter.present(navigation, animated: true)
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    // MARK: Livscykel

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.backButtonDisplayMode = .minimal
        hiddenCount = UserWords.shared.hiddenPairs.count
        if let entry = entry, let saved = UserWords.shared.senseID(lemma: entry.lemma, language: language),
           entry.senses.contains(where: { $0.id == saved }) {
            chosenSenseID = saved
        }

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = false
        view.addSubview(scrollView)
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        let inset = Self.inset
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: inset),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -inset),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -2 * inset),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: Theme.didChange,
                                               object: nil)
        rebuild()
    }

    @objc private func themeChanged() {
        rebuild()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Kortet har ingen menyrad (ordet står en gång, i kortet). Ett kort man bläddrat till har en
        // tillbakapil.
        let isRoot = navigationController?.viewControllers.first === self
        navigationController?.setNavigationBarHidden(isRoot, animated: animated)
        // Har användaren dolt en synonym i listan ska den försvinna här också.
        if UserWords.shared.hiddenPairs.count != hiddenCount, let current = lookup {
            hiddenCount = UserWords.shared.hiddenPairs.count
            if let fresh = WordDictionary.shared?.lookup(current.word,
                                                         sentence: context.sentence,
                                                         rangeInSentence: context.rangeInSentence,
                                                         language: current.language,
                                                         hidden: UserWords.shared.hiddenPairs) {
                // Visar rutan ett enskilt uppslagsord (från Även som) ska det vara samma ord.
                let same = fresh.entries.filter { $0.lemma == entry?.lemma && $0.pos == entry?.pos }
                lookup = current.entries.count == 1 && !same.isEmpty
                    ? WordLookup(word: fresh.word, key: fresh.key, language: fresh.language, entries: same,
                                 compound: fresh.compound, otherLanguageAvailable: fresh.otherLanguageAvailable)
                    : fresh
            }
            rebuild()
        }
        onReady?()
        onReady = nil
        // Spara i nästa varv, efter att rutan börjat visas. Rutan hålls kvar tills dess, så att ordet
        // sparas även om den stängs innan den syns helt. Med WAL väntar sparningen inte på disken.
        if pendingSave != nil {
            DispatchQueue.main.async {
                self.savePendingWord()
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        savePendingWord()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        savePendingWord()
    }

    private func savePendingWord() {
        guard let pending = pendingSave, let book = context.book else { return }
        pendingSave = nil
        UserWords.shared.save(word: pending.word, lemma: pending.lemma, language: pending.language,
                              sentence: context.sentence, book: book, pageIndex: context.pageIndex ?? 0,
                              bookID: context.bookID)
        if let id = chosenSenseID {
            UserWords.shared.setSense(lemma: pending.lemma, language: pending.language, senseID: id)
        }
    }

    /// Sparat, eller sparas så fort rutan syns.
    private func isSaved(lemma: String) -> Bool {
        if let pending = pendingSave, pending.lemma == lemma, pending.language == language {
            return true
        }
        return UserWords.shared.isSaved(lemma: lemma, language: language)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = view.bounds.width > 0 ? view.bounds.width : Self.cardWidth
        let inner = width - 2 * Self.inset
        for chips in chipViews {
            chips.preferredMaxLayoutWidth = inner
        }
        let fitting = stack.systemLayoutSizeFitting(CGSize(width: inner, height: UIView.layoutFittingCompressedSize.height),
                                                    withHorizontalFittingPriority: .required,
                                                    verticalFittingPriority: .fittingSizeLevel)
        let height = min(max(ceil(fitting.height) + Self.inset + 8, 120), 640)
        let size = CGSize(width: Self.cardWidth, height: height)
        if preferredContentSize != size {
            preferredContentSize = size
        }
        // Menyraden döljs när kortet visas. Kortet ska då börja överst, inte där menyraden slutade.
        let top = -scrollView.adjustedContentInset.top
        if !scrollView.isTracking, !scrollView.isDecelerating, scrollView.contentOffset.y < top {
            scrollView.contentOffset.y = top
        }
    }

    /// Kortets höjd efter innehållet, till självtestet.
    var contentHeight: CGFloat {
        preferredContentSize.height
    }

    // MARK: Kortet

    private func rebuild() {
        let palette = self.palette
        view.backgroundColor = palette.surface
        title = nil
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        chipViews = []

        if let lookup = lookup, let entry = entry {
            stack.addArrangedSubview(headerRow(word: entry.lemma, details: entry.posName))
            if let note = headerNote(lookup, entry) {
                stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)
                stack.addArrangedSubview(makeLabel(note, font: .preferredFont(forTextStyle: .footnote),
                                                   color: palette.inkSoft))
            }
            addAnswer(lookup, entry)
            if let sense = shownSense, !sense.synonyms.isEmpty {
                addSynonyms(sense)
            }
            if !entry.hasContent {
                stack.addArrangedSubview(makeLabel("Ordboken har ingen betydelse eller synonym för ordet.",
                                                   font: .preferredFont(forTextStyle: .body), color: palette.inkSoft))
            }
            if sensesExpanded, entry.senses.count > 1 {
                addSenseList(entry)
            }
            addSentence(lookup)
            if GeminiClient.isConfigured {
                addAI(entry)
            }
            if lookup.entries.count > 1 {
                addOtherEntries(lookup)
            }
        } else {
            stack.addArrangedSubview(headerRow(word: context.triedWord, details: ""))
            stack.addArrangedSubview(makeLabel("Hittade inte ordet i ordboken.",
                                               font: .preferredFont(forTextStyle: .title3), color: palette.ink))
            stack.addArrangedSubview(makeLabel("Ordet kan vara ett namn, ett ovanligt sammansatt ord eller felstavat i PDF:en.",
                                               font: .preferredFont(forTextStyle: .subheadline), color: palette.inkSoft))
        }
        addBottomBar()
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    /// Ordet stort i New York, ordklassen bredvid och SV eller EN till höger.
    private func headerRow(word: String, details: String) -> UIView {
        let palette = self.palette
        let text = NSMutableAttributedString(string: word, attributes: [
            .font: Theme.serif(.title1, size: 28, weight: .semibold), .foregroundColor: palette.ink,
        ])
        if !details.isEmpty {
            text.append(NSAttributedString(string: "  " + details, attributes: [
                .font: UIFont.systemFont(ofSize: 14), .foregroundColor: palette.inkSoft,
            ]))
        }
        let wordLabel = UILabel()
        wordLabel.attributedText = text
        wordLabel.numberOfLines = 0
        wordLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        wordLabel.accessibilityLabel = details.isEmpty ? word : "\(word), \(details)"

        var views: [UIView] = [wordLabel]
        if lookup != nil {
            let chip = PaddedLabel()
            chip.insets = UIEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
            chip.text = language == .english ? "EN" : "SV"
            chip.font = .systemFont(ofSize: 13, weight: .semibold)
            chip.textColor = palette.accent
            chip.backgroundColor = palette.accentSoft
            chip.layer.cornerRadius = 6
            chip.layer.masksToBounds = true
            chip.accessibilityLabel = language.name
            chip.setContentHuggingPriority(.required, for: .horizontal)
            chip.setContentCompressionResistancePriority(.required, for: .horizontal)
            views.append(chip)
        }
        if showsCloseButton, navigationController?.viewControllers.first === self {
            var configuration = UIButton.Configuration.plain()
            configuration.image = UIImage(systemName: "xmark.circle.fill",
                                          withConfiguration: UIImage.SymbolConfiguration(pointSize: 24))
            configuration.baseForegroundColor = palette.inkFaint
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 0)
            let close = UIButton(configuration: configuration,
                                 primaryAction: UIAction { [weak self] _ in self?.closeTapped() })
            close.accessibilityLabel = "Stäng"
            close.setContentHuggingPriority(.required, for: .horizontal)
            views.append(close)
        }
        let row = UIStackView(arrangedSubviews: views)
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        return row
    }

    /// Grundform, sammansatt ord och lånad översättning, i en liten rad under ordet.
    private func headerNote(_ lookup: WordLookup, _ entry: WordEntry) -> String? {
        var notes: [String] = []
        if let compound = lookup.compound {
            notes.append("Sammansatt ord som inte finns i ordboken: \(compound.head) + \(compound.tail). Kortet visar efterledet.")
        } else if WordDictionary.normalize(entry.lemma) != lookup.key {
            notes.append("Grundform till \(lookup.word)")
        }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    /// Svaret i stor stil.
    private func addAnswer(_ lookup: WordLookup, _ entry: WordEntry) {
        let palette = self.palette
        let big = UIFont.systemFont(ofSize: 20, weight: .regular)
        if lookup.language == .english {
            if entry.translations.isEmpty {
                stack.addArrangedSubview(makeLabel("Ingen svensk översättning i ordboken.", font: big, color: palette.inkSoft))
            } else {
                stack.addArrangedSubview(makeLabel(WordText.translationLine(entry), font: big, color: palette.ink))
                if let via = entry.translationVia {
                    stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)
                    stack.addArrangedSubview(makeLabel("Ordet saknas i lexikonet. Översättningen gäller \(via), som betyder samma sak.",
                                                       font: .preferredFont(forTextStyle: .footnote), color: palette.inkSoft))
                }
            }
            if let definition = shownSense?.definition {
                stack.addArrangedSubview(makeLabel(definition, font: .preferredFont(forTextStyle: .subheadline),
                                                   color: palette.inkSoft))
            }
        } else if let sense = shownSense {
            if let definition = sense.definition {
                stack.addArrangedSubview(makeLabel(definition, font: big, color: palette.ink))
            } else if !sense.synonyms.isEmpty {
                stack.addArrangedSubview(makeLabel(WordText.synonymLine(sense), font: big, color: palette.ink))
            }
        }
        if let id = chosenSenseID, entry.senses.count > 1,
           let index = entry.senses.firstIndex(where: { $0.id == id }) {
            stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)
            stack.addArrangedSubview(makeLabel("Betydelse \(index + 1) av \(entry.senses.count), vald av dig",
                                               font: .preferredFont(forTextStyle: .footnote), color: palette.accent))
        }
    }

    /// Synonymerna som knappar. Ett tryck slår upp ordet i samma ruta, med en tillbakapil.
    private func addSynonyms(_ sense: WordSense) {
        let palette = self.palette
        stack.addArrangedSubview(sectionLabel(language == .english ? "Liknande engelska ord" : "Liknande ord"))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)
        let chips = ChipFlowView()
        let chipFont = Theme.serif(.body, size: 16)
        for synonym in sense.synonyms.prefix(8) {
            var configuration = UIButton.Configuration.plain()
            configuration.title = synonym.word
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
            configuration.cornerStyle = .fixed
            configuration.background.cornerRadius = 10
            configuration.background.backgroundColor = palette.surfaceSunk
            configuration.baseForegroundColor = synonym.isRare ? palette.inkSoft : palette.ink
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = chipFont
                return outgoing
            }
            let word = synonym.word
            let button = UIButton(configuration: configuration,
                                  primaryAction: UIAction { [weak self] _ in self?.lookUp(word) })
            button.accessibilityHint = "Slår upp ordet"
            chips.addSubview(button)
        }
        chipViews.append(chips)
        stack.addArrangedSubview(chips)
    }

    /// Meningen ur boken i kursiv New York med ordet understruket, och boken och sidan under.
    private func addSentence(_ lookup: WordLookup) {
        let sentence = context.sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty, sentence.caseInsensitiveCompare(lookup.word) != .orderedSame else { return }
        let palette = self.palette
        let font = Theme.serif(.body, size: 17).withSymbolicTraits(.traitItalic)
        let text = NSMutableAttributedString(string: context.sentence, attributes: [
            .font: font, .foregroundColor: palette.ink,
        ])
        let length = (context.sentence as NSString).length
        var range = context.rangeInSentence ?? NSRange(location: NSNotFound, length: 0)
        if range.location == NSNotFound || NSMaxRange(range) > length || range.length == 0 {
            range = (context.sentence as NSString).range(of: lookup.word, options: [.caseInsensitive])
        }
        if range.location != NSNotFound, NSMaxRange(range) <= length {
            text.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue,
                                .underlineColor: palette.accent,
                                .foregroundColor: palette.accent], range: range)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.15
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: length))
        let sentenceLabel = UILabel()
        sentenceLabel.attributedText = text
        sentenceLabel.numberOfLines = 0

        var rows: [UIView] = [sentenceLabel]
        var source = WordText.source(book: context.book, pageIndex: context.pageIndex) ?? ""
        if context.book != nil, let lemma = entry?.lemma, isSaved(lemma: lemma) {
            source += source.isEmpty ? "Sparat" : ", sparat"
        }
        if !source.isEmpty {
            rows.append(makeLabel(source, font: .preferredFont(forTextStyle: .footnote), color: palette.inkSoft))
        }
        stack.addArrangedSubview(box(rows, background: palette.surfaceSunk))
    }

    /// Förklara i meningen: en ljus knapp vars svar växer fram i samma kort.
    private func addAI(_ entry: WordEntry) {
        let palette = self.palette
        switch aiState {
        case .idle, .loading:
            let soft = palette.inkSoft
            var configuration = UIButton.Configuration.plain()
            configuration.title = "Förklara i meningen"
            configuration.subtitle = "Meningen och ordet skickas till Gemini"
            configuration.image = UIImage(systemName: "sparkles")
            configuration.imagePadding = 10
            configuration.baseForegroundColor = palette.accent
            configuration.cornerStyle = .fixed
            configuration.background.cornerRadius = 14
            configuration.background.backgroundColor = palette.accentSoft
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
            configuration.titleAlignment = .leading
            if case .loading = aiState {
                configuration.title = "Frågar Gemini …"
                configuration.showsActivityIndicator = true
            }
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = .systemFont(ofSize: 17, weight: .medium)
                return outgoing
            }
            configuration.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = .systemFont(ofSize: 12)
                outgoing.foregroundColor = soft
                return outgoing
            }
            let button = UIButton(configuration: configuration,
                                  primaryAction: UIAction { [weak self] _ in self?.askAI() })
            button.contentHorizontalAlignment = .leading
            if case .loading = aiState {
                button.isEnabled = false
            }
            stack.addArrangedSubview(button)

        case .done(let answer):
            var rows: [UIView] = [
                makeLabel("Förklaring med AI", font: .systemFont(ofSize: 12, weight: .semibold), color: palette.accent),
                makeLabel(answer.explanation, font: .preferredFont(forTextStyle: .body), color: palette.ink),
            ]
            if let best = answer.bestWord {
                rows.append(makeLabel("Passar bäst här: \(best)", font: .preferredFont(forTextStyle: .subheadline),
                                      color: palette.inkSoft))
            }
            // O7: AI:n föreslår en betydelse, och man bekräftar själv.
            if let text = answer.senseText, entry.senses.count > 1,
               let suggested = entry.senses.prefix(6).first(where: { WordText.gloss($0) == text }),
               !suggested.id.isEmpty, suggested.id != chosenSenseID {
                let soft = palette.inkSoft
                var configuration = UIButton.Configuration.plain()
                configuration.title = "Välj den betydelsen"
                configuration.subtitle = text
                configuration.baseForegroundColor = palette.accent
                configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 2, trailing: 0)
                configuration.titleAlignment = .leading
                configuration.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                    var outgoing = incoming
                    outgoing.foregroundColor = soft
                    return outgoing
                }
                let id = suggested.id
                let button = UIButton(configuration: configuration,
                                      primaryAction: UIAction { [weak self] _ in self?.choose(senseID: id) })
                button.contentHorizontalAlignment = .leading
                rows.append(button)
            } else if let text = answer.senseText {
                rows.append(makeLabel("Betydelsen i ordboken: \(text)", font: .preferredFont(forTextStyle: .subheadline),
                                      color: palette.inkSoft))
            }
            stack.addArrangedSubview(box(rows, background: palette.accentSoft))

        case .failed(let message):
            var configuration = UIButton.Configuration.plain()
            configuration.title = message
            configuration.subtitle = "Tryck för att försöka igen."
            configuration.baseForegroundColor = palette.ribbon
            configuration.cornerStyle = .fixed
            configuration.background.cornerRadius = 14
            configuration.background.backgroundColor = palette.surfaceSunk
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
            configuration.titleAlignment = .leading
            let button = UIButton(configuration: configuration,
                                  primaryAction: UIAction { [weak self] _ in self?.askAI() })
            button.contentHorizontalAlignment = .leading
            stack.addArrangedSubview(button)
        }
    }

    /// O7: alla betydelser. Ett tryck väljer den som passar meningen, och kortet visar sedan bara den.
    private func addSenseList(_ entry: WordEntry) {
        let palette = self.palette
        let saved = context.book != nil || isSaved(lemma: entry.lemma)
        stack.addArrangedSubview(sectionLabel("Betydelser"))
        stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(makeLabel(saved
            ? "Tryck på den som passar meningen. Kortet och repetitionen visar sedan bara den."
            : "Tryck på en betydelse för att visa den överst.",
            font: .preferredFont(forTextStyle: .footnote), color: palette.inkSoft))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)
        let list = UIStackView()
        list.axis = .vertical
        list.spacing = 6
        let current = chosenSenseID ?? entry.senses.first?.id
        let soft = palette.inkSoft
        let titleFont = UIFont.preferredFont(forTextStyle: .subheadline)
        let subtitleFont = UIFont.preferredFont(forTextStyle: .footnote)
        for (index, sense) in entry.senses.enumerated() {
            let chosen = sense.id == current && chosenSenseID != nil
            var configuration = UIButton.Configuration.plain()
            configuration.title = "\(index + 1). " + WordText.gloss(sense)
            if sense.definition != nil, !sense.synonyms.isEmpty {
                configuration.subtitle = WordText.synonymLine(sense)
            }
            configuration.image = UIImage(systemName: chosen ? "checkmark.circle.fill" : "circle")
            configuration.imagePadding = 10
            configuration.imagePlacement = .leading
            configuration.titleAlignment = .leading
            configuration.baseForegroundColor = palette.ink
            configuration.cornerStyle = .fixed
            configuration.background.cornerRadius = 10
            configuration.background.backgroundColor = chosen ? palette.accentSoft : palette.surfaceSunk
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = titleFont
                return outgoing
            }
            configuration.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = subtitleFont
                outgoing.foregroundColor = soft
                return outgoing
            }
            let id = sense.id
            let button = UIButton(configuration: configuration,
                                  primaryAction: UIAction { [weak self] _ in self?.choose(senseID: id) })
            button.contentHorizontalAlignment = .leading
            button.tintColor = chosen ? palette.accent : palette.inkFaint
            button.isEnabled = !id.isEmpty
            button.accessibilityTraits = chosen ? [.button, .selected] : .button
            list.addArrangedSubview(button)
        }
        stack.addArrangedSubview(list)
    }

    /// Andra ordklasser och grundformer för samma ord.
    private func addOtherEntries(_ lookup: WordLookup) {
        let palette = self.palette
        stack.addArrangedSubview(sectionLabel("Även som"))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)
        let soft = palette.inkSoft
        for index in lookup.entries.indices.dropFirst() {
            let other = lookup.entries[index]
            var configuration = UIButton.Configuration.plain()
            configuration.title = [other.lemma, other.posName].filter { !$0.isEmpty }.joined(separator: ", ")
            configuration.subtitle = WordText.summary(other)
            configuration.image = UIImage(systemName: "chevron.right",
                                          withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
            configuration.imagePlacement = .trailing
            configuration.imagePadding = 8
            configuration.titleAlignment = .leading
            configuration.baseForegroundColor = palette.ink
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)
            configuration.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.foregroundColor = soft
                return outgoing
            }
            let button = UIButton(configuration: configuration,
                                  primaryAction: UIAction { [weak self] _ in self?.showEntry(at: index) })
            button.contentHorizontalAlignment = .leading
            button.tintColor = palette.inkFaint
            stack.addArrangedSubview(button)
        }
    }

    /// Raden längst ner: SO och SAOL, Sparat, Fel synonym och betydelserna, och under den byte av språk
    /// och Om ordboken.
    private func addBottomBar() {
        let palette = self.palette
        var buttons: [UIButton] = []
        if language == .swedish {
            buttons.append(barButton("SO och SAOL", symbol: "book") { [weak self] in self?.openSvenskaSe() })
        }
        if let lookup = lookup, let entry = entry {
            let saved = isSaved(lemma: entry.lemma)
            if context.book != nil || saved {
                buttons.append(barButton(saved ? "Sparat" : "Spara", symbol: saved ? "bookmark.fill" : "bookmark",
                                         tint: saved ? palette.success : nil) { [weak self] in
                    self?.toggleSaved()
                })
            }
            if let sense = shownSense, !sense.synonyms.isEmpty {
                buttons.append(barButton("Fel synonym", symbol: "hand.thumbsdown") { [weak self] in
                    guard let self = self else { return }
                    self.navigationController?.pushViewController(
                        SynonymListViewController(entry: entry, sense: sense, language: lookup.language), animated: true)
                })
            }
            if entry.senses.count > 1 {
                let title = sensesExpanded ? "Dölj betydelser" : "\(entry.senses.count) betydelser"
                buttons.append(barButton(title, symbol: "list.bullet") { [weak self] in
                    self?.toggleSenses()
                })
            }
        }
        let line = UIView()
        line.backgroundColor = palette.rule
        line.heightAnchor.constraint(equalToConstant: 1 / max(UIScreen.main.scale, 1)).isActive = true
        stack.addArrangedSubview(line)
        stack.setCustomSpacing(0, after: line)
        if !buttons.isEmpty {
            let bar = UIStackView(arrangedSubviews: buttons)
            bar.axis = .horizontal
            bar.distribution = .fillEqually
            bar.alignment = .top
            stack.addArrangedSubview(bar)
            stack.setCustomSpacing(2, after: bar)
        }

        var links: [UIButton] = []
        if let lookup = lookup, lookup.otherLanguageAvailable {
            links.append(linkButton("Visa som \(lookup.language.other.name)") { [weak self] in self?.switchLanguage() })
        }
        links.append(linkButton("Om ordboken") { [weak self] in
            self?.navigationController?.pushViewController(AboutDictionaryViewController(), animated: true)
        })
        let linkRow = UIStackView(arrangedSubviews: (links as [UIView]) + [UIView()])
        linkRow.axis = .horizontal
        linkRow.spacing = 18
        stack.addArrangedSubview(linkRow)
    }

    // MARK: Byggstenar

    private func makeLabel(_ text: String, font: UIFont, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = font
        label.textColor = color
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    /// Liten rubrik i versaler, som LIKNANDE ORD i skissen.
    private func sectionLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.attributedText = NSAttributedString(string: text.uppercased(with: Locale(identifier: "sv_SE")), attributes: [
            .font: UIFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: palette.inkSoft, .kern: 0.6,
        ])
        return label
    }

    /// En ruta med rundade hörn och luft runt innehållet.
    private func box(_ rows: [UIView], background: UIColor) -> UIView {
        let container = UIView()
        container.backgroundColor = background
        container.layer.cornerRadius = 14
        let inner = UIStackView(arrangedSubviews: rows)
        inner.axis = .vertical
        inner.spacing = 8
        inner.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            inner.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
            inner.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            inner.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
        ])
        return container
    }

    /// En knapp i raden längst ner: ikonen överst och en kort text under.
    private func barButton(_ title: String, symbol: String, tint: UIColor? = nil,
                           action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.image = UIImage(systemName: symbol,
                                      withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular))
        configuration.imagePlacement = .top
        configuration.imagePadding = 5
        configuration.baseForegroundColor = tint ?? palette.accent
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 2, bottom: 8, trailing: 2)
        configuration.titleLineBreakMode = .byTruncatingTail
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 12, weight: .medium)
            return outgoing
        }
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.accessibilityLabel = title
        return button
    }

    private func linkButton(_ title: String, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.baseForegroundColor = palette.accent
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)
        let font = UIFont.preferredFont(forTextStyle: .footnote)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = font
            return outgoing
        }
        return UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
    }

    // MARK: Händelser

    /// Ett synonymkort i samma ruta, med tillbakapil. Synonymer sparas inte.
    private func lookUp(_ word: String) {
        let found = WordDictionary.shared?.lookup(word, language: language, hidden: UserWords.shared.hiddenPairs)
        let next = Context(sentence: "", rangeInSentence: nil, book: nil, pageIndex: nil, triedWord: word)
        navigationController?.pushViewController(WordPopupViewController(lookup: found, context: next), animated: true)
    }

    private func showEntry(at index: Int) {
        guard let lookup = lookup, index < lookup.entries.count else { return }
        let single = WordLookup(word: lookup.word, key: lookup.key, language: lookup.language,
                                entries: [lookup.entries[index]],
                                compound: lookup.compound, otherLanguageAvailable: false)
        let next = Context(sentence: context.sentence, rangeInSentence: context.rangeInSentence,
                           book: nil, pageIndex: nil, triedWord: lookup.word)
        navigationController?.pushViewController(WordPopupViewController(lookup: single, context: next), animated: true)
    }

    private func switchLanguage() {
        guard let lookup = lookup,
              let other = WordDictionary.shared?.lookup(lookup.word,
                                                        sentence: context.sentence,
                                                        rangeInSentence: context.rangeInSentence,
                                                        language: lookup.language.other,
                                                        hidden: UserWords.shared.hiddenPairs) else { return }
        self.lookup = other
        aiState = .idle
        chosenSenseID = nil
        sensesExpanded = false
        if let entry = other.entries.first,
           let saved = UserWords.shared.senseID(lemma: entry.lemma, language: other.language),
           entry.senses.contains(where: { $0.id == saved }) {
            chosenSenseID = saved
        }
        animateRebuild()
    }

    private func toggleSaved() {
        guard let lookup = lookup, let entry = entry else { return }
        if isSaved(lemma: entry.lemma) {
            pendingSave = nil
            UserWords.shared.delete(lemma: entry.lemma, language: lookup.language)
        } else if let book = context.book {
            UserWords.shared.save(word: lookup.word, lemma: entry.lemma, language: lookup.language,
                                  sentence: context.sentence, book: book, pageIndex: context.pageIndex ?? 0,
                                  bookID: context.bookID)
            if let id = chosenSenseID {
                UserWords.shared.setSense(lemma: entry.lemma, language: lookup.language, senseID: id)
            }
        }
        Haptics.shared.wordTapped()
        rebuild()
    }

    private func toggleSenses() {
        sensesExpanded.toggle()
        animateRebuild()
    }

    /// O7: väljer betydelsen. Är ordet sparat sparas valet med det.
    func choose(senseID id: String) {
        guard let entry = entry, !id.isEmpty, entry.senses.contains(where: { $0.id == id }) else { return }
        savePendingWord()
        chosenSenseID = id
        if isSaved(lemma: entry.lemma) {
            UserWords.shared.setSense(lemma: entry.lemma, language: language, senseID: id)
        }
        Haptics.shared.wordTapped()
        animateRebuild()
    }

    /// Bygger om kortet och låter höjden glida till den nya (Apples riktlinje för storleksbyten i popovers).
    private func animateRebuild() {
        if UIAccessibility.isReduceMotionEnabled {
            rebuild()
            return
        }
        UIView.transition(with: stack, duration: 0.2, options: [.transitionCrossDissolve, .allowUserInteraction],
                          animations: { self.rebuild() })
    }

    /// Frågar Gemini om ordets betydelse i meningen.
    private func askAI() {
        guard let lookup = lookup else { return }
        switch aiState {
        case .loading, .done:
            return
        default:
            break
        }
        aiState = .loading
        rebuild()
        GeminiClient.explain(lookup, sentence: context.sentence) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let answer):
                self.aiState = .done(answer)
            case .failure(let error):
                self.aiState = .failed(error.localizedDescription)
            }
            self.animateRebuild()
        }
    }

    private func openSvenskaSe() {
        let word = entry?.lemma ?? context.triedWord
        var components = URLComponents(string: "https://svenska.se/tre/")
        components?.queryItems = [URLQueryItem(name: "sok", value: word), URLQueryItem(name: "pz", value: "1")]
        guard let url = components?.url else { return }
        let safari = SFSafariViewController(url: url)
        safari.dismissButtonStyle = .close
        present(safari, animated: true)
    }

    // MARK: Självtestet

    /// Visar ett AI-svar utan att fråga Gemini, så att kortet kan fotograferas med svaret.
    func showAIAnswerForTest(_ answer: WordExplanation) {
        aiState = .done(answer)
        rebuild()
    }

    /// Fäller ut betydelserna, till självtestet.
    func expandSensesForTest() {
        sensesExpanded = true
        rebuild()
    }

    /// Antalet betydelser och den valda, till självtestet.
    var senseSummaryForTest: String {
        guard let entry = entry else { return "inget ord" }
        let index = chosenSenseID.flatMap { id in entry.senses.firstIndex { $0.id == id } }
        return "\(entry.senses.count) betydelser, vald \(index.map { String($0 + 1) } ?? "ingen")"
    }

    /// Id:t för betydelse nummer `index` (från 0), till självtestet.
    func senseIDForTest(_ index: Int) -> String? {
        guard let entry = entry, index < entry.senses.count else { return nil }
        return entry.senses[index].id
    }
}

/// Alla betydelser av ett ord. Tryck på en för att se synonymerna en och en.
final class SenseListViewController: UITableViewController {

    private let entry: WordEntry
    private let language: WordLanguage

    init(entry: WordEntry, language: WordLanguage) {
        self.entry = entry
        self.language = language
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = entry.lemma
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Ordkortet döljer menyraden. Listan har den, med tillbakapil.
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = CGSize(width: 360, height: min(max(tableView.contentSize.height, 120), 560))
        if preferredContentSize != size {
            preferredContentSize = size
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        entry.senses.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        [entry.posName, language == .english ? "förklaringar på engelska" : nil]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let sense = entry.senses[indexPath.row]
        var content = UIListContentConfiguration.subtitleCell()
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.numberOfLines = 0
        content.secondaryTextProperties.color = .secondaryLabel
        content.textToSecondaryTextVerticalPadding = 4
        let synonyms = WordText.synonymLine(sense)
        if let definition = sense.definition {
            content.text = "\(indexPath.row + 1). \(definition)"
            content.secondaryText = synonyms.isEmpty ? nil : "Liknande ord: \(synonyms)"
        } else {
            content.text = "\(indexPath.row + 1). \(synonyms)"
            if sense.id.isEmpty {
                content.secondaryText = "Betydelsen är inte angiven i källan."
            }
        }
        cell.contentConfiguration = content
        cell.accessoryType = sense.synonyms.isEmpty ? .none : .disclosureIndicator
        cell.selectionStyle = sense.synonyms.isEmpty ? .none : .default
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let sense = entry.senses[indexPath.row]
        guard !sense.synonyms.isEmpty else { return }
        navigationController?.pushViewController(SynonymListViewController(entry: entry, sense: sense, language: language),
                                                 animated: true)
    }
}

/// Synonymerna i en betydelse, en per rad. Tryck för att slå upp, svep åt vänster för Fel synonym.
final class SynonymListViewController: UITableViewController {

    private let entry: WordEntry
    private let sense: WordSense
    private let language: WordLanguage
    private var synonyms: [Synonym]

    init(entry: WordEntry, sense: WordSense, language: WordLanguage) {
        self.entry = entry
        self.sense = sense
        self.language = language
        self.synonyms = sense.synonyms
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = entry.lemma
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Ordkortet döljer menyraden. Listan har den, med tillbakapil.
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = CGSize(width: 360, height: min(max(tableView.contentSize.height, 120), 560))
        if preferredContentSize != size {
            preferredContentSize = size
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        synonyms.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sense.definition ?? "Liknande ord"
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "Vanliga ord först. Tryck på ett ord för att slå upp det. Svep åt vänster på ett ord som inte passar "
            + "för att dölja det. Det döljs bara i appen och kan visas igen under Om ordboken."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let synonym = synonyms[indexPath.row]
        var content = UIListContentConfiguration.valueCell()
        content.text = synonym.word
        var notes: [String] = []
        if let score = synonym.score {
            notes.append(Self.strength(score))
        }
        if synonym.isRare {
            notes.append("ovanligt")
        }
        content.secondaryText = notes.joined(separator: ", ")
        if synonym.isRare {
            content.textProperties.color = .secondaryLabel
        }
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    /// Synlex-betyget som ord: 3 till 5.
    private static func strength(_ score: Double) -> String {
        switch score {
        case 4.5...: return "mycket nära"
        case 3.8..<4.5: return "nära"
        default: return "ungefär"
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let word = synonyms[indexPath.row].word
        let lookup = WordDictionary.shared?.lookup(word, language: language, hidden: UserWords.shared.hiddenPairs)
        let context = WordPopupViewController.Context(sentence: "", rangeInSentence: nil, book: nil,
                                                      pageIndex: nil, triedWord: word)
        navigationController?.pushViewController(WordPopupViewController(lookup: lookup, context: context),
                                                 animated: true)
    }

    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let action = UIContextualAction(style: .destructive, title: "Fel synonym") { [weak self] _, _, done in
            self?.hide(at: indexPath)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [action])
    }

    override func tableView(_ tableView: UITableView,
                            contextMenuConfigurationForRowAt indexPath: IndexPath,
                            point: CGPoint) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(title: "Fel synonym", image: UIImage(systemName: "hand.thumbsdown"),
                         attributes: .destructive) { _ in
                    self?.hide(at: indexPath)
                },
            ])
        }
    }

    private func hide(at indexPath: IndexPath) {
        guard indexPath.row < synonyms.count else { return }
        let synonym = synonyms.remove(at: indexPath.row)
        UserWords.shared.hide(HiddenPair(language: language, lemma: entry.lemma, synonym: synonym.word))
        tableView.deleteRows(at: [indexPath], with: .automatic)
    }
}

private extension UIFont {
    func bold() -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(.traitBold) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }
}
