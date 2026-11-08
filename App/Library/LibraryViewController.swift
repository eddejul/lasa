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
        BookImporter.shared.onChange = { [weak self] in
            self?.updateFooter()
        }
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Bara i simulatortestet i bygget: öppna testboken direkt.
        askNextQuestion()
        guard let name = SelfTest.bookName, !didStartSelfTest else { return }
        didStartSelfTest = true
        if let summary = BookRegistry.shared.lastMigrationSummary {
            SelfTest.log("Flytten till bokens id vid starten: \(summary)")
        }
        SelfTest.log("Bokregistret: \(BookRegistry.shared.records().count) böcker, "
                     + "biblioteket visar \(books.count): \(books.map(\.path).joined(separator: ", "))")
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
        let scanned = LibraryStore.shared.scan()
        books = scanned.books
        guard isViewLoaded else { return }
        tableView.reloadData()
        updateEmptyState()
        updateExpiryBanner()
        resolvePending(scanned.pending, urls: scanned.urls)
        fillMissingHashes(scanned.books)
    }

    private static var didFillHashes = false

    /// Böcker från före G3 har ingen kontrollsumma i registret. Den räknas i bakgrunden en gång per start,
    /// så att en bok som sedan döps om eller flyttas känns igen på innehållet.
    private func fillMissingHashes(_ books: [Book]) {
        guard !Self.didFillHashes else { return }
        Self.didFillHashes = true
        let missing = books.filter { BookRegistry.shared.record(id: $0.id)?.sha256.isEmpty ?? false }
        guard !missing.isEmpty else { return }
        Task { @MainActor in
            let started = CACurrentMediaTime()
            let ids = await BookIdentity.ids(for: missing)
            AppLog.shared.write("Kontrollsumma räknad för \(ids.count) av \(missing.count) böcker på "
                                + "\(Int(((CACurrentMediaTime() - started) * 1000).rounded())) ms")
        }
    }

    // MARK: Nya och ändrade filer (G3)

    private var isResolving = false
    private var questions: [BookRegistry.VersionQuestion] = []

    /// Filer som inte känns igen direkt (nya, omdöpta, flyttade eller ändrade) får sin kontrollsumma räknad
    /// i bakgrunden. En ny version av en bok ger frågan om markeringarna ska behållas.
    private func resolvePending(_ pending: [BookFile], urls: [String: URL]) {
        let waiting = pending.filter { file in !questions.contains { $0.file.path == file.path } }
        guard !isResolving, !waiting.isEmpty else {
            updateFooter(pendingCount: isResolving ? waiting.count : 0)
            return
        }
        isResolving = true
        updateFooter(pendingCount: waiting.count)
        Task { @MainActor [weak self] in
            let found = await BookRegistry.shared.resolve(waiting, urls: urls)
            guard let self = self else { return }
            self.isResolving = false
            self.questions.append(contentsOf: found.filter { new in
                !self.questions.contains { $0.file.path == new.file.path }
            })
            self.updateFooter(pendingCount: 0)
            self.reloadKnownBooks()
            self.askNextQuestion()
        }
    }

    /// Läser om listan utan att starta en ny inläsning.
    private func reloadKnownBooks() {
        books = LibraryStore.shared.scan().books
        tableView.reloadData()
        updateEmptyState()
    }

    private var pendingCount = 0

    private func updateFooter(pendingCount: Int) {
        self.pendingCount = pendingCount
        updateFooter()
    }

    /// Raden under listan: Lägger till Bok.pdf med förlopp (G10), och Läser in nya filer (G3).
    private func updateFooter() {
        guard isViewLoaded else { return }
        let jobs = BookImporter.shared.jobs
        guard pendingCount > 0 || !jobs.isEmpty else {
            tableView.tableFooterView = nil
            return
        }
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20)
        for job in jobs {
            let label = UILabel()
            label.text = "Lägger till \(job.name), \(Int((job.fraction * 100).rounded())) %"
            label.font = .preferredFont(forTextStyle: .footnote)
            label.textColor = .secondaryLabel
            label.numberOfLines = 0
            let bar = UIProgressView(progressViewStyle: .default)
            bar.progress = Float(job.fraction)
            stack.addArrangedSubview(label)
            stack.addArrangedSubview(bar)
        }
        if pendingCount > 0 {
            let label = UILabel()
            label.text = pendingCount == 1 ? "Läser in en ny fil" : "Läser in \(pendingCount) nya filer"
            label.textAlignment = .center
            label.font = .preferredFont(forTextStyle: .footnote)
            label.textColor = .secondaryLabel
            stack.addArrangedSubview(label)
        }
        let width = tableView.bounds.width
        let height = stack.systemLayoutSizeFitting(CGSize(width: width, height: 0),
                                                   withHorizontalFittingPriority: .required,
                                                   verticalFittingPriority: .fittingSizeLevel).height
        stack.frame = CGRect(x: 0, y: 0, width: width, height: ceil(height))
        tableView.tableFooterView = stack
    }

    /// Raden med förloppet, till självtestet.
    var footerText: String {
        (tableView.tableFooterView?.subviews ?? []).compactMap { ($0 as? UILabel)?.text }.joined(separator: " | ")
    }

    /// Ny version av boken, behåll markeringarna? En fråga i taget.
    private func askNextQuestion() {
        guard presentedViewController == nil, navigationController?.topViewController === self,
              let question = questions.first else { return }
        let alert = UIAlertController(title: "Ny version av boken", message: question.message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Behåll markeringarna", style: .default) { [weak self] _ in
            self?.answer(question, keep: true)
        })
        alert.addAction(UIAlertAction(title: "Nej, börja om", style: .default) { [weak self] _ in
            self?.answer(question, keep: false)
        })
        present(alert, animated: true)
    }

    private func answer(_ question: BookRegistry.VersionQuestion, keep: Bool) {
        questions.removeAll { $0.file.path == question.file.path }
        BookRegistry.shared.answer(question, keep: keep)
        reloadKnownBooks()
        askNextQuestion()
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
        // Väljaren har redan kopierat filerna (asCopy), så de flyttas in i Böcker i bakgrunden (G10).
        BookImporter.shared.start(urls, move: true, presenter: self) { [weak self] _ in
            self?.reload()
        }
    }

    /// Lägger till en fil och öppnar den, för Öppna i Läsa från Filer eller en annan app (G10).
    func importAndOpen(_ url: URL, move: Bool) {
        BookImporter.shared.start([url], move: move, presenter: self) { [weak self] books in
            guard let self = self else { return }
            self.reload()
            if let book = books.first {
                self.navigationController?.popToRootViewController(animated: false)
                self.open(book)
            }
        }
    }

    // MARK: Tabellen

    private func updateEmptyState() {
        guard books.isEmpty else {
            tableView.backgroundView = nil
            return
        }
        let label = UILabel()
        label.text = "Inga böcker än.\nTryck på + eller välj Öppna i Sensus från Filer."
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
        // Böcker i undermappar (G3) visar mappen, till exempel PDF, RETA30.
        content.secondaryText = book.folder.map { "\(book.kindLabel), \($0)" } ?? book.kindLabel
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
