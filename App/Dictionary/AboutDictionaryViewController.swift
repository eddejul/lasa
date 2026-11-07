import SafariServices
import UIKit

/// Om ordboken: källor och licenser (som licenserna kräver), databasens innehåll, hur snabba
/// uppslagen är, och synonymer som har dolts med Fel synonym.
final class AboutDictionaryViewController: UITableViewController {

    private struct Source {
        let name: String
        let use: String
        let license: String
        let url: String
    }

    private let sources = [
        Source(name: "Folkets synonymlexikon (Synlex)",
               use: "Svenska synonympar med betyg. Bara par med betyg 3 eller högre på den femgradiga skalan visas.",
               license: "Copyright (c) Viggo Kann, KTH, 2009. Fri att använda och kopiera med upphovsnotisen kvar. "
                   + "Läsa använder en bearbetad version: paren är kopplade till betydelser och ordklasser.",
               url: "https://folkets-lexikon.csc.kth.se/synlex.html"),
        Source(name: "Swesaurus, Språkbanken Text, Göteborgs universitet",
               use: "Vilken betydelse en svensk synonym hör till.",
               license: "CC BY 4.0",
               url: "https://spraakbanken.gu.se/resurser/swesaurus"),
        Source(name: "SALDO och SALDO morfologi, Språkbanken Text, Göteborgs universitet",
               use: "Svenska grundformer, ordklasser, böjningsformer och betydelser.",
               license: "CC BY 4.0",
               url: "https://spraakbanken.gu.se/resurser/saldo"),
        Source(name: "Open English WordNet 2025",
               use: "Engelska betydelser, definitioner och synonymer.",
               license: "CC BY 4.0",
               url: "https://en-word.net"),
        Source(name: "Folkets lexikon, KTH",
               use: "Svensk översättning av engelska ord, och oregelbundna engelska böjningar.",
               license: "CC BY-SA 2.5. Den bearbetade versionen i Läsa delas under samma licens.",
               url: "https://folkets-lexikon.csc.kth.se/folkets/"),
    ]

    private enum Section: Int, CaseIterable {
        case database, speed, sources, academy, hidden
    }

    private var hidden: [HiddenPair] = []

    init() {
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Om ordboken"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        hidden = UserWords.shared.hiddenPairs.sorted { ($0.lemma, $0.synonym) < ($1.lemma, $1.synonym) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = CGSize(width: 360, height: 560)
        if preferredContentSize != size {
            preferredContentSize = size
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .database: return "Ordboken"
        case .speed: return "Hastighet"
        case .sources: return "Källor och licenser"
        case .academy: return "Svenska Akademien"
        case .hidden: return hidden.isEmpty ? nil : "Dolda synonymer"
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .hidden: return hidden.isEmpty ? nil : "Svep åt vänster för att visa en synonym igen."
        case .speed: return "Målet är att rutan ska vara klar på under 150 ms efter att ordet har känts igen."
        default: return nil
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .database: return 1
        case .speed: return 1
        case .sources: return sources.count
        case .academy: return 1
        case .hidden: return hidden.count
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var content = UIListContentConfiguration.subtitleCell()
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.numberOfLines = 0
        content.secondaryTextProperties.color = .secondaryLabel
        cell.accessoryType = .none
        cell.selectionStyle = .none

        switch Section(rawValue: indexPath.section)! {
        case .database:
            if let dictionary = WordDictionary.shared {
                let counts = dictionary.counts()
                let built = dictionary.meta["built"] ?? "okänt datum"
                content.text = "Byggd \(built)"
                content.secondaryText = "\(counts.swedishWords) svenska ord, \(counts.swedishPairs) svenska synonympar, "
                    + "\(counts.englishWords) engelska ord och \(counts.translations) översättningar till svenska. "
                    + "Allt finns i appen och fungerar utan internet."
            } else {
                content.text = "Ordboken saknas i den här versionen av appen."
            }

        case .speed:
            content.text = LookupStats.shared.summary ?? "Inga uppslag än i den här körningen."

        case .sources:
            let source = sources[indexPath.row]
            content.text = source.name
            content.secondaryText = "\(source.use)\nLicens: \(source.license)"
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default

        case .academy:
            content.text = "SO och SAOL"
            content.secondaryText = "Svenska Akademiens ordböcker har ingen öppen licens. Knappen Visa i SO och SAOL "
                + "öppnar svenska.se, och inget därifrån sparas i appen."

        case .hidden:
            let pair = hidden[indexPath.row]
            content.text = "\(pair.lemma): \(pair.synonym)"
            content.secondaryText = pair.language.name
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard Section(rawValue: indexPath.section) == .sources, let url = URL(string: sources[indexPath.row].url) else {
            return
        }
        present(SFSafariViewController(url: url), animated: true)
    }

    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard Section(rawValue: indexPath.section) == .hidden else { return nil }
        let action = UIContextualAction(style: .normal, title: "Visa igen") { [weak self] _, _, done in
            guard let self = self, indexPath.row < self.hidden.count else { return done(false) }
            UserWords.shared.unhide(self.hidden.remove(at: indexPath.row))
            tableView.deleteRows(at: [indexPath], with: .automatic)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [action])
    }
}
