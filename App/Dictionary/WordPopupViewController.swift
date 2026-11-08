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
}

/// Rutan som visas när man släpper ett ord man har hållit på.
///
/// Överst ett tydligt svar: för ett engelskt ord den svenska översättningen, för ett svenskt ord
/// betydelsen (när Folkets lexikon har en) med de vanligaste synonymerna. Övriga betydelser och
/// ordklasser finns bakom ett tryck.
final class WordPopupViewController: UITableViewController {

    /// Var uppslaget kommer ifrån. Ord ur texten sparas automatiskt, synonymer man bläddrar till sparas inte.
    struct Context {
        let sentence: String
        let rangeInSentence: NSRange?
        let book: String?
        let pageIndex: Int?
        /// Ordet som det stod, om det inte hittades (visas i meddelandet).
        let triedWord: String
    }

    private enum Row {
        case header
        case compound
        case translation
        case noTranslation
        case meaning
        case noContent
        case moreSenses
        case otherEntry(Int)
        case notFound
        case svenskaSe
        case switchLanguage
        case unsave
        case about
        /// AI-knappen (fas 6): knappen, väntan, svaret eller felet.
        case ai
    }

    private enum AIState {
        case idle
        case loading
        case done(WordExplanation)
        case failed(String)
    }

    private struct Section {
        let title: String?
        let rows: [Row]
        var footer: String? = nil
    }

    private var lookup: WordLookup?
    private let context: Context
    private var sections: [Section] = []
    private var hiddenCount = 0
    private var aiState = AIState.idle
    var onReady: (() -> Void)?
    /// Ordet som ska sparas i Sparade ord. Det sparas först när rutan syns, så att rutan inte väntar på disken.
    private var pendingSave: (word: String, lemma: String, language: WordLanguage)?

