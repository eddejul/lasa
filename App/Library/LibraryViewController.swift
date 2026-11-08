import UIKit
import UniformTypeIdentifiers

/// Startskärmen (B1, B2): Fortsätt läsa överst och böckerna som ett rutnät med omslag, titel, författare och
/// hur långt man läst. Håll fingret på ett omslag för Byt namn, Välj omslag, Markera som läst och Ta bort.
final class LibraryViewController: UIViewController, UIDocumentPickerDelegate, UICollectionViewDataSource,
    UICollectionViewDelegate, UISearchResultsUpdating, UITabBarDelegate, UINavigationControllerDelegate {

    private enum Section: Int, CaseIterable {
        case banner, activity, continueReading, more, books
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

    // B3: sidopanelen, kurserna och sökningen.
    let sidebar = LibrarySidebarViewController()
    private var sidebarButton: UIBarButtonItem!
    private let searchController = UISearchController(searchResultsController: nil)
    private(set) var scope: LibraryScope = .all
    private(set) var courses: [Course] = []
    private var searchText = ""
    private var reviewCount = 0
    private var savedCount = 0
    /// B5: kortet Gör mer med Sensus (läses i `reload`, nyckelringen ska inte läsas vid varje utläggning).
    private var showsMoreCard = false
    /// U9: på iPhone en flikrad längst ner i stället för sidopanelen.
    let phoneBar = UITabBar()

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
        // B3: kurserna och orden ligger i sidopanelen. I stående nås den med knappen uppe till vänster.
        sidebarButton = UIBarButtonItem(image: UIImage(systemName: "sidebar.left"), style: .plain,
                                        target: self, action: #selector(showSidebar))
        sidebarButton.accessibilityLabel = "Kurser och ord"
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Sök titel, författare, kurs"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: makeLayout())
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.alwaysBounceVertical = true
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(BookCell.self, forCellWithReuseIdentifier: BookCell.id)
        collectionView.register(ContinueCell.self, forCellWithReuseIdentifier: ContinueCell.id)
        collectionView.register(MessageCell.self, forCellWithReuseIdentifier: MessageCell.id)
        collectionView.register(MoreCell.self, forCellWithReuseIdentifier: MoreCell.id)
        collectionView.register(BooksHeaderView.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                                withReuseIdentifier: BooksHeaderView.id)
        view.addSubview(collectionView)
        configureSidebar(sidebar)
        addChild(sidebar)
        view.addSubview(sidebar.view)
        sidebar.didMove(toParent: self)
        phoneBar.items = [
            UITabBarItem(title: "Bibliotek", image: UIImage(systemName: "books.vertical"), tag: 0),
            UITabBarItem(title: "Kurser", image: UIImage(systemName: "graduationcap"), tag: 1),
            UITabBarItem(title: "Ord", image: UIImage(systemName: "character.book.closed"), tag: 2),
        ]
        phoneBar.selectedItem = phoneBar.items?.first
        phoneBar.delegate = self
        phoneBar.isHidden = true
        view.addSubview(phoneBar)

        BookImporter.shared.onChange = { [weak self] in
            self?.updateActivity()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: Theme.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(coverUpdated), name: CoverStore.didUpdate,
                                               object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(memoryWarning),
                                               name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(coursesChanged), name: CourseStore.didChange,
                                               object: nil)
        applyTheme()
        reload()
    }

    // MARK: Sidopanelen (B3)

    /// Sidopanelen ligger fast till vänster i liggande på iPad.
    var showsSidebar: Bool {
        view.bounds.width > view.bounds.height && view.bounds.width >= 700
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPanels()
    }

    private func layoutPanels() {
        let bounds = view.bounds
        if showsSidebar {
            let width = min(280, max(240, (bounds.width * 0.24).rounded()))
            sidebar.view.isHidden = false
            sidebar.view.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
            collectionView.frame = CGRect(x: width, y: 0, width: bounds.width - width, height: bounds.height)
            if navigationItem.leftBarButtonItem != nil {
                navigationItem.leftBarButtonItem = nil
            }
        } else {
            sidebar.view.isHidden = true
            collectionView.frame = bounds
            // U9: på iPhone nås kurserna och orden med flikraden längst ner.
            let item: UIBarButtonItem? = isNarrow ? nil : sidebarButton
            if navigationItem.leftBarButtonItem !== item {
                navigationItem.leftBarButtonItem = item
            }
        }
        phoneBar.isHidden = !isNarrow
        if isNarrow {
            let height = 49 + view.safeAreaInsets.bottom
            phoneBar.frame = CGRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)
            view.bringSubviewToFront(phoneBar)
        }
        let bottom: CGFloat = isNarrow ? 49 : 0
        if collectionView.contentInset.bottom != bottom {
            collectionView.contentInset.bottom = bottom
            collectionView.verticalScrollIndicatorInsets.bottom = bottom
        }
    }

    /// U9: Kurser och Ord i flikraden öppnar sidopanelen som ett ark i halv höjd.
    func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        if item.tag == 0 {
            setScope(.all)
        } else {
            showSidebar()
        }
        tabBar.selectedItem = tabBar.items?.first
    }

    private func configureSidebar(_ panel: LibrarySidebarViewController) {
        panel.onSelectScope = { [weak self, weak panel] scope in
            guard let self = self else { return }
            self.setScope(scope)
            if let panel = panel, panel !== self.sidebar {
                panel.dismiss(animated: true)
            }
        }
        panel.onReview = { [weak self] in
            self?.afterDismissingPanel { self?.navigationController?.pushViewController(WordReviewViewController(),
                                                                                         animated: true) }
        }
        panel.onSavedWords = { [weak self] in
            self?.afterDismissingPanel { self?.navigationController?.pushViewController(SavedWordsViewController(),
                                                                                         animated: true) }
        }
        panel.onAboutDictionary = { [weak self] in
            self?.afterDismissingPanel { self?.navigationController?.pushViewController(AboutDictionaryViewController(),
                                                                                         animated: true) }
        }
        panel.onNewCourse = { [weak self] in
            self?.afterDismissingPanel { self?.newCourse(adding: nil) }
        }
        panel.courseMenu = { [weak self] course in
            self?.menu(for: course)
        }
    }

    /// Stänger sidopanelen om den visas som ruta, och gör sedan `action`.
    private func afterDismissingPanel(_ action: @escaping () -> Void) {
        if presentedViewController is LibrarySidebarViewController {
            dismiss(animated: true, completion: action)
        } else {
            action()
        }
    }

    @objc private func showSidebar() {
        let panel = LibrarySidebarViewController()
        configureSidebar(panel)
        panel.update(courses: courses, counts: sidebarCounts, selected: scope)
        if isNarrow {
            // U9: ett ark i halv höjd som kan dras upp, inga rutor i smala vyer.
            panel.modalPresentationStyle = .pageSheet
            if let sheet = panel.sheetPresentationController {
                sheet.detents = [.medium(), .large()]
                sheet.prefersGrabberVisible = true
            }
        } else {
            panel.preferredContentSize = CGSize(width: 320, height: 600)
            panel.modalPresentationStyle = .popover
            panel.popoverPresentationController?.barButtonItem = sidebarButton
            panel.popoverPresentationController?.backgroundColor = Theme.current.surfaceSunk
        }
        present(panel, animated: true)
    }

    private var sidebarCounts: LibrarySidebarViewController.Counts {
        var counts = LibrarySidebarViewController.Counts()
        counts.all = allItems.count
        counts.reading = allItems.filter(\.isReading).count
        for course in courses {
            counts.courses[course.id] = allItems.filter { $0.courses.contains(course.id) }.count
        }
        counts.review = reviewCount
        counts.saved = savedCount
        return counts
    }

    func setScope(_ scope: LibraryScope) {
        self.scope = scope
        rebuildItems()
        collectionView.reloadData()
        updateEmptyState()
        collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: false)
    }

    @objc private func coursesChanged() {
        rebuildItems()
        collectionView.reloadData()
        updateEmptyState()
    }

    /// Rubriken över rutnätet: Alla böcker, Läser nu eller kursens namn.
    private var scopeTitle: String {
        switch scope {
        case .all: return "Alla böcker"
        case .reading: return "Läser nu"
        case .course(let id): return courses.first { $0.id == id }?.name ?? "Kurs"
        }
    }

    // MARK: Sökningen (B3)

    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        guard text != searchText else { return }
        searchText = text
        rebuildItems()
        collectionView.reloadData()
        updateEmptyState()
    }

    // MARK: Kurserna (B3)

    /// Ny kurs med ett namn. `book`: boken läggs i kursen direkt.
    func newCourse(adding book: Book?) {
        let alert = UIAlertController(title: "Ny kurs", message: book == nil ? nil : "Boken läggs i kursen.",
                                      preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "Till exempel RETA30"
            field.autocapitalizationType = .sentences
        }
        alert.addAction(UIAlertAction(title: "Avbryt", style: .cancel))
        alert.addAction(UIAlertAction(title: "Skapa", style: .default) { [weak alert] _ in
            let name = BookFileReader.clean(alert?.textFields?.first?.text ?? "")
            guard !name.isEmpty, let course = CourseStore.shared.create(name: name) else { return }
            if let book = book {
                CourseStore.shared.add(book: book.id, to: course.id)
            }
        })
        present(alert, animated: true)
    }

    /// Hållmenyn på en kurs i sidopanelen: Byt namn, Färg och Ta bort kurs.
    func menu(for course: Course) -> UIMenu {
        let colors = HighlightColor.allCases.map { color in
            UIAction(title: color.title, image: UIImage(systemName: "circle.fill")?
                        .withTintColor(color.solid, renderingMode: .alwaysOriginal),
                     state: course.color == color.rawValue ? .on : .off) { _ in
                CourseStore.shared.setColor(course.id, color: course.color == color.rawValue ? "" : color.rawValue)
            }
        }
        return UIMenu(title: course.name, children: [
            UIAction(title: "Byt namn", image: UIImage(systemName: "pencil")) { [weak self] _ in
                self?.afterDismissingPanel { self?.renameCourse(course) }
            },
            UIMenu(title: "Färg", image: UIImage(systemName: "paintpalette"), children: colors),
            UIAction(title: "Ta bort kurs", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.afterDismissingPanel { self?.confirmDeleteCourse(course) }
            },
        ])
    }

    private func renameCourse(_ course: Course) {
        let alert = UIAlertController(title: "Byt namn på kursen", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = course.name
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Avbryt", style: .cancel))
        alert.addAction(UIAlertAction(title: "Spara", style: .default) { [weak alert] _ in
            let name = BookFileReader.clean(alert?.textFields?.first?.text ?? "")
            guard !name.isEmpty else { return }
            CourseStore.shared.rename(course.id, to: name)
        })
        present(alert, animated: true)
    }

    private func confirmDeleteCourse(_ course: Course) {
        let message = course.folder.isEmpty
            ? "Böckerna ligger kvar i biblioteket."
            : "Böckerna och mappen \(course.folder) i Böcker ligger kvar. Kursen skapas inte igen av mappen."
        let alert = UIAlertController(title: "Ta bort kursen \(course.name)?", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Avbryt", style: .cancel))
        alert.addAction(UIAlertAction(title: "Ta bort", style: .destructive) { [weak self] _ in
            CourseStore.shared.delete(course.id)
            if self?.scope == .course(course.id) {
                self?.setScope(.all)
            }
        })
        present(alert, animated: true)
    }

    /// Lägg i kurs i hållmenyn: kurserna med bock, och Ny kurs.
    private func courseMenu(for item: ShelfItem) -> UIMenu {
        var children: [UIMenuElement] = courses.map { course -> UIMenuElement in
            let member = item.courses.contains(course.id)
            let byFolder = !course.folder.isEmpty
                && CourseLogic.topFolder(of: item.book.path)?.lowercased() == course.folder.lowercased()
            let action = UIAction(title: course.name, state: member ? .on : .off) { _ in
                if member {
                    CourseStore.shared.remove(book: item.book.id, from: course.id)
                } else {
                    CourseStore.shared.add(book: item.book.id, to: course.id)
                }
            }
            if byFolder {
                action.subtitle = "Ligger i mappen \(course.folder)"
                action.attributes = .disabled
            }
            return action
        }
        children.append(UIAction(title: "Ny kurs", image: UIImage(systemName: "plus")) { [weak self] _ in
            self?.newCourse(adding: item.book)
        })
        return UIMenu(title: "Lägg i kurs", image: UIImage(systemName: "graduationcap"), children: children)
    }

    /// Randen på omslaget: den första kursens färg.
    private func stripe(for item: ShelfItem) -> UIColor? {
        courses.first { item.courses.contains($0.id) && $0.tint != nil }?.tint
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.delegate = self
        applyTheme()
        reload()
    }

    // MARK: Öppningen från omslaget (U10)

    /// Omslaget som boken öppnas från, och boken som är öppen (för vägen tillbaka).
    private var openingCover: (image: UIImage?, frame: CGRect)?
    private var openedBookID: String?

    /// Omslagets bild och ruta i fönstret för en bok som syns: kortet Fortsätt läsa först, sedan rutnätet.
    private func visibleCover(for id: String) -> (image: UIImage?, frame: CGRect)? {
        collectionView.layoutIfNeeded()
        var paths: [IndexPath] = []
        if collectionView.numberOfItems(inSection: Section.continueReading.rawValue) > 0, continueItem?.book.id == id {
            paths.append(IndexPath(item: 0, section: Section.continueReading.rawValue))
        }
        if let index = items.firstIndex(where: { $0.book.id == id }) {
            paths.append(IndexPath(item: index, section: Section.books.rawValue))
        }
        for path in paths {
            let cell = collectionView.cellForItem(at: path)
            let cover = (cell as? BookCell)?.cover ?? (cell as? ContinueCell)?.cover
            guard let view = cover, view.window != nil else { continue }
            let frame = view.convert(view.bounds, to: nil)
            guard frame.intersects(collectionView.convert(collectionView.bounds, to: nil)) else { continue }
            return (view.snapshotImage(), frame)
        }
        return nil
    }

    func navigationController(_ navigationController: UINavigationController,
                              animationControllerFor operation: UINavigationController.Operation,
                              from fromVC: UIViewController,
                              to toVC: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        func isReader(_ controller: UIViewController) -> Bool {
            controller is PDFCurlReaderViewController || controller is ReflowReaderViewController
        }
        if operation == .push, fromVC === self, isReader(toVC) {
            let cover = openingCover
            openingCover = nil
            SelfTest.log("Öppningen (U10): \(cover == nil ? "toning" : "från omslaget")")
            return BookOpenTransition(opening: true, cover: cover?.image, coverFrame: cover?.frame)
        }
        if operation == .pop, toVC === self, isReader(fromVC), let id = openedBookID {
            return BookOpenTransition(opening: false, cover: nil, coverFrame: nil) { [weak self] in
                let found = self?.visibleCover(for: id)
                SelfTest.log("Tillbaka (U10): \(found == nil ? "toning" : "in i omslaget")")
                return (found?.image, found?.frame)
            }
        }
        return nil
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // B5: välkomstsidan, bara för en ny installation utan böcker eller data.
        if !SelfTest.isActive, presentedViewController == nil, Onboarding.shouldShowWelcome {
            showWelcome()
            return
        }
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

    // MARK: Första start (B5)

    func showWelcome() {
        let welcome = WelcomeViewController()
        welcome.modalPresentationStyle = .fullScreen
        welcome.onStart = { [weak self] in
            self?.openSampleBook()
        }
        present(welcome, animated: false)
    }

    /// Lägger exempelboken i biblioteket och öppnar den.
    func openSampleBook() {
        guard let url = Onboarding.writeSampleBook() else { return }
        // Finns det borttagna böcker i registret känns en ny fil igen först när kontrollsumman räknats.
        // Exempelboken är liten, så den räknas direkt och boken läggs in på en gång.
        var book = LibraryStore.shared.book(at: url)
        if book == nil, let hash = BookIdentity.hash(of: url) {
            book = LibraryStore.shared.registerFile(at: url, hash: hash)
        }
        reload()
        if let book = book {
            open(book)
        } else {
            AppLog.shared.write("Exempelboken kunde inte öppnas")
        }
    }

    private func explainFiles() {
        showMessage(title: "Öppna från Filer",
                    message: "I appen Filer: håll fingret på en bok, välj Dela och sedan Sensus. Du kan också lägga "
                        + "filer i På min iPad, Sensus, Böcker. En mapp där blir en kurs.")
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
        sidebar.applyTheme()
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = palette.canvas
        appearance.shadowColor = palette.rule
        phoneBar.standardAppearance = appearance
        if #available(iOS 15.0, *) {
            phoneBar.scrollEdgeAppearance = appearance
        }
        phoneBar.tintColor = palette.accent
        phoneBar.unselectedItemTintColor = palette.inkSoft
    }

    @objc private func memoryWarning() {
        CoverStore.shared.releaseMemory()
    }

    // MARK: Böckerna

    func reload() {
        let scanned = LibraryStore.shared.scan()
        books = scanned.books
        guard isViewLoaded else { return }
        if !showsEmptyForSelfTest {
            CourseStore.shared.addFolderCourses(for: books)
        }
        reviewCount = UserWords.shared.reviewCount()
        savedCount = UserWords.shared.savedWords().count
        showsMoreCard = Onboarding.showsMoreCard
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
        courses = CourseStore.shared.courses()
        let explicit = CourseStore.shared.membership()
        allItems = books.map { book in
            var item = ShelfItem(book: book, record: records[book.id],
                                 lastRead: LibraryStore.shared.positionDate(for: book)?.timeIntervalSince1970 ?? 0)
            item.courses = CourseLogic.courses(forPath: book.path, bookID: book.id, courses: courses, explicit: explicit)
            item.courseNames = courses.filter { item.courses.contains($0.id) }.map(\.name)
            return item
        }
        continueItem = LibraryLogic.continueReading(allItems)
        if case .course(let id) = scope, !courses.contains(where: { $0.id == id }) {
            scope = .all
        }
        var scoped = allItems
        switch scope {
        case .all: break
        case .reading: scoped = scoped.filter(\.isReading)
        case .course(let id): scoped = scoped.filter { $0.courses.contains(id) }
        }
        items = LibraryLogic.sort(LibraryLogic.search(LibraryLogic.filter(scoped, filter), searchText), by: sort)
        sidebar.update(courses: courses, counts: sidebarCounts, selected: scope)
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
        openedBookID = book.id
        if openingCover == nil {
            openingCover = visibleCover(for: book.id)
        }
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
        if allItems.isEmpty {
            // B5: tre vägar in.
            let empty = EmptyLibraryView(palette: palette)
            empty.onChoose = { [weak self] in self?.addTapped() }
            empty.onFiles = { [weak self] in self?.explainFiles() }
            empty.onSample = { [weak self] in self?.openSampleBook() }
            collectionView.backgroundView = empty
            return
        }
        let label = UILabel()
        if !searchText.isEmpty {
            label.text = "Inga böcker hittades för \(searchText)."
        } else {
            label.text = filter == .all ? "Inga böcker i \(scopeTitle) än.\nHåll fingret på en bok och välj Lägg i kurs."
                : "Inga böcker under \(filter.title) i \(scopeTitle)."
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
            case .more:
                guard count > 0 else { return empty }
                let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                                  heightDimension: .absolute(MoreCell.height + (narrow ? 30 : 0)))
                let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
                let result = NSCollectionLayoutSection(group: group)
                result.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: margin, bottom: 16, trailing: margin)
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
        case .continueReading: return continueItem == nil || scope != .all || !searchText.isEmpty ? 0 : 1
        case .more: return showsMoreCard && scope == .all && searchText.isEmpty && !allItems.isEmpty ? 1 : 0
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
                cell.configure(item, cover: coverContent(for: item), stripe: stripe(for: item), palette: palette)
                cell.onContinue = { [weak self] in
                    self?.open(item.book)
                }
            }
            return cell
        case .more:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: MoreCell.id, for: indexPath) as! MoreCell
            cell.configure(palette: palette)
            cell.onSetUp = { [weak self] in
                self?.navigationController?.pushViewController(SettingsViewController(), animated: true)
            }
            cell.onLater = { [weak self] in
                Onboarding.dismissMoreCard()
                self?.showsMoreCard = false
                self?.collectionView.reloadData()
            }
            return cell
        case .books, .none:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: BookCell.id, for: indexPath) as! BookCell
            if indexPath.item < items.count {
                let item = items[indexPath.item]
                cell.configure(item, cover: coverContent(for: item), stripe: stripe(for: item), palette: palette)
            }
            return cell
        }
    }

    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String,
                        at indexPath: IndexPath) -> UICollectionReusableView {
        let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: BooksHeaderView.id,
                                                                     for: indexPath) as! BooksHeaderView
        header.configure(title: scopeTitle, filter: filter, sort: sort, palette: Theme.current)
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
        actions.append(courseMenu(for: item))
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
