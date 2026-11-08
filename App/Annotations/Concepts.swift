import UIKit

/// Ett begrepp i bokens begreppsregister (K8): termen, definitionen (bokens mening eller ens egen) och
/// markeringen det skapades från.
struct Concept: Equatable {
    let id: String
    let book: String
    var term: String
    var definition: String
    var highlight: String
    let created: Date
    var updated: Date
}

/// Begreppen i tabellen `concepts` i markeringar.sqlite (steg 9 i trappan, följer med i säkerhetskopian).
/// Inget raderas: borttaget får `deleted = 1`. Används bara från huvudtråden.
final class ConceptStore {

    static let shared = ConceptStore()

    private init() {}

    /// Bokens begrepp i bokstavsordning.
    func concepts(book: String) -> [Concept] {
        var result: [Concept] = []
        AnnotationStore.shared.readBooks { db in
            try db.query("""
                SELECT id, book, term, definition, highlight, created, updated FROM concepts
                WHERE book = ? AND deleted = 0
                """, [book]) { row in
                result.append(Concept(id: row.string(0), book: row.string(1), term: row.string(2),
                                      definition: row.string(3), highlight: row.string(4),
                                      created: Date(timeIntervalSince1970: row.double(5)),
                                      updated: Date(timeIntervalSince1970: row.double(6))))
            }
        }
        return ConceptLogic.sorted(result)
    }

    @discardableResult
    func add(book: String, term: String, definition: String, highlight: String) -> Concept {
        let now = Date()
        let concept = Concept(id: UUID().uuidString.lowercased(), book: book, term: term, definition: definition,
                              highlight: highlight, created: now, updated: now)
        save(concept)
        return concept
    }

    func save(_ concept: Concept) {
        AnnotationStore.shared.writeBooks("begreppet") { db in
            try db.execute("""
                INSERT INTO concepts (id, book, term, definition, highlight, created, updated, deleted)
                VALUES (?, ?, ?, ?, ?, ?, ?, 0)
                ON CONFLICT(id) DO UPDATE SET term = excluded.term, definition = excluded.definition,
                    updated = excluded.updated, deleted = 0
                """, [concept.id, concept.book, concept.term, concept.definition, concept.highlight,
                      concept.created.timeIntervalSince1970, Date().timeIntervalSince1970])
        }
        NotificationCenter.default.post(name: AnnotationStore.didChange, object: concept.book)
    }

    func delete(_ concept: Concept) {
        AnnotationStore.shared.writeBooks("borttagningen av begreppet") { db in
            try db.execute("UPDATE concepts SET deleted = 1, updated = ? WHERE id = ?",
                           [Date().timeIntervalSince1970, concept.id])
        }
        NotificationCenter.default.post(name: AnnotationStore.didChange, object: concept.book)
    }
}

/// Ren logik för begreppen (G13).
enum ConceptLogic {

    /// Termen ur en markering: kort text som den är, annars de första orden. Citattecken och skiljetecken bort.
    static func term(from text: String) -> String {
        let clean = Citation.cleanQuote(text).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?()[] "))
        let words = clean.split(separator: " ")
        return words.count <= 4 ? clean : words.prefix(4).joined(separator: " ")
    }

    /// Definitionen som föreslås: markeringens anteckning, annars markeringens text när den är längre än termen.
    static func suggestedDefinition(text: String, note: String, term: String) -> String {
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNote.isEmpty {
            return trimmedNote
        }
        let clean = Citation.cleanQuote(text)
        return clean == term ? "" : clean
    }

    static func sorted(_ concepts: [Concept]) -> [Concept] {
        concepts.sorted { $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending }
    }
}

/// Rutan Begrepp: term och definition. Används när ett begrepp skapas ur en markering och när det ändras.
@MainActor
enum ConceptEditor {