    init(lookup: WordLookup?, context: Context) {
        self.lookup = lookup
        self.context = context
        super.init(style: .insetGrouped)
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

    // MARK: Visa

    /// Visar rutan vid ordet: en popover på iPad, ett ark nerifrån på iPhone.
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
        if context.book != nil, let lookup = lookup, let lemma = lookup.entries.first?.lemma {
            popup.pendingSave = (lookup.word, lemma, lookup.language)
        }
        let navigation = WordPopupNavigationController(rootViewController: popup)
        navigation.onDismiss = onDismiss

        if presenter.traitCollection.userInterfaceIdiom == .pad {
            navigation.modalPresentationStyle = .popover
            if let popover = navigation.popoverPresentationController {
                popover.sourceView = sourceView
                popover.sourceRect = sourceRect
                popover.permittedArrowDirections = [.up, .down, .left, .right]
            }
        } else {
            navigation.modalPresentationStyle = .pageSheet
            if let sheet = navigation.sheetPresentationController {
                sheet.detents = [.medium(), .large()]
                sheet.prefersGrabberVisible = true
                sheet.prefersScrollingExpandsWhenScrolledToEdge = false
            }
            popup.navigationItem.rightBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .done, target: popup, action: #selector(WordPopupViewController.closeTapped))
        }
        presenter.present(navigation, animated: true)
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    // MARK: Livscykel

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        tableView.estimatedRowHeight = 44
        tableView.rowHeight = UITableView.automaticDimension
        tableView.sectionHeaderTopPadding = 4
        hiddenCount = UserWords.shared.hiddenPairs.count
        rebuild()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
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
                              sentence: context.sentence, book: book, pageIndex: context.pageIndex ?? 0)
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
        let height = min(max(tableView.contentSize.height, 120), 560)
        let size = CGSize(width: 360, height: height)
        if preferredContentSize != size {
            preferredContentSize = size
        }
    }

    private func rebuild() {
        title = lookup?.word ?? context.triedWord
        sections = []

        if let lookup = lookup, let entry = entry {
            var top: [Row] = [.header]
            if lookup.compound != nil {
                top.append(.compound)
            }
            sections.append(Section(title: nil, rows: top))

            if lookup.language == .english {
                sections.append(Section(title: "På svenska",
                                        rows: [entry.translations.isEmpty ? .noTranslation : .translation]))
            }
            if let first = entry.senses.first {
                var rows: [Row] = [.meaning]
                if entry.senses.count > 1 {
                    rows.append(.moreSenses)
                }
                let title: String
                if lookup.language == .english {
                    title = "Förklaring på engelska"
                } else {
                    title = first.definition == nil ? "Andra ord för det" : "Betydelse"
                }
                sections.append(Section(title: title, rows: rows))
            } else if entry.translations.isEmpty {
                sections.append(Section(title: nil, rows: [.noContent]))
            }
            if GeminiClient.isConfigured {
                sections.append(Section(title: "Förklaring med AI", rows: [.ai],
                                        footer: "Meningen och ordet skickas till Google Gemini."))
            }
            if lookup.entries.count > 1 {
                sections.append(Section(title: "Även som", rows: lookup.entries.indices.dropFirst().map { Row.otherEntry($0) }))
            }
        } else {
            sections.append(Section(title: nil, rows: [.notFound]))
        }

        var actions: [Row] = []
        if language == .swedish {
            actions.append(.svenskaSe)
        }
        if lookup?.otherLanguageAvailable == true {
            actions.append(.switchLanguage)
        }
        if context.book != nil, let lemma = entry?.lemma, isSaved(lemma: lemma) {
            actions.append(.unsave)
        }
        actions.append(.about)
        var footer: String?
        if context.book != nil, lookup != nil {
            footer = "Ordet är sparat i Sparade ord."
        }
        sections.append(Section(title: nil, rows: actions, footer: footer))
        tableView.reloadData()
    }

    // MARK: Tabellen

    override func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].rows.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].title
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        sections[section].footer
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        cell.accessoryType = .none
        cell.selectionStyle = .none
        var content = UIListContentConfiguration.subtitleCell()
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.numberOfLines = 0
        content.textToSecondaryTextVerticalPadding = 4

        switch sections[indexPath.section].rows[indexPath.row] {
        case .header:
            guard let lookup = lookup, let entry = entry else { break }
            content.text = entry.lemma
            content.textProperties.font = .preferredFont(forTextStyle: .title2).bold()
            var details = [entry.posName].filter { !$0.isEmpty }
            if lookup.compound != nil {
                details.append("efterled i \(lookup.word)")
            } else if WordDictionary.normalize(entry.lemma) != lookup.key {
                details.append("grundform till \(lookup.word)")
            }
            if lookup.language == .english {
                details.append("engelska")
            }
            content.secondaryText = details.joined(separator: ", ")

        case .compound:
            if let compound = lookup?.compound {
                content.text = "\(compound.head) + \(compound.tail)"
                content.secondaryText = "Sammansatt ord som inte finns i ordboken. Det visar efterledet."
            }

        case .translation:
            guard let entry = entry else { break }
            content.text = WordText.translationLine(entry)
            content.textProperties.font = .preferredFont(forTextStyle: .title3)
            if let via = entry.translationVia {
                content.secondaryText = "Ordet saknas i lexikonet. Översättningen gäller \(via), som betyder samma sak."
            }

        case .noTranslation:
            content.text = "Ingen svensk översättning i ordboken."
            content.textProperties.color = .secondaryLabel

        case .meaning:
            guard let sense = entry?.senses.first else { break }
            let synonyms = WordText.synonymLine(sense)
            if let definition = sense.definition {
                content.text = definition
                if !synonyms.isEmpty {
                    content.secondaryText = (language == .english ? "Liknande engelska ord: " : "Liknande ord: ") + synonyms
                }
            } else {
                content.text = synonyms
            }
            if !sense.synonyms.isEmpty {
                cell.accessoryType = .disclosureIndicator
                cell.selectionStyle = .default
            }

        case .noContent:
            content.text = "Ordboken har ingen betydelse eller synonym för ordet."
            content.textProperties.color = .secondaryLabel

        case .moreSenses:
            content = UIListContentConfiguration.cell()
            let count = (entry?.senses.count ?? 1) - 1
            content.text = count == 1 ? "1 betydelse till" : "\(count) betydelser till"
            content.textProperties.color = view.tintColor
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default

        case .otherEntry(let index):
            guard let other = lookup?.entries[index] else { break }
            content.text = [other.lemma, other.posName].filter { !$0.isEmpty }.joined(separator: ", ")
            content.secondaryText = WordText.summary(other)
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default

        case .notFound:
            content.text = "Hittade inte \(context.triedWord) i ordboken."
            content.secondaryText = "Ordet kan vara ett namn, ett ovanligt sammansatt ord eller felstavat i PDF:en."

        case .svenskaSe:
            content = actionContent("Visa i SO och SAOL", symbol: "book")
            cell.selectionStyle = .default

        case .switchLanguage:
            content = actionContent("Visa som \(language.other.name)", symbol: "globe")
            cell.selectionStyle = .default

        case .unsave:
            content = actionContent("Ta bort från Sparade ord", symbol: "bookmark.slash")
            content.textProperties.color = .systemRed
            cell.selectionStyle = .default

        case .about:
            content = actionContent("Om ordboken", symbol: "info.circle")
            cell.selectionStyle = .default

        case .ai:
            switch aiState {
            case .idle:
                content = actionContent("Förklara i meningen", symbol: "sparkles")
                cell.selectionStyle = .default
            case .loading:
                content = UIListContentConfiguration.cell()
                content.text = "Frågar Gemini …"
                content.textProperties.color = .secondaryLabel
                let spinner = UIActivityIndicatorView(style: .medium)
                spinner.startAnimating()
                cell.accessoryView = spinner
            case .done(let answer):
                content.text = answer.explanation
                var details: [String] = []
                if let best = answer.bestWord {
                    details.append("Passar bäst här: \(best)")
                }
                if let sense = answer.senseText {
                    details.append("Betydelsen i ordboken: \(sense)")
                }
                content.secondaryText = details.isEmpty ? nil : details.joined(separator: "\n")
            case .failed(let message):
                content.text = message
                content.textProperties.color = .systemRed
                content.secondaryText = "Tryck för att försöka igen."
                cell.selectionStyle = .default
            }
        }
        if case .ai = sections[indexPath.section].rows[indexPath.row], case .loading = aiState {
            // Snurran sattes ovan.
        } else {
            cell.accessoryView = nil
        }
        cell.contentConfiguration = content
        return cell
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
            self.rebuild()
        }
    }

    private func actionContent(_ title: String, symbol: String) -> UIListContentConfiguration {
        var content = UIListContentConfiguration.cell()
        content.text = title
        content.image = UIImage(systemName: symbol)
        content.textProperties.color = view.tintColor
        return content
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let lookup = lookup else {
            if case .about = sections[indexPath.section].rows[indexPath.row] {
                navigationController?.pushViewController(AboutDictionaryViewController(), animated: true)
            } else if case .svenskaSe = sections[indexPath.section].rows[indexPath.row] {
                openSvenskaSe()
            }
            return
        }
        switch sections[indexPath.section].rows[indexPath.row] {
        case .meaning:
            guard let entry = entry, let sense = entry.senses.first, !sense.synonyms.isEmpty else { return }
            navigationController?.pushViewController(
                SynonymListViewController(entry: entry, sense: sense, language: lookup.language), animated: true)

        case .moreSenses:
            guard let entry = entry else { return }
            navigationController?.pushViewController(
                SenseListViewController(entry: entry, language: lookup.language), animated: true)

        case .otherEntry(let index):
            let other = lookup.entries[index]
            let single = WordLookup(word: lookup.word, key: lookup.key, language: lookup.language, entries: [other],
                                    compound: lookup.compound, otherLanguageAvailable: false)
            let nextContext = Context(sentence: context.sentence, rangeInSentence: context.rangeInSentence,
                                      book: nil, pageIndex: nil, triedWord: lookup.word)
            navigationController?.pushViewController(WordPopupViewController(lookup: single, context: nextContext),
                                                     animated: true)

        case .svenskaSe:
            openSvenskaSe()

        case .switchLanguage:
            if let other = WordDictionary.shared?.lookup(lookup.word,
                                                         sentence: context.sentence,
                                                         rangeInSentence: context.rangeInSentence,
                                                         language: lookup.language.other,
                                                         hidden: UserWords.shared.hiddenPairs) {
                self.lookup = other
                aiState = .idle
                rebuild()
            }

        case .unsave:
            if let lemma = entry?.lemma {
                pendingSave = nil
                UserWords.shared.delete(lemma: lemma, language: lookup.language)
                rebuild()
            }

        case .about:
            navigationController?.pushViewController(AboutDictionaryViewController(), animated: true)

        case .ai:
            askAI()

        default:
            break
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
