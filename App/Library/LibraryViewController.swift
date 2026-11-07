import UIKit
import UniformTypeIdentifiers

/// Startskärmen: listan med böcker.
final class LibraryViewController: UITableViewController, UIDocumentPickerDelegate {

    private static let cellID = "book"
    private var books: [Book] = []

    init() {
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Bibliotek"
        navigationItem.largeTitleDisplayMode = .always
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add,
                                                            target: self,
                                                            action: #selector(addTapped))
        let words = UIBarButtonItem(title: nil,
                                    image: UIImage(systemName: "character.book.closed"),
                                    primaryAction: nil,
                                    menu: UIMenu(children: [
                                        UIAction(title: "Sparade ord", image: UIImage(systemName: "bookmark")) { [weak self] _ in
                                            self?.navigationController?.pushViewController(SavedWordsViewController(),
                                                                                           animated: true)
                                        },
                                        UIAction(title: "Om ordboken", image: UIImage(systemName: "info.circle")) { [weak self] _ in
                                            self?.navigationController?.pushViewController(AboutDictionaryViewController(),
                                                                                           animated: true)
                                        },
                                    ]))
        words.accessibilityLabel = "Ordboken"
        navigationItem.leftBarButtonItem = words
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.cellID)
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    func reload() {
        books = LibraryStore.shared.allBooks()
        guard isViewLoaded else { return }
        tableView.reloadData()
        updateEmptyState()
    }

    // MARK: Öppna

    func open(_ book: Book) {
        switch book.kind {
        case .pdf:
            guard let reader = PDFCurlReaderViewController(book: book) else {
                showMessage(title: "Kunde inte öppna boken",
                            message: "Filen verkar vara skadad eller lösenordsskyddad.")
                return
            }
            navigationController?.pushViewController(reader, animated: true)
        case .epub, .text:
            showMessage(title: "Kommer snart",
                        message: "EPUB och textfiler kommer i fas 3. Just nu läser appen PDF.")
        case .other:
            showMessage(title: "Okänt format",
                        message: "Appen kan inte öppna den här filtypen.")
        }
    }

    func showMessage(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: Lägg till

    @objc private func addTapped() {
        var types: [UTType] = [.pdf, .plainText, .rtf, .html]
        if let epub = UTType(filenameExtension: "epub") {
            types.append(epub)
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        var failed: [String] = []
        for url in urls {
            do {
                try LibraryStore.shared.importFile(at: url)
            } catch {
                failed.append(url.lastPathComponent)
            }
        }
        reload()
        if !failed.isEmpty {
            showMessage(title: "Några filer kunde inte läggas till",
                        message: failed.joined(separator: "\n"))
        }
    }

    // MARK: Tabellen

    private func updateEmptyState() {
        guard books.isEmpty else {
            tableView.backgroundView = nil
            return
        }
        let label = UILabel()
        label.text = "Inga böcker än.\nTryck på + eller välj Öppna i Läsa från Filer."
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .body)
        tableView.backgroundView = label
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        books.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellID, for: indexPath)
        let book = books[indexPath.row]

        var content = cell.defaultContentConfiguration()
        content.text = book.title
        content.secondaryText = book.kindLabel
        content.secondaryTextProperties.color = .secondaryLabel
        content.image = UIImage(systemName: book.symbolName)
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        open(books[indexPath.row])
    }

    override func tableView(_ tableView: UITableView,
                            titleForDeleteConfirmationButtonForRowAt indexPath: IndexPath) -> String? {
        "Ta bort"
    }

    override func tableView(_ tableView: UITableView,
                            commit editingStyle: UITableViewCell.EditingStyle,
                            forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        let book = books[indexPath.row]
        do {
            try LibraryStore.shared.delete(book)
            books.remove(at: indexPath.row)
            tableView.deleteRows(at: [indexPath], with: .automatic)
            updateEmptyState()
        } catch {
            showMessage(title: "Kunde inte ta bort", message: error.localizedDescription)
        }
    }
}
