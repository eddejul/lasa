import SafariServices
import UIKit

/// Hur lång tid uppslagen tar, så att målet i specen (under 150 ms) går att följa på iPaden.
/// Visas under Om ordboken. Finns bara i minnet. Används bara från huvudtråden.
final class LookupStats {

    static let shared = LookupStats()

    private(set) var lookupMilliseconds: [Double] = []
    private(set) var readyMilliseconds: [Double] = []

    private init() {}

    /// `lookup`: att hitta ordet och slå upp det. `ready`: från trycket tills rutan är klar att visas.
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

/// Rutan som visas när man håller på ett ord: grundform, ordklass, synonymer per betydelse,
/// svensk översättning av engelska ord och en knapp till svenska.se.
final class WordPopupViewController: UITableViewController {

    /// Var uppslaget kommer ifrån. Ord ur texten sparas automatiskt, synonymer man bläddrar till sparas inte.
    struct Context {
        let sentence: String
        let rangeInSentence: NSRange?
        let book: String?
        let pageIndex: Int?
        /// Formerna som prövades, om ordet inte hittades (visas i meddelandet).
        let triedWord: String
    }

    private enum Row {
        case header(Int)
        case compound
        case translations(Int)
        case sense(Int, Int)
        case noSynonyms
        case notFound
        case svenskaSe
        case switchLanguage
        case unsave
        case about
    }

    private var lookup: WordLookup?
    private let context: Context
    private var sections: [[Row]] = []
    private var hiddenCount = 0
    var onReady: (() -> Void)?

    init(lookup: WordLookup?, context: Context) {
        self.lookup = lookup
        self.context = context
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
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
        tableView.sectionHeaderTopPadding = 6
        hiddenCount = UserWords.shared.hiddenPairs.count
        rebuild()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Har användaren dolt en synonym i listan ska den försvinna här också.
        if UserWords.shared.hiddenPairs.count != hiddenCount, let current = lookup {
            hiddenCount = UserWords.shared.hiddenPairs.count
            lookup = WordDictionary.shared?.lookup(current.word,
                                                   sentence: context.sentence,
                                                   rangeInSentence: context.rangeInSentence,
                                                   language: current.language,
                                                   hidden: UserWords.shared.hiddenPairs) ?? current
            rebuild()
        }
        onReady?()
        onReady = nil
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
        if let lookup = lookup, !lookup.isEmpty {
            for (index, entry) in lookup.entries.enumerated() {
                var rows: [Row] = [.header(index)]
                if index == 0, lookup.compound != nil {
                    rows.append(.compound)
                }
                if !entry.translations.isEmpty {
                    rows.append(.translations(index))
                }
                if entry.senses.isEmpty {
                    if entry.translations.isEmpty {
                        rows.append(.noSynonyms)
                    }
                } else {
                    rows += entry.senses.indices.map { .sense(index, $0) }
                }
                sections.append(rows)
            }
        } else {
            sections.append([.notFound])
        }

        var actions: [Row] = []
        let language = lookup?.language ?? .swedish
        if language == .swedish {
            actions.append(.svenskaSe)
        }
        if lookup?.otherLanguageAvailable == true {
            actions.append(.switchLanguage)
        }
        if context.book != nil, let lemma = lookup?.entries.first?.lemma,
           UserWords.shared.isSaved(lemma: lemma, language: language) {
            actions.append(.unsave)
        }
        actions.append(.about)
        sections.append(actions)
        tableView.reloadData()
    }

    // MARK: Tabellen

    override func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        cell.accessoryType = .none
        cell.selectionStyle = .default
        var content = UIListContentConfiguration.subtitleCell()
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.numberOfLines = 0

