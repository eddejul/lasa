import UIKit

/// Färgernas egna namn (K1), till exempel Viktigt, Begrepp, Exempel och Fråga. Väljs en gång och gäller alla
/// böcker. Sparas i tabellen `meta` i markeringar.sqlite (finns sedan steg 2), så att de följer med i
/// säkerhetskopian utan ett nytt steg i trappan. Används bara från huvudtråden.
enum HighlightColorNames {

    private static func key(_ color: HighlightColor) -> String {
        "color_name." + color.rawValue
    }

    /// Namnet läsaren valt, eller nil.
    static func custom(_ color: HighlightColor) -> String? {
        var result: String?
        AnnotationStore.shared.readBooks { db in
            try db.query("SELECT value FROM meta WHERE key = ?", [key(color)]) { row in
                let value = row.string(0).trimmingCharacters(in: .whitespacesAndNewlines)
                result = value.isEmpty ? nil : value
            }
        }
        return result
    }

    /// Namnet som visas: läsarens eget, annars färgens (Gul, Grön, Blå, Rosa).
    static func name(_ color: HighlightColor) -> String {
        custom(color) ?? color.title
    }

    /// Alla fyra på en gång (en databasfråga), till listor och filter.
    static func all() -> [HighlightColor: String] {
        var result: [HighlightColor: String] = [:]
        AnnotationStore.shared.readBooks { db in
            try db.query("SELECT key, value FROM meta WHERE key LIKE 'color_name.%'") { row in
                let raw = String(row.string(0).dropFirst("color_name.".count))
                let value = row.string(1).trimmingCharacters(in: .whitespacesAndNewlines)
                if let color = HighlightColor(rawValue: raw), !value.isEmpty {
                    result[color] = value
                }
            }
        }
        for color in HighlightColor.allCases where result[color] == nil {
            result[color] = color.title
        }
        return result
    }

