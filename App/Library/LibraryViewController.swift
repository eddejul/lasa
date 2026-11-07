import UIKit
import UniformTypeIdentifiers

/// Startskärmen: listan med böcker.
final class LibraryViewController: UITableViewController, UIDocumentPickerDelegate {

    private static let cellID = "book"
    private var books: [Book] = []
    private var didStartSelfTest = false

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
        let settings = UIBarButtonItem(image: UIImage(systemName: "gearshape"), style: .plain,
                                       target: self, action: #selector(settingsTapped))
        settings.accessibilityLabel = "Inställningar"
        navigationItem.rightBarButtonItems = [UIBarButtonItem(barButtonSystemItem: .add,
                                                              target: self,
                                                              action: #selector(addTapped)),
                                              settings]
        let words = UIBarButtonItem(title: nil,
                                    image: UIImage(systemName: "character.book.closed"),
                                    primaryAction: nil,
                                    menu: UIMenu(children: [
                                        UIAction(title: "Sparade ord", image: UIImage(systemName: "bookmark")) { [weak self] _ in
                                            self?.navigationController?.pushViewController(SavedWordsViewController(),
                                                                                           animated: true)
                                        },
                                        UIAction(title: "Repetera ord", image: UIImage(systemName: "rectangle.stack")) { [weak self] _ in
                                            self?.navigationController?.pushViewController(WordReviewViewController(),
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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Bara i simulatortestet i bygget: öppna testboken direkt.
        guard let name = SelfTest.bookName, !didStartSelfTest else { return }
        didStartSelfTest = true
        if name == SelfTest.fas6Name {
            // Fas 6 utan bok: repetition, inställningar, AI-svaret och synken mot en låtsasserver.
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                await Fas6SelfTest.run(from: self)
            }
            return
        }
        if let book = books.first(where: { $0.url.lastPathComponent == name }) {
            open(book)
        } else {
            SelfTest.log("FEL: hittade inte \(name) i biblioteket")
            SelfTest.finish()
        }
    }

    func reload() {
        books = LibraryStore.shared.allBooks()
        guard isViewLoaded else { return }
        tableView.reloadData()
        updateEmptyState()
        updateExpiryBanner()
    }

    // MARK: Appen går ut (G1)

    private var expiryText: String?

    /// En rad överst två dagar innan appen går ut: Läsa går ut torsdag kl. 14, förnya i Sideloadly.
    private func updateExpiryBanner() {
        let text = AppExpiry.warning()
        guard text != expiryText || (text != nil && tableView.tableHeaderView == nil) else { return }
        expiryText = text
        guard let text = text else {
            tableView.tableHeaderView = nil
            return
        }
        let label = PaddedLabel()
        label.insets = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        label.text = text
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .label
        label.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.18)
        label.layer.cornerRadius = 12
        label.layer.masksToBounds = true
        label.accessibilityTraits = .staticText
        let container = UIView()
        container.addSubview(label)
        tableView.tableHeaderView = container
        layoutExpiryBanner()
    }

    private func layoutExpiryBanner() {
        guard let container = tableView.tableHeaderView, let label = container.subviews.first as? UILabel else { return }
        let width = tableView.bounds.width
        let side = max(tableView.layoutMargins.left, 16)
        let labelWidth = max(width - side * 2, 100)
        let height = label.sizeThatFits(CGSize(width: labelWidth, height: .greatestFiniteMagnitude)).height
        label.frame = CGRect(x: side, y: 8, width: labelWidth, height: ceil(height))
        let total = ceil(height) + 12
        if container.frame.width != width || container.frame.height != total {
            container.frame = CGRect(x: 0, y: 0, width: width, height: total)
            tableView.tableHeaderView = container
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutExpiryBanner()
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
            navigationController?.pushViewController(ReflowReaderViewController(book: book), animated: true)
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

    @objc private func settingsTapped() {
        navigationController?.pushViewController(SettingsViewController(), animated: true)
    }

    // MARK: Lägg till

    @objc private func addTapped() {
        var types: [UTType] = [.pdf, .plainText, .rtf, .html]
        if let epub = UTType(filenameExtension: "epub") {
            types.append(epub)
        }
        if let markdown = UTType(filenameExtension: "md", conformingTo: .plainText) {
            types.append(markdown)
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
