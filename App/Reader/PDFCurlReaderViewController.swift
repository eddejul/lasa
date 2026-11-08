import PDFKit
import UIKit

/// PDF-läsaren med pappersvikning, som i Apple Books.
///
/// Stående: en sida i taget med ryggen till vänster. Liggande på iPad: ett uppslag med ryggen i mitten,
/// där omslaget ligger ensamt till höger som i en tryckt bok.
/// Tryck i kanterna eller dra för att bläddra. Tryck i mitten för menyn, dubbeltryck i mitten för att zooma.
/// Håll fingret på ett ord för att slå upp det i ordboken.
final class PDFCurlReaderViewController: UIViewController {

    /// Hur länge fingret ska ligga still på ett ord innan det slås upp.
    static let wordPressDuration = WordPressGesture.duration

    private enum Mode: Equatable {
        case single, spread
    }

    private let book: Book
    /// Läsarens dokument: innehåll, sidnummer och zoom. Renderaren har ett eget.
    private let document: PDFDocument
    private let renderer: PDFPageRenderer

    private var pageController: UIPageViewController?
    private var mode: Mode = .single
    private var theme = ReaderTheme.effective

    /// Sidan man läser. I ett uppslag en av de två sidorna som syns.
    private var currentIndex: Int
    /// Menyraden, gemensam med EPUB-läsaren (G12).
    private lazy var chrome: ReaderChrome = {
        return ReaderChrome(controller: self, bottomBar: bottomBar, readerItem: nil, theme: theme,
                            actions: .init(contents: #selector(showContents), search: #selector(showSearch),
                                           mark: #selector(toggleMarkMode), bookmark: #selector(toggleBookmark),
                                           goToPage: #selector(showGoToPage), zoom: #selector(zoomCurrentPage)),
                            onTheme: { [weak self] option in self?.setTheme(option) })
    }()

    private var chromeHidden: Bool {
        chrome.isHidden
    }

    private let bottomBar = ReaderBottomBar()
    private var chromeTap: UITapGestureRecognizer?
    private var zoomTap: UITapGestureRecognizer?
    /// Trycket på bokmärkesbandet i sidans hörn (U3).
    private var ribbonTap: UITapGestureRecognizer?
    private var wordPress: UILongPressGestureRecognizer?
    private var pressedWord: PressedWord?
    /// Markeringsradens ruta senast den visades (U5), till självtestet.
    private var lastMarkMenuAnchor: CGRect?
    /// Bubblan ovanför fingret när ett ord hålls (G12, gemensam med den andra läsaren).
    private lazy var wordBubble = WordBubble(host: view)

    private var contentsItem: UIBarButtonItem? {
        chrome.contentsItem
    }

    private var lastLayoutSize: CGSize = .zero
    private var seenTopInset: CGFloat = 0
    private var contentInsets: UIEdgeInsets = .zero

    // Fas 4: markeringar, anteckningar, bokmärken och sökning. Koden ligger sist i filen.
    /// Markeringsläget, gemensamt med EPUB-läsaren (G12). Skapas när gesterna läggs in.
    private var marking: MarkMode?
    private var markMode: Bool {
        marking?.isOn ?? false
    }

    private var markDrag: UILongPressGestureRecognizer? {
        marking?.drag
    }

    private var markTap: UITapGestureRecognizer? {
        marking?.tap
    }

    private var markBar: HighlightModeBar? {
        marking?.bar
    }
    private var markSelection: PDFMarkSelection?
    private var marksCache: [Int: [PDFPageViewController.Mark]] = [:]
    /// Bokens markeringar per sida, inlästa en gång (G6), så att en sida som viks fram inte frågar databasen.
    private var highlightsByPage: [Int: [Highlight]]?
    /// Sidor vars saknade rutor räknas på renderingskön just nu.
    private var rectsInFlight = Set<Int>()
    /// Markeringar vars text inte gick att hitta på sidan. De räknas inte om igen under besöket.
    private var unplaceable = Set<String>()
    /// Hur lång tid det tog att förbereda markeringarna när en sida viktes fram, till självtestet (G6).
    private(set) var markSetupTimes: [Double] = []
    /// Punkten i sidans koordinater där ordet under fingret senast togs fram (G6).
    private var lastWordProbe: CGPoint?
    /// Hur många gånger ordet under fingret togs fram och hur många gånger det kunde hoppas över (G6).
    private(set) var wordProbes = 0
    private(set) var skippedWordProbes = 0
    private var bookmarks: [Bookmark] = []
    private var bookmarkedPages: Set<Int> = []
    private var searchItem: UIBarButtonItem? {
        chrome.searchItem
    }

    private var markItem: UIBarButtonItem? {
        chrome.markItem
    }

    private var bookmarkItem: UIBarButtonItem? {
        chrome.bookmarkItem
    }
    /// Bokens nyckel i sökregistret (G11).
    private lazy var searchKey = SearchIndex.Key.make(for: book, chapters: nil)
    private lazy var bookSearch = BookSearch(source: .pdf(book.url), index: searchKey)
    private var lastQuery: String?
    private var selfTestStarted = false

    init?(book: Book) {
        guard let document = PDFDocument(url: book.url),
              !document.isLocked,
              document.pageCount > 0,
              let renderer = PDFPageRenderer(url: book.url, pageCount: document.pageCount,
                                             cacheKey: Self.diskCacheKey(for: book)) else {
            return nil
        }
        self.book = book
        self.document = document
        self.renderer = renderer
        let saved = LibraryStore.shared.savedPageIndex(for: book)
        self.currentIndex = min(max(saved, 0), document.pageCount - 1)
        super.init(nibName: nil, bundle: nil)
        title = book.title
        navigationItem.largeTitleDisplayMode = .never
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    override var prefersStatusBarHidden: Bool {
        chromeHidden
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        theme.isDark ? .lightContent : .darkContent
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = theme.paperColor
        NotificationCenter.default.addObserver(self, selector: #selector(appThemeChanged), name: Theme.didChange,
                                               object: nil)
        setUpNavigationBar()
        setUpBottomBar()
        setUpTaps()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyThemeToChrome()
    }

    /// När boken öppnades och när första sidbilden kom, till loggen (G4).
    private let openedAt = CACurrentMediaTime()
    private var loggedFirstPage = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !loggedFirstPage {
            AppLog.shared.write("Öppnade \(book.url.lastPathComponent) (PDF, \(document.pageCount) sidor)")
            logFirstPage()
            // Sökregistret byggs i bakgrunden om det saknas, när de första sidorna hunnit ritas.
            SearchIndex.shared.prepare(searchKey, source: .pdf(book.url), delay: 4)
        }
        PageTurnSound.shared.prepare()
        WordDictionary.warmUpLanguageModels()
        startSelfTestIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard isMovingFromParent else { return }
        AppLog.shared.write("Stängde \(book.url.lastPathComponent): \(renderer.statsSummary) Appen använder "
                            + String(format: "%.0f MB.", MemoryUsage.megabytes))
        SyncEngine.shared.syncSoon()
        if chromeHidden {
            navigationController?.setNavigationBarHidden(false, animated: animated)
        }
        navigationController?.overrideUserInterfaceStyle = .unspecified
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateLayoutIfNeeded()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        bookSearch.releaseMemory()
    }

    /// Väntar på första sidbilden och skriver tiden i loggen.
    private func logFirstPage() {
        loggedFirstPage = true
        Task { @MainActor [weak self] in
            for _ in 0..<200 {
                guard let self = self else { return }
                if self.visiblePages.contains(where: { $0.imageFrame != nil }) {
                    let milliseconds = Int(((CACurrentMediaTime() - self.openedAt) * 1000).rounded())
                    AppLog.shared.write("Första sidan syntes efter \(milliseconds) ms")
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    // MARK: Layout och läge

    /// Byter mellan en sida och uppslag, och ritar om när storleken ändras.
    /// Att menyn visas eller döljs ändrar ingenting här, så sidan står still.
    private func updateLayoutIfNeeded() {
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }

        let insets = stableInsets(for: size)
        let newMode = preferredMode(for: size)
        let changed = size != lastLayoutSize || insets != contentInsets
        guard changed || pageController == nil else { return }

        lastLayoutSize = size
        contentInsets = insets
        renderer.configure(size: renderSize(for: size, mode: newMode), scale: displayScale, theme: theme)

        if newMode != mode || pageController == nil {
            mode = newMode
            installPageController()
        } else {
            refreshVisiblePages()
        }
        updatePageLabel()
        keepNeighbours()
    }

    /// Marginalerna runt sidan. De följer skärmens hörn och kanter, men inte menyraden eller statusfältet.
    /// Överkanten får alltid plats för statusfältet, så att sidan inte hoppar när det visas eller döljs.
    private func stableInsets(for size: CGSize) -> UIEdgeInsets {
        let window = view.window?.safeAreaInsets ?? .zero
        if size != lastLayoutSize {
            seenTopInset = 0
        }
        seenTopInset = max(seenTopInset, window.top, 20)
        return UIEdgeInsets(top: seenTopInset, left: window.left, bottom: window.bottom, right: window.right)
    }

    private func preferredMode(for size: CGSize) -> Mode {
        let isPad = traitCollection.userInterfaceIdiom == .pad
        return isPad && size.width > size.height ? .spread : .single
    }

    /// Storleken som sidbilderna ritas i. Den beror bara på vyns storlek och de fasta marginalerna.
    private func renderSize(for size: CGSize, mode: Mode) -> CGSize {
        let margin = PDFPageViewController.margin
        let height = size.height - contentInsets.top - contentInsets.bottom - margin * 2
        let width: CGFloat
        switch mode {
        case .single:
            width = size.width - contentInsets.left - contentInsets.right - margin * 2
        case .spread:
            width = size.width / 2 - max(contentInsets.left, contentInsets.right) - margin
        }
        return CGSize(width: max(width, 1), height: max(height, 1))
    }

    private var displayScale: CGFloat {
        traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
    }

    private func installPageController() {
        if let old = pageController {
            old.willMove(toParent: nil)
            old.view.removeFromSuperview()
            old.removeFromParent()
        }

        let spine: UIPageViewController.SpineLocation = mode == .spread ? .mid : .min
        let controller = UIPageViewController(
            transitionStyle: .pageCurl,
            navigationOrientation: .horizontal,
            options: [.spineLocation: NSNumber(value: spine.rawValue)]
        )
        controller.isDoubleSided = mode == .spread
        controller.dataSource = self
        controller.delegate = self

        addChild(controller)
        controller.view.frame = view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insertSubview(controller.view, at: 0)
        controller.didMove(toParent: self)
        pageController = controller

        controller.setViewControllers(pages(showing: currentIndex), direction: .forward, animated: false)

        // Pappersvikningens egna tryck ska bara gälla kanterna, mitten styr menyn och zoomen.
        for recognizer in controller.gestureRecognizers where recognizer is UITapGestureRecognizer {
            recognizer.delegate = self
        }
        // Medan man markerar text står sidan still.
        for recognizer in controller.gestureRecognizers {
            recognizer.isEnabled = !markMode
        }
    }

    // MARK: Sidor och uppslag

    /// Bladen som visar en viss sida: ett i stående, två i ett uppslag.
    private func pages(showing index: Int) -> [UIViewController] {
        switch mode {
        case .single:
            return [makePage(index)]
        case .spread:
            let left = Self.leftPageIndex(ofSpreadContaining: index)
            return [makePage(left), makePage(left + 1)]
        }
    }

    /// I ett uppslag ligger omslaget (index 0) ensamt till höger, sedan 1 och 2, 3 och 4 och så vidare.
    /// Vänstersidan har därför ett udda index, eller -1 för det tomma bladet före omslaget.
    private static func leftPageIndex(ofSpreadContaining index: Int) -> Int {
        index % 2 == 0 ? index - 1 : index
    }

    /// Första och sista bladet. Uppslag börjar med ett tomt blad och slutar alltid med en högersida.
    private var firstIndex: Int {
        mode == .spread ? -1 : 0
    }

    private var lastIndex: Int {
        let last = renderer.pageCount - 1
        return mode == .spread ? Self.leftPageIndex(ofSpreadContaining: last) + 1 : last
    }

    private func makePage(_ index: Int) -> PDFPageViewController {
        let side: PDFPageViewController.Side
        switch mode {
        case .single: side = .single
        case .spread: side = index % 2 != 0 ? .left : .right
        }
        let page = PDFPageViewController(pageIndex: index,
                                         side: side,
                                         renderer: renderer,
                                         paperColor: theme.paperColor,
                                         contentInsets: contentInsets)
        configureAnnotations(page)
        return page
    }

    private var visiblePages: [PDFPageViewController] {
        (pageController?.viewControllers ?? []).compactMap { $0 as? PDFPageViewController }
    }

    /// De riktiga sidorna som syns, utan tomma blad.
    private var visibleIndices: [Int] {
        visiblePages.map(\.pageIndex).filter { $0 >= 0 && $0 < renderer.pageCount }
    }

    private func refreshVisiblePages() {
        for page in visiblePages {
            page.apply(paperColor: theme.paperColor, contentInsets: contentInsets)
        }
    }

    /// Ritar grannsidorna i förväg, viktigast först. Högst fem bilder.
    private func keepNeighbours() {
        switch mode {
        case .single:
            let n = currentIndex
            renderer.keep([n, n + 1, n - 1, n + 2])
        case .spread:
            let left = Self.leftPageIndex(ofSpreadContaining: currentIndex)
            renderer.keep([left, left + 1, left + 2, left + 3, left - 1])
        }
    }

    /// Hoppar direkt till en sida, utan vikning.
    private func jump(to index: Int) {
        let index = min(max(index, 0), renderer.pageCount - 1)
        guard let controller = pageController else { return }
        currentIndex = index
        LibraryStore.shared.savePageIndex(index, for: book)
        if !visibleIndices.contains(index) {
            controller.setViewControllers(pages(showing: index), direction: .forward, animated: false)
        }
        updatePageLabel()
        updateBookmarkState()
        keepNeighbours()
    }

    // MARK: Menyn

    private func setUpNavigationBar() {
        chrome.install()
    }

    private func setUpBottomBar() {
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomBar)
        NSLayoutConstraint.activate([
            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        let slider = bottomBar.slider
        slider.minimumValue = 0
        slider.maximumValue = Float(max(renderer.pageCount - 1, 0))
        slider.isEnabled = renderer.pageCount > 1
        slider.value = Float(currentIndex)
        slider.addTarget(self, action: #selector(sliderMoved), for: .valueChanged)
        slider.addTarget(self, action: #selector(sliderReleased), for: [.touchUpInside, .touchUpOutside])

        bottomBar.pageButton.addTarget(self, action: #selector(showGoToPage), for: .touchUpInside)
        updatePageLabel()
    }

    private func setUpTaps() {
        let zoom = UITapGestureRecognizer(target: self, action: #selector(handleZoomTap(_:)))
        zoom.numberOfTapsRequired = 2
        zoom.delegate = self
        view.addGestureRecognizer(zoom)

        let chrome = UITapGestureRecognizer(target: self, action: #selector(toggleChrome))
        chrome.delegate = self
        chrome.require(toFail: zoom)
        view.addGestureRecognizer(chrome)

        let ribbon = UITapGestureRecognizer(target: self, action: #selector(handleRibbonTap(_:)))
        ribbon.delegate = self
        view.addGestureRecognizer(ribbon)
        ribbonTap = ribbon

        let press = WordPressGesture.makeRecognizer(target: self, action: #selector(handleWordPress(_:)), delegate: self)
        view.addGestureRecognizer(press)

        zoomTap = zoom
        chromeTap = chrome
        wordPress = press
        setUpMarkGestures()
    }

    @objc private func toggleChrome() {
        setChromeHidden(!chromeHidden, animated: true)
    }

    private func setChromeHidden(_ hidden: Bool, animated: Bool) {
        chrome.setHidden(hidden, animated: animated)
        // Bandets kontur i hörnet syns medan menyn är framme, så att man ser var man trycker (U3).
        for page in visiblePages {
            page.showsRibbonHint = !hidden
        }
    }

    private func updatePageLabel() {
        let indices = visibleIndices.isEmpty ? [currentIndex] : visibleIndices
        bottomBar.pageButton.setTitle(pageText(for: indices), for: .normal)
        chrome.setSubtitle(chapterTitle(for: indices.first ?? currentIndex))
        if !bottomBar.slider.isTracking {
            bottomBar.slider.value = Float(currentIndex)
        }
    }

    /// PDF:ens bokmärken (innehållet) med sidorna, i sidordning. Läses en gång, på huvudtråden.
    private lazy var chapterStarts: [(index: Int, title: String)] = {
        guard let root = document.outlineRoot else { return [] }
        var result: [(index: Int, title: String)] = []
        func visit(_ outline: PDFOutline, depth: Int) {
            guard depth < 2 else { return }
            for childIndex in 0..<outline.numberOfChildren {
                guard result.count < 500, let child = outline.child(at: childIndex) else { continue }
                let page = child.destination?.page ?? (child.action as? PDFActionGoTo)?.destination.page
                let title = (child.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if let page = page, !title.isEmpty {
                    let index = document.index(for: page)
                    if index >= 0, index < document.pageCount {
                        result.append((index, title))
                    }
                }
                visit(child, depth: depth + 1)
            }
        }
        visit(root, depth: 0)
        return result.sorted { $0.index < $1.index }
    }()

    /// Kapitlet som sidan hör till, ur PDF:ens innehåll (U3, under titeln i menyraden).
    private func chapterTitle(for index: Int) -> String? {
        chapterStarts.last { $0.index <= index }?.title
    }

    /// "52 av 300", eller med bokens egna sidnummer när de skiljer sig: "Sida 45, 52 av 300".
    private func pageText(for indices: [Int]) -> String {
        let numbers = indices.map { String($0 + 1) }.joined(separator: " och ")
        let printed = indices.compactMap { printedLabel(for: $0) }
        if !printed.isEmpty, printed.count == indices.count {
            return "Sida \(printed.joined(separator: " och ")), \(numbers) av \(renderer.pageCount)"
        }
        return "\(numbers) av \(renderer.pageCount)"
    }

    /// Sidnumret som står i boken, om det skiljer sig från sidans plats i filen.
    private func printedLabel(for index: Int) -> String? {
        guard let label = document.page(at: index)?.label?.trimmingCharacters(in: .whitespaces),
              !label.isEmpty,
              label != String(index + 1) else {
            return nil
        }
        return label
    }

    private lazy var hasPrintedLabels: Bool = {
        let limit = min(self.document.pageCount, 60)
        return (0..<limit).contains { self.printedLabel(for: $0) != nil }
    }()

    // MARK: Reglaget

    @objc private func sliderMoved() {
        let index = Int(bottomBar.slider.value.rounded())
        if bottomBar.slider.isTracking {
            bottomBar.pageButton.setTitle(pageText(for: [index]), for: .normal)
        } else {
            // VoiceOver ändrar värdet utan att dra.
            jump(to: index)
        }
    }

    @objc private func sliderReleased() {
        jump(to: Int(bottomBar.slider.value.rounded()))
    }

    // MARK: Innehåll och Gå till sida

    @objc private func showContents() {
        let outline = OutlineViewController(document: document, currentIndex: currentIndex)
        outline.onSelectPage = { [weak self] index in
            self?.dismiss(animated: true)
            self?.jump(to: index)
        }
        outline.onGoToPage = { [weak self] in
            self?.dismiss(animated: true) {
                self?.showGoToPage()
            }
        }
        let container = ReaderContentsContainerViewController(contents: outline,
                                                             annotations: makeAnnotationsList(),
                                                             initial: 0)
        let navigation = UINavigationController(rootViewController: container)
        navigation.modalPresentationStyle = .popover
        navigation.popoverPresentationController?.barButtonItem = contentsItem
        present(navigation, animated: true)
    }

    @objc private func showGoToPage() {
        let message = hasPrintedLabels
            ? "Skriv sidnumret som det står i boken."
            : "Skriv ett nummer från 1 till \(renderer.pageCount)."
        let alert = UIAlertController(title: "Gå till sida", message: message, preferredStyle: .alert)
        alert.addTextField { field in
            field.keyboardType = .numbersAndPunctuation
            field.returnKeyType = .go
            field.placeholder = "Sidnummer"
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Avbryt", style: .cancel))
        alert.addAction(UIAlertAction(title: "Gå", style: .default) { [weak self, weak alert] _ in
            guard let self = self, let text = alert?.textFields?.first?.text else { return }
            if let index = self.pageIndex(forTyped: text) {
                self.jump(to: index)
            } else {
                self.showMessage(title: "Sidan finns inte",
                                 message: "Hittade ingen sida \(text) i boken.")
            }
        })
        present(alert, animated: true)
    }

    /// Bokens egna sidnummer först (som "xii" eller "45"), annars sidans plats i filen.
    private func pageIndex(forTyped text: String) -> Int? {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return nil }
        if hasPrintedLabels {
            for index in 0..<document.pageCount {
                if let label = document.page(at: index)?.label,
                   label.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(typed) == .orderedSame {
                    return index
                }
            }
        }
        if let number = Int(typed), number >= 1, number <= document.pageCount {
            return number - 1
        }
        return nil
    }

    private func showMessage(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: Zoom

    @objc private func zoomCurrentPage() {
        openZoom(at: visibleIndices.first ?? currentIndex)
    }

    @objc private func handleZoomTap(_ tap: UITapGestureRecognizer) {
        var index = visibleIndices.first ?? currentIndex
        if mode == .spread {
            // Den sida i uppslaget som man tryckte på.
            let left = Self.leftPageIndex(ofSpreadContaining: currentIndex)
            index = tap.location(in: view).x < view.bounds.midX ? left : left + 1
        }
        guard index >= 0, index < renderer.pageCount else { return }
        openZoom(at: index)
    }

    private func openZoom(at index: Int) {
        guard let page = document.page(at: index) else { return }
        let zoom = PDFZoomViewController(document: document, page: page)
        let navigation = UINavigationController(rootViewController: zoom)
        navigation.modalPresentationStyle = .fullScreen
        present(navigation, animated: true)
    }

    // MARK: Ordboken

    /// Hur långt från fingret ett ord får ligga och ändå väljas, i punkter (G12, samma i båda läsarna).
    static let fingerTolerance = WordPressGesture.fingerTolerance

    /// Ordet under fingret medan man håller.
    private struct PressedWord {
        let found: FoundWord
        let page: PDFPageViewController
        /// Ordets rutor i bladets vy.
        let rects: [CGRect]
        /// Var fingret var senast, i bladets vy.
        let finger: CGPoint
    }

    /// Håll fingret på ett ord: ordet markeras, och en bubbla ovanför fingret visar vilket ord det är.
    /// Drar man vidare följer markeringen med. Rutan med ordboken öppnas när man släpper,
    /// och ordet sparas i Sparade ord tillsammans med meningen.
    @objc private func handleWordPress(_ press: UILongPressGestureRecognizer) {
        let point = press.location(in: view)
        switch press.state {
        case .began:
            guard presentedViewController == nil else { return }
            lastWordProbe = nil
            // Trycket ska inte också vika sidan eller visa menyn när fingret lyfts.
            cancelPageGestures()
            if !updatePressedWord(at: point),
               let page = pageView(at: point),
               let pdfPage = document.page(at: page.pageIndex),
               !PDFWordFinder.pageHasText(pdfPage) {
                showToast("Sidan har ingen text att slå upp. Den är troligen skannad.")
            }
        case .changed:
            updatePressedWord(at: point)
        case .ended:
            wordBubble.hide()
            if let pressed = pressedWord {
                lookUp(pressed)
            }
        default:
            wordBubble.hide()
            clearPressedWord()
        }
    }

    private func pageView(at point: CGPoint) -> PDFPageViewController? {
        visiblePages.first { candidate in
            !candidate.isBlank && candidate.view.bounds.contains(candidate.view.convert(point, from: view))
        }
    }

    /// Tar fram ordet närmast fingret och flyttar markeringen dit. Falskt om inget ord fanns nära.
    /// Ligger fingret mellan ord ligger markeringen kvar på det senaste, så att små glidningar inte tappar ordet.
    @discardableResult
    private func updatePressedWord(at point: CGPoint) -> Bool {
        guard let page = pageView(at: point),
              let pdfPage = document.page(at: page.pageIndex),
              let imageFrame = page.imageFrame else {
            return false
        }
        let local = page.view.convert(point, from: view)
        guard let pagePoint = PDFPageGeometry.pagePoint(for: local, imageFrame: imageFrame, page: pdfPage) else {
            return false
        }
        // Fingret ligger kvar på samma ord, eller har knappt rört sig: inget behöver räknas om (G6).
        if let current = pressedWord, current.page === page {
            let stillOnWord = current.found.pageRects.contains { $0.insetBy(dx: -1, dy: -1).contains(pagePoint) }
            let barelyMoved = lastWordProbe.map { hypot($0.x - pagePoint.x, $0.y - pagePoint.y) < 1.5 } ?? false
            if stillOnWord || barelyMoved {
                pressedWord = PressedWord(found: current.found, page: page, rects: current.rects, finger: local)
                wordBubble.move(to: point)
                skippedWordProbes += 1
                return true
            }
        }
        lastWordProbe = pagePoint
        wordProbes += 1
        let tolerance = Self.fingerTolerance * PDFPageGeometry.pageUnitsPerPoint(imageFrame: imageFrame, page: pdfPage)
        guard let found = PDFWordFinder.word(on: pdfPage, at: pagePoint, tolerance: tolerance) else {
            if pressedWord != nil {
                wordBubble.move(to: point)
            }
            return false
        }
        if let current = pressedWord, current.page === page, current.found.location == found.location {
            pressedWord = PressedWord(found: current.found, page: page, rects: current.rects, finger: local)
            wordBubble.move(to: point)
            return true
        }
        let rects = found.pageRects.map { PDFPageGeometry.viewRect(for: $0, imageFrame: imageFrame, page: pdfPage) }
        pressedWord?.page.clearHighlight()
        page.showHighlight(rects)
        pressedWord = PressedWord(found: found, page: page, rects: rects, finger: local)
        Haptics.shared.wordTapped()
        wordBubble.show(found.candidates.first ?? "", at: point)
        return true
    }

    /// Slår upp ordet som var markerat när fingret släpptes, och visar rutan vid ordet.
    private func lookUp(_ pressed: PressedWord) {
        let started = CACurrentMediaTime()
        guard let dictionary = WordDictionary.shared else {
            clearPressedWord()
            showMessage(title: "Ordboken saknas", message: "Den här versionen av appen byggdes utan ordboken.")
            return
        }
        let found = pressed.found
        let hidden = UserWords.shared.hiddenPairs
        var lookup: WordLookup?
        for candidate in found.candidates {
            lookup = dictionary.lookup(candidate,
                                       sentence: found.sentence,
                                       rangeInSentence: found.rangeInSentence,
                                       hidden: hidden)
            if lookup != nil { break }
        }
        let lookupTime = (CACurrentMediaTime() - started) * 1000

        let anchor = pressed.rects.first(where: { $0.insetBy(dx: -6, dy: -6).contains(pressed.finger) })
            ?? pressed.rects.first
            ?? CGRect(x: pressed.finger.x, y: pressed.finger.y, width: 1, height: 1)
        let sourceRect = view.convert(anchor, from: pressed.page.view)
        let pageIndex = pressed.page.pageIndex

        // Ordet sparas i Sparade ord av rutan, när den syns.
        let context = WordPopupViewController.Context(sentence: found.sentence,
                                                      rangeInSentence: found.rangeInSentence,
                                                      book: book.title,
                                                      pageIndex: pageIndex,
                                                      triedWord: found.candidates.first ?? "",
                                                      bookID: book.id)
        WordPopupViewController.present(
            lookup: lookup,
            context: context,
            from: self,
            sourceView: view,
            sourceRect: sourceRect,
            onReady: {
                LookupStats.shared.record(lookup: lookupTime, ready: (CACurrentMediaTime() - started) * 1000)
            },
            onDismiss: { [weak self] in
                self?.clearPressedWord()
            })
    }

    private func clearPressedWord() {
        pressedWord?.page.clearHighlight()
        pressedWord = nil
    }

    /// Avbryter pappersvikningens och menyns tryck som redan har börjat.
    private func cancelPageGestures() {
        let others: [UIGestureRecognizer?] = [chromeTap, zoomTap]
        WordPressGesture.cancel((pageController?.gestureRecognizers ?? []) + others.compactMap { $0 })
    }

    /// Ett kort meddelande nere på sidan som försvinner av sig självt.
    private func showToast(_ text: String) {
        chrome.showToast(text)
    }

    // MARK: Bakgrund

    /// Följ systemet bytte bakgrund medan boken är öppen (U1).
    @objc private func appThemeChanged() {
        setTheme(ReaderTheme.effective, remember: false)
    }

    /// `remember`: ett val i menyn sparas, gäller hela appen och stänger av Följ systemet (U1).
    private func setTheme(_ newTheme: ReaderTheme, remember: Bool = true) {
        let store = remember && (newTheme != ReaderTheme.current || ReaderTheme.followsSystem)
        if store {
            ReaderTheme.followsSystem = false
            ReaderTheme.current = newTheme
        }
        // Resten av appen byter efter läsaren, när den här funktionen är klar.
        defer {
            if store {
                Theme.apply()
            }
        }
        guard newTheme != theme else { return }
        theme = newTheme
        chrome.updateThemeMenu(newTheme)
        view.backgroundColor = newTheme.paperColor
        applyThemeToChrome()
        renderer.configure(size: renderSize(for: view.bounds.size, mode: mode), scale: displayScale, theme: newTheme)
        refreshVisiblePages()
        refreshAllMarks()
        keepNeighbours()
    }

    /// Menyraden och reglaget följer bakgrunden: mörka på mörkt papper, ljusa annars.
    private func applyThemeToChrome() {
        chrome.applyStyle(for: theme)
    }
}

// MARK: Pappersvikningen

extension PDFCurlReaderViewController: UIPageViewControllerDataSource, UIPageViewControllerDelegate {

    func pageViewController(_ pageViewController: UIPageViewController,
                            viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let page = viewController as? PDFPageViewController else { return nil }
        let previous = page.pageIndex - 1
        return previous >= firstIndex ? makePage(previous) : nil
    }

    func pageViewController(_ pageViewController: UIPageViewController,
                            viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let page = viewController as? PDFPageViewController else { return nil }
        let next = page.pageIndex + 1
        return next <= lastIndex ? makePage(next) : nil
    }

    func pageViewController(_ pageViewController: UIPageViewController,
                            willTransitionTo pendingViewControllers: [UIViewController]) {
        Haptics.shared.prepareForPageTurn()
        PageTurnSound.shared.play()
    }

    func pageViewController(_ pageViewController: UIPageViewController,
                            didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController],
                            transitionCompleted completed: Bool) {
        guard completed, let index = visibleIndices.first else { return }
        currentIndex = index
        LibraryStore.shared.savePageIndex(currentIndex, for: book)
        updatePageLabel()
        updateBookmarkState()
        Haptics.shared.pageTurned()
        setChromeHidden(true, animated: true)
        keepNeighbours()
    }
}

// MARK: Tryckzoner

extension PDFCurlReaderViewController: UIGestureRecognizerDelegate {

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Reglaget och sidnumret har egna tryck, liksom raden som visas medan man markerar.
        if let touched = touch.view, touched.isDescendant(of: bottomBar) {
            return false
        }
        if let bar = markBar, let touched = touch.view, touched.isDescendant(of: bar) {
            return false
        }
        if gestureRecognizer === markDrag {
            return markMode
        }
        // Bandet i hörnet (U3) går före kanttrycket som bläddrar och före menyn.
        let onRibbon = !markMode && ribbonPage(at: touch.location(in: view)) != nil
        if gestureRecognizer === ribbonTap {
            return onRibbon
        }
        if onRibbon, gestureRecognizer is UITapGestureRecognizer {
            return false
        }
        let onMark = markHit(at: touch.location(in: view)) != nil
        if gestureRecognizer === markTap {
            return !markMode && onMark
        }
        if onMark, gestureRecognizer is UITapGestureRecognizer {
            // Ett tryck på en markering öppnar markeringens ruta, inte menyn eller nästa sida.
            return false
        }
        let width = max(view.bounds.width, 1)
        let position = touch.location(in: view).x / width
        let inMiddle = position > 0.3 && position < 0.7

        if gestureRecognizer === wordPress {
            return true
        }
        if gestureRecognizer === chromeTap || gestureRecognizer === zoomTap {
            return inMiddle
        }
        // Pappersvikningens tryck: bara i kanterna.
        return !inMiddle
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}

// MARK: Markeringar, anteckningar, bokmärken och sökning (fas 4)

/// Det fingret drar över medan man markerar.
fileprivate struct PDFMarkSelection {
    let page: PDFPageViewController
    let pdfPage: PDFPage
    /// Ordet där fingret började, eller nil om det inte var på ett ord.
    let anchor: NSRange?
    var current: NSRange?
    let startPoint: CGPoint
    var moved: Bool
    /// Markeringen fingret började på, om det var ett tryck på en markering.
    let tappedMark: String?

    var range: NSRange? {
        guard let anchor = anchor else { return nil }
        return PDFTextRanges.span(from: anchor, to: current ?? anchor)
    }
}

extension PDFCurlReaderViewController {

    fileprivate var bookKey: String {
        AnnotationStore.key(for: book)
    }

    fileprivate func setUpMarkGestures() {
        let marking = MarkMode(host: view, target: self, drag: #selector(handleMarkDrag(_:)),
                               tap: #selector(handleMarkTap(_:)), delegate: self)
        marking.onTurn = { [weak self] forward in
            self?.turnPage(forward: forward)
        }
        marking.onDone = { [weak self] in
            self?.setMarkMode(false)
        }
        self.marking = marking
        bookmarksChanged()
    }

    // MARK: Markeringarna på sidorna

    /// Markeringarna på en sida. Rutorna är sparade sedan markeringen skapades (G6), så här räknas inget
    /// med PDFKit. Saknas de (markeringar från före G6 eller från synken) räknas de på renderingskön och
    /// sparas, och sidan får dem när de är klara.
    fileprivate func marks(forPage index: Int) -> [PDFPageViewController.Mark] {
        if let cached = marksCache[index] {
            return cached
        }
        if highlightsByPage == nil {
            highlightsByPage = Dictionary(grouping: AnnotationStore.shared.highlights(book: bookKey), by: \.section)
        }
        let highlights = highlightsByPage?[index] ?? []
        let missing = highlights.filter { $0.rects.isEmpty && !unplaceable.contains($0.id) }
        let marks = highlights.filter { !$0.rects.isEmpty }.map { highlight in
            PDFPageViewController.Mark(id: highlight.id, rects: highlight.rects, color: highlight.color,
                                       hasNote: highlight.hasNote)
        }
        if !missing.isEmpty {
            computeRects(for: missing, onPage: index)
        } else {
            marksCache[index] = marks
        }
        return marks
    }

    private func computeRects(for highlights: [Highlight], onPage index: Int) {
        guard rectsInFlight.insert(index).inserted else { return }
        let ranges = highlights.map { NSRange(location: $0.start, length: $0.length) }
        renderer.rects(onPage: index, ranges: ranges) { [weak self] result in
            guard let self = self, self.rectsInFlight.remove(index) != nil else { return }
            var updated = self.highlightsByPage?[index] ?? []
            for (highlight, rects) in zip(highlights, result) {
                guard !rects.isEmpty else {
                    // Texten finns inte på sidan längre (till exempel en ny version av boken).
                    self.unplaceable.insert(highlight.id)
                    continue
                }
                AnnotationStore.shared.setRects(rects, forHighlight: highlight.id)
                if let position = updated.firstIndex(where: { $0.id == highlight.id }) {
                    updated[position].rects = rects
                }
            }
            self.highlightsByPage?[index] = updated
            self.marksCache[index] = nil
            for page in self.visiblePages where page.pageIndex == index {
                page.setMarks(self.marks(forPage: index), dark: self.theme.isDark)
            }
        }
    }

    fileprivate func configureAnnotations(_ page: PDFPageViewController) {
        guard !page.isBlank else { return }
        let started = CACurrentMediaTime()
        page.pdfPage = document.page(at: page.pageIndex)
        page.setMarks(marks(forPage: page.pageIndex), dark: theme.isDark)
        page.isBookmarked = bookmarkedPages.contains(page.pageIndex)
        page.showsRibbonHint = !chromeHidden
        if marksCache[page.pageIndex]?.isEmpty == false {
            markSetupTimes = Array((markSetupTimes + [(CACurrentMediaTime() - started) * 1000]).suffix(200))
        }
    }

    /// Markeringarna på en sida har ändrats: läs om dem ur databasen.
    fileprivate func refreshMarks(onPage index: Int) {
        marksCache[index] = nil
        highlightsByPage?[index] = AnnotationStore.shared.highlights(book: bookKey, section: index)
        for page in visiblePages where page.pageIndex == index {
            page.setMarks(marks(forPage: index), dark: theme.isDark)
        }
    }

    fileprivate func refreshAllMarks() {
        marksCache.removeAll()
        rectsInFlight.removeAll()
        for page in visiblePages where !page.isBlank {
            page.setMarks(marks(forPage: page.pageIndex), dark: theme.isDark)
        }
    }

    fileprivate func markHit(at point: CGPoint) -> (page: PDFPageViewController, id: String)? {
        for page in visiblePages where !page.isBlank {
            let local = page.view.convert(point, from: view)
            if page.view.bounds.contains(local), let id = page.markID(at: local) {
                return (page, id)
            }
        }
        return nil
    }

    fileprivate func pageName(_ index: Int) -> String {
        "Sida \(printedLabel(for: index) ?? String(index + 1))"
    }

    // MARK: Markera med fingret

    @objc fileprivate func toggleMarkMode() {
        setMarkMode(!markMode)
    }

    /// Markeringsläget: sidan står still, och fingret markerar det det drar över.
    fileprivate func setMarkMode(_ on: Bool) {
        let others: [UIGestureRecognizer?] = [chromeTap, zoomTap, wordPress]
        let paused = (pageController?.gestureRecognizers ?? []) + others.compactMap { $0 }
        guard let marking = marking, marking.setOn(on, pausing: paused) else { return }
        if on {
            setChromeHidden(true, animated: true)
            marking.showBar()
        } else {
            markSelection?.page.clearPreview()
            markSelection = nil
            marking.removeBar()
        }
    }

    @objc fileprivate func handleMarkDrag(_ press: UILongPressGestureRecognizer) {
        let point = press.location(in: view)
        switch press.state {
        case .began:
            markSelection = nil
            guard let page = pageView(at: point),
                  let pdfPage = document.page(at: page.pageIndex),
                  let frame = page.imageFrame else { return }
            let local = page.view.convert(point, from: view)
            let tapped = page.markID(at: local)
            let word = PDFCurlReaderViewController.word(on: pdfPage, at: local, imageFrame: frame)
            if word == nil, tapped == nil, !PDFWordFinder.pageHasText(pdfPage) {
                showToast("Sidan har ingen text att markera. Den är troligen skannad.")
            }
            markSelection = PDFMarkSelection(page: page, pdfPage: pdfPage, anchor: word, current: word,
                                             startPoint: point, moved: false, tappedMark: tapped)
            if tapped == nil {
                showMarkPreview()
            }

        case .changed:
            guard var selection = markSelection, selection.anchor != nil,
                  let frame = selection.page.imageFrame else { return }
            if !selection.moved, hypot(point.x - selection.startPoint.x, point.y - selection.startPoint.y) > 6 {
                selection.moved = true
            }
            var local = selection.page.view.convert(point, from: view)
            local.x = min(max(local.x, frame.minX + 1), frame.maxX - 1)
            local.y = min(max(local.y, frame.minY + 1), frame.maxY - 1)
            let previous = selection.current
            if let word = PDFCurlReaderViewController.word(on: selection.pdfPage, at: local, imageFrame: frame) {
                selection.current = word
            }
            markSelection = selection
            // Förhandsvisningen byggs bara om när fingret nått ett nytt ord (G6).
            if selection.current != previous {
                showMarkPreview()
            }

        case .ended:
            guard let selection = markSelection else { return }
            markSelection = nil
            selection.page.clearPreview()
            if !selection.moved, let id = selection.tappedMark {
                presentMarkMenu(id: id, at: point)
                return
            }
            if let range = selection.range {
                createHighlight(onPage: selection.page.pageIndex, pdfPage: selection.pdfPage, range: range)
            }

        default:
            markSelection?.page.clearPreview()
            markSelection = nil
        }
    }

    /// Ordet närmast en punkt i bladets vy.
    fileprivate static func word(on pdfPage: PDFPage, at local: CGPoint, imageFrame: CGRect) -> NSRange? {
        guard let pagePoint = PDFPageGeometry.pagePoint(for: local, imageFrame: imageFrame, page: pdfPage) else { return nil }
        let tolerance = fingerTolerance * PDFPageGeometry.pageUnitsPerPoint(imageFrame: imageFrame, page: pdfPage)
        return PDFTextRanges.word(on: pdfPage, at: pagePoint, tolerance: tolerance)
    }

    fileprivate func showMarkPreview() {
        guard let selection = markSelection, let range = selection.range else { return }
        selection.page.showPreview(PDFTextRanges.rects(on: selection.pdfPage, range: range),
                                   color: ReaderSettings.highlightColor)
    }

    @discardableResult
    fileprivate func createHighlight(onPage index: Int, pdfPage: PDFPage, range: NSRange) -> Highlight? {
        let text = PDFTextRanges.text(on: pdfPage, range: range)
        guard !text.isEmpty else { return nil }
        // Rutorna sparas med markeringen (G6), så att sidan senare kan vikas fram utan att de räknas.
        let highlight = AnnotationStore.shared.addHighlight(book: bookKey, section: index, start: range.location,
                                                            length: range.length, text: text,
                                                            color: ReaderSettings.highlightColor,
                                                            textProvider: { start, length in
            PDFTextRanges.text(on: pdfPage, range: NSRange(location: start, length: length))
        }, rectsProvider: { start, length in
            PDFTextRanges.rects(on: pdfPage, range: NSRange(location: start, length: length))
        })
        refreshMarks(onPage: index)
        Haptics.shared.wordTapped()
        return highlight
    }

    /// Viker fram nästa eller förra sidan med kod, som ett tryck i kanten.
    fileprivate func turnPage(forward: Bool) {
        guard let controller = pageController else { return }
        let target: Int
        switch mode {
        case .single:
            target = currentIndex + (forward ? 1 : -1)
            guard target >= 0, target < renderer.pageCount else { return }
        case .spread:
            let left = Self.leftPageIndex(ofSpreadContaining: currentIndex)
            let lastLeft = Self.leftPageIndex(ofSpreadContaining: renderer.pageCount - 1)
            target = left + (forward ? 2 : -2)
            guard target >= firstIndex, target <= lastLeft else { return }
        }
        PageTurnSound.shared.play()
        controller.setViewControllers(pages(showing: target), direction: forward ? .forward : .reverse, animated: true) { [weak self] _ in
            guard let self = self, let index = self.visibleIndices.first else { return }
            self.currentIndex = index
            LibraryStore.shared.savePageIndex(index, for: self.book)
            self.updatePageLabel()
            self.updateBookmarkState()
            self.keepNeighbours()
        }
    }

    // MARK: Rutan för en markering

    @objc fileprivate func handleMarkTap(_ tap: UITapGestureRecognizer) {
        let point = tap.location(in: view)
        guard let hit = markHit(at: point) else { return }
        presentMarkMenu(id: hit.id, at: point)
    }

    fileprivate func presentMarkMenu(id: String, at point: CGPoint) {
        guard presentedViewController == nil, let highlight = AnnotationStore.shared.highlight(id: id) else { return }
        let menu = HighlightMenuViewController(highlight: highlight)
        menu.onColor = { [weak self] color in
            guard var changed = AnnotationStore.shared.highlight(id: id) else { return }
            changed.color = color
            ReaderSettings.highlightColor = color
            AnnotationStore.shared.update(changed)
            self?.refreshMarks(onPage: changed.section)
        }
        menu.onNote = { [weak self] in
            self?.editNote(highlightID: id)
        }
        menu.onDelete = { [weak self] in
            guard let current = AnnotationStore.shared.highlight(id: id) else { return }
            AnnotationStore.shared.delete(current)
            self?.refreshMarks(onPage: current.section)
        }
        let page = visiblePages.first { !$0.isBlank && !$0.markRects(id: id).isEmpty }
        let anchor = page.map { HighlightMenuViewController.anchor(for: $0.markRects(id: id), in: view,
                                                                   from: $0.view, fallback: point) }
            ?? CGRect(x: point.x - 1, y: point.y - 10, width: 2, height: 20)
        menu.onLookUp = { [weak self] in
            guard let self = self else { return }
            HighlightLookUp.present(highlight, book: self.book, pageIndex: highlight.section, from: self,
                                    sourceView: self.view, sourceRect: anchor)
        }
        lastMarkMenuAnchor = anchor
        HighlightMenuViewController.present(menu, from: self, sourceView: view, sourceRect: anchor)
    }

    fileprivate func editNote(highlightID id: String) {
        guard let highlight = AnnotationStore.shared.highlight(id: id) else { return }
        NoteEditorViewController.present(quote: highlight.text, note: highlight.note, from: self) { [weak self] note in
            guard var current = AnnotationStore.shared.highlight(id: id) else { return }
            current.note = note
            AnnotationStore.shared.update(current)
            self?.refreshMarks(onPage: current.section)
        }
    }

    // MARK: Bokmärken

    fileprivate func bookmarksChanged() {
        bookmarks = AnnotationStore.shared.bookmarks(book: bookKey)
        bookmarkedPages = Set(bookmarks.map(\.section))
        for page in visiblePages {
            page.isBookmarked = bookmarkedPages.contains(page.pageIndex)
        }
        updateBookmarkState()
    }

    fileprivate func updateBookmarkState() {
        let shown = visibleIndices.isEmpty ? [currentIndex] : visibleIndices
        let marked = shown.contains { bookmarkedPages.contains($0) }
        bookmarkItem?.image = UIImage(systemName: marked ? "bookmark.fill" : "bookmark")
        bookmarkItem?.accessibilityValue = marked ? "Sidan har ett bokmärke" : "Inget bokmärke"
        chrome.updateBookmark(marked)
    }

    /// Bokmärker sidan man läser, eller tar bort bokmärket om sidan redan har ett.
    @objc fileprivate func toggleBookmark() {
        toggleBookmark(indices: visibleIndices.isEmpty ? [currentIndex] : visibleIndices)
    }

    /// Bandet i sidans hörn (U3): ett tryck där bokmärker just den sidan.
    @objc fileprivate func handleRibbonTap(_ tap: UITapGestureRecognizer) {
        guard let page = ribbonPage(at: tap.location(in: view)) else { return }
        toggleBookmark(indices: [page.pageIndex])
        SelfTest.log("Bandet i hörnet: sidan \(page.pageIndex + 1) \(bookmarkedPages.contains(page.pageIndex) ? "har" : "har inte") bokmärke")
    }

    fileprivate func ribbonPage(at point: CGPoint) -> PDFPageViewController? {
        visiblePages.first { page in
            guard !page.isBlank, let zone = page.ribbonZone else { return false }
            return page.view.convert(zone, to: view).contains(point)
        }
    }

    /// Självtestet (U3): menyradens zoner och bandets tryckyta i hörnet.
    fileprivate func selfTestChromeLayout() {
        let left = (navigationItem.leftBarButtonItems ?? []).compactMap(\.accessibilityLabel)
        let right = (navigationItem.rightBarButtonItems ?? []).compactMap(\.accessibilityLabel)
        let page = visiblePages.first { !$0.isBlank && $0.ribbonZone != nil }
        let zone: CGRect? = page.flatMap { shown in shown.ribbonZone.map { shown.view.convert($0, to: view) } }
        let hit = zone.map { ribbonPage(at: CGPoint(x: $0.midX, y: $0.midY)) != nil } ?? false
        let middle = ribbonPage(at: CGPoint(x: view.bounds.midX, y: view.bounds.midY)) != nil
        SelfTest.log("Menyraden (U3): vänster \(left.joined(separator: ", ")), höger från kanten "
                     + "\(right.joined(separator: ", ")), titel \(title ?? "ingen"), under titeln "
                     + "\(chrome.subtitle ?? "inget"). Bandet i hörnet tar trycket: \(hit ? "ja" : "FEL, nej"), "
                     + "mitten av sidan: \(middle ? "FEL, ja" : "nej")")
    }

    fileprivate func toggleBookmark(indices shown: [Int]) {
        let existing = bookmarks.filter { shown.contains($0.section) }
        if existing.isEmpty {
            let index = shown.first ?? currentIndex
            let text = AnnotationFormat.excerpt(PDFTextRanges.clean(document.page(at: index)?.string ?? ""))
            let label = text.isEmpty ? pageName(index) : "\(pageName(index)): \(text)"
            AnnotationStore.shared.addBookmark(book: bookKey, section: index, progression: 0, label: label)
            Haptics.shared.wordTapped()
        } else {
            existing.forEach { AnnotationStore.shared.delete($0) }
        }
        bookmarksChanged()
    }

    // MARK: Listan med bokmärken och markeringar

    fileprivate func makeAnnotationsList() -> AnnotationsViewController {
        let list = AnnotationsViewController(kind: .highlights)
        list.rows = { [weak self] kind in
            self?.annotationRows(kind) ?? []
        }
        list.onSelect = { [weak self] kind, id in
            self?.dismiss(animated: true)
            self?.openAnnotation(kind, id: id)
        }
        list.onDelete = { [weak self] kind, id in
            self?.deleteAnnotation(kind, id: id)
        }
        return list
    }

    fileprivate func annotationRows(_ kind: AnnotationsViewController.Kind) -> [AnnotationsViewController.Row] {
        switch kind {
        case .bookmarks:
            return AnnotationStore.shared.bookmarks(book: bookKey).map { bookmark in
                AnnotationsViewController.Row(id: bookmark.id, title: bookmark.label,
                                              detail: AnnotationFormat.date(bookmark.created), note: nil, color: nil)
            }
        case .highlights:
            return AnnotationStore.shared.highlights(book: bookKey).map { highlight in
                AnnotationsViewController.Row(id: highlight.id, title: highlight.text,
                                              detail: pageName(highlight.section),
                                              note: highlight.hasNote ? highlight.note : nil,
                                              color: highlight.color)
            }
        }
    }

    fileprivate func openAnnotation(_ kind: AnnotationsViewController.Kind, id: String) {
        switch kind {
        case .bookmarks:
            guard let bookmark = AnnotationStore.shared.bookmarks(book: bookKey).first(where: { $0.id == id }) else { return }
            jump(to: bookmark.section)
        case .highlights:
            guard let highlight = AnnotationStore.shared.highlight(id: id) else { return }
            jump(to: highlight.section)
            flash(NSRange(location: highlight.start, length: highlight.length), onPage: highlight.section)
        }
    }

    fileprivate func deleteAnnotation(_ kind: AnnotationsViewController.Kind, id: String) {
        switch kind {
        case .bookmarks:
            if let bookmark = AnnotationStore.shared.bookmarks(book: bookKey).first(where: { $0.id == id }) {
                AnnotationStore.shared.delete(bookmark)
            }
            bookmarksChanged()
        case .highlights:
            if let highlight = AnnotationStore.shared.highlight(id: id) {
                AnnotationStore.shared.delete(highlight)
                refreshMarks(onPage: highlight.section)
            }
        }
    }

    fileprivate func flash(_ range: NSRange, onPage index: Int) {
        guard let pdfPage = document.page(at: index) else { return }
        let rects = PDFTextRanges.rects(on: pdfPage, range: range)
        visiblePages.first { $0.pageIndex == index }?.flash(rects)
    }

    // MARK: Sök

    @objc fileprivate func showSearch() {
        guard presentedViewController == nil else { return }
        let controller = BookSearchViewController(search: bookSearch, query: lastQuery) { [weak self] section in
            self?.pageName(section) ?? "Sida \(section + 1)"
        }
        controller.onQueryChange = { [weak self] query in
            self?.lastQuery = query
        }
        controller.onSelect = { [weak self] hit, query in
            self?.lastQuery = query
            self?.dismiss(animated: true)
            self?.jump(to: hit.section)
            self?.flash(NSRange(location: hit.start, length: hit.length), onPage: hit.section)
        }
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .popover
        navigation.popoverPresentationController?.barButtonItem = searchItem
        present(navigation, animated: true)
    }
}

// MARK: Självtestet för PDF (fas 4)

extension PDFCurlReaderViewController {

    fileprivate func startSelfTestIfNeeded() {
        guard SelfTest.isActive, !selfTestStarted, SelfTest.bookName?.lowercased().hasSuffix(".pdf") == true else { return }
        selfTestStarted = true
        Task { @MainActor [weak self] in
            await self?.runSelfTest()
        }
    }

    fileprivate func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    fileprivate func waitForImages() async -> Bool {
        for _ in 0..<150 {
            if !visiblePages.isEmpty, visiblePages.allSatisfy({ $0.isBlank || $0.imageFrame != nil }) {
                return true
            }
            await pause(0.1)
        }
        return false
    }

    fileprivate func waitForPresented<T: UIViewController>(_ type: T.Type) async -> T? {
        for _ in 0..<40 {
            if let navigation = presentedViewController as? UINavigationController,
               let found = navigation.viewControllers.first as? T {
                return found
            }
            if let found = presentedViewController as? T {
                return found
            }
            await pause(0.1)
        }
        return nil
    }

    fileprivate func dismissPresented() async {
        guard presentedViewController != nil else { return }
        dismiss(animated: false)
        await pause(0.5)
    }

    /// Ett fel i ritningen ska ge ett nytt försök, och två fel i följd en text på sidan.
    fileprivate func selfTestRenderFailure() async {
        let start = currentIndex
        let once = min(start + 4, renderer.pageCount - 1)
        let twice = min(start + 6, renderer.pageCount - 1)
        guard once != start, twice != once else {
            SelfTest.log("Sidfel: boken är för kort för testet")
            return
        }
        renderer.simulateFailures(1, at: once)
        jump(to: once)
        let shown = await waitForImages()
        let failedOnce = visiblePages.contains { $0.showsFailure }
        SelfTest.log("Sidfel en gång: \(shown && !failedOnce ? "ritades om och syns" : "FEL, sidan syns inte")")

        renderer.simulateFailures(2, at: twice)
        jump(to: twice)
        var failed = false
        for _ in 0..<30 {
            if visiblePages.contains(where: { $0.pageIndex == twice && $0.showsFailure }) {
                failed = true
                break
            }
            await pause(0.1)
        }
        SelfTest.log("Sidfel två gånger: \(failed ? "texten visas" : "FEL, ingen text")")
        SelfTest.saveScreen(view, name: "02b-sidfel")
        jump(to: start)
        _ = await waitForImages()
    }

    /// Nyckeln för sidbilderna på disk (G5): bokens id, och filens storlek och ändringstid, så att en ny
    /// version av filen (som behållit bokens id) inte visar gamla bilder.
    static func diskCacheKey(for book: Book) -> String {
        let values = try? book.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? 0
        let date = Int(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        return "\(book.id)-\(size)-\(date)"
    }

    /// G5: en fotad PDF (en stor JPEG per sida). Första varvet ritas sidorna utan förritning, andra varvet
    /// kommer de från disken. Tiderna hamnar i självtestets logg och i loggen i Filer.
    fileprivate func selfTestPhotoPDF() async {
        renderer.prefillEnabled = false
        _ = await waitForImages()
        SelfTest.saveScreen(view, name: "01-foto")
        renderer.resetTimes()
        for _ in 0..<6 {
            turnPage(forward: true)
            await pause(1.2)
        }
        _ = await waitForImages()
        await renderer.waitUntilIdle()
        let drawn = renderer.statsSummary
        let stored = renderer.diskCount()

        renderer.resetTimes()
        renderer.forgetImagesInMemory()
        jump(to: 0)
        _ = await waitForImages()
        for _ in 0..<6 {
            turnPage(forward: true)
            await pause(1.2)
        }
        _ = await waitForImages()
        let fromDisk = renderer.statsSummary

        renderer.prefillEnabled = true
        turnPage(forward: true)
        await pause(1.0)
        await renderer.waitUntilIdle()
        let line = "Fotad PDF med \(document.pageCount) sidor. Första varvet (ritas): \(drawn) "
            + "Sidbilder på disken efter första varvet: \(stored). Andra varvet (minnet tömt): \(fromDisk) "
            + "Med förritning: \(renderer.diskCount()) sidbilder på disken."
        SelfTest.log(line)
        AppLog.shared.write("Självtest G5: " + line)
        SelfTest.saveScreen(view, name: "02-foto-senare")

        // U1: vad bakgrunden kostar ovanpå en färdigritad fotad sida, i bakgrunden med ett eget dokument.
        let url = book.url
        let size = renderSize(for: view.bounds.size, mode: mode)
        let scale = displayScale
        let cost = await Task.detached(priority: .userInitiated) { () -> String in
            guard let copy = PDFDocument(url: url), let page = copy.page(at: 1) else { return "ingen sida" }
            var parts: [String] = []
            let drawStart = CACurrentMediaTime()
            let image = page.thumbnail(of: CGSize(width: size.width * scale, height: size.height * scale),
                                       for: .mediaBox)
            parts.append("ritning \(Int(((CACurrentMediaTime() - drawStart) * 1000).rounded())) ms "
                         + "(\(Int(image.size.width * image.scale)) x \(Int(image.size.height * image.scale)) px)")
            for theme in ReaderTheme.allCases {
                var times: [Double] = []
                for _ in 0..<3 {
                    let start = CACurrentMediaTime()
                    _ = PageImageStyler.apply(theme, to: image)
                    times.append((CACurrentMediaTime() - start) * 1000)
                }
                parts.append("\(theme.title) \(Int((times.sorted()[1]).rounded())) ms")
            }
            return parts.joined(separator: ", ")
        }.value
        SelfTest.log("Bakgrundens kostnad på en fotad sida (U1, mittvärde av tre): \(cost)")
        AppLog.shared.write("Självtest U1: bakgrundens kostnad: \(cost)")
    }

    fileprivate func runSelfTest() async {
        if SelfTest.bookName == "foto.pdf" {
            await selfTestPhotoPDF()
            SelfTest.finish()
            return
        }
        let saved = AnnotationStore.shared.totalCounts()
        SelfTest.log("PDF med \(document.pageCount) sidor. Sparat från tidigare starter: \(saved.highlights) markeringar, "
                     + "\(saved.notes) anteckningar, \(saved.bookmarks) bokmärken")
        let shown = await waitForImages()
        SelfTest.log("Första sidan: \(shown ? "ok" : "FEL, sidbilden kom inte")")
        SelfTest.saveScreen(view, name: "01-start")

        turnPage(forward: true)
        await pause(1.5)
        _ = await waitForImages()
        SelfTest.log("Efter en sida: \(bottomBar.pageButton.title(for: .normal) ?? "")")

        // Ordet under en punkt, som när fingret börjar markera.
        guard let page = visiblePages.first(where: { !$0.isBlank }),
              let pdfPage = document.page(at: page.pageIndex),
              let frame = page.imageFrame,
              let string = pdfPage.string else {
            SelfTest.log("FEL: ingen sida med text")
            SelfTest.finish()
            return
        }
        let text = string as NSString
        let target = text.range(of: "kunskap", options: [.caseInsensitive])
        if target.location != NSNotFound, let rect = PDFTextRanges.rects(on: pdfPage, range: target).first,
           let shownRect = page.viewRect(forPageRect: rect) {
            let finger = CGPoint(x: shownRect.midX, y: shownRect.midY)
            let word = PDFCurlReaderViewController.word(on: pdfPage, at: finger, imageFrame: frame)
            let pagePoint = PDFPageGeometry.pagePoint(for: finger, imageFrame: frame, page: pdfPage)
            let index = pagePoint.map { pdfPage.characterIndex(at: $0) } ?? -2
            SelfTest.log("Ord under fingret vid \"kunskap\": \(word.map { text.substring(with: $0) } ?? "inget") "
                         + "(ruta \(rect), punkt \(pagePoint.map { "\($0)" } ?? "ingen"), tecken \(index))")
        } else {
            SelfTest.log("FEL: hittade inte ordet kunskap på sidan")
        }

        // Markera en mening och ge den en anteckning.
        let sentenceEnd = text.range(of: ".", options: [], range: NSRange(location: 0, length: text.length))
        let length = sentenceEnd.location == NSNotFound ? min(40, text.length) : sentenceEnd.location + 1
        if let highlight = createHighlight(onPage: page.pageIndex, pdfPage: pdfPage, range: NSRange(location: 0, length: length)) {
            var noted = highlight
            noted.note = "Testanteckning från självtestet."
            AnnotationStore.shared.update(noted)
            refreshMarks(onPage: page.pageIndex)
            SelfTest.log("Markering: \"\(highlight.text)\"")
        } else {
            SelfTest.log("FEL: markeringen skapades inte")
        }
        await pause(0.6)
        SelfTest.saveScreen(view, name: "02-markering")

        // En anteckning som sveps bort ska sparas, inte försvinna.
        if let highlight = AnnotationStore.shared.highlights(book: bookKey).last {
            editNote(highlightID: highlight.id)
            if let editor = await waitForPresented(NoteEditorViewController.self) {
                await pause(0.6)
                let hasDelegate = editor.simulateSwipeAway(typing: "Svept anteckning.")
                // Arket försvinner först när tangentbordet gått ner, det kan ta en stund i simulatorn.
                for _ in 0..<40 where presentedViewController != nil {
                    await pause(0.1)
                }
                await pause(0.3)
                let note = AnnotationStore.shared.highlight(id: highlight.id)?.note ?? ""
                SelfTest.log("Anteckning som sveptes bort: \(note == "Svept anteckning." ? "sparad" : "FEL, \(note)"). "
                             + "Delegaten för svepet: \(hasDelegate ? "satt" : "FEL, saknas")")
            } else {
                SelfTest.log("FEL: anteckningen öppnades inte")
            }
            await dismissPresented()
        }

        // En sidbild som inte kan ritas ritas om en gång, och annars står det på sidan.
        await selfTestRenderFailure()

        toggleBookmark()
        await pause(0.4)
        SelfTest.log("Bokmärke: knappen visar \(bookmarkItem?.accessibilityValue ?? "inget"), "
                     + "\(bookmarks.count) bokmärken i boken")
        setChromeHidden(false, animated: false)
        await pause(0.4)
        SelfTest.saveScreen(view, name: "03-bokmarke")
        selfTestChromeLayout()

        setMarkMode(true)
        await pause(0.6)
        SelfTest.saveScreen(view, name: "04-markeringslage")
        setMarkMode(false)
        setChromeHidden(false, animated: false)
        await pause(0.4)

        showSearch()
        if let search = await waitForPresented(BookSearchViewController.self) {
            search.searchNow("kunskap")
            for _ in 0..<80 where search.searching {
                await pause(0.1)
            }
            SelfTest.log("Sökning efter kunskap: \(search.hitCount) träffar")
            SelfTest.saveScreen(view.window ?? view, name: "05-sok")
            if let hit = search.firstHit {
                search.onSelect?(hit, "kunskap")
                await pause(1.0)
                _ = await waitForImages()
                SelfTest.log("Första träffen på \(pageName(hit.section)), läsaren visar \(bottomBar.pageButton.title(for: .normal) ?? "")")
                SelfTest.saveScreen(view, name: "06-traff")
            }
        } else {
            SelfTest.log("FEL: sökrutan öppnades inte")
        }
        await dismissPresented()
        await SearchIndexSelfTest.run(source: .pdf(book.url), key: searchKey)

        showContents()
        if let container = await waitForPresented(ReaderContentsContainerViewController.self) {
            container.showTab(2)
            await pause(0.6)
            SelfTest.log("Flikarna: \(container.visibleListCount) lista syns")
            SelfTest.saveScreen(view.window ?? view, name: "07-markeringar")
            container.showTab(1)
            await pause(0.4)
            SelfTest.saveScreen(view.window ?? view, name: "08-bokmarken")
        } else {
            SelfTest.log("FEL: innehållet öppnades inte")
        }
        await dismissPresented()

        if let highlight = AnnotationStore.shared.highlights(book: bookKey).first {
            jump(to: highlight.section)
            _ = await waitForImages()
            if let page = visiblePages.first(where: { $0.pageIndex == highlight.section }),
               let pdfPage = document.page(at: highlight.section),
               let rect = PDFTextRanges.rects(on: pdfPage, range: NSRange(location: highlight.start, length: highlight.length)).first,
               let shownRect = page.viewRect(forPageRect: rect) {
                let point = view.convert(CGPoint(x: shownRect.midX, y: shownRect.midY), from: page.view)
                SelfTest.log("Tryck på markeringen hittar: \(markHit(at: point)?.id == highlight.id ? "rätt markering" : "FEL")")
                presentMarkMenu(id: highlight.id, at: point)
                await pause(0.8)
                if let shown = presentedViewController as? HighlightMenuViewController, let anchor = lastMarkMenuAnchor {
                    let frame = view.convert(shown.view.bounds, from: shown.view)
                    let covers = frame.intersects(anchor.insetBy(dx: 0, dy: 1))
                    SelfTest.log("Markeringsraden (U5): \(HighlightMenuViewController.lastPlacement) markeringen, "
                                 + "\(Int(frame.width)) x \(Int(frame.height)) punkter, täcker markeringen: "
                                 + (covers ? "FEL, ja" : "nej"))
                }
                SelfTest.saveScreen(view.window ?? view, name: "09-markeringsmeny")
                await dismissPresented()
            }
        }

        let savedTheme = theme
        setTheme(.dark)
        await pause(0.8)
        _ = await waitForImages()
        SelfTest.saveScreen(view, name: "10-morkt")
        setTheme(.white)
        await pause(0.8)
        _ = await waitForImages()
        SelfTest.saveScreen(view, name: "10b-vitt")
        setTheme(savedTheme)

        await selfTestFoldWork()

        let after = AnnotationStore.shared.totalCounts()
        SelfTest.log("Sparat nu: \(after.highlights) markeringar, \(after.notes) anteckningar, \(after.bookmarks) bokmärken")
        SelfTest.finish()
    }

    /// G6: markeringarnas rutor är sparade, saknade rutor räknas på renderingskön, sidor med markeringar
    /// förbereds utan PDFKit, och ordet under fingret räknas bara om när fingret lämnat ordet.
    fileprivate func selfTestFoldWork() async {
        let all = AnnotationStore.shared.highlights(book: bookKey)
        SelfTest.log("Markeringar med sparade rutor: \(all.filter { !$0.rects.isEmpty }.count) av \(all.count)")
        if let first = all.first {
            // Som en markering från före G6: rutorna saknas och räknas fram på renderingskön.
            AnnotationStore.shared.setRects([], forHighlight: first.id)
            highlightsByPage = nil
            marksCache.removeAll()
            _ = marks(forPage: first.section)
            for _ in 0..<30 where !rectsInFlight.isEmpty {
                await pause(0.1)
            }
            let stored = AnnotationStore.shared.highlight(id: first.id)?.rects.count ?? 0
            SelfTest.log("Saknade rutor räknades på renderingskön: \(stored > 0 ? "\(stored) rutor sparade" : "FEL, inga")")

            // Bläddra fram och tillbaka över sidan med markeringen.
            markSetupTimes.removeAll()
            jump(to: max(first.section - 2, 0))
            _ = await waitForImages()
            for forward in [true, true, true, false, false, false] {
                turnPage(forward: forward)
                await pause(0.9)
            }
            let longest = markSetupTimes.max() ?? -1
            SelfTest.log("Sidor med markeringar förbereddes \(markSetupTimes.count) gånger, längsta "
                         + String(format: "%.2f", longest) + " ms" + (longest > 5 ? " FEL, för långsamt" : ""))
            jump(to: first.section)
            _ = await waitForImages()
        }

        // Ordet under fingret: ett första uppslag, sedan små rörelser på samma ord. Bladet måste ha hunnit
        // läggas ut efter hoppet (bildrutan var 0 x 0 direkt efter), som det alltid har när ett finger trycker.
        await pause(0.6)
        view.layoutIfNeeded()
        visiblePages.forEach { $0.view.layoutIfNeeded() }
        guard let page = visiblePages.first(where: { !$0.isBlank }),
              let pdfPage = document.page(at: page.pageIndex),
              let text = pdfPage.string.map({ $0 as NSString }) else { return }
        let target = text.range(of: "kunskap", options: [.caseInsensitive])
        guard target.location != NSNotFound, let rect = PDFTextRanges.rects(on: pdfPage, range: target).first,
              let shown = page.viewRect(forPageRect: rect) else {
            SelfTest.log("FEL: hittade inte ordet för fingerprovet")
            return
        }
        wordProbes = 0
        skippedWordProbes = 0
        lastWordProbe = nil
        let screen = view.convert(CGPoint(x: shown.midX, y: shown.midY), from: page.view)
        let local = page.view.convert(screen, from: view)
        let pagePoint = page.imageFrame.flatMap { PDFPageGeometry.pagePoint(for: local, imageFrame: $0, page: pdfPage) }
        SelfTest.log("Fingerprovet: sida \(page.pageIndex + 1), bladet under fingret \(pageView(at: screen).map { "\($0.pageIndex + 1)" } ?? "inget"), "
                     + "bildruta \(page.imageFrame.map { "\($0)" } ?? "ingen"), punkt \(pagePoint.map { "\($0)" } ?? "ingen")")
        for step in 0..<12 {
            let local = CGPoint(x: shown.midX + CGFloat(step % 4) - 1.5, y: shown.midY + CGFloat(step % 3) * 0.5)
            updatePressedWord(at: view.convert(local, from: page.view))
        }
        SelfTest.log("Ordet under fingret: \(pressedWord?.found.candidates.first ?? "inget"), \(wordProbes) uppslag "
                     + "och \(skippedWordProbes) överhoppade på 12 rörelser" + (wordProbes > 2 ? " FEL" : ""))
        wordBubble.hide()
        clearPressedWord()
    }
}