    static func save(_ names: [HighlightColor: String]) {
        AnnotationStore.shared.writeBooks("färgernas namn") { db in
            for color in HighlightColor.allCases {
                let value = (names[color] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                try db.execute("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                               [key(color), value == color.title ? "" : value])
            }
        }
        NotificationCenter.default.post(name: AnnotationStore.didChange, object: nil)
    }

    /// Rutan Namnge färgerna.
    @MainActor
    static func edit(from presenter: UIViewController, completion: @escaping () -> Void) {
        let current = all()
        let alert = UIAlertController(title: "Namnge färgerna",
                                      message: "Namnen blir filter i anteckningsboken och taggar i exporten. Tomt ger färgens namn.",
                                      preferredStyle: .alert)
        for color in HighlightColor.allCases {
            alert.addTextField { field in
                field.placeholder = color.title
                field.text = current[color] == color.title ? "" : current[color]
                field.autocapitalizationType = .sentences
                field.clearButtonMode = .whileEditing
            }
        }
        alert.addAction(UIAlertAction(title: "Avbryt", style: .cancel))
        alert.addAction(UIAlertAction(title: "Spara", style: .default) { [weak alert] _ in
            var names: [HighlightColor: String] = [:]
            for (index, color) in HighlightColor.allCases.enumerated() {
                let text = alert?.textFields?[safe: index]?.text ?? ""
                names[color] = text.isEmpty ? color.title : text
            }
            save(names)
            completion()
        })
        presenter.present(alert, animated: true)
    }
}

/// En rad i anteckningsboken: markeringen, boken, kapitlet och bokens sidnummer.
struct NotebookEntry: Equatable {
    let highlight: Highlight
    let bookID: String
    let bookTitle: String
    /// Kapitlet, eller tomt när det inte är känt.
    let chapter: String
    /// Bokens sidnummer (K2), eller nil i EPUB och text.
    let page: String?
    /// K12: en anteckning bredvid texten (till en sida eller ett kapitel), inte en markering. Texten ligger i
    /// `highlight.text`, och id:t börjar med `pageNotePrefix`.
    var isPageNote = false
    /// A2: en förklaring av kapitlet med egna ord. Förklaringen ligger i `highlight.text`, sammanfattningen av
    /// jämförelsen och svaret i `highlight.note`, och id:t börjar med `explanationPrefix`.
    var isExplanation = false

    static let pageNotePrefix = "sidanteckning:"
    static let explanationPrefix = "forklaring:"
}

/// Filter och gruppering i anteckningsboken (K1). Ren logik (G13).
enum NotebookLogic {

    struct Filter: Equatable {
        var colors: Set<HighlightColor> = []
        var notesOnly = false
        var query = ""
        /// Böckerna i den valda kursen, nil för alla.
        var books: Set<String>?
    }

    struct Group: Equatable {
        let title: String
        let entries: [NotebookEntry]
    }

    /// Raden under filtren: "3 markeringar och 1 anteckning", med filter "2 av 4: 2 markeringar".
    static func countText(shown: [NotebookEntry], all: [NotebookEntry]) -> String {
        func describe(_ list: [NotebookEntry]) -> String {
            let notes = list.filter(\.isPageNote).count
            let explanations = list.filter(\.isExplanation).count
            let marks = list.count - notes - explanations
            var text = marks == 1 ? "1 markering" : "\(marks) markeringar"
            if notes > 0 {
                text += notes == 1 ? " och 1 anteckning" : " och \(notes) anteckningar"
            }
            if explanations > 0 {
                text += explanations == 1 ? " och 1 förklaring" : " och \(explanations) förklaringar"
            }
            return text
        }
        return shown.count == all.count ? describe(all) : "\(shown.count) av \(all.count): " + describe(shown)
    }

    static func filter(_ entries: [NotebookEntry], _ filter: Filter) -> [NotebookEntry] {
        let query = FoldedText(filter.query.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).text as String
        return entries.filter { entry in
            if !filter.colors.isEmpty, entry.isPageNote || entry.isExplanation
                || !filter.colors.contains(entry.highlight.color) { return false }
            if filter.notesOnly, !entry.highlight.hasNote, !entry.isPageNote, !entry.isExplanation { return false }
            if let books = filter.books, !books.contains(entry.bookID) { return false }
            if !query.isEmpty {
                let haystack = FoldedText((entry.highlight.text + " " + entry.highlight.note + " " + entry.chapter) as NSString).text as String
                if !haystack.contains(query) { return false }
            }
            return true
        }
    }

    /// Grupperna i bokens ordning: per kapitel i en bok, per bok och kapitel för alla böcker.
    static func groups(_ entries: [NotebookEntry], allBooks: Bool) -> [Group] {
        var result: [(title: String, entries: [NotebookEntry])] = []
        for entry in entries {
            let title: String
            if allBooks {
                title = entry.chapter.isEmpty ? entry.bookTitle : "\(entry.bookTitle): \(entry.chapter)"
            } else {
                title = entry.chapter.isEmpty ? "Utan kapitel" : entry.chapter
            }
            if let last = result.last, last.title == title {
                result[result.count - 1].entries.append(entry)
            } else {
                result.append((title, [entry]))
            }
        }
        return result.map { Group(title: $0.title, entries: $0.entries) }
    }
}

/// Anteckningsboken (K1): markeringarna grupperade per kapitel som citat, anteckningen under och sidnumret
/// till höger. Filter för färg (med färgernas namn), kurs och bara med anteckning, och ett sökfält.
/// Finns per bok i läsarens Mer och för alla böcker i sidopanelen.
final class NotebookViewController: UITableViewController, UISearchResultsUpdating {

    enum Scope {
        /// En bok, med läsarens kapitel och sidnummer.
        case book(Book, chapter: (Highlight) -> String, page: (Highlight) -> String?)
        case all
    }

    /// Ett tryck på en markering (bara i en bok): läsaren går dit.
    var onSelect: ((Highlight) -> Void)?

    private let scope: Scope
    private var entries: [NotebookEntry] = []
    private var groups: [NotebookLogic.Group] = []
    private var filter = NotebookLogic.Filter()
    private var colorNames: [HighlightColor: String] = [:]
    private var courses: [Course] = []
    private let chips = UIStackView()
    private let countLabel = UILabel()
    private var observer: NSObjectProtocol?

    /// Antalet rader som syns, till självtestet.
    var visibleCount: Int {
        groups.reduce(0) { $0 + $1.entries.count }
    }

    /// Antalet förklaringar med egna ord (A2), till självtestet.
    var explanationCount: Int {
        entries.filter(\.isExplanation).count
    }

    init(scope: Scope) {
        self.scope = scope
        super.init(style: .insetGrouped)
        title = "Anteckningsbok"
        preferredContentSize = CGSize(width: 520, height: 700)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    deinit {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let palette = Theme.current
        tableView.backgroundColor = palette.canvas
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "entry")
        tableView.estimatedRowHeight = 80
        tableView.rowHeight = UITableView.automaticDimension
        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "Sök i markeringar och anteckningar"
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Klar", style: .done, target: self,
                                                           action: #selector(close))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: nil, image: UIImage(systemName: "ellipsis.circle"),
                                                            primaryAction: nil, menu: makeMenu())
        observer = NotificationCenter.default.addObserver(forName: AnnotationStore.didChange, object: nil,
                                                          queue: .main) { [weak self] _ in
            self?.load()
        }
        load()
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    private func makeMenu() -> UIMenu {
        var children: [UIMenuElement] = [
            UIAction(title: "Namnge färgerna", image: UIImage(systemName: "tag")) { [weak self] _ in
                guard let self = self else { return }
                HighlightColorNames.edit(from: self) { [weak self] in
                    self?.load()
                }
            },
        ]
        children.append(UIMenu(title: "Exportera till Anki", image: UIImage(systemName: "square.and.arrow.up"), children: [
            UIAction(title: "Markeringarna som syns (lucktext)") { [weak self] _ in
                guard let self = self else { return }
                AnkiExport.share(highlights: NotebookLogic.filter(self.entries, self.filter), includeWords: false,
                                 from: self, sourceItem: self.navigationItem.rightBarButtonItem)
            },
            UIAction(title: "Sparade ord") { [weak self] _ in
                guard let self = self else { return }
                AnkiExport.share(highlights: [], includeWords: true, from: self,
                                 sourceItem: self.navigationItem.rightBarButtonItem)
            },
        ]))
        if case .all = scope {
            let courseActions = [UIAction(title: "Alla kurser", state: filter.books == nil ? .on : .off) { [weak self] _ in
                self?.filter.books = nil
                self?.applyFilter()
            }] + courses.map { course in
                UIAction(title: course.name) { [weak self] _ in
                    self?.selectCourse(course)
                }
            }
            children.append(UIMenu(title: "Kurs", image: UIImage(systemName: "graduationcap"), children: courseActions))
        }
        return UIMenu(title: "", children: children)
    }

    private func selectCourse(_ course: Course) {
        let books = LibraryStore.shared.allBooks()
        let membership = CourseStore.shared.membership()
        let all = CourseStore.shared.courses()
        filter.books = Set(books.filter {
            CourseLogic.courses(forPath: $0.path, bookID: $0.id, courses: all, explicit: membership).contains(course.id)
        }.map(\.id))
        applyFilter()
    }

    /// Läser markeringarna. En bok: bokens markeringar. Alla böcker: varje bok i biblioteket, i titelordning.
    private func load() {
        colorNames = HighlightColorNames.all()
        switch scope {
        case let .book(book, chapter, page):
            var list = AnnotationStore.shared.highlights(book: book.id).map {
                NotebookEntry(highlight: $0, bookID: book.id, bookTitle: book.title, chapter: chapter($0), page: page($0))
            }
            // K12: anteckningarna bredvid texten, först på sin sida.
            for note in PageNoteStore.shared.notes(book: book.id) {
                let highlight = Highlight(id: NotebookEntry.pageNotePrefix + String(note.section), book: book.id,
                                          section: note.section, start: -1, length: 0, text: note.text, color: .yellow,
                                          note: "", created: note.updated, updated: note.updated)
                list.append(NotebookEntry(highlight: highlight, bookID: book.id, bookTitle: book.title,
                                          chapter: chapter(highlight), page: page(highlight), isPageNote: true))
            }
            // A2: förklaringarna med egna ord, först i sitt kapitel.
            for explanation in ChapterExplanationStore.shared.explanations(book: book.id) {
                let highlight = Highlight(id: NotebookEntry.explanationPrefix + explanation.id, book: book.id,
                                          section: explanation.section, start: -2, length: 0, text: explanation.text,
                                          color: .yellow, note: explanation.summary, created: explanation.created,
                                          updated: explanation.updated)
                let title = chapter(highlight)
                list.append(NotebookEntry(highlight: highlight, bookID: book.id, bookTitle: book.title,
                                          chapter: title.isEmpty ? explanation.chapter : title, page: page(highlight),
                                          isExplanation: true))
            }
            entries = list.sorted {
                ($0.highlight.section, $0.highlight.start) < ($1.highlight.section, $1.highlight.start)
            }
        case .all:
            courses = CourseStore.shared.courses()
            var result: [NotebookEntry] = []
            for book in LibraryStore.shared.allBooks() {
                let highlights = AnnotationStore.shared.highlights(book: book.id)
                guard !highlights.isEmpty else { continue }
                let record = BookRegistry.shared.record(id: book.id)
                let numbering = BookInfoStore.shared.numbering(for: book, pageCount: record?.pages ?? 0)
                let title = record?.displayTitle ?? book.title
                for highlight in highlights {
                    // D4-5: samma sidnumrering som läsaren, och ingen sida där den inte går att räkna fram.
                    let page = numbering?.citationPage(for: highlight.section, half: nil, pdfLabel: nil)
                    result.append(NotebookEntry(highlight: highlight, bookID: book.id, bookTitle: title,
                                                chapter: "", page: page))
                }
            }
            entries = result
            navigationItem.rightBarButtonItem?.menu = makeMenu()
        }
        buildChips()
        applyFilter()
    }

    private func applyFilter() {
        let shown = NotebookLogic.filter(entries, filter)
        if case .all = scope {
            groups = NotebookLogic.groups(shown, allBooks: true)
        } else {
            groups = NotebookLogic.groups(shown, allBooks: false)
        }
        countLabel.text = NotebookLogic.countText(shown: shown, all: entries)
        updateChips()
        navigationItem.rightBarButtonItem?.menu = makeMenu()
        tableView.reloadData()
        if entries.isEmpty {
            let label = UILabel()
            label.text = "Inga markeringar än.\nTryck på pennan i läsarens meny och dra över texten du vill markera."
            label.numberOfLines = 0
            label.textAlignment = .center
            label.textColor = Theme.current.inkSoft
            tableView.backgroundView = label
        } else {
            tableView.backgroundView = nil
        }
    }

    // MARK: Filtren

    private func buildChips() {
        for view in chips.arrangedSubviews {
            chips.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        chips.axis = .horizontal
        chips.spacing = 8
        for color in HighlightColor.allCases {
            chips.addArrangedSubview(chip(colorNames[color] ?? color.title, dot: color.solid) { [weak self] in
                guard let self = self else { return }
                if self.filter.colors.contains(color) {
                    self.filter.colors.remove(color)
                } else {
                    self.filter.colors.insert(color)
                }
                self.applyFilter()
            })
        }
        chips.addArrangedSubview(chip("Med anteckning", dot: nil) { [weak self] in
            self?.filter.notesOnly.toggle()
            self?.applyFilter()
        })
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        chips.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(chips)
        countLabel.font = .preferredFont(forTextStyle: .footnote)
        countLabel.textColor = Theme.current.inkSoft
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        let header = UIView(frame: CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 74))
        header.addSubview(scroll)
        header.addSubview(countLabel)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: header.topAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 36),
            chips.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            chips.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            chips.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            chips.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            chips.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            countLabel.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            countLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20),
        ])
        tableView.tableHeaderView = header
    }

    private func chip(_ title: String, dot: UIColor?, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.bordered()
        configuration.title = title
        configuration.cornerStyle = .capsule
        configuration.buttonSize = .small
        if let dot = dot {
            configuration.image = UIImage(systemName: "circle.fill")?.withTintColor(dot, renderingMode: .alwaysOriginal)
            configuration.imagePadding = 5
        }
        let button = UIButton(configuration: configuration)
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func updateChips() {
        let palette = Theme.current
        for (index, view) in chips.arrangedSubviews.enumerated() {
            guard let button = view as? UIButton, var configuration = button.configuration else { continue }
            let selected: Bool
            if index < HighlightColor.allCases.count {
                selected = filter.colors.contains(HighlightColor.allCases[index])
            } else {
                selected = filter.notesOnly
            }
            configuration.baseBackgroundColor = selected ? palette.accentSoft : palette.surfaceSunk
            configuration.baseForegroundColor = selected ? palette.accent : palette.ink
            button.configuration = configuration
            button.accessibilityTraits = selected ? [.button, .selected] : .button
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        filter.query = searchController.searchBar.text ?? ""
        applyFilter()
    }

    // MARK: Tabellen

    override func numberOfSections(in tableView: UITableView) -> Int {
        groups.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        groups[safe: section]?.title
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        groups[safe: section]?.entries.count ?? 0
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "entry", for: indexPath)
        guard let entry = groups[safe: indexPath.section]?.entries[safe: indexPath.row] else { return cell }
        let palette = Theme.current
        var content = UIListContentConfiguration.subtitleCell()
        content.text = "”\(Citation.cleanQuote(entry.highlight.text))”"
        content.textProperties.font = Theme.serif(.body)
        content.textProperties.color = palette.ink
        let colorName = entry.isExplanation ? "Min förklaring av kapitlet"
            : entry.isPageNote ? "Anteckning bredvid texten"
            : colorNames[entry.highlight.color] ?? entry.highlight.color.title
        if entry.isPageNote || entry.isExplanation {
            content.text = entry.highlight.text
            content.textProperties.font = .preferredFont(forTextStyle: .body)
        }
        if entry.isExplanation {
            content.textProperties.numberOfLines = 4
        }
        var detail = entry.highlight.hasNote ? entry.highlight.note : ""
        detail += (detail.isEmpty ? "" : "\n") + colorName
        content.secondaryText = detail
        content.secondaryTextProperties.color = palette.inkSoft
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)
        content.image = UIImage(systemName: entry.isExplanation ? "text.bubble"
                                    : entry.isPageNote ? "square.and.pencil" : "circle.fill")
        content.imageProperties.tintColor = entry.isPageNote || entry.isExplanation ? palette.inkSoft
            : entry.highlight.color.solid
        content.imageProperties.maximumSize = CGSize(width: 12, height: 12)
        content.textToSecondaryTextVerticalPadding = 6
        cell.contentConfiguration = content
        cell.backgroundColor = palette.surface
        if let page = entry.page {
            let label = UILabel()
            label.text = "s. \(page)"
            label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            label.textColor = palette.inkSoft
            label.sizeToFit()
            cell.accessoryView = label
        } else {
            cell.accessoryView = nil
        }
        cell.accessibilityLabel = "\(colorName). \(entry.highlight.text)" + (entry.page.map { ", sida \($0)" } ?? "")
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let entry = groups[safe: indexPath.section]?.entries[safe: indexPath.row] else { return }
        if entry.isExplanation {
            // A2: den sparade förklaringen med jämförelsen och svaret, utan nät.
            let id = String(entry.highlight.id.dropFirst(NotebookEntry.explanationPrefix.count))
            if let saved = ChapterExplanationStore.shared.explanation(id: id) {
                navigationController?.pushViewController(ChapterExplainViewController(saved: saved), animated: true)
            }
            return
        }
        if let onSelect = onSelect {
            dismiss(animated: true) {
                onSelect(entry.highlight)
            }
        }
    }

    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath,
                            point: CGPoint) -> UIContextMenuConfiguration? {
        guard let entry = groups[safe: indexPath.section]?.entries[safe: indexPath.row] else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            var children: [UIMenuElement] = [
                UIAction(title: "Kopiera", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = Citation.cleanQuote(entry.highlight.text)
                },
            ]
            if entry.isExplanation {
                let id = String(entry.highlight.id.dropFirst(NotebookEntry.explanationPrefix.count))
                children.append(UIAction(title: "Ta bort förklaringen", image: UIImage(systemName: "trash"),
                                         attributes: .destructive) { _ in
                    ChapterExplanationStore.shared.delete(id: id, book: entry.bookID)
                })
            }
            return UIMenu(title: "", children: children)
        }
    }

}
