import SafariServices
import UIKit

/// Läsaren för EPUB och textfiler, med samma pappersvikning som PDF-läsaren.
///
/// Varje kapitel ligger i en webbvy, dold bakom sidorna, som delar kapitlet i kolumner lika stora som en sida.
/// Bladen i vikningen är färdiga bilder av kolumnerna, så att vikningen bara flyttar bilder.
/// Ord och länkar hittas i den dolda webbvyn, på samma ställe som fingret trycker på bilden.
///
/// Stående: en sida i taget med ryggen till vänster. Liggande på iPad: uppslag med ryggen i mitten.
/// Varje kapitel börjar på en vänstersida. Tryck i kanterna eller dra för att bläddra, tryck i mitten för menyn,
/// håll fingret på ett ord för att slå upp det, tryck på en länk (till exempel en fotnot) för att följa den.
final class ReflowReaderViewController: UIViewController {

    /// Hur länge fingret ska ligga still på ett ord innan det slås upp, samma som i PDF-läsaren.
    static let wordPressDuration = WordPressGesture.duration

    private enum Mode: Equatable {
        case single, spread
    }

    /// Sidan som ska visas när kapitlet är mätt: en plats i kapitlet, eller ett ankare som en fotnot.
    private struct PendingJump {
        let chapter: Int
        let progression: Double
        let fragment: String?
        var isResolving = false
    }

    private let book: Book
    private var content: ReflowableBook?
    private var renderer: ReflowRenderer?
    private let webHost = UIView()
    private let paperCover = UIView()
    private var pageController: UIPageViewController?
    private var controllerMode: Mode = .single
    private var mode: Mode = .single
    private var theme = ReaderTheme.effective
    private var typography = ReaderTypography.current

    /// Den sparade platsen, som används tills första sidan visas.
    private var location: ReflowLocation
    private var currentChapter = 0
    /// Bladet som syns, i ett uppslag det vänstra.
    private var currentSlot = 0
    /// Kapitlets sidantal när sidan visades, eller nil om kapitlet inte var mätt än.
    /// Används för läspositionen medan kapitlet mäts om.
    private var currentCount: Int?
    private let openedAt = CACurrentMediaTime()
    private var loadedAt: CFTimeInterval?
    private var firstMeasuredAt: CFTimeInterval?
    private var isShowingPages = false
    private var pendingJump: PendingJump?
    /// Platsen i ett kapitel som inte kunde visas, när man tryckt på Försök igen (G2).
    private var retryLocation: ReflowLocation?
    /// En sida som ska visas när fingret har vikt klart. Bladen får inte bytas mitt i en vikning.
    private var deferredShow: (chapter: Int, page: Int)?
    private var turnToken = 0

