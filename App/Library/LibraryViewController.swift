import UIKit
import UniformTypeIdentifiers

/// Startskärmen (B1, B2): Fortsätt läsa överst och böckerna som ett rutnät med omslag, titel, författare och
/// hur långt man läst. Håll fingret på ett omslag för Byt namn, Välj omslag, Markera som läst och Ta bort.
final class LibraryViewController: UIViewController, UIDocumentPickerDelegate, UICollectionViewDataSource,
    UICollectionViewDelegate {

    private enum Section: Int, CaseIterable {
        case banner, activity, continueReading, books
    }

    private var collectionView: UICollectionView!
    /// Alla böcker som känns igen i Böcker (också för självtestet).
    private(set) var books: [Book] = []
    /// Alla böcker som biblioteket visar dem, och de som syns med filtret och sorteringen.
    private(set) var allItems: [ShelfItem] = []
    private(set) var items: [ShelfItem] = []
    private(set) var continueItem: ShelfItem?
    private var records: [String: BookRecord] = [:]
    private var didStartSelfTest = false

    private static let filterKey = "library.filter"
    private static let sortKey = "library.sort"

    private(set) var filter: LibraryFilter = LibraryFilter(
        rawValue: UserDefaults.standard.string(forKey: LibraryViewController.filterKey) ?? "") ?? .all
    private(set) var sort: LibrarySort = LibrarySort(
        rawValue: UserDefaults.standard.string(forKey: LibraryViewController.sortKey) ?? "") ?? .recent

    init() {
        super.init(nibName: nil, bundle: nil)
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
        let add = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addTapped))
        add.accessibilityLabel = "Lägg till böcker"
        navigationItem.rightBarButtonItems = [add, settings]
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

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: makeLayout())
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.alwaysBounceVertical = true
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(BookCell.self, forCellWithReuseIdentifier: BookCell.id)
        collectionView.register(ContinueCell.self, forCellWithReuseIdentifier: ContinueCell.id)
        collectionView.register(MessageCell.self, forCellWithReuseIdentifier: MessageCell.id)
        collectionView.register(BooksHeaderView.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                                withReuseIdentifier: BooksHeaderView.id)
        view.addSubview(collectionView)

        BookImporter.shared.onChange = { [weak self] in
            self?.updateActivity()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: Theme.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(coverUpdated), name: CoverStore.didUpdate,
                                               object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(memoryWarning),
                                               name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        applyTheme()
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyTheme()
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

    // MARK: Temat (U1)

    @objc private func themeChanged() {
        applyTheme()
        collectionView.reloadData()
    }

    /// Målar biblioteket i temats färger.
    func applyTheme() {
        guard isViewLoaded else { return }
        let palette = Theme.current
        view.backgroundColor = palette.canvas
        collectionView.backgroundColor = palette.canvas
        Theme.style(navigationController?.navigationBar)
    }

    @objc private func memoryWarning() {
        CoverStore.shared.releaseMemory()
    }

    // MARK: Böckerna

    func reload() {
        let scanned = LibraryStore.shared.scan()
        books = scanned.books
        guard isViewLoaded else { return }
        rebuildItems()
        collectionView.reloadData()
        updateEmptyState()
        resolvePending(scanned.pending, urls: scanned.urls)
        fillMissingHashes(scanned.books)
        prepareCovers()
    }

    /// Bygger om det som visas ur böckerna och registret, utan att läsa Böcker igen.
    private func rebuildItems() {
        records = Dictionary(BookRegistry.shared.records().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let books = showsEmptyForSelfTest ? [] : self.books
        allItems = books.map { book in
            ShelfItem(book: book, record: records[book.id],
                        lastRead: LibraryStore.shared.positionDate(for: book)?.timeIntervalSince1970 ?? 0)
        }
        continueItem = LibraryLogic.continueReading(allItems)
        items = LibraryLogic.sort(LibraryLogic.filter(allItems, filter), by: sort)
    }

    /// Titel, författare och omslag läses i bakgrunden, en bok i taget, i den ordning de syns.
    private func prepareCovers() {
        var seen = Set<String>()
        for item in items + allItems where !seen.contains(item.book.id) {
            seen.insert(item.book.id)
            guard let record = records[item.book.id] else { continue }
            _ = CoverStore.shared.image(for: item.book, record: record)
        }
    }

    private var coverReloadPending = false

    /// Ett omslag eller en titel är klar. Flera på rad slås ihop till en omritning.
    @objc private func coverUpdated() {
        guard !coverReloadPending else { return }
        coverReloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self else { return }
            self.coverReloadPending = false
            self.rebuildItems()
            self.collectionView.reloadData()
        }
    }

    private func coverContent(for item: ShelfItem) -> CoverView.Content {
        let record = records[item.book.id]
        if let image = CoverStore.shared.image(for: item.book, record: record) {
            return .image(image)
        }
        if item.book.kind == .text || CoverStore.shared.hasNoImage(record) {
            return .drawn
        }
        return .loading
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
            updateActivity(pendingCount: isResolving ? waiting.count : 0)
            return
        }
        isResolving = true
        updateActivity(pendingCount: waiting.count)
        Task { @MainActor [weak self] in
            let found = await BookRegistry.shared.resolve(waiting, urls: urls)
            guard let self = self else { return }
            self.isResolving = false
            self.questions.append(contentsOf: found.filter { new in
                !self.questions.contains { $0.file.path == new.file.path }
            })
            self.updateActivity(pendingCount: 0)
            self.reloadKnownBooks()
            self.askNextQuestion()
        }
    }

    /// Läser om listan utan att starta en ny inläsning.
    private func reloadKnownBooks() {
        books = LibraryStore.shared.scan().books
        rebuildItems()
        collectionView.reloadData()
        updateEmptyState()
        prepareCovers()
    }

    private var pendingCount = 0

    private func updateActivity(pendingCount: Int) {
        self.pendingCount = pendingCount
        updateActivity()
    }

    /// Raderna Lägger till Bok.pdf med förlopp (G10) och Läser in nya filer (G3).
    private var activityLines: [(text: String, progress: Double?)] {
        var lines: [(text: String, progress: Double?)] = []
        for job in BookImporter.shared.jobs {
            lines.append((text: "Lägger till \(job.name), \(Int((job.fraction * 100).rounded())) %",
                          progress: Optional(job.fraction)))
        }
        if pendingCount > 0 {
            lines.append((pendingCount == 1 ? "Läser in en ny fil" : "Läser in \(pendingCount) nya filer", nil))
        }
        return lines
    }

    private var shownActivityCount = 0

    private func updateActivity() {
        guard isViewLoaded else { return }
        let count = activityLines.isEmpty ? 0 : 1
        let section = Section.activity.rawValue
        if count == 1, shownActivityCount == 1,
           let cell = collectionView.cellForItem(at: IndexPath(item: 0, section: section)) as? MessageCell {
            configureActivity(cell)
            return
        }
        shownActivityCount = count
        UIView.performWithoutAnimation {
            collectionView.reloadSections(IndexSet(integer: section))
        }
    }

    private func configureActivity(_ cell: MessageCell) {
        let palette = Theme.current
        cell.configure(lines: activityLines, background: palette.surface, palette: palette)
    }

    /// Förloppet, till självtestet.
    var footerText: String {
        activityLines.map(\.text).joined(separator: " | ")
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

    /// En rad överst två dagar innan appen går ut: Sensus går ut torsdag kl. 14, förnya i Sideloadly.
    private var expiryText: String? {
        AppExpiry.warning()
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

    /// Lägger till en fil och öppnar den, för Öppna i Sensus från Filer eller en annan app (G10).
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

    // MARK: Tomt bibliotek

    private func updateEmptyState() {
        let palette = Theme.current
        guard items.isEmpty else {
            collectionView.backgroundView = nil
            return
        }
        let label = UILabel()
        if allItems.isEmpty {
            label.text = "Inga böcker än.\nTryck på + eller välj Öppna i Sensus från Filer."
        } else {
            label.text = "Inga böcker under \(filter.title)."
        }
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = palette.inkSoft
        label.font = .preferredFont(forTextStyle: .body)
        collectionView.backgroundView = label
    }

    // MARK: Rutnätet

    private var isNarrow: Bool {
        view.bounds.width < 500
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            guard let self = self, let section = Section(rawValue: index) else { return nil }
            let width = environment.container.effectiveContentSize.width
            let narrow = width < 500
            let margin: CGFloat = narrow ? 16 : 24
            let count = self.collectionView(self.collectionView, numberOfItemsInSection: index)
            let empty = NSCollectionLayoutSection(group: .vertical(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(1)),
                subitems: [NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                                                                      heightDimension: .absolute(1)))]))
            switch section {
            case .banner, .activity:
                guard count > 0 else { return empty }
                let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(56))
                let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
                let result = NSCollectionLayoutSection(group: group)
                result.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: margin, bottom: 8, trailing: margin)
                return result
            case .continueReading:
                guard count > 0 else { return empty }
                let height: CGFloat = narrow ? 190 : 210
                let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(height))
                let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
                let result = NSCollectionLayoutSection(group: group)
                result.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: margin, bottom: 16, trailing: margin)
                return result
            case .books:
                let landscape = self.view.bounds.width > self.view.bounds.height
                let columns = LibraryLogic.columns(width: width, landscape: landscape)
                let spacing: CGFloat = narrow ? 16 : 24
                let available = width - margin * 2
                let itemWidth = ((available - spacing * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down)
                let itemHeight = (itemWidth * 1.5).rounded() + BookCell.textHeight
                let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
                    widthDimension: .absolute(itemWidth), heightDimension: .absolute(itemHeight)))
                let group = NSCollectionLayoutGroup.horizontal(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                                       heightDimension: .absolute(itemHeight)),
                    subitem: item, count: columns)
                group.interItemSpacing = .fixed(spacing)
                let result = NSCollectionLayoutSection(group: group)
                result.interGroupSpacing = narrow ? 20 : 28
                result.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: margin, bottom: 32, trailing: margin)
                let header = NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                                       heightDimension: .absolute(BooksHeaderView.height(compact: width < 560))),
                    elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
                // Utan böcker visas ingen rubrik över rutnätet.
                result.boundarySupplementaryItems = self.allItems.isEmpty ? [] : [header]
                return result
            }
        }
    }

    func numberOfSections(in collectionView: UICollectionView) -> Int {
        Section.allCases.count
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        guard isViewLoaded else { return 0 }
        switch Section(rawValue: section) {
        case .banner: return expiryText == nil ? 0 : 1
        case .activity: return activityLines.isEmpty ? 0 : 1
        case .continueReading: return continueItem == nil ? 0 : 1
        case .books: return items.count
        case .none: return 0
        }
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let palette = Theme.current
        switch Section(rawValue: indexPath.section) {
        case .banner:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: MessageCell.id, for: indexPath) as! MessageCell
            cell.configure(lines: [(text: expiryText ?? "", progress: nil)],
                           background: palette.warning.withAlphaComponent(0.18),
                           palette: palette)
            return cell
        case .activity:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: MessageCell.id, for: indexPath) as! MessageCell
            shownActivityCount = 1
            configureActivity(cell)
            return cell
        case .continueReading:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ContinueCell.id,
                                                          for: indexPath) as! ContinueCell
            if let item = continueItem {
                cell.configure(item, cover: coverContent(for: item), stripe: nil, palette: palette)
                cell.onContinue = { [weak self] in
                    self?.open(item.book)
                }
            }
            return cell
        case .books, .none:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: BookCell.id, for: indexPath) as! BookCell
            if indexPath.item < items.count {
                let item = items[indexPath.item]
                cell.configure(item, cover: coverContent(for: item), stripe: nil, palette: palette)
            }
            return cell
        }
    }

    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String,
                        at indexPath: IndexPath) -> UICollectionReusableView {
        let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: BooksHeaderView.id,
                                                                     for: indexPath) as! BooksHeaderView
        header.configure(title: "Alla böcker", filter: filter, sort: sort, palette: Theme.current)
        header.onFilter = { [weak self] filter in
            self?.setFilter(filter)
        }
        header.onSort = { [weak self] sort in
            self?.setSort(sort)
        }
        return header
    }

    func setFilter(_ filter: LibraryFilter) {
        self.filter = filter
        UserDefaults.standard.set(filter.rawValue, forKey: Self.filterKey)
        rebuildItems()
        collectionView.reloadData()
        updateEmptyState()
    }

    func setSort(_ sort: LibrarySort) {
        self.sort = sort
        UserDefaults.standard.set(sort.rawValue, forKey: Self.sortKey)
        rebuildItems()
        collectionView.reloadData()
    }

    private func item(at indexPath: IndexPath) -> ShelfItem? {
        switch Section(rawValue: indexPath.section) {
        case .continueReading: return continueItem
        case .books: return indexPath.item < items.count ? items[indexPath.item] : nil
        default: return nil
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = item(at: indexPath) else { return }
        open(item.book)
    }

    // MARK: Självtestet

    /// Visar biblioteket som tomt, till självtestets bild.
    var showsEmptyForSelfTest = false

    var collectionViewForSelfTest: UICollectionView {
        collectionView
    }

    /// Hur många omslag som har bild, är ritade och fortfarande laddas.
    var coverSummary: (images: Int, drawn: Int, loading: Int) {
        var result = (images: 0, drawn: 0, loading: 0)
        for item in allItems {
            switch coverContent(for: item) {
            case .image: result.images += 1
            case .drawn: result.drawn += 1
            case .loading: result.loading += 1
            }
        }
        return result
    }

    // MARK: Hållmenyn (B1)

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath,
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard let item = item(at: indexPath) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.menu(for: item)
        }
    }

    /// Byt namn, Välj omslag (PDF), Markera som läst och Ta bort.
    func menu(for item: ShelfItem) -> UIMenu {
        let book = item.book
        var actions: [UIMenuElement] = [
            UIAction(title: "Byt namn", image: UIImage(systemName: "pencil")) { [weak self] _ in
                self?.rename(item)
            },
        ]
        if book.kind == .pdf {
            actions.append(UIAction(title: "Välj omslag", image: UIImage(systemName: "photo")) { [weak self] _ in
                self?.chooseCover(item)
            })
        }
        let finished = records[book.id]?.finished ?? false
        actions.append(UIAction(title: finished ? "Markera som oläst" : "Markera som läst",
                                image: UIImage(systemName: finished ? "circle" : "checkmark.circle")) { [weak self] _ in
            BookRegistry.shared.setFinished(id: book.id, !finished)
            self?.rebuildItems()
            self?.collectionView.reloadData()
            self?.updateEmptyState()
        })
        actions.append(UIAction(title: "Ta bort", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            self?.confirmDelete(item)
        })
        return UIMenu(title: item.title, children: actions)
    }

    private func rename(_ item: ShelfItem) {
        let record = records[item.book.id]
        let alert = UIAlertController(title: "Byt namn", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "Titel"
            field.text = item.title
            field.autocapitalizationType = .sentences
            field.clearButtonMode = .whileEditing
        }
        alert.addTextField { field in
            field.placeholder = "Författare"
            field.text = item.author
            field.autocapitalizationType = .words
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Avbryt", style: .cancel))
        if let record = record, !record.customTitle.isEmpty || !record.customAuthor.isEmpty {
            alert.addAction(UIAlertAction(title: "Bokens eget namn", style: .default) { [weak self] _ in
                BookRegistry.shared.rename(id: item.book.id, title: "", author: "")
                self?.reloadKnownBooks()
            })
        }
        alert.addAction(UIAlertAction(title: "Spara", style: .default) { [weak self, weak alert] _ in
            let title = BookFileReader.clean(alert?.textFields?.first?.text ?? "")
            let author = BookFileReader.clean(alert?.textFields?.last?.text ?? "")
            // Samma som bokens egna: ingen egen titel sparas, så att den följer filen.
            let ownTitle = record.map { $0.bookTitle.isEmpty ? BookRecord.cleanedTitle($0.title) : $0.bookTitle } ?? ""
            BookRegistry.shared.rename(id: item.book.id, title: title == ownTitle ? "" : title,
                                       author: author == (record?.author ?? "") ? "" : author)
            self?.reloadKnownBooks()
        })
        present(alert, animated: true)
    }

    private func chooseCover(_ item: ShelfItem) {
        guard let record = records[item.book.id] else { return }
        let picker = CoverPageViewController(book: item.book, selected: max(record.coverPage, 0)) { [weak self] page in
            if let old = BookRegistry.shared.record(id: item.book.id) {
                CoverStore.shared.forget(old)
            }
            BookRegistry.shared.setCoverPage(id: item.book.id, page: page)
            self?.reloadKnownBooks()
        }
        let navigation = NavigationController(rootViewController: picker)
        navigation.modalPresentationStyle = .formSheet
        present(navigation, animated: true)
    }

    private func confirmDelete(_ item: ShelfItem) {
        let alert = UIAlertController(title: "Ta bort \(item.title)?",
                                      message: "Filen tas bort ur Sensus. Markeringar, anteckningar och bokmärken sparas "
                                        + "och kommer tillbaka om du lägger in samma fil igen.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Avbryt", style: .cancel))
        alert.addAction(UIAlertAction(title: "Ta bort", style: .destructive) { [weak self] _ in
            self?.delete(item.book)
        })
        present(alert, animated: true)
    }

    /// Tar bort filen. Raden i registret står kvar med `missing = 1`, och markeringarna finns kvar.
    func delete(_ book: Book) {
        do {
            try LibraryStore.shared.delete(book)
            books.removeAll { $0.id == book.id }
            rebuildItems()
            collectionView.reloadData()
            updateEmptyState()
        } catch {
            showMessage(title: "Kunde inte ta bort", message: error.localizedDescription)
        }
    }
}