        switch sections[indexPath.section][indexPath.row] {
        case .header(let index):
            guard let lookup = lookup else { break }
            let entry = lookup.entries[index]
            content.text = entry.lemma
            content.textProperties.font = .preferredFont(forTextStyle: .title3).bold()
            var details = [entry.posName].filter { !$0.isEmpty }
            if WordDictionary.normalize(entry.lemma) != lookup.key, index == 0 || lookup.compound == nil {
                details.append(lookup.compound == nil ? "grundform till \(lookup.word)" : "efterled")
            }
            if index == 0 {
                details.append(lookup.language.name)
            }
            content.secondaryText = details.joined(separator: ", ")
            cell.selectionStyle = .none

        case .compound:
            if let compound = lookup?.compound {
                content.text = "\(compound.head) + \(compound.tail)"
                content.secondaryText = "Sammansatt ord som inte finns i ordboken. Efterledet visas."
            }
            cell.selectionStyle = .none

        case .translations(let index):
            guard let entry = lookup?.entries[index] else { break }
            content.text = entry.translations
                .map { $0.comment.isEmpty ? $0.text : "\($0.text) (\($0.comment))" }
                .joined(separator: ", ")
            content.secondaryText = "på svenska"
            cell.selectionStyle = .none

        case .sense(let index, let senseIndex):
            guard let entry = lookup?.entries[index] else { break }
            let sense = entry.senses[senseIndex]
            let number = entry.senses.count > 1 ? "\(senseIndex + 1). " : ""
            if sense.synonyms.isEmpty {
                content.text = number + (sense.definition ?? "")
                cell.selectionStyle = .none
            } else {
                content.text = number + sense.synonyms.map(\.word).joined(separator: ", ")
                content.secondaryText = sense.definition
                if sense.id.isEmpty, lookup?.language == .swedish {
                    content.secondaryText = "betydelsen är inte angiven i källan"
                }
                cell.accessoryType = .disclosureIndicator
            }

        case .noSynonyms:
            content.text = "Inga synonymer i ordboken."
            content.textProperties.color = .secondaryLabel
            cell.selectionStyle = .none

        case .notFound:
            content.text = "Hittade inte \(context.triedWord) i ordboken."
            content.secondaryText = "Ordet kan vara ett namn, ett ovanligt sammansatt ord eller felstavat i PDF:en."
            cell.selectionStyle = .none

        case .svenskaSe:
            content = UIListContentConfiguration.cell()
            content.text = "Visa i SO och SAOL"
            content.secondaryText = nil
            content.image = UIImage(systemName: "book")
            content.textProperties.color = view.tintColor

        case .switchLanguage:
            content = UIListContentConfiguration.cell()
            let other = (lookup?.language ?? .swedish).other
            content.text = "Visa som \(other.name)"
            content.image = UIImage(systemName: "globe")
            content.textProperties.color = view.tintColor

        case .unsave:
            content = UIListContentConfiguration.cell()
            content.text = "Ta bort från Sparade ord"
            content.image = UIImage(systemName: "bookmark.slash")
            content.textProperties.color = .systemRed

        case .about:
            content = UIListContentConfiguration.cell()
            content.text = "Om ordboken"
            content.image = UIImage(systemName: "info.circle")
            content.textProperties.color = view.tintColor
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == sections.count - 1, lookup?.language == .swedish || lookup == nil else { return nil }
        return "Ordet sparas i Sparade ord. Definitioner finns i Svenska Akademiens ordböcker på svenska.se."
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section][indexPath.row] {
        case .sense(let index, let senseIndex):
            guard let lookup = lookup else { return }
            let entry = lookup.entries[index]
            let sense = entry.senses[senseIndex]
            guard !sense.synonyms.isEmpty else { return }
            let list = SynonymListViewController(entry: entry, sense: sense, language: lookup.language)
            navigationController?.pushViewController(list, animated: true)

        case .svenskaSe:
            openSvenskaSe()

        case .switchLanguage:
            guard let current = lookup else { return }
            if let other = WordDictionary.shared?.lookup(current.word,
                                                         sentence: context.sentence,
                                                         rangeInSentence: context.rangeInSentence,
                                                         language: current.language.other,
                                                         hidden: UserWords.shared.hiddenPairs) {
                lookup = other
                rebuild()
            }

        case .unsave:
            if let lookup = lookup, let lemma = lookup.entries.first?.lemma {
                UserWords.shared.delete(lemma: lemma, language: lookup.language)
                rebuild()
            }

        case .about:
            navigationController?.pushViewController(AboutDictionaryViewController(), animated: true)

        default:
            break
        }
    }

    private func openSvenskaSe() {
        let word = lookup?.entries.first?.lemma ?? context.triedWord
        var components = URLComponents(string: "https://svenska.se/tre/")
        components?.queryItems = [URLQueryItem(name: "sok", value: word), URLQueryItem(name: "pz", value: "1")]
        guard let url = components?.url else { return }
        let safari = SFSafariViewController(url: url)
        safari.dismissButtonStyle = .close
        present(safari, animated: true)
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
        sense.definition
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "Tryck på en synonym för att slå upp den. Svep åt vänster på en synonym som inte passar för att "
            + "dölja den. Den döljs bara i appen och kan visas igen under Om ordboken."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let synonym = synonyms[indexPath.row]
        var content = UIListContentConfiguration.valueCell()
        content.text = synonym.word
        if let score = synonym.score {
            content.secondaryText = Self.strength(score)
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
