import UIKit

/// Sök i boken. Träffarna kommer medan sökningen pågår, grupperade per sida eller kapitel.
final class BookSearchViewController: UITableViewController, UISearchBarDelegate {

    /// Träffen man tryckte på, och söktexten.
    var onSelect: ((SearchHit, String) -> Void)?
    /// Den senaste söktexten, så att den finns kvar nästa gång rutan öppnas.
    var onQueryChange: ((String) -> Void)?

    private static let cellID = "hit"
    private let search: BookSearch
    private let sectionTitle: (Int) -> String
    private let searchBar = UISearchBar()
    private var query: String
    private var groups: [(section: Int, hits: [SearchHit])] = []
    private var total = 0
    private var isSearching = false
    private var debounce: Task<Void, Never>?

    init(search: BookSearch, query: String?, sectionTitle: @escaping (Int) -> String) {
        self.search = search
        self.query = query ?? ""
        self.sectionTitle = sectionTitle
        super.init(style: .plain)
        preferredContentSize = CGSize(width: 420, height: 640)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        searchBar.placeholder = "Sök i boken"
        searchBar.text = query
        searchBar.delegate = self
        searchBar.autocapitalizationType = .none
        searchBar.returnKeyType = .search
        searchBar.searchBarStyle = .minimal
        navigationItem.titleView = searchBar
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done,
                                                            target: self,
                                                            action: #selector(doneTapped))
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.cellID)
        tableView.keyboardDismissMode = .onDrag
        tableView.estimatedRowHeight = 60
        tableView.rowHeight = UITableView.automaticDimension
        if !query.isEmpty {
            run()
        } else {
            updateStatus()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if query.isEmpty {
            searchBar.becomeFirstResponder()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        debounce?.cancel()
    }

    /// Används av självtestet: sök direkt, utan tangentbordet.
    func searchNow(_ text: String) {
        query = text
        searchBar.text = text
        run()
    }

    var hitCount: Int {
        total
    }

    var searching: Bool {
        isSearching
    }

    var firstHit: SearchHit? {
        groups.first?.hits.first
    }

    @objc private func doneTapped() {
        search.cancel()
        dismiss(animated: true)
    }

    // MARK: Sökfältet

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        query = searchText
        onQueryChange?(searchText)
        debounce?.cancel()
        debounce = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self?.run()
        }
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        debounce?.cancel()
        searchBar.resignFirstResponder()
        run()
    }

    private func run() {
        let text = query
        guard FoldedText.query(text).count >= 2 else {
            search.cancel()
            groups = []
            total = 0
            isSearching = false
            tableView.reloadData()
            updateStatus()
            return
        }
        isSearching = true
        updateStatus()
        search.start(text) { [weak self] hits, done in
            guard let self = self, self.query == text else { return }
            self.show(hits)
            self.isSearching = !done
            self.updateStatus()
        }
    }

    private func show(_ hits: [SearchHit]) {
        var grouped: [(section: Int, hits: [SearchHit])] = []
        for hit in hits {
            if let last = grouped.last, last.section == hit.section {
                grouped[grouped.count - 1].hits.append(hit)
            } else {
                grouped.append((hit.section, [hit]))
            }
        }
        groups = grouped
        total = hits.count
        tableView.reloadData()
    }

    private func updateStatus() {
        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .footnote)
        if FoldedText.query(query).count < 2 {
            label.text = "Skriv minst två tecken."
        } else if isSearching {
            label.text = total == 0 ? "Söker …" : "Söker … \(total) träffar hittills"
        } else if total == 0 {
            label.text = "Inga träffar."
        } else if total >= BookSearch.maxHits {
            label.text = "Visar de första \(total) träffarna."
        } else {
            label.text = total == 1 ? "1 träff" : "\(total) träffar"
        }
        label.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 44)
        tableView.tableFooterView = label
    }

    // MARK: Tabellen

    override func numberOfSections(in tableView: UITableView) -> Int {
        groups.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sectionTitle(groups[section].section)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        groups[section].hits.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellID, for: indexPath)
        let hit = groups[indexPath.section].hits[indexPath.row]
        let font = UIFont.preferredFont(forTextStyle: .body)
        let text = NSMutableAttributedString(string: hit.snippet,
                                             attributes: [.font: font, .foregroundColor: UIColor.label])
        if NSMaxRange(hit.match) <= (hit.snippet as NSString).length {
            text.addAttributes([.font: font.withSymbolicTraits(.traitBold),
                                .backgroundColor: HighlightColor.yellow.solid.withAlphaComponent(0.35)],
                               range: hit.match)
        }
        var content = UIListContentConfiguration.cell()
        content.attributedText = text
        content.textProperties.numberOfLines = 3
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let hit = groups[indexPath.section].hits[indexPath.row]
        onSelect?(hit, query)
    }
}
