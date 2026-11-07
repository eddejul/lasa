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
    static let wordPressDuration: TimeInterval = 0.35

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
    private var theme = ReaderTheme.current
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
    /// En sida som ska visas när fingret har vikt klart. Bladen får inte bytas mitt i en vikning.
    private var deferredShow: (chapter: Int, page: Int)?
    private var turnToken = 0

    private var chromeHidden = false
    private let bottomBar = ReaderBottomBar()
    private let spinner = UIActivityIndicatorView(style: .large)
    private var chromeTap: UITapGestureRecognizer?
    private var linkTap: UITapGestureRecognizer?
    private var wordPress: UILongPressGestureRecognizer?
    private var pressedWord: PressedWord?
    private var wordQueryRunning = false
    private var queuedWordPoint: CGPoint?
    private var pressEnded = false
    private weak var wordBubble: PaddedLabel?
    private weak var toastLabel: UILabel?
    private var contentsItem: UIBarButtonItem?
    private var typographyItem: UIBarButtonItem?
    private var themeItem: UIBarButtonItem?

    private var lastLayout: ReflowLayout?
    private var lastSize: CGSize = .zero
    private var seenTopInset: CGFloat = 0
    private var backLocation: ReflowLocation?
    private var backButton: UIButton?
    private var turnsSinceLink = 0
    private var typographyTask: Task<Void, Never>?
    private var selfTestStarted = false

    // Fas 4: markeringar, anteckningar, bokmärken och sökning. Koden ligger sist i filen.
    private var markMode = false
    private var markDrag: UILongPressGestureRecognizer?
    private var markTap: UITapGestureRecognizer?
    private var markBar: HighlightModeBar?
    private var markSelection: ReflowMarkSelection?
    private var bookmarks: [Bookmark] = []
    private var searchItem: UIBarButtonItem?
    private var markItem: UIBarButtonItem?
    private var bookmarkItem: UIBarButtonItem?
    private var bookSearch: BookSearch?
    private var lastQuery: String?

    // Fas 6: uppläsning. Koden ligger sist i filen.
    private var readItem: UIBarButtonItem?
    private var readBar: ReadAloudBar?
    private var readingPosition: ReflowPage?
    private var readingSpan: (start: Int, text: FoldedText)?
    private var spokenWords = 0

    init(book: Book) {
        self.book = book
        self.location = LibraryStore.shared.savedLocation(for: book) ?? ReflowLocation(chapter: 0, progression: 0)
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
        setUpTaps()

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
        stopReading()
        guard isMovingFromParent else { return }
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
    }

    // MARK: Öppna boken

    private func loadContent() {
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
            if location.chapter < 0 || location.chapter >= content.chapters.count {
                location = ReflowLocation(chapter: 0, progression: 0)
            }
            title = content.title
            let renderer = ReflowRenderer(book: content, host: webHost, theme: theme)
            renderer.onChapterMeasured = { [weak self] chapter in
                self?.chapterMeasured(chapter)
            }
            installMarksProvider(on: renderer)
            self.renderer = renderer
            pendingJump = PendingJump(chapter: location.chapter, progression: location.progression, fragment: nil)
            bottomBar.slider.isEnabled = true
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
        let side = min(max((pageWidth * 0.075).rounded(), 20), 64) + max(insets.left, insets.right)
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
        return page
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
        currentCount = renderer.pageCount(of: chapter)
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
        currentCount = renderer?.pageCount(of: first.chapter)
        saveLocation()
        updatePageLabel()
        updateBookmarkState()
        keepNeighbours()
        turnsSinceLink += 1
        if turnsSinceLink >= 3 {
            hideBackButton()
        }
    }

    // MARK: Läsposition

    private func currentLocation() -> ReflowLocation {
        guard isShowingPages else { return location }
        guard let count = currentCount, count > 0 else {
            return ReflowLocation(chapter: currentChapter, progression: 0)
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
        if chapter == currentChapter, isShowingPages, pendingJump == nil,
           let count = renderer?.pageCount(of: chapter) {
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
        // Menyraden ligger ovanpå sidan med en egen bakgrund, så att knapparna syns mot texten.
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance
        navigationItem.compactAppearance = appearance

        let contents = UIBarButtonItem(image: UIImage(systemName: "list.bullet"),
                                       style: .plain,
                                       target: self,
                                       action: #selector(showContents))
        contents.accessibilityLabel = "Innehåll"

        let text = UIBarButtonItem(image: UIImage(systemName: "textformat.size"),
                                   style: .plain,
                                   target: self,
                                   action: #selector(showTypography))
        text.accessibilityLabel = "Typsnitt och storlek"

        let themeButton = UIBarButtonItem(title: nil,
                                          image: UIImage(systemName: "circle.lefthalf.fill"),
                                          primaryAction: nil,
                                          menu: themeMenu())
        themeButton.accessibilityLabel = "Bakgrund"

        let annotationItems = ReaderMenus.annotationItems(target: self,
                                                          search: #selector(showSearch),
                                                          mark: #selector(toggleMarkMode),
                                                          bookmark: #selector(toggleBookmark))
        searchItem = annotationItems[0]
        markItem = annotationItems[1]
        bookmarkItem = annotationItems[2]
        navigationItem.rightBarButtonItems = [themeButton, text, makeReadItem()] + annotationItems + [contents]
        contentsItem = contents
        typographyItem = text
        themeItem = themeButton
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
    }

    private func setUpTaps() {
        let link = UITapGestureRecognizer(target: self, action: #selector(handleLinkTap(_:)))
        link.delegate = self
        view.addGestureRecognizer(link)

        let chrome = UITapGestureRecognizer(target: self, action: #selector(toggleChrome))
        chrome.delegate = self
        view.addGestureRecognizer(chrome)

        let press = UILongPressGestureRecognizer(target: self, action: #selector(handleWordPress(_:)))
        press.minimumPressDuration = Self.wordPressDuration
        press.delegate = self
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
        guard hidden != chromeHidden else { return }
        chromeHidden = hidden
        navigationController?.setNavigationBarHidden(hidden, animated: animated)
        bottomBar.isUserInteractionEnabled = !hidden
        UIView.animate(withDuration: animated ? 0.25 : 0) {
            self.bottomBar.alpha = hidden ? 0 : 1
            self.setNeedsStatusBarAppearanceUpdate()
        }
    }

    private func updatePageLabel() {
        guard let content = content, let renderer = renderer, isShowingPages else { return }
        bottomBar.pageButton.setTitle(pageText(content: content, renderer: renderer), for: .normal)
        if !bottomBar.slider.isTracking {
            bottomBar.slider.value = Float(content.fraction(at: currentLocation()))
        }
    }

    /// "52 av 300" när hela boken är mätt, annars sidan i kapitlet och hur långt in i boken man är.
    private func pageText(content: ReflowableBook, renderer: ReflowRenderer) -> String {
        let pages = visiblePages.compactMap { $0.page }
        let shown = pages.isEmpty ? [currentSlot] : pages
        if let all = renderer.allPageCounts() {
            let before = all.prefix(currentChapter).reduce(0, +)
            let total = all.reduce(0, +)
            let numbers = shown.map { String(before + $0 + 1) }.joined(separator: " och ")
            return "\(numbers) av \(total)"
        }
        let numbers = shown.map { String($0 + 1) }.joined(separator: " och ")
        let percent = Int((content.fraction(at: currentLocation()) * 100).rounded())
        guard let count = currentCount else {
            return "Sida \(numbers) i kapitlet, \(percent) % av boken"
        }
        return "Sida \(numbers) av \(count) i kapitlet, \(percent) % av boken"
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
            let percent = Int((Double(bottomBar.slider.value) * 100).rounded())
            let name = content.title(ofChapter: target.chapter) ?? "Avsnitt \(target.chapter + 1)"
            bottomBar.pageButton.setTitle("\(name), \(percent) %", for: .normal)
        } else {
            // VoiceOver ändrar värdet utan att dra.
            jump(to: target)
        }
    }

    @objc private func sliderReleased() {
        guard let content = content else { return }
        hideBackButton()
        jump(to: content.location(atFraction: Double(bottomBar.slider.value)))
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
            self?.hideBackButton()
            self?.jump(to: ReflowLocation(chapter: targets[row].chapter, progression: 0),
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

    @objc private func showTypography() {
        guard presentedViewController == nil else { return }
        let controller = TypographyViewController(typography: typography)
        controller.onChange = { [weak self] value in
            self?.setTypography(value)
        }
        controller.diagnostics = { [weak self] in
            guard let self = self, let renderer = self.renderer else { return nil }
            var text = renderer.statsSummary
            if let first = renderer.firstSnapshotAt {
                text += " Boken öppnades på \(Int(((first - self.openedAt) * 1000).rounded())) ms."
            }
            return text
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

    private func themeMenu() -> UIMenu {
        let actions = ReaderTheme.allCases.map { option in
            UIAction(title: option.title,
                     image: UIImage(systemName: option.symbolName),
                     state: option == theme ? .on : .off) { [weak self] _ in
                self?.setTheme(option)
            }
        }
        let sound = ReaderMenus.soundSection { [weak self] in
            self?.themeItem?.menu = self?.themeMenu()
        }
        return UIMenu(title: "Bakgrund", children: actions + [sound])
    }

    private func setTheme(_ newTheme: ReaderTheme) {
        guard newTheme != theme else { return }
        theme = newTheme
        ReaderTheme.current = newTheme
        themeItem?.menu = themeMenu()
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
        let style: UIUserInterfaceStyle = theme.isDark ? .dark : .light
        overrideUserInterfaceStyle = style
        navigationController?.overrideUserInterfaceStyle = style
        setNeedsStatusBarAppearanceUpdate()
    }

    // MARK: Ordboken

    /// Hur långt från fingret ett ord får ligga och ändå väljas, i punkter. Samma som i PDF-läsaren.
    static let fingerTolerance: CGFloat = 22

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
                moveWordBubble(to: point)
            }
        case .ended:
            guard presentedViewController == nil else { return }
            pressEnded = true
            hideWordBubble()
            if !wordQueryRunning {
                finishPress()
            }
        default:
            pressEnded = false
            queuedWordPoint = nil
            hideWordBubble()
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
            showWordBubble(found.word, at: screenPoint)
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

    /// Fingret skymmer ordet, så ordet visas också i en bubbla ovanför fingret medan man håller.
    private func showWordBubble(_ word: String, at point: CGPoint) {
        let bubble: PaddedLabel
        if let existing = wordBubble {
            bubble = existing
        } else {
            bubble = PaddedLabel()
            bubble.insets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
            bubble.font = .preferredFont(forTextStyle: .headline)
            bubble.textColor = .white
            bubble.backgroundColor = UIColor(white: 0.12, alpha: 0.9)
            bubble.layer.cornerRadius = 10
            bubble.layer.masksToBounds = true
            bubble.isUserInteractionEnabled = false
            view.addSubview(bubble)
            wordBubble = bubble
        }
        bubble.text = word
        bubble.sizeToFit()
        moveWordBubble(to: point)
    }

    private func moveWordBubble(to point: CGPoint) {
        guard let bubble = wordBubble else { return }
        let size = bubble.bounds.size
        let margin: CGFloat = 8
        var center = CGPoint(x: point.x, y: point.y - 64)
        if center.y - size.height / 2 < view.safeAreaInsets.top + margin {
            center.y = point.y + 64
        }
        center.x = min(max(center.x, size.width / 2 + margin), view.bounds.width - size.width / 2 - margin)
        bubble.center = center
    }

    private func hideWordBubble() {
        wordBubble?.removeFromSuperview()
        wordBubble = nil
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

        if let lookup = lookup, let lemma = lookup.entries.first?.lemma {
            UserWords.shared.save(word: lookup.word, lemma: lemma, language: lookup.language,
                                  sentence: sentence, book: book.title, pageIndex: pageIndex)
        }
        SelfTest.log("Ord: \(found.word), mening: \(sentence), grundform: \(lookup?.entries.first?.lemma ?? "hittades inte"), "
                     + "uppslag \(Int(lookupTime.rounded())) ms")

        let context = WordPopupViewController.Context(sentence: sentence,
                                                      rangeInSentence: range,
                                                      book: book.title,
                                                      pageIndex: pageIndex,
                                                      triedWord: found.word)
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
        var recognizers = pageController?.gestureRecognizers ?? []
        recognizers += [chromeTap, linkTap].compactMap { $0 }
        for recognizer in recognizers where recognizer.isEnabled {
            recognizer.isEnabled = false
            recognizer.isEnabled = true
        }
    }

    // MARK: Länkar

    private func link(at point: CGPoint) -> ReflowLink? {
        for page in visiblePages where !page.isBlank {
            let local = page.view.convert(point, from: view)
            if page.view.bounds.contains(local) {
                return page.link(at: local)
            }
        }
        return nil
    }

    @objc private func handleLinkTap(_ tap: UITapGestureRecognizer) {
        guard let link = link(at: tap.location(in: view)) else { return }
        follow(link.url)
    }

    /// En länk inom boken hoppar dit (med en Tillbaka-knapp). En webblänk öppnas i Safari i appen.
    private func follow(_ url: URL) {
        guard let content = content else { return }
        if url.isFileURL {
            guard let chapter = content.chapterIndex(for: url) else { return }
            let fragment = url.fragment.map { $0.removingPercentEncoding ?? $0 }
            backLocation = currentLocation()
            jump(to: ReflowLocation(chapter: chapter, progression: 0), fragment: fragment)
            showBackButton()
            turnsSinceLink = 0
        } else if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            let safari = SFSafariViewController(url: url)
            safari.dismissButtonStyle = .close
            present(safari, animated: true)
        }
    }

    private func showBackButton() {
        hideBackButton()
        var configuration = UIButton.Configuration.filled()
        configuration.title = "Tillbaka"
        configuration.image = UIImage(systemName: "arrow.uturn.backward")
        configuration.imagePadding = 6
        configuration.cornerStyle = .capsule
        let button = UIButton(configuration: configuration)
        button.accessibilityHint = "Går tillbaka till sidan där länken stod"
        button.addTarget(self, action: #selector(goBack), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            button.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -76),
        ])
        backButton = button
    }

    private func hideBackButton() {
        backButton?.removeFromSuperview()
        backButton = nil
    }

    @objc private func goBack() {
        guard let target = backLocation else { return }
        backLocation = nil
        hideBackButton()
        jump(to: target)
    }

    // MARK: Meddelanden

    private func showMessage(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    /// Ett kort meddelande nere på sidan som försvinner av sig självt.
    private func showToast(_ text: String) {
        toastLabel?.removeFromSuperview()
        let label = PaddedLabel()
        label.text = text
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .white
        label.backgroundColor = UIColor(white: 0.1, alpha: 0.85)
        label.layer.cornerRadius = 12
        label.layer.masksToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alpha = 0
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -60),
            label.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -48),
        ])
        toastLabel = label
        UIView.animate(withDuration: 0.2) { label.alpha = 1 }
        UIView.animate(withDuration: 0.4, delay: 2.5, options: []) {
            label.alpha = 0
        } completion: { _ in
            label.removeFromSuperview()
        }
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
        // Bläddrar man själv slutar uppläsningen.
        stopReading()
        Haptics.shared.pageTurned()
        setChromeHidden(true, animated: true)
        pagesChanged()
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
            if let back = backButton, touched.isDescendant(of: back) {
                return false
            }
            if let bar = markBar, touched.isDescendant(of: bar) {
                return false
            }
            if let bar = readBar, touched.isDescendant(of: bar) {
                return false
            }
        }
        if gestureRecognizer === markDrag {
            return markMode
        }
        let onMark = markHit(at: touch.location(in: view)) != nil
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
        guard SelfTest.isActive, !selfTestStarted else { return }
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
        SelfTest.log("\(label): \(pages.joined(separator: ", ")). Etikett: \(bottomBar.pageButton.title(for: .normal) ?? ""). "
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
        await selfTestReadAloud()

        let isFull = SelfTest.bookName?.lowercased().hasSuffix(".epub") == true
        if isFull, content.toc.count > 2 {
            jump(to: ReflowLocation(chapter: content.toc[2].chapter, progression: 0), fragment: content.toc[2].fragment)
            _ = await waitUntilShown()
            logState("Innehållets tredje rad")
            SelfTest.saveScreen(view, name: "04-innehall")

            if let link = visiblePages.flatMap({ $0.links }).first(where: { $0.url.isFileURL }) {
                SelfTest.log("Följer länken \(link.url.lastPathComponent)#\(link.url.fragment ?? "")")
                follow(link.url)
                _ = await waitUntilShown()
                logState("Efter länken")
                SelfTest.saveScreen(view, name: "05-lank")
                goBack()
                _ = await waitUntilShown()
                logState("Tillbaka")
                SelfTest.saveScreen(view, name: "06-tillbaka")
            } else {
                SelfTest.log("FEL: inga länkar på sidan")
            }
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
                             + "bubblan visar \(wordBubble?.text ?? "ingenting")")
                SelfTest.saveScreen(view, name: name + "-haller")
                pressEnded = true
                hideWordBubble()
                finishPress()
                await pause(1.5)
                SelfTest.saveScreen(view.window ?? view, name: name)
                dismiss(animated: false)
                clearPressedWord()
                return
            }
        }
        SelfTest.log("FEL: hittade inget ord på sidan")
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
        let drag = UILongPressGestureRecognizer(target: self, action: #selector(handleMarkDrag(_:)))
        drag.minimumPressDuration = 0
        drag.allowableMovement = .greatestFiniteMagnitude
        drag.delegate = self
        drag.isEnabled = false
        view.addGestureRecognizer(drag)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleMarkTap(_:)))
        tap.delegate = self
        view.addGestureRecognizer(tap)

        markDrag = drag
        markTap = tap
        PageTurnSound.shared.prepare()
        bookmarksChanged()
    }

    /// Renderaren lägger in kapitlets markeringar när kapitlet laddas.
    fileprivate func installMarksProvider(on renderer: ReflowRenderer) {
        let key = bookKey
        renderer.marksProvider = { chapter in
            ReflowMarks.arguments(for: AnnotationStore.shared.highlights(book: key, section: chapter))
        }
    }

    /// Markeringarna i ett kapitel har ändrats: lägg in dem igen och rita om sidorna.
    fileprivate func reloadMarks(inChapter chapter: Int) {
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
        guard on != markMode else { return }
        markMode = on
        for recognizer in pageController?.gestureRecognizers ?? [] {
            recognizer.isEnabled = !on
        }
        chromeTap?.isEnabled = !on
        linkTap?.isEnabled = !on
        wordPress?.isEnabled = !on
        markDrag?.isEnabled = on
        if on {
            setChromeHidden(true, animated: true)
            let bar = HighlightModeBar(color: ReaderSettings.highlightColor)
            bar.onColor = { color in
                ReaderSettings.highlightColor = color
            }
            bar.onTurn = { [weak self] forward in
                PageTurnSound.shared.play()
                self?.turn(forward: forward)
            }
            bar.onDone = { [weak self] in
                self?.setMarkMode(false)
            }
            ReaderMenus.installModeBar(bar, in: view)
            markBar = bar
        } else {
            markSelection?.page.clearPreview()
            markSelection = nil
            markBar?.removeFromSuperview()
            markBar = nil
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
            let tapped = page.markID(at: local)
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
        HighlightMenuViewController.present(menu, from: self, sourceView: view,
                                            sourceRect: CGRect(x: point.x - 1, y: point.y - 10, width: 2, height: 20))
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
    }

    /// Bokmärker sidan man läser, eller tar bort bokmärket om sidan redan har ett.
    @objc fileprivate func toggleBookmark() {
        let shown = visiblePages.filter { !$0.isBlank }
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
            hideBackButton()
            jump(to: ReflowLocation(chapter: bookmark.section, progression: bookmark.progression))
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
        hideBackButton()
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
        let search = bookSearch ?? BookSearch(source: .chapters(content.chapters.map { $0.url }))
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
        let a = page.pagePoint(CGPoint(x: size.width * 0.25, y: size.height * 0.30))
        let b = page.pagePoint(CGPoint(x: size.width * 0.70, y: size.height * 0.36))
        let arguments: [String: Any] = ["index": number, "x1": Double(a.x), "y1": Double(a.y),
                                        "x2": Double(b.x), "y2": Double(b.y)]
        let range: ReflowTextRange? = await withCheckedContinuation { continuation in
            renderer.evaluate("return lasaMarks.select(index, x1, y1, x2, y2);", arguments: arguments,
                              in: page.chapter) { value in
                continuation.resume(returning: ReflowMarks.textRange(from: value))
            }
        }
        guard let range = range else {
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
                SelfTest.saveScreen(view.window ?? view, name: "03c-markeringsmeny")
                dismiss(animated: false)
                await pause(0.4)
            }
        }

        toggleBookmark()
        await pause(0.3)
        SelfTest.log("Bokmärke: \(bookmarkItem?.accessibilityValue ?? "inget"), \(bookmarks.count) i boken")
        setMarkMode(true)
        await pause(0.5)
        SelfTest.saveScreen(view, name: "03d-markeringslage")
        setMarkMode(false)

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

        showContents()
        if let container = await SelfTestHelpers.presented(ReaderContentsContainerViewController.self, by: self) {
            container.showTab(2)
            await pause(0.6)
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

// MARK: Uppläsning (fas 6)

extension ReflowReaderViewController {

    fileprivate func makeReadItem() -> UIBarButtonItem {
        let item = UIBarButtonItem(image: UIImage(systemName: "speaker.wave.2"), style: .plain,
                                   target: self, action: #selector(toggleReading))
        item.accessibilityLabel = "Läs upp"
        readItem = item
        return item
    }

    @objc fileprivate func toggleReading() {
        if readingPosition != nil {
            stopReading()
        } else if let page = visiblePages.first(where: { !$0.isBlank }), let number = page.page {
            startReading(chapter: page.chapter, page: number)
        }
    }

    /// Läser sidan och fortsätter på nästa, med pappersvikning när sidan är slut.
    /// Texten på sidan tas fram i kapitlets webbvy.
    fileprivate func startReading(chapter: Int, page: Int, emptyPages: Int = 0) {
        guard let renderer = renderer else { return }
        let position = ReflowPage(chapter: chapter, page: page)
        readingPosition = position
        readingSpan = nil
        showReadBar()
        if let count = renderer.pageCount(of: chapter), page >= count {
            // Ett tomt blad efter kapitlets sista sida i ett uppslag.
            continueReading(from: position, emptyPages: emptyPages)
            return
        }
        renderer.evaluate("return lasaMarks.pageText(index);", arguments: ["index": page], in: chapter) { [weak self] value in
            guard let self = self, self.readingPosition == position else { return }
            let info = value as? [String: Any]
            let text = info?["text"] as? String ?? ""
            let start = Int(ReflowValues.number(info?["start"]) ?? 0)
            let spoken = FoldedText(text as NSString, lowercase: false)
            guard !(spoken.text as String).trimmingCharacters(in: .whitespaces).isEmpty else {
                if emptyPages >= 3 {
                    self.stopReading()
                } else {
                    self.continueReading(from: position, emptyPages: emptyPages + 1)
                }
                return
            }
            self.readingSpan = (start, spoken)
            ReadAloud.shared.speak(spoken.text as String, onWord: { [weak self] range in
                self?.showSpokenWord(range, at: position)
            }, onFinish: { [weak self] in
                self?.continueReading(from: position, emptyPages: 0)
            })
        }
    }

    fileprivate func showSpokenWord(_ range: NSRange, at position: ReflowPage) {
        guard readingPosition == position, let span = readingSpan, let renderer = renderer else { return }
        spokenWords += 1
        let original = span.text.originalRange(of: range)
        guard original.length > 0 else { return }
        renderer.evaluate("return lasaMarks.rectsOn(index, start, length);",
                          arguments: ["index": position.page, "start": span.start + original.location,
                                      "length": original.length],
                          in: position.chapter) { [weak self] value in
            guard let self = self, self.readingPosition == position else { return }
            let info = value as? [String: Any]
            let rects = (info?["rects"] as? [Any] ?? []).compactMap { ReflowValues.rect(from: $0) }
            self.visiblePages.first { $0.chapter == position.chapter && $0.page == position.page }?
                .showPreview(rects, color: .blue, dark: self.theme.isDark)
        }
    }

    fileprivate func continueReading(from position: ReflowPage, emptyPages: Int) {
        visiblePages.forEach { $0.clearPreview() }
        guard let next = step(chapter: position.chapter, slot: position.page, forward: true) else {
            stopReading()
            return
        }
        if visiblePages.contains(where: { $0.chapter == next.chapter && $0.slot == next.slot }) {
            startReading(chapter: next.chapter, page: next.slot, emptyPages: emptyPages)
            return
        }
        turn(forward: true)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard let self = self, self.readingPosition == position else { return }
            self.startReading(chapter: next.chapter, page: next.slot, emptyPages: emptyPages)
        }
    }

    fileprivate func stopReading() {
        guard readingPosition != nil || readBar != nil else { return }
        readingPosition = nil
        readingSpan = nil
        ReadAloud.shared.stop()
        readBar?.removeFromSuperview()
        readBar = nil
        visiblePages.forEach { $0.clearPreview() }
        readItem?.image = UIImage(systemName: "speaker.wave.2")
        readItem?.accessibilityLabel = "Läs upp"
    }

    fileprivate func showReadBar() {
        readItem?.image = UIImage(systemName: "speaker.slash")
        readItem?.accessibilityLabel = "Sluta läsa upp"
        guard readBar == nil else { return }
        let bar = ReadAloudBar()
        bar.onPause = { [weak bar] in
            if ReadAloud.shared.isPaused {
                ReadAloud.shared.resume()
                bar?.setPaused(false)
            } else {
                ReadAloud.shared.pause()
                bar?.setPaused(true)
            }
        }
        bar.onStop = { [weak self] in
            self?.stopReading()
        }
        bar.install(in: view)
        readBar = bar
    }

    /// Självtestet: läs upp en stund och räkna orden.
    fileprivate func selfTestReadAloud() async {
        spokenWords = 0
        toggleReading()
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        SelfTest.log("Uppläsning: \(spokenWords) ord lästa på fyra sekunder, röst "
                     + "\(ReadAloud.voice(for: "Det här är en svensk mening.")?.language ?? "saknas")")
        SelfTest.saveScreen(view, name: "03i-upplasning")
        stopReading()
    }
}