    private let bottomBar = ReaderBottomBar()
    /// Menyraden, gemensam med PDF-läsaren (G12).
    private lazy var chrome: ReaderChrome = {
        let text = UIBarButtonItem(image: UIImage(systemName: "textformat.size"),
                                   style: .plain,
                                   target: self,
                                   action: #selector(showTypography))
        text.accessibilityLabel = "Utseende och text"
        return ReaderChrome(controller: self, bottomBar: bottomBar, readerItem: text, theme: theme,
                            actions: .init(contents: #selector(showContents), search: #selector(showSearch),
                                           mark: #selector(toggleMarkMode), bookmark: #selector(toggleBookmark)),
                            onTheme: { [weak self] option in self?.setTheme(option) })
    }()

    private var chromeHidden: Bool {
        chrome.isHidden
    }
    private let spinner = UIActivityIndicatorView(style: .large)
    private var chromeTap: UITapGestureRecognizer?
    private var linkTap: UITapGestureRecognizer?
    /// Trycket på bokmärkesbandet i sidans hörn (U3).
    private var ribbonTap: UITapGestureRecognizer?
    private var wordPress: UILongPressGestureRecognizer?
    private var pressedWord: PressedWord?
    /// Markeringsradens ruta senast den visades (U5), till självtestet.
    private var lastMarkMenuAnchor: CGRect?
    private var wordQueryRunning = false
    private var queuedWordPoint: CGPoint?
    private var pressEnded = false
    /// Bubblan ovanför fingret när ett ord hålls (G12, gemensam med den andra läsaren).
    private lazy var wordBubble = WordBubble(host: view)

    private var contentsItem: UIBarButtonItem? {
        chrome.contentsItem
    }

    private var typographyItem: UIBarButtonItem? {
        chrome.readerItem
    }

    private var lastLayout: ReflowLayout?
    private var lastSize: CGSize = .zero
    private var seenTopInset: CGFloat = 0
    /// V4: platserna man hoppat ifrån och Tillbaka i hörnet (G12, samma som i PDF-läsaren).
    private let backStack = ReaderBackStack<ReflowLocation>()
    private var typographyTask: Task<Void, Never>?
    /// V5: hur lång tid det tog att hitta senaste fotnoten, till självtestet.
    private var lastNoteMilliseconds: Int?
    private var selfTestStarted = false

    // Fas 4: markeringar, anteckningar, bokmärken och sökning. Koden ligger sist i filen.
    /// Markeringsläget, gemensamt med PDF-läsaren (G12). Skapas när gesterna läggs in.
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
    private var markSelection: ReflowMarkSelection?
    private var bookmarks: [Bookmark] = []
    private var searchItem: UIBarButtonItem? {
        chrome.searchItem
    }

    private var markItem: UIBarButtonItem? {
        chrome.markItem
    }

    private var bookmarkItem: UIBarButtonItem? {
        chrome.bookmarkItem
    }
    private var bookSearch: BookSearch?
    private var lastQuery: String?
    /// V6: när boken senast lästes, läst innan läsaren sparar en ny plats, och om kortet redan prövats.
    private let lastReadDate: Date?
    private var resumeChecked = false

    init(book: Book) {
        self.book = book
        self.lastReadDate = LibraryStore.shared.positionDate(for: book)
        self.location = LibraryStore.shared.savedLocation(for: book) ?? ReflowLocation(chapter: 0, progression: 0)
        super.init(nibName: nil, bundle: nil)
        title = book.displayTitle
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
        NotificationCenter.default.addObserver(self, selector: #selector(savedWordMarksChanged),
                                               name: SavedWordMarks.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateTimelineMarks),
                                               name: AnnotationStore.didChange, object: nil)
        SavedWordMarks.shared.refresh()

        // Webbvyerna ligger längst ner, under ett papper, så att de aldrig syns.
        webHost.isUserInteractionEnabled = false
        view.addSubview(webHost)
        paperCover.backgroundColor = theme.paperColor
        paperCover.isUserInteractionEnabled = false
        paperCover.frame = view.bounds
        paperCover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(paperCover)

        setUpNavigationBar()
        setUpBottomBar()
        setUpBackStack()
        setUpTaps()
        // B5: stegen i exempelboken, en rad längst ner som inte tar tryck.
        OnboardingTips.shared.attach(to: view, book: book)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        loadContent()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyThemeToChrome()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard isMovingFromParent else { return }
        if let renderer = renderer {
            var line = "Stängde \(book.url.lastPathComponent): \(renderer.statsSummary)"
            if let first = renderer.firstSnapshotAt {
                line += " Första sidan syntes efter \(Int(((first - openedAt) * 1000).rounded())) ms."
            }
            AppLog.shared.write(line)
        }
        defer { SyncEngine.shared.syncSoon() }
        if isShowingPages {
            saveLocation()
        }
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
        renderer?.releaseMemory()
        bookSearch?.releaseMemory()
    }

    // MARK: Öppna boken

    private func loadContent() {
        WordDictionary.warmUpLanguageModels()
        spinner.startAnimating()
        let book = self.book
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<ReflowableBook, Error> in
                Result { try ReflowableBookLoader.load(book) }
            }.value
            self?.didLoad(result)
        }
    }

    private func didLoad(_ result: Result<ReflowableBook, Error>) {
        switch result {
        case .failure(let error):
            spinner.stopAnimating()
            SelfTest.log("FEL vid öppning: \(error.localizedDescription)")
            if SelfTest.isActive {
                SelfTest.finish()
            }
            let alert = UIAlertController(title: "Kunde inte öppna boken",
                                          message: error.localizedDescription,
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
                self?.navigationController?.popViewController(animated: true)
            })
            present(alert, animated: true)

        case .success(let content):
            self.content = content
            loadedAt = CACurrentMediaTime()
            AppLog.shared.write("Öppnade \(book.url.lastPathComponent) (\(content.chapters.count) kapitel), "
                                + "uppackad och läst efter \(Int(((loadedAt ?? openedAt) - openedAt) * 1000)) ms")
            if location.chapter < 0 || location.chapter >= content.chapters.count {
                location = ReflowLocation(chapter: 0, progression: 0)
            }
            title = book.customTitle ?? content.title
            let renderer = ReflowRenderer(book: content, host: webHost, theme: theme)
            renderer.onChapterMeasured = { [weak self] chapter in
                self?.chapterMeasured(chapter)
            }
            installMarksProvider(on: renderer)
            self.renderer = renderer
            // Sökregistret byggs i bakgrunden om det saknas, när de första sidorna hunnit visas (G11).
            SearchIndex.shared.prepare(SearchIndex.Key.make(for: book, chapters: content.chapters.count),
                                       source: .chapters(content.chapters.map { $0.url }), delay: 4)
            pendingJump = PendingJump(chapter: location.chapter, progression: location.progression, fragment: nil)
            bottomBar.slider.isEnabled = true
            updateTimelineMarks()
            updateLayoutIfNeeded(force: true)
        }
    }

    // MARK: Layout och läge

    /// Byter mellan en sida och uppslag, och delar kapitlen om i sidor när storlek eller typografi ändras.
    /// Att menyn visas eller döljs ändrar ingenting här, så sidan står still.
    private func updateLayoutIfNeeded(force: Bool = false) {
        guard let renderer = renderer else { return }
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }

        let insets = stableInsets(for: size)
        let newMode = preferredMode(for: size)
        let layout = makeLayout(size: size, insets: insets, mode: newMode)
        guard force || layout != lastLayout || newMode != mode else { return }

        if isShowingPages, pendingJump == nil, lastLayout != nil, layout != lastLayout {
            let here = currentLocation()
            pendingJump = PendingJump(chapter: here.chapter, progression: here.progression, fragment: nil)
        }
        mode = newMode
        lastLayout = layout
        renderer.configure(layout: layout, theme: theme)
        renderer.setWindow(center: pendingJump?.chapter ?? currentChapter)
        resolvePendingJump()
    }

    /// Marginalerna runt sidan följer skärmens hörn och kanter, men inte menyraden eller statusfältet.
    /// Överkanten har alltid plats för statusfältet, så att sidan inte hoppar när det visas eller döljs.
    private func stableInsets(for size: CGSize) -> UIEdgeInsets {
        let window = view.window?.safeAreaInsets ?? .zero
        if size != lastSize {
            seenTopInset = 0
            lastSize = size
        }
        seenTopInset = max(seenTopInset, window.top, 20)
        return UIEdgeInsets(top: seenTopInset, left: window.left, bottom: window.bottom, right: window.right)
    }

    private func preferredMode(for size: CGSize) -> Mode {
        let isPad = traitCollection.userInterfaceIdiom == .pad
        return isPad && size.width > size.height ? .spread : .single
    }

    /// Sidans storlek och textens marginaler. I ett uppslag är en sida halva bredden.
    private func makeLayout(size: CGSize, insets: UIEdgeInsets, mode: Mode) -> ReflowLayout {
        let pageWidth = mode == .spread ? (size.width / 2).rounded(.down) : size.width
        let factor = typography.margin.factor
        let side = min(max((pageWidth * 0.075 * factor).rounded(), 16), 90) + max(insets.left, insets.right)
        let padding = UIEdgeInsets(top: insets.top + 30, left: side, bottom: insets.bottom + 36, right: side)
        return ReflowLayout(pageSize: CGSize(width: pageWidth, height: size.height),
                            padding: padding,
                            typography: typography)
    }

    private func installPageController(with pages: [UIViewController]) {
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
        view.insertSubview(controller.view, aboveSubview: paperCover)
        controller.didMove(toParent: self)
        pageController = controller
        controllerMode = mode

        controller.setViewControllers(pages, direction: .forward, animated: false)

        // Pappersvikningens egna tryck ska bara gälla kanterna. Mitten styr menyn, och länkar har egna tryck.
        for recognizer in controller.gestureRecognizers where recognizer is UITapGestureRecognizer {
            recognizer.delegate = self
        }
        // Medan man markerar text står sidan still.
        for recognizer in controller.gestureRecognizers {
            recognizer.isEnabled = !markMode
        }
    }

    // MARK: Sidor och uppslag

    /// Antalet blad i ett kapitel. I ett uppslag avrundat uppåt till jämnt, så att nästa kapitel börjar till vänster.
    private func slots(forPageCount count: Int) -> Int {
        mode == .spread ? (count + 1) / 2 * 2 : count
    }

    private func makePage(chapter: Int, slot: Int) -> ReflowPageViewController? {
        guard let renderer = renderer, let layout = lastLayout else { return nil }
        let count = renderer.pageCount(of: chapter)
        let exists = count.map { slot < $0 } ?? true
        let side: ReflowPageViewController.Side
        switch mode {
        case .single: side = .single
        case .spread: side = slot % 2 == 0 ? .left : .right
        }
        let page = ReflowPageViewController(chapter: chapter,
                                            slot: slot,
                                            page: exists ? slot : nil,
                                            side: side,
                                            pageSize: layout.pageSize,
                                            renderer: renderer,
                                            paperColor: theme.paperColor)
        page.isBookmarked = !bookmarksOnPage(page).isEmpty
        page.showsRibbonHint = !chromeHidden
        page.onRetry = { [weak self] page in
            self?.retryChapter(page.chapter)
        }
        return page
    }

    /// Försök igen på ett kapitel som inte kunde visas (G2). Platsen man skulle till sparas, så att den
    /// visas när kapitlet väl mätts.
    private func retryChapter(_ chapter: Int) {
        guard let renderer = renderer else { return }
        if chapter == currentChapter {
            retryLocation = currentLocation()
        }
        renderer.retry(chapter: chapter)
        for page in visiblePages where page.chapter == chapter {
            page.reloadImage()
        }
    }

    /// Bladen som visar ett visst blad: ett i stående, två i ett uppslag.
    private func pageViewControllers(chapter: Int, slot: Int) -> [UIViewController] {
        switch mode {
        case .single:
            return [makePage(chapter: chapter, slot: slot)].compactMap { $0 }
        case .spread:
            let left = slot - slot % 2
            let pages = [makePage(chapter: chapter, slot: left), makePage(chapter: chapter, slot: left + 1)]
            let built = pages.compactMap { $0 }
            return built.count == 2 ? built : []
        }
    }

    private var visiblePages: [ReflowPageViewController] {
        (pageController?.viewControllers ?? []).compactMap { $0 as? ReflowPageViewController }
    }

    /// Visar en sida direkt, utan vikning.
    private func show(chapter: Int, page: Int) {
        guard let renderer = renderer else { return }
        if renderer.isTurning {
            deferredShow = (chapter, page)
            return
        }
        deferredShow = nil
        let count = renderer.pageCount(of: chapter) ?? 1
        currentChapter = chapter
        // Ett kapitel som inte kunde visas har inget riktigt sidantal, så den sparade platsen står kvar.
        currentCount = renderer.measuredPageCount(of: chapter)
        currentSlot = min(max(page, 0), count - 1)
        if mode == .spread {
            currentSlot -= currentSlot % 2
        }
        let pages = pageViewControllers(chapter: chapter, slot: currentSlot)
        guard !pages.isEmpty else { return }
        if let controller = pageController, controllerMode == mode {
            controller.setViewControllers(pages, direction: .forward, animated: false)
        } else {
            installPageController(with: pages)
        }
        isShowingPages = true
        spinner.stopAnimating()
        saveLocation()
        updatePageLabel()
        updateBookmarkState()
        keepNeighbours()
        if !resumeChecked {
            resumeChecked = true
            scheduleResumeCard()
        }
        startSelfTestIfNeeded()
    }

    /// Bladet efter eller före ett blad, även över kapitelgränser. Nil om grannkapitlet inte är mätt än.
    private func step(chapter: Int, slot: Int, forward: Bool) -> (chapter: Int, slot: Int)? {
        guard let renderer = renderer, let content = content else { return nil }
        if forward {
            if let count = renderer.pageCount(of: chapter) {
                if slot + 1 < slots(forPageCount: count) {
                    return (chapter, slot + 1)
                }
            } else if !(mode == .spread && slot % 2 == 0) {
                return nil
            } else {
                // Uppslaget måste bli helt, även innan kapitlet är mätt.
                return (chapter, slot + 1)
            }
            return chapter + 1 < content.chapters.count ? (chapter + 1, 0) : nil
        }
        if slot > 0 {
            return (chapter, slot - 1)
        }
        guard chapter > 0, let count = renderer.pageCount(of: chapter - 1) else { return nil }
        return (chapter - 1, slots(forPageCount: count) - 1)
    }

    /// Gör sidorna runt den man läser i förväg, viktigast först. Högst fem bilder.
    private func keepNeighbours() {
        guard let renderer = renderer else { return }
        var pages: [ReflowPage] = []
        func add(_ position: (chapter: Int, slot: Int)?) {
            guard let position = position else { return }
            let count = renderer.pageCount(of: position.chapter)
            if count.map({ position.slot < $0 }) ?? (position.slot == 0) {
                pages.append(ReflowPage(chapter: position.chapter, page: position.slot))
            }
        }
        let here = (chapter: currentChapter, slot: currentSlot)
        switch mode {
        case .single:
            let next = step(chapter: here.chapter, slot: here.slot, forward: true)
            add(here)
            add(next)
            add(step(chapter: here.chapter, slot: here.slot, forward: false))
            if let next = next {
                add(step(chapter: next.chapter, slot: next.slot, forward: true))
            }
        case .spread:
            let right = (chapter: here.chapter, slot: here.slot + 1)
            add(here)
            add(right)
            if let nextLeft = step(chapter: right.chapter, slot: right.slot, forward: true) {
                add(nextLeft)
                add(step(chapter: nextLeft.chapter, slot: nextLeft.slot, forward: true))
            }
            add(step(chapter: here.chapter, slot: here.slot, forward: false))
        }
        renderer.keep(pages)
        renderer.setWindow(center: currentChapter)
    }

    /// Bladen som syns har bytts, efter en vikning eller ett programmerat byte.
    private func pagesChanged() {
        guard let first = visiblePages.first else { return }
        currentChapter = first.chapter
        currentSlot = first.slot
        currentCount = renderer?.measuredPageCount(of: first.chapter)
        saveLocation()
        updatePageLabel()
        updateBookmarkState()
        keepNeighbours()
        backStack.pageTurned()
    }

    // MARK: Läsposition

    private func currentLocation() -> ReflowLocation {
        guard isShowingPages else { return location }
        guard let count = currentCount, count > 0 else {
            // Kapitlet är inte mätt (eller kunde inte visas): den sparade platsen i kapitlet står kvar.
            let progression = location.chapter == currentChapter ? location.progression : 0
            return ReflowLocation(chapter: currentChapter, progression: progression)
        }
        let page = min(currentSlot, count - 1)
        return ReflowLocation(chapter: currentChapter, progression: (Double(page) + 0.5) / Double(count))
    }

    private func saveLocation() {
        location = currentLocation()
        LibraryStore.shared.saveLocation(location, for: book)
    }

    /// Ett kapitel har mätts. Väntar läsaren på det kapitlet visas sidan nu.
    private func chapterMeasured(_ chapter: Int) {
        if firstMeasuredAt == nil {
            firstMeasuredAt = CACurrentMediaTime()
        }
        if let retry = retryLocation, retry.chapter == chapter, chapter == currentChapter, isShowingPages,
           pendingJump == nil, let count = renderer?.measuredPageCount(of: chapter) {
            // Kapitlet gick att visas efter Försök igen: till platsen man skulle till.
            retryLocation = nil
            show(chapter: chapter, page: Int(retry.progression * Double(count)))
        } else if chapter == currentChapter, isShowingPages, pendingJump == nil,
           let count = renderer?.measuredPageCount(of: chapter) {
            if let previous = currentCount, previous != count {
                // Kapitlet fick ett annat sidantal med samma layout (till exempel när ett typsnitt laddats klart).
                let progression = currentLocation().progression
                show(chapter: chapter, page: Int(progression * Double(count)))
            } else if currentCount == nil {
                // Man har bläddrat in i kapitlet innan det mättes. Sidan man är på stämmer redan.
                currentCount = count
                saveLocation()
            }
        }
        resolvePendingJump()
        updatePageLabel()
    }

    private func resolvePendingJump() {
        guard var jump = pendingJump, !jump.isResolving, let renderer = renderer,
              let count = renderer.pageCount(of: jump.chapter) else { return }
        if let fragment = jump.fragment {
            jump.isResolving = true
            pendingJump = jump
            renderer.page(ofFragment: fragment, in: jump.chapter) { [weak self] page in
                guard let self = self, self.pendingJump?.isResolving == true,
                      self.pendingJump?.chapter == jump.chapter else { return }
                self.pendingJump = nil
                self.show(chapter: jump.chapter, page: page ?? 0)
            }
            return
        }
        pendingJump = nil
        // Platsen man hoppar till står kvar som sparad plats om kapitlet inte kunde visas (G2).
        location = ReflowLocation(chapter: jump.chapter, progression: jump.progression)
        show(chapter: jump.chapter, page: Int(jump.progression * Double(count)))
    }

    /// Hoppar till en plats eller ett ankare. Sidan visas när kapitlet är mätt, oftast direkt.
    private func jump(to target: ReflowLocation, fragment: String? = nil) {
        guard let renderer = renderer else { return }
        pendingJump = PendingJump(chapter: target.chapter, progression: target.progression, fragment: fragment)
        renderer.setWindow(center: target.chapter)
        resolvePendingJump()
        if pendingJump != nil {
            spinner.startAnimating()
        }
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
            bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let slider = bottomBar.slider
        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.value = 0
        slider.isEnabled = false
        slider.addTarget(self, action: #selector(sliderMoved), for: .valueChanged)
        slider.addTarget(self, action: #selector(sliderReleased), for: [.touchUpInside, .touchUpOutside])

        bottomBar.pageButton.titleLabel?.lineBreakMode = .byTruncatingMiddle
        bottomBar.pageButton.accessibilityHint = "Öppnar innehållsförteckningen"
        bottomBar.pageButton.setTitle("Öppnar boken", for: .normal)
        bottomBar.pageButton.addTarget(self, action: #selector(showContents), for: .touchUpInside)
        bottomBar.infoButton.addTarget(self, action: #selector(toggleRemaining), for: .touchUpInside)
    }

    /// V1: ett tryck på sidor kvar växlar mellan kapitlet och boken.
    @objc private func toggleRemaining() {
        PageInfo.toggle(hasChapters: true)
        updatePageLabel()
    }

    /// V1: sidorna kvar efter den sista sidan som syns, i kapitlet eller i boken. Innan alla kapitel är mätta
    /// uppskattas boken från kapitlens storlek, och texten säger cirka.
    private func remainingText(renderer: ReflowRenderer) -> String {
        let last = visiblePages.compactMap { $0.page }.max() ?? currentSlot
        switch PageInfo.effectiveScope(hasChapters: true) {
        case .chapter:
            guard let count = currentCount else { return "" }
            return PageInfo.text(left: PageInfo.pagesLeft(lastShown: last, end: count), scope: .chapter)
        case .book:
            if let all = renderer.allPageCounts() {
                let before = all.prefix(currentChapter).reduce(0, +)
                return PageInfo.text(left: PageInfo.pagesLeft(lastShown: before + last, end: all.reduce(0, +)),
                                     scope: .book)
            }
            guard let total = estimatedBookPages() else { return "" }
            let shown = bookPageIndex(chapter: currentChapter, page: last)
            return PageInfo.text(left: PageInfo.pagesLeft(lastShown: shown, end: total), scope: .book, estimated: true)
        }
    }

    /// Bokens sidantal uppskattat från de mätta kapitlen och kapitlens storlek, tills alla kapitel är mätta.
    private func estimatedBookPages() -> Int? {
        guard let content = content, let renderer = renderer else { return nil }
        var measuredPages = 0
        var measuredWeight = 0
        for index in content.chapters.indices {
            if let count = renderer.pageCount(of: index) {
                measuredPages += count
                measuredWeight += content.chapters[index].weight
            }
        }
        guard measuredPages > 0, measuredWeight > 0 else { return nil }
        return Int((Double(content.totalWeight) * Double(measuredPages) / Double(measuredWeight)).rounded())
    }

    private func setUpTaps() {
        let link = UITapGestureRecognizer(target: self, action: #selector(handleLinkTap(_:)))
        link.delegate = self
        view.addGestureRecognizer(link)

        let chrome = UITapGestureRecognizer(target: self, action: #selector(toggleChrome))
        chrome.delegate = self
        view.addGestureRecognizer(chrome)

        let ribbon = UITapGestureRecognizer(target: self, action: #selector(handleRibbonTap(_:)))
        ribbon.delegate = self
        view.addGestureRecognizer(ribbon)
        ribbonTap = ribbon

        let press = WordPressGesture.makeRecognizer(target: self, action: #selector(handleWordPress(_:)), delegate: self)
        view.addGestureRecognizer(press)

        linkTap = link
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
        guard let content = content, let renderer = renderer, isShowingPages else { return }
        bottomBar.pageButton.setTitle(pageText(content: content, renderer: renderer), for: .normal)
        bottomBar.infoButton.setTitle(remainingText(renderer: renderer), for: .normal)
        bottomBar.chapterLabel.text = chapterName(currentChapter)
        chrome.setSubtitle(chapterName(currentChapter))
        if !bottomBar.slider.isTracking {
            bottomBar.slider.value = Float(content.fraction(at: currentLocation()))
        }
        reportReadingStatus(content: content, renderer: renderer)
    }

    /// Var man är, till biblioteket (B1, B2): andel läst, kapitlet, och sidan och sidantalet när hela boken
    /// är mätt, annars sidor kvar i kapitlet.
    private func reportReadingStatus(content: ReflowableBook, renderer: ReflowRenderer) {
        var status = ReadingStatus(progress: content.fraction(at: currentLocation()),
                                   chapter: content.title(ofChapter: currentChapter) ?? "")
        let slot = visiblePages.compactMap { $0.page }.max() ?? currentSlot
        if let count = currentCount, count > 0 {
            status.chapterLeft = max(count - slot - 1, 0)
        }
        if let all = renderer.allPageCounts() {
            status.page = all.prefix(currentChapter).reduce(0, +) + slot + 1
            status.pages = all.reduce(0, +)
        }
        LibraryStore.shared.saveStatus(status, for: book)
    }

    /// "s. 52 av 300" när hela boken är mätt, annars sidan i kapitlet: "s. 3 av 12 i kapitlet".
    /// Sidor kvar står till höger (V1), så procenten av boken behövs inte här.
    private func pageText(content: ReflowableBook, renderer: ReflowRenderer) -> String {
        let pages = visiblePages.compactMap { $0.page }
        let shown = pages.isEmpty ? [currentSlot] : pages
        if let all = renderer.allPageCounts() {
            let before = all.prefix(currentChapter).reduce(0, +)
            let total = all.reduce(0, +)
            let numbers = shown.map { String(before + $0 + 1) }.joined(separator: " och ")
            return "s. \(numbers) av \(total)"
        }
        let numbers = shown.map { String($0 + 1) }.joined(separator: " och ")
        guard let count = currentCount else {
            return "s. \(numbers) i kapitlet"
        }
        return "s. \(numbers) av \(count) i kapitlet"
    }

    /// Sidan i hela boken, från 0, till Sparade ord. Uppskattad från kapitlens storlek tills alla kapitel är mätta.
    private func bookPageIndex(chapter: Int, page: Int) -> Int {
        guard let content = content, let renderer = renderer else { return page }
        if let all = renderer.allPageCounts() {
            return all.prefix(chapter).reduce(0, +) + page
        }
        var measuredPages = 0
        var measuredWeight = 0
        for index in content.chapters.indices {
            if let count = renderer.pageCount(of: index) {
                measuredPages += count
                measuredWeight += content.chapters[index].weight
            }
        }
        guard measuredPages > 0, measuredWeight > 0 else { return page }
        let weightPerPage = Double(measuredWeight) / Double(measuredPages)
        let before = content.chapters.prefix(chapter).reduce(0) { $0 + $1.weight }
        return Int(Double(before) / weightPerPage) + page
    }

    // MARK: Reglaget

    @objc private func sliderMoved() {
        guard let content = content else { return }
        let target = content.location(atFraction: Double(bottomBar.slider.value))
        if bottomBar.slider.isTracking {
            let name = content.title(ofChapter: target.chapter) ?? "Avsnitt \(target.chapter + 1)"
            let page = pageLabel(for: target, content: content)
            bottomBar.pageButton.setTitle(page, for: .normal)
            // V2: kapitlet och sidan i bubblan ovanför fingret.
            bottomBar.slider.bubbleText = "\(name)\n\(page)"
        } else {
            // VoiceOver ändrar värdet utan att dra.
            jump(to: target)
        }
    }

    /// Sidan vid en plats, för bubblan när man drar (V2): i boken när alla kapitel är mätta, annars i kapitlet,
    /// och procent av boken om kapitlet inte är mätt än.
    private func pageLabel(for target: ReflowLocation, content: ReflowableBook) -> String {
        guard let renderer = renderer else { return "" }
        if let all = renderer.allPageCounts(), target.chapter >= 0, target.chapter < all.count {
            let count = all[target.chapter]
            let page = min(Int(target.progression * Double(count)), max(count - 1, 0))
            return "s. \(all.prefix(target.chapter).reduce(0, +) + page + 1) av \(all.reduce(0, +))"
        }
        if let count = renderer.pageCount(of: target.chapter), count > 0 {
            let page = min(Int(target.progression * Double(count)), count - 1)
            return "s. \(page + 1) av \(count) i kapitlet"
        }
        return "\(Int((content.fraction(at: target) * 100).rounded())) % av boken"
    }

    /// V2: kapitlen (innehållets översta nivå), markeringarna och bokmärkena på tidslinjen, som andelar av
    /// boken. En markerings plats i kapitlet uppskattas från kapitlets storlek. Ritas om bara när de ändras.
    @objc private func updateTimelineMarks() {
        guard let content = content else { return }
        let timeline = bottomBar.slider
        let top = content.toc.map(\.level).min()
        let starts = top.map { level in content.toc.filter { $0.level == level }.map(\.chapter) }
            ?? Array(content.chapters.indices)
        timeline.chapters = Array(Set(starts)).sorted().map {
            content.fraction(at: ReflowLocation(chapter: $0, progression: 0))
        }
        timeline.dots = AnnotationStore.shared.highlights(book: bookKey).compactMap { highlight in
            guard highlight.section >= 0, highlight.section < content.chapters.count else { return nil }
            let weight = Double(max(content.chapters[highlight.section].weight, 1))
            let location = ReflowLocation(chapter: highlight.section, progression: min(Double(highlight.start) / weight, 1))
            return ReaderTimeline.Dot(position: content.fraction(at: location), color: highlight.color.solid)
        }
        timeline.bookmarks = AnnotationStore.shared.bookmarks(book: bookKey).map {
            content.fraction(at: ReflowLocation(chapter: $0.section, progression: $0.progression))
        }
    }

    @objc private func sliderReleased() {
        guard let content = content else { return }
        hop(to: content.location(atFraction: Double(bottomBar.slider.value)))
    }

    // MARK: Innehåll

    @objc private func showContents() {
        guard let content = content, presentedViewController == nil else { return }
        let entries: [BookContentsViewController.Entry]
        let targets: [(chapter: Int, fragment: String?)]
        let currentRow: Int?
        if content.toc.isEmpty {
            // Ingen innehållsförteckning i boken: visa kapitlen.
            entries = content.chapters.indices.map { index in
                BookContentsViewController.Entry(title: content.chapters[index].title ?? "Avsnitt \(index + 1)", level: 0)
            }
            targets = content.chapters.indices.map { (chapter: $0, fragment: nil as String?) }
            currentRow = currentChapter
        } else {
            entries = content.toc.map { BookContentsViewController.Entry(title: $0.title, level: $0.level) }
            targets = content.toc.map { (chapter: $0.chapter, fragment: $0.fragment) }
            currentRow = content.toc.indices.last { content.toc[$0].chapter <= currentChapter }
        }

        let contents = BookContentsViewController(entries: entries,
                                                  currentRow: currentRow,
                                                  emptyText: "Boken har ingen innehållsförteckning.")
        contents.onSelect = { [weak self] row in
            guard row < targets.count else { return }
            self?.dismiss(animated: true)
            self?.hop(to: ReflowLocation(chapter: targets[row].chapter, progression: 0),
                      fragment: targets[row].fragment)
        }
        let container = ReaderContentsContainerViewController(contents: contents,
                                                             annotations: makeAnnotationsList(),
                                                             initial: 0)
        let navigation = UINavigationController(rootViewController: container)
        navigation.modalPresentationStyle = .popover
        navigation.popoverPresentationController?.barButtonItem = contentsItem
        present(navigation, animated: true)
    }

    // MARK: Typsnitt och storlek

    /// Aa: utseenderutan med bakgrund, storlek, typsnitt, marginal, radavstånd och justering (U2).
    /// Mätvärdena som rutan Text visade förut står i loggen när boken stängs.
    @objc private func showTypography() {
        guard presentedViewController == nil else { return }
        let controller = AppearanceViewController(theme: theme, typography: typography)
        controller.onTypography = { [weak self] value in
            self?.setTypography(value)
        }
        controller.onTheme = { [weak self] option in
            self?.setTheme(option)
        }
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .popover
        navigation.popoverPresentationController?.barButtonItem = typographyItem
        present(navigation, animated: true)
    }

    /// Ny typografi. Väntar en kort stund, så att flera tryck i rad bara delar om kapitlen en gång.
    private func setTypography(_ value: ReaderTypography) {
        typography = value
        ReaderTypography.current = value
        typographyTask?.cancel()
        typographyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.updateLayoutIfNeeded(force: true)
        }
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
        paperCover.backgroundColor = newTheme.paperColor
        applyThemeToChrome()
        if let layout = lastLayout {
            renderer?.configure(layout: layout, theme: newTheme)
        }
        for page in visiblePages {
            page.apply(paperColor: newTheme.paperColor)
        }
        keepNeighbours()
    }

    /// Menyraden och reglaget följer bakgrunden: mörka på mörkt papper, ljusa annars.
    private func applyThemeToChrome() {
        chrome.applyStyle(for: theme)
    }

    // MARK: Ordboken

    /// Hur långt från fingret ett ord får ligga och ändå väljas, i punkter (G12, samma i båda läsarna).
    static let fingerTolerance = WordPressGesture.fingerTolerance

    /// Ordet under fingret medan man håller.
    private struct PressedWord {
        let found: ReflowWord
        let page: ReflowPageViewController
        /// Var fingret var senast, i bladets vy.
        let finger: CGPoint
    }

    /// Håll fingret på ett ord, som i PDF-läsaren: ordet närmast fingret markeras och visas i en bubbla
    /// ovanför fingret, markeringen följer med om man drar, och rutan öppnas när man släpper.
    /// Ordet hittas i kapitlets dolda webbvy. Ett uppslag i taget, fingrets senaste plats väntar på tur.
    @objc private func handleWordPress(_ press: UILongPressGestureRecognizer) {
        let point = press.location(in: view)
        switch press.state {
        case .began:
            guard presentedViewController == nil else { return }
            // Trycket ska inte också vika sidan eller visa menyn när fingret lyfts.
            cancelPageGestures()
            pressEnded = false
            requestPressedWord(at: point)
        case .changed:
            guard presentedViewController == nil else { return }
            requestPressedWord(at: point)
            if pressedWord != nil {
                wordBubble.move(to: point)
            }
        case .ended:
            guard presentedViewController == nil else { return }
            pressEnded = true
            wordBubble.hide()
            if !wordQueryRunning {
                finishPress()
            }
        default:
            pressEnded = false
            queuedWordPoint = nil
            wordBubble.hide()
            clearPressedWord()
        }
    }

    private func pageView(at point: CGPoint) -> ReflowPageViewController? {
        visiblePages.first { candidate in
            !candidate.isBlank && candidate.hasImage
                && candidate.view.bounds.contains(candidate.view.convert(point, from: view))
        }
    }

    /// Frågar webbvyn efter ordet närmast fingret. Ligger fingret mellan ord ligger markeringen kvar.
    private func requestPressedWord(at point: CGPoint) {
        if wordQueryRunning {
            queuedWordPoint = point
            return
        }
        guard let renderer = renderer, let page = pageView(at: point), let number = page.page else { return }
        wordQueryRunning = true
        let local = page.view.convert(point, from: view)
        let tolerance = Self.fingerTolerance * page.pagePoint(CGPoint(x: 1, y: 0)).x
        renderer.word(at: page.pagePoint(local),
                      on: ReflowPage(chapter: page.chapter, page: number),
                      tolerance: tolerance) { [weak self, weak page] found in
            guard let self = self else { return }
            self.wordQueryRunning = false
            if let page = page, let found = found {
                self.setPressedWord(found, on: page, finger: local, screenPoint: point)
            } else if self.pressedWord != nil {
                self.pressedWord = self.pressedWord.map {
                    PressedWord(found: $0.found, page: $0.page, finger: local)
                }
            }
            if let next = self.queuedWordPoint, !self.pressEnded {
                self.queuedWordPoint = nil
                self.requestPressedWord(at: next)
                return
            }
            self.queuedWordPoint = nil
            if self.pressEnded {
                self.finishPress()
            }
        }
    }

    private func setPressedWord(_ found: ReflowWord, on page: ReflowPageViewController, finger: CGPoint, screenPoint: CGPoint) {
        if let current = pressedWord, current.page === page,
           current.found.word == found.word, current.found.rects.first == found.rects.first {
            pressedWord = PressedWord(found: current.found, page: page, finger: finger)
            return
        }
        pressedWord?.page.clearHighlight()
        page.showHighlight(found.rects)
        pressedWord = PressedWord(found: found, page: page, finger: finger)
        Haptics.shared.wordTapped()
        if !pressEnded {
            wordBubble.show(found.word, at: screenPoint)
        }
    }

    /// Fingret är släppt: slå upp ordet som var markerat.
    private func finishPress() {
        pressEnded = false
        guard let pressed = pressedWord else { return }
        presentWord(pressed.found, on: pressed.page, started: CACurrentMediaTime(), finger: pressed.finger)
    }

    private func clearPressedWord() {
        pressedWord?.page.clearHighlight()
        pressedWord = nil
    }

    /// Slår upp ordet och visar ordrutan vid ordet. Det enda stället där EPUB-läsaren använder ordboken.
    private func presentWord(_ found: ReflowWord,
                             on page: ReflowPageViewController,
                             started: CFTimeInterval,
                             finger: CGPoint? = nil,
                             onShown: (() -> Void)? = nil) {
        guard presentedViewController == nil else { return }
        guard let dictionary = WordDictionary.shared else {
            showMessage(title: "Ordboken saknas", message: "Den här versionen av appen byggdes utan ordboken.")
            return
        }
        OnboardingTips.shared.record(.word, book: book)
        let (sentence, range) = ReflowValues.sentence(before: found.before, word: found.word, after: found.after)
        var candidates = [found.word]
        if found.word.contains("-") {
            candidates.append(found.word.replacingOccurrences(of: "-", with: ""))
        }
        let hidden = UserWords.shared.hiddenPairs
        var lookup: WordLookup?
        for candidate in candidates {
            lookup = dictionary.lookup(candidate, sentence: sentence, rangeInSentence: range, hidden: hidden)
            if lookup != nil {
                break
            }
        }
        let lookupTime = (CACurrentMediaTime() - started) * 1000

        if pressedWord?.page !== page || pressedWord?.found.word != found.word {
            pressedWord?.page.clearHighlight()
            page.showHighlight(found.rects)
            pressedWord = PressedWord(found: found, page: page, finger: finger ?? .zero)
        }
        let rects = found.rects.map { page.viewRect($0) }
        let anchor = rects.first { rect in finger.map { rect.insetBy(dx: -6, dy: -6).contains($0) } ?? false }
            ?? rects.first
            ?? CGRect(x: page.view.bounds.midX, y: page.view.bounds.midY, width: 1, height: 1)
        let sourceRect = view.convert(anchor, from: page.view)
        let pageIndex = bookPageIndex(chapter: page.chapter, page: page.page ?? 0)

        // Ordet sparas i Sparade ord av rutan, när den syns.
        SelfTest.log("Ord: \(found.word), mening: \(sentence), grundform: \(lookup?.entries.first?.lemma ?? "hittades inte"), "
                     + "uppslag \(Int(lookupTime.rounded())) ms")

        let context = WordPopupViewController.Context(sentence: sentence,
                                                      rangeInSentence: range,
                                                      book: book.title,
                                                      pageIndex: pageIndex,
                                                      triedWord: found.word,
                                                      bookID: book.id)
        WordPopupViewController.present(
            lookup: lookup,
            context: context,
            from: self,
            sourceView: view,
            sourceRect: sourceRect,
            onReady: {
                LookupStats.shared.record(lookup: lookupTime, ready: (CACurrentMediaTime() - started) * 1000)
                onShown?()
            },
            onDismiss: { [weak self] in
                self?.clearPressedWord()
            })
    }

    /// Avbryter pappersvikningens, menyns och länkarnas tryck som redan har börjat.
    private func cancelPageGestures() {
        let others: [UIGestureRecognizer?] = [chromeTap, linkTap]
        WordPressGesture.cancel((pageController?.gestureRecognizers ?? []) + others.compactMap { $0 })
    }

    // MARK: Länkar

    private func link(at point: CGPoint) -> ReflowLink? {
        linkHit(at: point)?.link
    }

    /// Länken under en punkt och bladet den står på.
    private func linkHit(at point: CGPoint) -> (link: ReflowLink, page: ReflowPageViewController)? {
        for page in visiblePages where !page.isBlank {
            let local = page.view.convert(point, from: view)
            if page.view.bounds.contains(local) {
                return page.link(at: local).map { ($0, page) }
            }
        }
        return nil
    }

    @objc private func handleLinkTap(_ tap: UITapGestureRecognizer) {
        guard let hit = linkHit(at: tap.location(in: view)) else { return }
        if hit.link.isNote, showNote(hit.link, on: hit.page) {
            return
        }
        follow(hit.link.url)
    }

    /// V5: en fotnot i en ruta vid siffran. Noten letas upp i kapitelfilen i bakgrunden. Hittas den inte hoppar
    /// boken till noten som förut. Svarar false när länken inte går till ett ankare i boken.
    @discardableResult
    private func showNote(_ link: ReflowLink, on page: ReflowPageViewController) -> Bool {
        guard let content = content, link.url.isFileURL,
              let chapter = content.chapterIndex(for: link.url),
              let fragment = link.url.fragment.map({ $0.removingPercentEncoding ?? $0 }), !fragment.isEmpty else {
            return false
        }
        let file = content.chapters[chapter].url
        let anchor = view.convert(page.viewRect(link.rect), from: page.view)
        let started = CACurrentMediaTime()
        Task { @MainActor [weak self] in
            let text = await Task.detached(priority: .userInitiated) {
                NoteFinder.text(in: file, fragment: fragment)
            }.value
            guard let self = self, self.presentedViewController == nil else { return }
            guard let text = text else {
                AppLog.shared.write("Fotnoten hittades inte i kapitlet, hoppar dit i stället")
                self.follow(link.url)
                return
            }
            self.lastNoteMilliseconds = Int(((CACurrentMediaTime() - started) * 1000).rounded())
            NotePopoverViewController.present(from: self, sourceView: self.view, sourceRect: anchor,
                                              heading: "Not", text: text) { [weak self] in
                self?.follow(link.url)
            }
        }
        return true
    }

    /// En länk inom boken hoppar dit (med en Tillbaka-knapp). En webblänk öppnas i Safari i appen.
    private func follow(_ url: URL) {
        guard let content = content else { return }
        if url.isFileURL {
            guard let chapter = content.chapterIndex(for: url) else { return }
            let fragment = url.fragment.map { $0.removingPercentEncoding ?? $0 }
            hop(to: ReflowLocation(chapter: chapter, progression: 0), fragment: fragment)
        } else if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            let safari = SFSafariViewController(url: url)
            safari.dismissButtonStyle = .close
            present(safari, animated: true)
        }
    }

    // MARK: Här var du (V6)

    /// Kortet visas när boken öppnas efter mer än ett dygn, strax efter att första sidan syns.
    /// Självtestet visar kortet själv (`selfTestResumeCard`), så att det inte ligger över de andra bilderna.
    private func scheduleResumeCard() {
        guard !SelfTest.isActive, ReaderResumeCard.shouldShow(lastRead: lastReadDate) else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self = self, self.presentedViewController == nil else { return }
            self.showResumeCard(lastRead: self.lastReadDate)
        }
    }

    /// Kapitlets rubrik och de tre senaste markeringarna i boken.
    @discardableResult
    private func showResumeCard(lastRead: Date?) -> ReaderResumeCard {
        let latest = AnnotationStore.shared.highlights(book: bookKey).sorted { $0.created > $1.created }
        let card = ReaderResumeCard(chapter: chapterName(currentChapter), lastRead: lastRead,
                                    highlights: Array(latest.prefix(3)))
        card.show(in: view)
        return card
    }

    // MARK: Tillbaka och historik (V4)

    private func setUpBackStack() {
        backStack.install(in: view, above: bottomBar)
        chrome.backControl = backStack.control
        backStack.apply(Theme.palette(for: theme))
        backStack.onGo = { [weak self] location in
            self?.jump(to: location)
        }
        backStack.onChange = { [weak self] in
            guard let self = self else { return }
            self.chrome.setHistory(self.backStack.recentLabels) { [weak self] offset in
                self?.backStack.goBack(offset)
            }
        }
    }

    /// Ett hopp som användaren gör (innehåll, sök, länk, markering, bokmärke, reglaget): platsen man lämnar
    /// sparas, så att Tillbaka hittar dit. Samma mekanism som Tillbaka efter länkar hade förut (SPEC 6.3).
    private func hop(to target: ReflowLocation, fragment: String? = nil, sticky: Bool = false) {
        recordPlace(sticky: sticky)
        jump(to: target, fragment: fragment)
    }

    /// Sparar platsen man är på i historiken, före ett hopp.
    private func recordPlace(sticky: Bool = false) {
        guard isShowingPages else { return }
        backStack.record(currentLocation(), label: placeLabel(), sticky: sticky)
    }

    /// Platsen som den står i Tillbaka: sidan i boken när alla kapitel är mätta, annars kapitlet och sidan i det.
    private func placeLabel() -> String {
        if renderer?.allPageCounts() != nil {
            return "s. \(bookPageIndex(chapter: currentChapter, page: currentSlot) + 1)"
        }
        return "\(chapterName(currentChapter)), s. \(currentSlot + 1)"
    }

    /// Går tillbaka dit man var före senaste hoppet.
    private func goBack() {
        backStack.goBack()
    }

    // MARK: Meddelanden

    private func showMessage(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    /// Ett kort meddelande nere på sidan som försvinner av sig självt.
    private func showToast(_ text: String) {
        chrome.showToast(text)
    }

    // MARK: Bläddra med kod

    /// Viker fram nästa eller förra bladet, som ett tryck i kanten. Används av självtestet.
    private func turn(forward: Bool) {
        guard let controller = pageController,
              let first = visiblePages.first,
              let last = visiblePages.last else { return }
        let from = forward ? last : first
        guard let target = step(chapter: from.chapter, slot: from.slot, forward: forward) else { return }
        let pages = pageViewControllers(chapter: target.chapter, slot: target.slot)
        guard !pages.isEmpty else { return }
        controller.setViewControllers(pages, direction: forward ? .forward : .reverse, animated: true) { [weak self] _ in
            self?.pagesChanged()
        }
    }
}

// MARK: Pappersvikningen

extension ReflowReaderViewController: UIPageViewControllerDataSource, UIPageViewControllerDelegate {

    func pageViewController(_ pageViewController: UIPageViewController,
                            viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let page = viewController as? ReflowPageViewController,
              let target = step(chapter: page.chapter, slot: page.slot, forward: false) else { return nil }
        return makePage(chapter: target.chapter, slot: target.slot)
    }

    func pageViewController(_ pageViewController: UIPageViewController,
                            viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let page = viewController as? ReflowPageViewController,
              let target = step(chapter: page.chapter, slot: page.slot, forward: true) else { return nil }
        return makePage(chapter: target.chapter, slot: target.slot)
    }

    func pageViewController(_ pageViewController: UIPageViewController,
                            willTransitionTo pendingViewControllers: [UIViewController]) {
        Haptics.shared.prepareForPageTurn()
        PageTurnSound.shared.play()
        renderer?.isTurning = true
        // Skydd om vikningen aldrig rapporterar att den är klar: då ska förritning och hopp inte stå still.
        turnToken += 1
        let token = turnToken
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self = self, self.turnToken == token, self.renderer?.isTurning == true else { return }
            self.renderer?.isTurning = false
        }
    }

    func pageViewController(_ pageViewController: UIPageViewController,
                            didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController],
                            transitionCompleted completed: Bool) {
        renderer?.isTurning = false
        if let deferred = deferredShow {
            deferredShow = nil
            show(chapter: deferred.chapter, page: deferred.page)
            return
        }
        guard completed else { return }
        Haptics.shared.pageTurned()
        setChromeHidden(true, animated: true)
        pagesChanged()
        OnboardingTips.shared.record(.turn, book: book)
    }
}

// MARK: Tryckzoner

extension ReflowReaderViewController: UIGestureRecognizerDelegate {

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Reglaget, sidnumret och Tillbaka har egna tryck.
        if let touched = touch.view {
            if touched.isDescendant(of: bottomBar) {
                return false
            }
            if touched.isDescendant(of: backStack.control) {
                return false
            }
            if let bar = markBar, touched.isDescendant(of: bar) {
                return false
            }
            // Knappar på bladet, som Försök igen när ett kapitel inte kunde visas (G2).
            var ancestor: UIView? = touched
            while let current = ancestor, current !== view {
                if current is UIControl {
                    return false
                }
                ancestor = current.superview
            }
        }
        if gestureRecognizer === markDrag {
            return markMode
        }
        // Bandet i hörnet (U3) går före kanttrycket som bläddrar, menyn och länkarna.
        let onRibbon = !markMode && ribbonPage(at: touch.location(in: view)) != nil
        if gestureRecognizer === ribbonTap {
            return onRibbon
        }
        if onRibbon, gestureRecognizer is UITapGestureRecognizer {
            return false
        }
        // V5: en notsiffra går före ett ordstreck (O4), en markering och bläddringen.
        if !markMode, link(at: touch.location(in: view))?.isNote == true {
            return gestureRecognizer === linkTap || gestureRecognizer === wordPress
        }
        let onMark = markHit(at: touch.location(in: view)).map { hit in
            // O4: ett sparat ord tar trycket bara mitt på sidan, så att kanterna alltid bläddrar.
            !SavedWordMarks.isWordID(hit.id) || Self.isMiddle(touch.location(in: view).x, width: view.bounds.width)
        } ?? false
        if gestureRecognizer === markTap {
            return !markMode && onMark
        }
        if onMark, gestureRecognizer is UITapGestureRecognizer {
            // Ett tryck på en markering öppnar markeringens ruta, inte menyn, länken eller nästa sida.
            return false
        }
        if gestureRecognizer === wordPress {
            return true
        }
        let point = touch.location(in: view)
        let onLink = link(at: point) != nil
        if gestureRecognizer === linkTap {
            return onLink
        }
        if onLink {
            return false
        }
        let position = point.x / max(view.bounds.width, 1)
        let inMiddle = position > 0.3 && position < 0.7
        if gestureRecognizer === chromeTap {
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

// MARK: Självtestet

extension ReflowReaderViewController {

    private func startSelfTestIfNeeded() {
        // Bara boken som självtestet startades med. Exempelboken som fas 6 öppnar (B5) kör inget läsartest.
        guard SelfTest.isActive, SelfTest.bookName == book.url.lastPathComponent, !selfTestStarted else { return }
        selfTestStarted = true
        Task { @MainActor [weak self] in
            await self?.runSelfTest()
        }
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Väntar tills en ny sida visas och bladen som syns har sina bilder, högst femton sekunder.
    private func waitUntilShown() async -> Bool {
        for _ in 0..<150 {
            if pendingJump == nil, isShowingPages, !visiblePages.isEmpty,
               visiblePages.allSatisfy({ $0.isBlank || $0.hasImage }) {
                return true
            }
            await pause(0.1)
        }
        return false
    }

    private func logState(_ label: String) {
        let pages = visiblePages.map { page in
            "kapitel \(page.chapter + 1) blad \(page.slot + 1)\(page.isBlank ? " (tomt)" : "")\(page.hasImage ? "" : " UTAN BILD")"
        }
        let counts = (0..<(content?.chapters.count ?? 0)).map { renderer?.pageCount(of: $0).map(String.init) ?? "?" }
        let size = "\(Int(view.bounds.width))x\(Int(view.bounds.height))"
        SelfTest.log("\(label): \(pages.joined(separator: ", ")). Etikett: \(bottomBar.pageButton.title(for: .normal) ?? ""), "
                     + "\(bottomBar.infoButton.title(for: .normal) ?? ""). "
                     + "Sidantal per kapitel: \(counts.joined(separator: " ")). Vy \(size), \(mode == .spread ? "uppslag" : "en sida"), "
                     + "layout \(lastLayout?.key ?? "ingen")")
    }

    private func runSelfTest() async {
        guard let content = content, let renderer = renderer else {
            SelfTest.finish()
            return
        }
        SelfTest.log("Bok: \(content.title), \(content.chapters.count) kapitel, \(content.toc.count) rader i innehållet")
        SelfTest.log("Innehåll: " + content.toc.prefix(12).map { "\($0.title) (kap \($0.chapter + 1))" }.joined(separator: "; "))

        let firstShown = await waitUntilShown()
        func since(_ time: CFTimeInterval?) -> Int {
            Int((((time ?? CACurrentMediaTime()) - openedAt) * 1000).rounded())
        }
        SelfTest.log("Första sidan: \(firstShown ? "ok efter \(since(nil)) ms" : "FEL, sidbilden kom inte"). "
                     + "Boken uppackad och läst efter \(since(loadedAt)) ms, första kapitlet mätt efter \(since(firstMeasuredAt)) ms.")
        logState("Start")
        SelfTest.saveScreen(view, name: "01-start")

        for _ in 0..<4 {
            turn(forward: true)
            await pause(1.2)
        }
        _ = await waitUntilShown()
        logState("Efter fyra sidor")
        SelfTest.saveScreen(view, name: "02-fyra-sidor")

        await selfTestWord(name: "03-ord")
        await selfTestAnnotations()
        await selfTestResumeCard()

        let isFull = SelfTest.bookName?.lowercased().hasSuffix(".epub") == true
        if isFull, content.toc.count > 2 {
            jump(to: ReflowLocation(chapter: content.toc[2].chapter, progression: 0), fragment: content.toc[2].fragment)
            _ = await waitUntilShown()
            logState("Innehållets tredje rad")
            SelfTest.saveScreen(view, name: "04-innehall")

            if let link = visiblePages.flatMap({ $0.links }).first(where: { $0.url.isFileURL }) {
                await selfTestNote(link)
                SelfTest.log("Följer länken \(link.url.lastPathComponent)#\(link.url.fragment ?? "")")
                follow(link.url)
                _ = await waitUntilShown()
                logState("Efter länken")
                SelfTest.log("Tillbaka (V4): \(backStack.isShowing ? "syns" : "FEL, syns inte"), knappen visar "
                             + "\(backStack.control.title ?? "inget"), senaste platser \(backStack.recentLabels.joined(separator: ", "))")
                SelfTest.saveScreen(view, name: "05-lank")
                goBack()
                _ = await waitUntilShown()
                logState("Tillbaka")
                SelfTest.log("Efter Tillbaka: knappen \(backStack.isShowing ? "FEL, syns" : "dold"), "
                             + "kvar i historiken \(backStack.recentLabels.count)")
                SelfTest.saveScreen(view, name: "06-tillbaka")
            } else {
                SelfTest.log("FEL: inga länkar på sidan")
            }
            await selfTestBrokenChapter()
        }

        // Spara Edvins inställningar och återställ dem sist, även i simulatorn.
        let savedTypography = typography
        let savedTheme = theme

        var bigger = typography
        bigger.sizeIndex = min(ReaderTypography.defaultSizeIndex + 2, ReaderTypography.sizes.count - 1)
        setTypography(bigger)
        await pause(0.6)
        _ = await waitUntilShown()
        logState("Större text")
        SelfTest.saveScreen(view, name: "07-storre")

        var font = bigger
        font.font = .georgia
        setTypography(font)
        await pause(0.6)
        _ = await waitUntilShown()
        logState("Georgia")
        SelfTest.saveScreen(view, name: "08-georgia")

        setTheme(.dark)
        await pause(0.4)
        _ = await waitUntilShown()
        SelfTest.saveScreen(view, name: "09-morkt")
        setTheme(.sepia)
        await pause(0.4)
        _ = await waitUntilShown()
        SelfTest.saveScreen(view, name: "10-sepia")
        setTheme(.white)
        await pause(0.4)
        _ = await waitUntilShown()
        SelfTest.saveScreen(view, name: "10b-vitt")
        setTheme(.paper)
        await pause(0.4)
        _ = await waitUntilShown()
        SelfTest.saveScreen(view, name: "10c-papper")

        await selfTestAppearance()

        setTheme(savedTheme)
        setTypography(savedTypography)
        await pause(0.6)
        _ = await waitUntilShown()
        logState("Återställd typografi")

        if isFull {
            await selfTestSpread()
        }

        SelfTest.log(renderer.statsSummary)
        SelfTest.finish()
    }

    /// G2: ett kapitel som inte går att mäta visar Kapitlet kunde inte visas och Försök igen, en krasch i
    /// webbvyn räknas som ett fel, och en minnesvarning stänger de dolda webbvyerna utom den man läser.
    /// V6: kortet Här var du med kapitlet och de tre senaste markeringarna, och ett tryck stänger det.
    private func selfTestResumeCard() async {
        SelfTest.log("Här var du (V6): boken lästes senast \(lastReadDate.map { "\($0)" } ?? "aldrig"), kortet skulle "
                     + (ReaderResumeCard.shouldShow(lastRead: lastReadDate) ? "visas" : "inte visas"))
        let card = showResumeCard(lastRead: Date().addingTimeInterval(-3 * 86_400))
        await pause(0.6)
        SelfTest.log("Kortet: \(card.summary)")
        SelfTest.saveScreen(view, name: "03j-har-var-du")
        card.close()
        await pause(0.5)
        SelfTest.log("Efter ett tryck: kortet \(card.superview == nil ? "stängt" : "FEL, ligger kvar")")
    }

    /// V5: fotnoten visas i en ruta vid siffran, och trycket på siffran går före bläddringen.
    private func selfTestNote(_ link: ReflowLink) async {
        guard let page = visiblePages.first(where: { $0.links.contains { $0.url == link.url } }) else {
            SelfTest.log("FEL: hittade inte bladet med fotnoten")
            return
        }
        let center = view.convert(CGPoint(x: page.viewRect(link.rect).midX, y: page.viewRect(link.rect).midY), from: page.view)
        let tapGoesToLink = self.link(at: center)?.isNote == true
        SelfTest.log("Fotnoten (V5): länken räknas som not \(link.isNote ? "ja" : "FEL, nej"), trycket på siffran hittar noten "
                     + "\(tapGoesToLink ? "ja" : "FEL, nej")")
        lastNoteMilliseconds = nil
        showNote(link, on: page)
        for _ in 0..<40 where !(presentedViewController is NotePopoverViewController) {
            await pause(0.1)
        }
        if let note = presentedViewController as? NotePopoverViewController {
            await pause(0.5)
            SelfTest.log("Fotnoten i rutan: \"\(note.noteText.prefix(80))\" efter \(lastNoteMilliseconds.map { "\($0)" } ?? "?") ms, "
                         + "\(Int(note.preferredContentSize.width)) x \(Int(note.preferredContentSize.height)) punkter")
            SelfTest.saveScreen(note.view, name: "04b-fotnot")
            dismiss(animated: false)
            await pause(0.3)
        } else {
            SelfTest.log("FEL: fotnoten visades inte i en ruta")
        }
    }

    private func selfTestBrokenChapter() async {
        guard let renderer = renderer, let content = content, content.chapters.count > 4 else { return }
        let start = currentLocation()
        let broken = content.chapters.count - 2
        renderer.simulateFailures(3, inChapter: broken)
        jump(to: ReflowLocation(chapter: broken, progression: 0.5))
        var shown = false
        for _ in 0..<150 where !shown {
            await pause(0.1)
            shown = visiblePages.contains { $0.showsFailure }
        }
        let saved = LibraryStore.shared.savedLocation(for: book)
        SelfTest.log("Kapitelfel: \(shown ? "Kapitlet kunde inte visas syns" : "FEL, felet syns inte"), "
                     + "\(renderer.failureCount(inChapter: broken)) fel i kapitlet, sparad plats kapitel "
                     + "\((saved?.chapter ?? -1) + 1) andel \(saved.map { String(format: "%.2f", $0.progression) } ?? "?")"
                     + ((saved?.chapter == broken && saved?.progression == 0.5) ? "" : " FEL, platsen skrevs över"))
        SelfTest.saveScreen(view, name: "06b-kapitelfel")

        visiblePages.first { $0.showsFailure }?.simulateRetryTap()
        _ = await waitUntilShown()
        await pause(0.5)
        _ = await waitUntilShown()
        let measured = renderer.measuredPageCount(of: broken)
        SelfTest.log("Försök igen: \(measured.map { "kapitlet mättes, \($0) sidor" } ?? "FEL, kapitlet mättes inte"), "
                     + "\(visiblePages.contains { $0.showsFailure } ? "FEL, felet syns fortfarande" : "felet borta"), "
                     + "\(renderer.failureCount(inChapter: broken)) fel kvar")
        logState("Efter Försök igen")
        SelfTest.saveScreen(view, name: "06c-forsok-igen")

        // En krasch mitt i en fråga till webbvyn räknas som ett fel, inte två.
        let chapter = currentChapter
        var answered = false
        if let page = visiblePages.first(where: { !$0.isBlank }), let number = page.page {
            renderer.word(at: CGPoint(x: 100, y: 200), on: ReflowPage(chapter: chapter, page: number)) { _ in
                answered = true
            }
        }
        let crashed = renderer.simulateTermination(ofChapter: chapter)
        let right = renderer.failureCount(inChapter: chapter)
        await pause(1.0)
        _ = await waitUntilShown()
        SelfTest.log("Krasch i webbvyn: \(crashed ? "simulerad" : "FEL, kapitlet var inte laddat"), "
                     + "\(right) fel direkt\(right > 1 ? " FEL, räknades flera gånger" : ""), "
                     + "\(renderer.failureCount(inChapter: chapter)) fel efter omladdningen, frågan "
                     + (answered ? "fick svar" : "FEL, fick inget svar"))

        // Minnesvarning: bara kapitlet man läser behåller sin webbvy.
        let before = renderer.loadedViewCount
        renderer.releaseMemory()
        let after = renderer.loadedViewCount
        turn(forward: true)
        await pause(1.5)
        _ = await waitUntilShown()
        SelfTest.log("Minnesvarning: \(before) webbvyer före, \(after) efter\(after > 1 ? " FEL" : ""), "
                     + "\(renderer.loadedViewCount) efter en sida till")
        logState("Efter minnesvarningen")

        jump(to: start)
        _ = await waitUntilShown()
    }

    /// Vrider till liggande för att pröva uppslaget. Vrider inte simulatorn görs läsarens yta bred i stället.
    private func selfTestSpread() async {
        var rotated = false
        if #available(iOS 16.0, *), let scene = view.window?.windowScene {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { error in
                SelfTest.log("Vridningen nekades: \(error.localizedDescription)")
            }
            await pause(2.0)
            rotated = view.bounds.width > view.bounds.height
        }
        let container = navigationController?.view
        let original = container?.frame ?? .zero
        if !rotated, let container = container {
            container.frame = CGRect(x: 0, y: 0, width: original.width, height: (original.width * 0.72).rounded())
            await pause(1.0)
        }
        SelfTest.log(rotated ? "Uppslag: simulatorn vreds till liggande" : "Uppslag: läsarens yta gjordes bred (simulatorn vred inte)")
        _ = await waitUntilShown()
        logState("Liggande")
        SelfTest.saveScreen(view, name: "11-liggande")
        turn(forward: true)
        await pause(1.5)
        _ = await waitUntilShown()
        logState("Liggande efter ett uppslag")
        SelfTest.saveScreen(view, name: "12-liggande-uppslag")
        for _ in 0..<6 {
            turn(forward: true)
            await pause(1.2)
        }
        _ = await waitUntilShown()
        logState("Liggande efter sex uppslag till")
        SelfTest.saveScreen(view, name: "13-liggande-senare")

        if rotated, #available(iOS 16.0, *), let scene = view.window?.windowScene {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        } else {
            container?.frame = original
        }
        await pause(2.0)
        _ = await waitUntilShown()
        logState("Stående igen")
    }

    /// Letar upp ett ord på sidan och slår upp det, som när fingret hålls stilla på det.
    private func selfTestWord(name: String) async {
        guard let renderer = renderer,
              let page = visiblePages.first(where: { !$0.isBlank && $0.hasImage }),
              let number = page.page else {
            SelfTest.log("FEL: ingen sida att slå upp ord på")
            return
        }
        let size = page.view.bounds.size
        for row in 2...8 {
            for column in [3, 5, 7] {
                let local = CGPoint(x: size.width * CGFloat(column) / 10, y: size.height * CGFloat(row) / 10)
                let found: ReflowWord? = await withCheckedContinuation { continuation in
                    renderer.word(at: page.pagePoint(local),
                                  on: ReflowPage(chapter: page.chapter, page: number),
                                  tolerance: Self.fingerTolerance) { word in
                        continuation.resume(returning: word)
                    }
                }
                guard found != nil else { continue }
                // Samma väg som fingret: håll (markering och bubbla), släpp (rutan öppnas).
                let screen = view.convert(local, from: page.view)
                pressEnded = false
                requestPressedWord(at: screen)
                await pause(0.6)
                SelfTest.log("Hållgesten: \(pressedWord?.found.word ?? "FEL, inget ord markerat"), "
                             + "bubblan visar \(wordBubble.text ?? "ingenting")")
                SelfTest.saveScreen(view, name: name + "-haller")
                pressEnded = true
                wordBubble.hide()
                finishPress()
                await pause(1.5)
                SelfTest.saveScreen(view.window ?? view, name: name)
                // Ordet sparas när rutan syns, eller senast när den stängs.
                let shownWord = UserWords.shared.savedWords().first?.word ?? "inget"
                dismiss(animated: false)
                await pause(0.3)
                SelfTest.log("Senast sparade ord medan rutan syns: \(shownWord), efter att den stängts: "
                             + "\(UserWords.shared.savedWords().first?.word ?? "inget"). "
                             + (LookupStats.shared.summary ?? "Ingen tid för rutan."))
                clearPressedWord()
                await selfTestWordMarks(name: name)
                return
            }
        }
        SelfTest.log("FEL: hittade inget ord på sidan")
    }

    /// O4: ordet som just slogs upp är sparat och ska ha fått ett streck på sidan, och ett tryck på strecket
    /// ska hitta ordet.
    fileprivate func selfTestWordMarks(name: String) async {
        // Ordet som slogs upp kan vara ett småord, som inte får något streck. Två ord ur testböckerna sparas
        // därför också, som om de slagits upp.
        for word in ["kunskap", "vacker"] {
            UserWords.shared.save(word: word, lemma: word, language: .swedish, sentence: word, book: book.title,
                                  pageIndex: 0, bookID: book.id)
        }
        var shown: [ReflowMarkRect] = []
        for _ in 0..<30 {
            await pause(0.2)
            shown = visiblePages.flatMap { $0.marks }.filter { SavedWordMarks.isWordID($0.id) }
            if !shown.isEmpty {
                break
            }
        }
        var tapped = "INGET"
        if let first = shown.first,
           let page = visiblePages.first(where: { !$0.markRects(id: first.id).isEmpty }),
           let rect = page.markRects(id: first.id).first {
            let center = view.convert(CGPoint(x: rect.midX, y: rect.midY), from: page.view)
            tapped = markHit(at: center)?.id ?? "INGET"
        }
        SelfTest.log("Dina ord i texten (O4): \(shown.count) streck på sidorna, former \(SavedWordMarks.shared.forms.count), "
                     + "tryck på strecket hittar \(tapped)")
        SelfTest.saveScreen(view, name: name + "-ordstreck")
    }
}

// MARK: Markeringar, anteckningar, bokmärken och sökning (fas 4)

/// Det fingret drar över medan man markerar. Punkterna är i sidans koordinater i renderaren.
fileprivate struct ReflowMarkSelection {
    let page: ReflowPageViewController
    let address: ReflowPage
    let start: CGPoint
    var last: CGPoint
    let startScreen: CGPoint
    var moved = false
    /// Markeringen fingret började på, om det var ett tryck på en markering.
    let tappedMark: String?
    var range: ReflowTextRange?
    /// En fråga till webbvyn pågår, och fingret har flyttat sig sedan den skickades.
    var querying = false
    var pending = false
    /// Fingret har lyfts: markeringen sparas när svaret kommer.
    var ended = false
}

extension ReflowReaderViewController {

    fileprivate var bookKey: String {
        AnnotationStore.key(for: book)
    }

    fileprivate func setUpMarkGestures() {
        let marking = MarkMode(host: view, target: self, drag: #selector(handleMarkDrag(_:)),
                               tap: #selector(handleMarkTap(_:)), delegate: self)
        marking.onTurn = { [weak self] forward in
            PageTurnSound.shared.play()
            self?.turn(forward: forward)
        }
        marking.onDone = { [weak self] in
            self?.setMarkMode(false)
        }
        self.marking = marking
        PageTurnSound.shared.prepare()
        bookmarksChanged()
    }

    /// Renderaren lägger in kapitlets markeringar när kapitlet laddas.
    fileprivate func installMarksProvider(on renderer: ReflowRenderer) {
        let key = bookKey
        renderer.marksProvider = { chapter in
            ReflowMarks.arguments(for: AnnotationStore.shared.highlights(book: key, section: chapter))
        }
        renderer.wordsProvider = {
            SavedWordMarks.shared.forms
        }
    }

    /// O4: de sparade orden har ändrats, eller strecken slogs av eller på: lägg in dem igen i kapitlen som syns.
    @objc fileprivate func savedWordMarksChanged() {
        // Även kapitel som är laddade men inte syns, så att nästa kapitel också har strecken.
        let shown = Set(visiblePages.filter { !$0.isBlank }.map(\.chapter))
        for chapter in shown.union(renderer?.loadedChapters ?? []) {
            reloadMarks(inChapter: chapter)
        }
    }

    /// Mitten av sidan, där ett tryck inte bläddrar.
    fileprivate static func isMiddle(_ x: CGFloat, width: CGFloat) -> Bool {
        let position = x / max(width, 1)
        return position > 0.3 && position < 0.7
    }

    /// O4: ett tryck på ett streck visar ordkortet för det sparade ordet, med meningen det sparades i.
    fileprivate func presentSavedWord(id: String, page: ReflowPageViewController, at point: CGPoint) {
        guard presentedViewController == nil, let word = SavedWordMarks.word(fromID: id),
              let saved = UserWords.shared.savedWords().first(where: { $0.lemma == word.lemma && $0.language == word.language })
        else { return }
        let lookup = WordDictionary.shared?.lookup(saved.word, sentence: saved.sentence, language: saved.language,
                                                   hidden: UserWords.shared.hiddenPairs)
        var context = WordPopupViewController.Context(sentence: saved.sentence, rangeInSentence: nil, book: saved.book,
                                                      pageIndex: saved.pageIndex, triedWord: saved.word)
        context.savesWord = false
        let anchor = HighlightMenuViewController.anchor(for: page.markRects(id: id), in: view, from: page.view,
                                                        fallback: point)
        WordPopupViewController.present(lookup: lookup, context: context, from: self, sourceView: view,
                                        sourceRect: anchor, onReady: {}, onDismiss: {})
    }

    /// Markeringarna i ett kapitel har ändrats: lägg in dem igen och rita om sidorna.
    fileprivate func reloadMarks(inChapter chapter: Int) {
        updateTimelineMarks()
        renderer?.reloadMarks(in: chapter) { [weak self] in
            guard let self = self else { return }
            for page in self.visiblePages where page.chapter == chapter {
                page.reloadImage()
            }
            self.keepNeighbours()
        }
    }

    fileprivate func markHit(at point: CGPoint) -> (page: ReflowPageViewController, id: String)? {
        for page in visiblePages where !page.isBlank {
            let local = page.view.convert(point, from: view)
            if page.view.bounds.contains(local), let id = page.markID(at: local) {
                return (page, id)
            }
        }
        return nil
    }

    fileprivate func chapterName(_ chapter: Int) -> String {
        content?.title(ofChapter: chapter) ?? "Avsnitt \(chapter + 1)"
    }

    // MARK: Markera med fingret

    @objc fileprivate func toggleMarkMode() {
        setMarkMode(!markMode)
    }

    /// Markeringsläget: sidan står still, och fingret markerar det det drar över.
    fileprivate func setMarkMode(_ on: Bool) {
        let others: [UIGestureRecognizer?] = [chromeTap, linkTap, wordPress]
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
            guard let page = visiblePages.first(where: { candidate in
                !candidate.isBlank && candidate.hasImage
                    && candidate.view.bounds.contains(candidate.view.convert(point, from: view))
            }), let number = page.page else { return }
            let local = page.view.convert(point, from: view)
            let pagePoint = page.pagePoint(local)
            let tapped = page.markID(at: local).flatMap { SavedWordMarks.isWordID($0) ? nil : $0 }
            markSelection = ReflowMarkSelection(page: page,
                                                address: ReflowPage(chapter: page.chapter, page: number),
                                                start: pagePoint,
                                                last: pagePoint,
                                                startScreen: point,
                                                tappedMark: tapped)
            if tapped == nil {
                requestMarkRange()
            }

        case .changed:
            guard var selection = markSelection else { return }
            if !selection.moved, hypot(point.x - selection.startScreen.x, point.y - selection.startScreen.y) > 6 {
                selection.moved = true
            }
            var local = selection.page.view.convert(point, from: view)
            let bounds = selection.page.view.bounds
            local.x = min(max(local.x, 1), bounds.width - 1)
            local.y = min(max(local.y, 1), bounds.height - 1)
            selection.last = selection.page.pagePoint(local)
            markSelection = selection
            if selection.moved {
                requestMarkRange()
            }

        case .ended:
            guard var selection = markSelection else { return }
            if !selection.moved, let id = selection.tappedMark {
                markSelection = nil
                presentMarkMenu(id: id, at: point)
                return
            }
            selection.ended = true
            markSelection = selection
            requestMarkRange()

        default:
            markSelection?.page.clearPreview()
            markSelection = nil
        }
    }

    /// Frågar webbvyn vad som ligger mellan punkterna. En fråga i taget, den senaste punkten vinner.
    fileprivate func requestMarkRange() {
        guard var selection = markSelection, let renderer = renderer else { return }
        if selection.querying {
            selection.pending = true
            markSelection = selection
            return
        }
        selection.querying = true
        selection.pending = false
        markSelection = selection
        let address = selection.address
        let arguments: [String: Any] = [
            "index": address.page,
            "x1": Double(selection.start.x), "y1": Double(selection.start.y),
            "x2": Double(selection.last.x), "y2": Double(selection.last.y),
        ]
        renderer.evaluate("return lasaMarks.select(index, x1, y1, x2, y2);", arguments: arguments,
                          in: address.chapter) { [weak self] value in
            self?.markRangeArrived(ReflowMarks.textRange(from: value), for: address)
        }
    }

    fileprivate func markRangeArrived(_ range: ReflowTextRange?, for address: ReflowPage) {
        guard var selection = markSelection, selection.address == address else { return }
        selection.querying = false
        if let range = range {
            selection.range = range
            selection.page.showPreview(range.rects, color: ReaderSettings.highlightColor, dark: theme.isDark)
        }
        markSelection = selection
        if selection.pending {
            requestMarkRange()
            return
        }
        guard selection.ended else { return }
        markSelection = nil
        guard let range = selection.range else {
            selection.page.clearPreview()
            return
        }
        createHighlight(chapter: address.chapter, range: range)
    }

    fileprivate func createHighlight(chapter: Int, range: ReflowTextRange) {
        guard !range.text.isEmpty else { return }
        OnboardingTips.shared.record(.highlight, book: book)
        let highlight = AnnotationStore.shared.addHighlight(book: bookKey, section: chapter, start: range.start,
                                                            length: range.length, text: range.text,
                                                            color: ReaderSettings.highlightColor)
        if highlight.start != range.start || highlight.length != range.length {
            // Den nya markeringen slogs ihop med en gammal: hämta texten för hela intervallet.
            renderer?.evaluate("return lasaMarks.text(start, length);",
                               arguments: ["start": highlight.start, "length": highlight.length],
                               in: chapter) { value in
                guard let text = value as? String, !text.isEmpty,
                      var current = AnnotationStore.shared.highlight(id: highlight.id) else { return }
                current.text = text
                AnnotationStore.shared.update(current)
            }
        }
        reloadMarks(inChapter: chapter)
        Haptics.shared.wordTapped()
    }

    // MARK: Rutan för en markering

    @objc fileprivate func handleMarkTap(_ tap: UITapGestureRecognizer) {
        let point = tap.location(in: view)
        guard let hit = markHit(at: point) else { return }
        if SavedWordMarks.isWordID(hit.id) {
            presentSavedWord(id: hit.id, page: hit.page, at: point)
            return
        }
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
            self?.reloadMarks(inChapter: changed.section)
        }
        menu.onNote = { [weak self] in
            self?.editNote(highlightID: id)
        }
        menu.onDelete = { [weak self] in
            guard let current = AnnotationStore.shared.highlight(id: id) else { return }
            AnnotationStore.shared.delete(current)
            self?.reloadMarks(inChapter: current.section)
        }
        let page = visiblePages.first { !$0.isBlank && !$0.markRects(id: id).isEmpty }
        let anchor = page.map { HighlightMenuViewController.anchor(for: $0.markRects(id: id), in: view,
                                                                   from: $0.view, fallback: point) }
            ?? CGRect(x: point.x - 1, y: point.y - 10, width: 2, height: 20)
        let pageIndex = page.map { bookPageIndex(chapter: $0.chapter, page: $0.page ?? 0) }
        menu.onLookUp = { [weak self] in
            guard let self = self else { return }
            HighlightLookUp.present(highlight, book: self.book, pageIndex: pageIndex, from: self,
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
            self?.reloadMarks(inChapter: current.section)
        }
    }

    // MARK: Bokmärken

    fileprivate func bookmarksChanged() {
        updateTimelineMarks()
        bookmarks = AnnotationStore.shared.bookmarks(book: bookKey)
        for page in visiblePages {
            page.isBookmarked = !bookmarksOnPage(page).isEmpty
        }
        updateBookmarkState()
    }

    /// Bokmärkena som hamnar på en sida, med kapitlets nuvarande sidantal.
    fileprivate func bookmarksOnPage(_ page: ReflowPageViewController) -> [Bookmark] {
        guard let number = page.page, let count = renderer?.pageCount(of: page.chapter), count > 0 else { return [] }
        let low = Double(number) / Double(count)
        let high = Double(number + 1) / Double(count)
        return bookmarks.filter { $0.section == page.chapter && $0.progression >= low && $0.progression < high }
    }

    fileprivate func updateBookmarkState() {
        let marked = visiblePages.contains { !bookmarksOnPage($0).isEmpty }
        for page in visiblePages {
            page.isBookmarked = !bookmarksOnPage(page).isEmpty
        }
        bookmarkItem?.image = UIImage(systemName: marked ? "bookmark.fill" : "bookmark")
        bookmarkItem?.accessibilityValue = marked ? "Sidan har ett bokmärke" : "Inget bokmärke"
        chrome.updateBookmark(marked)
    }

    /// Bokmärker sidan man läser, eller tar bort bokmärket om sidan redan har ett.
    @objc fileprivate func toggleBookmark() {
        toggleBookmarks(onPages: visiblePages.filter { !$0.isBlank })
    }

    /// Bandet i sidans hörn (U3): ett tryck där bokmärker just den sidan.
    @objc fileprivate func handleRibbonTap(_ tap: UITapGestureRecognizer) {
        guard let page = ribbonPage(at: tap.location(in: view)) else { return }
        toggleBookmarks(onPages: [page])
        SelfTest.log("Bandet i hörnet: sidan \(bookmarksOnPage(page).isEmpty ? "har inte" : "har") bokmärke")
    }

    fileprivate func ribbonPage(at point: CGPoint) -> ReflowPageViewController? {
        visiblePages.first { page in
            guard !page.isBlank, page.page != nil else { return false }
            return page.view.convert(page.ribbonZone, to: view).contains(point)
        }
    }

    /// Självtestet (U2): utseenderutan i alla fyra bakgrunder, och radlängden, radavståndet och avstavningen
    /// i kapitlet som syns. Rutans egen vy sparas, eftersom popovers i iOS 26 ritas som glas.
    fileprivate func selfTestAppearance() async {
        for option in ReaderTheme.allCases {
            setTheme(option)
            await pause(0.3)
            showTypography()
            await pause(0.9)
            if let navigation = presentedViewController as? UINavigationController {
                SelfTest.saveScreen(navigation.view, name: "14-utseende-\(option.rawValue)")
            } else {
                SelfTest.log("FEL: utseenderutan öppnades inte")
            }
            dismiss(animated: false)
            await pause(0.3)
        }
        guard let renderer = renderer else { return }
        for margin in ReaderTypography.Margin.allCases {
            var value = typography
            value.margin = margin
            setTypography(value)
            await pause(0.8)
            _ = await waitUntilShown()
            let line: String = await withCheckedContinuation { continuation in
                renderer.evaluate(Self.lineMeasureScript, arguments: [:], in: currentChapter) { value in
                    continuation.resume(returning: value as? String ?? "inget svar")
                }
            }
            SelfTest.log("Radlängd (U2), marginal \(margin.title): \(line). Nyckel \(value.key)")
            if margin == .normal {
                SelfTest.saveScreen(view, name: "15-radlangd-normal")
            }
        }
    }

    /// Mäter raden i kapitlet: sidmarginal, textbredd, ungefär antal tecken per rad (medelbredden för tecknen
    /// i ett långt stycke), radavstånd, justering, avstavning och språk.
    private static let lineMeasureScript = #"""
    var root = document.documentElement;
    var cs = getComputedStyle(root);
    var side = parseFloat(cs.paddingLeft) || 0;
    var width = window.innerWidth - 2 * side;
    var all = document.querySelectorAll('p');
    var p = null;
    for (var i = 0; i < all.length; i++) {
      if ((all[i].textContent || '').length > 120) { p = all[i]; break; }
    }
    if (!p) { return 'sidmarginal ' + Math.round(side) + ' px, inget långt stycke'; }
    var ps = getComputedStyle(p);
    var context = document.createElement('canvas').getContext('2d');
    context.font = ps.fontStyle + ' ' + ps.fontWeight + ' ' + ps.fontSize + ' ' + ps.fontFamily;
    var text = (p.textContent || '').replace(/\s+/g, ' ').slice(0, 400);
    var per = context.measureText(text).width / Math.max(text.length, 1);
    return 'sidmarginal ' + Math.round(side) + ' px, textbredd ' + Math.round(width) + ' px, ungefär ' +
      Math.round(width / per) + ' tecken per rad, textstorlek ' + ps.fontSize + ', radavstånd ' + ps.lineHeight +
      ', justering ' + ps.textAlign + ', avstavning ' + (ps.webkitHyphens || ps.hyphens || 'okänd') +
      ', språk ' + (root.getAttribute('lang') || 'inget');
    """#

    /// Självtestet (U3): menyradens zoner och bandets tryckyta i hörnet.
    fileprivate func selfTestChromeLayout() {
        let left = (navigationItem.leftBarButtonItems ?? []).compactMap(\.accessibilityLabel)
        let right = (navigationItem.rightBarButtonItems ?? []).compactMap(\.accessibilityLabel)
        let page = visiblePages.first { !$0.isBlank && $0.page != nil }
        let zone = page.map { $0.view.convert($0.ribbonZone, to: view) }
        let hit = zone.map { ribbonPage(at: CGPoint(x: $0.midX, y: $0.midY)) != nil } ?? false
        let middle = ribbonPage(at: CGPoint(x: view.bounds.midX, y: view.bounds.midY)) != nil
        SelfTest.log("Menyraden (U3): vänster \(left.joined(separator: ", ")), höger från kanten "
                     + "\(right.joined(separator: ", ")), titel \(title ?? "ingen"), under titeln "
                     + "\(chrome.subtitle ?? "inget"). Bandet i hörnet tar trycket: \(hit ? "ja" : "FEL, nej"), "
                     + "mitten av sidan: \(middle ? "FEL, ja" : "nej")")
        selfTestTimeline()
    }

    /// V2: tidslinjens streck och prickar, bubblan ovanför fingret och hur lång tid linjen tar att rita.
    fileprivate func selfTestTimeline() {
        let timeline = bottomBar.slider
        let drawMs = timeline.redrawTrackNow()
        SelfTest.log("Tidslinjen (V2): \(timeline.chapters.count) kapitelstreck, \(timeline.dots.count) markeringar, "
                     + "\(timeline.bookmarks.count) bokmärken, under linjen \(bottomBar.pageButton.title(for: .normal) ?? ""), "
                     + "\(bottomBar.chapterLabel.text ?? "inget kapitel"), \(bottomBar.infoButton.title(for: .normal) ?? ""). "
                     + "Linjen ritad på \(String(format: "%.2f", drawMs)) ms")
        if let content = content {
            let target = content.location(atFraction: 0.6)
            let name = content.title(ofChapter: target.chapter) ?? "Avsnitt \(target.chapter + 1)"
            let shown = timeline.value
            timeline.value = 0.6
            timeline.previewBubble("\(name)\n\(pageLabel(for: target, content: content))")
            SelfTest.saveScreen(view, name: "03i-tidslinje")
            timeline.previewBubble(nil)
            timeline.value = shown
        }
    }

    fileprivate func toggleBookmarks(onPages shown: [ReflowPageViewController]) {
        let existing = shown.flatMap { bookmarksOnPage($0) }
        if existing.isEmpty {
            guard let page = shown.first, let number = page.page else { return }
            let count = max(renderer?.pageCount(of: page.chapter) ?? 1, 1)
            let progression = (Double(number) + 0.5) / Double(count)
            let fraction = content?.fraction(at: ReflowLocation(chapter: page.chapter, progression: progression)) ?? 0
            let label = "\(chapterName(page.chapter)), \(Int((fraction * 100).rounded())) % av boken"
            AnnotationStore.shared.addBookmark(book: bookKey, section: page.chapter, progression: progression, label: label)
            Haptics.shared.wordTapped()
        } else {
            existing.forEach { AnnotationStore.shared.delete($0) }
            // Granskning 2, N7: ett tryck på bandet ska aldrig ta bort ett bokmärke utan väg tillbaka.
            UndoBar.show(existing.count == 1 ? "Bokmärket borttaget" : "Bokmärkena borttagna", in: view) { [weak self] in
                existing.forEach { AnnotationStore.shared.undelete($0) }
                self?.bookmarksChanged()
            }
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
                                              detail: chapterName(highlight.section),
                                              note: highlight.hasNote ? highlight.note : nil,
                                              color: highlight.color)
            }
        }
    }

    fileprivate func openAnnotation(_ kind: AnnotationsViewController.Kind, id: String) {
        switch kind {
        case .bookmarks:
            guard let bookmark = AnnotationStore.shared.bookmarks(book: bookKey).first(where: { $0.id == id }) else { return }
            hop(to: ReflowLocation(chapter: bookmark.section, progression: bookmark.progression))
        case .highlights:
            guard let highlight = AnnotationStore.shared.highlight(id: id) else { return }
            reveal(chapter: highlight.section, body: "return lasaMarks.reveal(start, length);",
                   arguments: ["start": highlight.start, "length": highlight.length])
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
                reloadMarks(inChapter: highlight.section)
            }
        }
    }

    /// Visar sidan där ett textintervall står och markerar det en kort stund. Webbvyn letar upp sidan.
    fileprivate func reveal(chapter: Int, body: String, arguments: [String: Any]) {
        guard let renderer = renderer else { return }
        recordPlace()
        spinner.startAnimating()
        renderer.setWindow(center: chapter)
        renderer.evaluate(body, arguments: arguments, in: chapter) { [weak self] value in
            guard let self = self else { return }
            self.spinner.stopAnimating()
            guard let range = ReflowMarks.textRange(from: value) else {
                self.jump(to: ReflowLocation(chapter: chapter, progression: 0))
                return
            }
            self.pendingJump = nil
            self.show(chapter: chapter, page: range.page)
            let rects = range.rects
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 150_000_000)
                self?.visiblePages.first { $0.chapter == chapter && $0.page == range.page }?.flash(rects)
            }
        }
    }

    // MARK: Sök

    @objc fileprivate func showSearch() {
        guard presentedViewController == nil, let content = content else { return }
        let search = bookSearch ?? BookSearch(source: .chapters(content.chapters.map { $0.url }),
                                              index: SearchIndex.Key.make(for: book, chapters: content.chapters.count))
        bookSearch = search
        let controller = BookSearchViewController(search: search, query: lastQuery) { [weak self] section in
            self?.chapterName(section) ?? "Avsnitt \(section + 1)"
        }
        controller.onQueryChange = { [weak self] query in
            self?.lastQuery = query
        }
        controller.onSelect = { [weak self] hit, query in
            self?.lastQuery = query
            self?.dismiss(animated: true)
            self?.reveal(chapter: hit.section, body: "return lasaMarks.find(query, occurrence, context);",
                         arguments: ["query": query, "occurrence": hit.occurrence, "context": hit.snippet])
        }
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .popover
        navigation.popoverPresentationController?.barButtonItem = searchItem
        present(navigation, animated: true)
    }

    // MARK: Självtestet för fas 4

    fileprivate func selfTestAnnotations() async {
        let saved = AnnotationStore.shared.totalCounts()
        SelfTest.log("Sparat från tidigare starter: \(saved.highlights) markeringar, \(saved.notes) anteckningar, "
                     + "\(saved.bookmarks) bokmärken")
        guard let renderer = renderer,
              let page = visiblePages.first(where: { !$0.isBlank && $0.hasImage }),
              let number = page.page else {
            SelfTest.log("FEL: ingen sida att markera på")
            return
        }
        let size = page.view.bounds.size
        // Sista sidan i ett kapitel kan vara nästan tom: prova högre upp om det inte finns text där.
        var found: ReflowTextRange?
        for top in [0.30, 0.15, 0.06] as [CGFloat] {
            let a = page.pagePoint(CGPoint(x: size.width * 0.25, y: size.height * top))
            let b = page.pagePoint(CGPoint(x: size.width * 0.70, y: size.height * (top + 0.06)))
            let arguments: [String: Any] = ["index": number, "x1": Double(a.x), "y1": Double(a.y),
                                            "x2": Double(b.x), "y2": Double(b.y)]
            found = await withCheckedContinuation { continuation in
                renderer.evaluate("return lasaMarks.select(index, x1, y1, x2, y2);", arguments: arguments,
                                  in: page.chapter) { value in
                    continuation.resume(returning: ReflowMarks.textRange(from: value))
                }
            }
            if found != nil {
                break
            }
            SelfTest.log("Ingen text att markera på \(Int(top * 100)) procent av sidans höjd (tomrummet ger ingen markering)")
        }
        guard let range = found else {
            SelfTest.log("FEL: markeringen gav inget textintervall")
            return
        }
        SelfTest.log("Markering: \"\(range.text)\" (\(range.length) tecken, \(range.rects.count) rutor)")
        page.showPreview(range.rects, color: ReaderSettings.highlightColor, dark: theme.isDark)
        createHighlight(chapter: page.chapter, range: range)
        await pause(1.5)
        _ = await waitUntilShown()
        let shown = visiblePages.first { $0.chapter == page.chapter && $0.page == number }
        SelfTest.log("Sidbilden har \(shown?.marks.count ?? 0) markeringsrutor")
        SelfTest.saveScreen(view, name: "03b-markering")

        if let highlight = AnnotationStore.shared.highlights(book: bookKey, section: page.chapter).last {
            var noted = highlight
            noted.note = "Testanteckning från självtestet."
            AnnotationStore.shared.update(noted)
            reloadMarks(inChapter: page.chapter)
            await pause(1.2)
            _ = await waitUntilShown()
            if let current = visiblePages.first(where: { $0.chapter == page.chapter && $0.page == number }),
               let rect = current.marks.first?.rect {
                let shownRect = current.viewRect(rect)
                let center = view.convert(CGPoint(x: shownRect.midX, y: shownRect.midY), from: current.view)
                SelfTest.log("Tryck på markeringen hittar: \(markHit(at: center) != nil ? "en markering" : "FEL, ingen")")
                presentMarkMenu(id: noted.id, at: center)
                await pause(0.8)
                if let shown = presentedViewController as? HighlightMenuViewController, let anchor = lastMarkMenuAnchor {
                    let frame = view.convert(shown.view.bounds, from: shown.view)
                    let covers = frame.intersects(anchor.insetBy(dx: 0, dy: 1))
                    SelfTest.log("Markeringsraden (U5): \(HighlightMenuViewController.lastPlacement) markeringen, "
                                 + "\(Int(frame.width)) x \(Int(frame.height)) punkter, täcker markeringen: "
                                 + (covers ? "FEL, ja" : "nej"))
                }
                SelfTest.saveScreen(view.window ?? view, name: "03c-markeringsmeny")
                dismiss(animated: false)
                await pause(0.4)
            }
        }

        toggleBookmark()
        await pause(0.3)
        SelfTest.log("Bokmärke: \(bookmarkItem?.accessibilityValue ?? "inget"), \(bookmarks.count) i boken")
        selfTestChromeLayout()
        // Granskning 2, N7: bokmärket tas bort med raden Ångra, och Ångra tar tillbaka det.
        let bookmarksBefore = bookmarks.count
        toggleBookmark()
        await pause(0.3)
        let bookmarksRemoved = bookmarks.count
        let undoShown = UndoBar.current != nil
        UndoBar.current?.performUndo()
        await pause(0.3)
        SelfTest.log("Bokmärket bort med bandet (N7): \(bookmarksBefore) före, \(bookmarksRemoved) efter, raden Ångra "
                     + "\(undoShown ? "visas" : "saknas"), \(bookmarks.count) efter Ångra. "
                     + (bookmarksBefore > 0 && bookmarksRemoved == bookmarksBefore - 1 && undoShown
                        && bookmarks.count == bookmarksBefore ? "Rätt" : "FEL"))
        setMarkMode(true)
        await pause(0.5)
        SelfTest.saveScreen(view, name: "03d-markeringslage")
        setMarkMode(false)
        setChromeHidden(false, animated: false)
        await pause(0.4)

        showSearch()
        if let search = await SelfTestHelpers.presented(BookSearchViewController.self, by: self) {
            search.searchNow("kunskap")
            for _ in 0..<80 where search.searching {
                await pause(0.1)
            }
            SelfTest.log("Sökning efter kunskap: \(search.hitCount) träffar")
            SelfTest.saveScreen(view.window ?? view, name: "03e-sok")
            if let hit = search.firstHit {
                search.onSelect?(hit, "kunskap")
                await pause(1.5)
                _ = await waitUntilShown()
                logState("Första sökträffen (\(chapterName(hit.section)))")
                SelfTest.saveScreen(view, name: "03f-traff")
            }
        } else {
            SelfTest.log("FEL: sökrutan öppnades inte")
        }
        if presentedViewController != nil {
            dismiss(animated: false)
            await pause(0.4)
        }
        if let content = content {
            await SearchIndexSelfTest.run(source: .chapters(content.chapters.map { $0.url }),
                                          key: SearchIndex.Key.make(for: book, chapters: content.chapters.count))
        }

        showContents()
        if let container = await SelfTestHelpers.presented(ReaderContentsContainerViewController.self, by: self) {
            container.showTab(2)
            await pause(0.6)
            SelfTest.log("Flikarna: \(container.visibleListCount) lista syns")
            SelfTest.saveScreen(view.window ?? view, name: "03g-markeringar")
            container.showTab(1)
            await pause(0.4)
            SelfTest.saveScreen(view.window ?? view, name: "03h-bokmarken")
        } else {
            SelfTest.log("FEL: innehållet öppnades inte")
        }
        if presentedViewController != nil {
            dismiss(animated: false)
            await pause(0.4)
        }
        let after = AnnotationStore.shared.totalCounts()
        SelfTest.log("Sparat nu: \(after.highlights) markeringar, \(after.notes) anteckningar, \(after.bookmarks) bokmärken")
    }
}