    static func present(title: String, term: String, definition: String, from presenter: UIViewController,
                        save: @escaping (String, String) -> Void) {
        let alert = UIAlertController(title: title,
                                      message: "Definitionen kan vara bokens mening eller din egen. Sensus letar upp alla förekomster i boken.",
                                      preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "Begrepp, till exempel ethos"
            field.text = term
            field.clearButtonMode = .whileEditing
        }
        alert.addTextField { field in
            field.placeholder = "Definition"
            field.text = definition
            field.clearButtonMode = .whileEditing
            field.autocapitalizationType = .sentences
        }
        alert.addAction(UIAlertAction(title: "Avbryt", style: .cancel))
        alert.addAction(UIAlertAction(title: "Spara", style: .default) { [weak alert] _ in
            let term = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let definition = alert?.textFields?.last?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !term.isEmpty else { return }
            save(term, definition)
        })
        presenter.present(alert, animated: true)
    }

    /// Skapar ett begrepp ur en markering (markeringsraden, knappen Begrepp).
    static func add(from highlight: Highlight, presenter: UIViewController) {
        let term = ConceptLogic.term(from: highlight.text)
        let definition = ConceptLogic.suggestedDefinition(text: highlight.text, note: highlight.note, term: term)
        present(title: "Nytt begrepp", term: term, definition: definition, from: presenter) { term, definition in
            ConceptStore.shared.add(book: highlight.book, term: term, definition: definition, highlight: highlight.id)
            AppLog.shared.write("K8: nytt begrepp")
        }
    }
}

/// Begreppsregistret för en bok (K8, första versionen): begrepp och definition i bokstavsordning. Ett tryck
/// söker efter begreppet i boken, och sökningens lista hoppar till varje träff. Ingen karta än.
final class ConceptsViewController: UITableViewController {

    /// Ett tryck på ett begrepp: läsaren stänger rutan och söker efter termen.
    var onSearch: ((String) -> Void)?

    private let book: Book
    private var concepts: [Concept] = []

    /// Antalet begrepp, till självtestet.
    var count: Int {
        concepts.count
    }

    init(book: Book) {
        self.book = book
        super.init(style: .insetGrouped)
        title = "Begrepp"
        preferredContentSize = CGSize(width: 460, height: 620)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = Theme.current.canvas
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "concept")
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Klar", style: .done, target: self, action: #selector(close))
        reload()
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    private func reload() {
        concepts = ConceptStore.shared.concepts(book: book.id)
        tableView.reloadData()
        if concepts.isEmpty {
            let label = UILabel()
            label.text = "Inga begrepp än.\nMarkera en term, tryck på markeringen och välj Begrepp."
            label.numberOfLines = 0
            label.textAlignment = .center
            label.textColor = Theme.current.inkSoft
            tableView.backgroundView = label
        } else {
            tableView.backgroundView = nil
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        concepts.count
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        concepts.isEmpty ? nil : "Tryck på ett begrepp för att se var det står i boken."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "concept", for: indexPath)
        guard let concept = concepts[safe: indexPath.row] else { return cell }
        let palette = Theme.current
        var content = UIListContentConfiguration.subtitleCell()
        content.text = concept.term
        content.textProperties.font = Theme.serif(.headline, size: 17, weight: .semibold)
        content.textProperties.color = palette.ink
        content.secondaryText = concept.definition.isEmpty ? "Ingen definition" : concept.definition
        content.secondaryTextProperties.color = palette.inkSoft
        content.textToSecondaryTextVerticalPadding = 4
        cell.contentConfiguration = content
        cell.backgroundColor = palette.surface
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let concept = concepts[safe: indexPath.row], let onSearch = onSearch else { return }
        dismiss(animated: true) {
            onSearch(concept.term)
        }
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
        -> UISwipeActionsConfiguration? {
        guard let concept = concepts[safe: indexPath.row] else { return nil }
        let delete = UIContextualAction(style: .destructive, title: "Ta bort") { [weak self] _, _, done in
            ConceptStore.shared.delete(concept)
            self?.reload()
            done(true)
        }
        let edit = UIContextualAction(style: .normal, title: "Ändra") { [weak self] _, _, done in
            guard let self = self else { return done(false) }
            ConceptEditor.present(title: "Ändra begrepp", term: concept.term, definition: concept.definition,
                                  from: self) { [weak self] term, definition in
                var changed = concept
                changed.term = term
                changed.definition = definition
                ConceptStore.shared.save(changed)
                self?.reload()
            }
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [delete, edit])
    }
}
