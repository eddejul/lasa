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
        let appearance = UIBarButtonItem(image: UIImage(systemName: "textformat.size"),
                                         style: .plain,
                                         target: self,
                                         action: #selector(showAppearance))
        appearance.accessibilityLabel = "Utseende"
        return ReaderChrome(controller: self, bottomBar: bottomBar, readerItem: appearance, theme: theme,
                            actions: .init(contents: #selector(showContents), search: #selector(showSearch),
                                           mark: #selector(toggleMarkMode), bookmark: #selector(toggleBookmark),
                                           goToPage: #selector(showGoToPage), zoom: #selector(zoomCurrentPage),
                                           thumbnails: #selector(showThumbnails),
                                           bookPages: #selector(showBookPages), bookInfo: #selector(showBookInfo),
                                           notebook: #selector(showNotebook), sideNotes: #selector(toggleSideNotes),
                                           concepts: #selector(showConcepts)),
                            onTheme: { [weak self] option in self?.setTheme(option) })
    }()

    private var chromeHidden: Bool {
        chrome.isHidden
    }

    private let bottomBar = ReaderBottomBar()
    /// V4: sidorna man hoppat ifrån och Tillbaka i hörnet (G12, samma som i EPUB-läsaren).
    private let backStack = ReaderBackStack<Int>()
    private var chromeTap: UITapGestureRecognizer?
    private var zoomTap: UITapGestureRecognizer?
    /// Trycket på bokmärkesbandet i sidans hörn (U3).
    private var ribbonTap: UITapGestureRecognizer?
    private var wordPress: UILongPressGestureRecognizer?
    private var pressedWord: PressedWord?
    /// Markeringsradens ruta senast den visades (U5), till självtestet.
    private var lastMarkMenuAnchor: CGRect?
    /// K12: anteckningarna bredvid texten, när panelen är framme.
    fileprivate var sideNotes: SideNotesPanel?
    /// D4-1: bokens sida för filens första sida enligt tryckta sidnummer i textlagret, bara ett förslag.
    fileprivate var printedPageSuggestion: (first: Int, votes: Int)?
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
    /// O4: strecken under sparade ord per sida, räknade på renderingskön.
    private var wordMarksCache: [Int: [PDFPageViewController.WordMark]] = [:]
    private var wordMarksInFlight = Set<Int>()
    private var wordMarksVersion = -1
    /// Punkten i sidans koordinater där ordet under fingret senast togs fram (G6).
    private var lastWordProbe: CGPoint?
    /// V5: sidornas interna länkar, lästa på renderingskön, och trycket på dem.
    private var linksCache: [Int: [PDFInternalLink]] = [:]
    private var linksInFlight = Set<Int>()
    private var linkTap: UITapGestureRecognizer?
    private var lastNoteMilliseconds: Int?
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
    /// V6: när boken senast lästes, läst innan läsaren sparar en ny plats.
    private let lastReadDate: Date?

    init?(book: Book) {
        guard let document = PDFDocument(url: book.url),
              !document.isLocked,
              document.pageCount > 0,
              let renderer = PDFPageRenderer(url: book.url, pageCount: document.pageCount,
                                             cacheKey: Self.diskCacheKey(for: book)) else {
            return nil
        }
        self.book = book
        self.lastReadDate = LibraryStore.shared.positionDate(for: book)
        self.document = document
        self.renderer = renderer
        let saved = LibraryStore.shared.savedPageIndex(for: book)
        self.currentIndex = min(max(saved, 0), document.pageCount - 1)
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
        NotificationCenter.default.addObserver(self, selector: #selector(updateReadRanges),
                                               name: ReadingLog.didChange, object: nil)
        SavedWordMarks.shared.refresh()
        setUpNavigationBar()
        setUpBottomBar()
        setUpBackStack()
        setUpTaps()
        setUpPhotoPages()
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
            scheduleResumeCard()
            // Sökregistret byggs i bakgrunden om det saknas, när de första sidorna hunnit ritas.
            SearchIndex.shared.prepare(searchKey, source: .pdf(book.url), delay: 4)
            startPrintedPageDetection()
        }
        PageTurnSound.shared.prepare()
        WordDictionary.warmUpLanguageModels()
        startSelfTestIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard isMovingFromParent else { return }
        ReadingLog.shared.pause()
        sideNotes?.saveNow()
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

    // MARK: Beskärning och textläge (P3, P4)

    /// P3: bokens ram läses när läsaren öppnas, före första sidbilden. P3 och P4 får egna rader i Mer.
    private func setUpPhotoPages() {
        renderer.setCrop(PageCropStore.active(bookID: book.id))
        chrome.pageItems = { [weak self] in
            self?.photoPageItems() ?? []
        }
    }

    /// Beskär marginalerna (eller Visa hela sidan när ramen är på), Ändra beskärningen och Visa texten.
    private func photoPageItems() -> [UIMenuElement] {
        var items: [UIMenuElement] = []
        let saved = PageCropStore.saved(bookID: book.id)
        if let saved = saved, saved.isOn {
            items.append(UIAction(title: "Visa hela sidan",
                                  image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")) { [weak self] _ in
                self?.setCropOn(false)
            })
        } else {
            items.append(UIAction(title: "Beskär marginalerna", image: UIImage(systemName: "crop")) { [weak self] _ in
                if saved != nil {
                    self?.setCropOn(true)
                } else {
                    self?.showCropEditor()
                }
            })
        }
        if saved != nil {
            items.append(UIAction(title: "Ändra beskärningen", image: UIImage(systemName: "slider.horizontal.3")) {
                [weak self] _ in
                self?.showCropEditor()
            })
        }
        if PDFTextCompanion.textURL(forPDF: book.url) != nil {
            items.append(UIAction(title: "Visa texten", image: UIImage(systemName: "text.alignleft")) { [weak self] _ in
                self?.showTextMode()
            })
        }
        return items
    }

    /// Ett tryck: hela sidan, eller beskuret igen med samma ram.
    private func setCropOn(_ on: Bool) {
        guard var saved = PageCropStore.saved(bookID: book.id) else { return }
        saved.isOn = on
        PageCropStore.save(saved, bookID: book.id)
        applyCrop()
        showToast(on ? "Marginalerna är beskurna i hela boken." : "Hela sidan visas. Beskär igen i Mer.")
    }

    /// Ritar om sidorna med ramen som gäller. Den gamla bilden står kvar tills den nya är ritad (i bakgrunden).
    private func applyCrop() {
        renderer.setCrop(PageCropStore.active(bookID: book.id))
        refreshVisiblePages()
        keepNeighbours()
        chrome.refreshMoreMenu()
        AppLog.shared.write("Beskärning (P3): " + (PageCropStore.saved(bookID: book.id).map(PageCropStore.format) ?? "ingen"))
    }

    /// Rutan där ramen dras, med sidan man läser.
    @objc fileprivate func showCropEditor() {
        let index = min(max(currentIndex, 0), renderer.pageCount - 1)
        let current = PageCropStore.saved(bookID: book.id)?.crop ?? .full
        let renderer = self.renderer
        let width = min(view.bounds.width, view.bounds.height, 820)
        let scale = displayScale
        let editor = PageCropViewController(crop: current) { completion in
            let operation = renderer.thumbnail(for: index, width: width, scale: scale) { image in
                completion(image)
            }
            // Före förritningen till disken, som annars kan ta flera sekunder på en fotad bok.
            operation.queuePriority = .veryHigh
        }
        // Föreslå: texten på sidan man läser och fyra sidor runt den, små bilder på renderingskön.
        editor.suggestPages = { completion in
            let pages = [index, index + 1, index + 2, index - 1, index + 3].filter { $0 >= 0 && $0 < renderer.pageCount }
            var crops: [PageCrop] = []
            var left = pages.count
            for page in pages {
                let operation = renderer.thumbnail(for: page, width: 300, scale: 1) { image in
                    if let image = image, let crop = PageCropSuggestion.suggest(from: image) {
                        crops.append(crop)
                    }
                    left -= 1
                    if left == 0 {
                        completion(PageCropSuggestion.union(crops))
                    }
                }
                operation.queuePriority = .veryHigh
            }
        }
        editor.onSave = { [weak self] crop in
            guard let self = self else { return }
            PageCropStore.save(PageCropStore.Saved(crop: crop, isOn: true), bookID: self.book.id)
            self.applyCrop()
        }
        editor.onFullPage = { [weak self] in
            guard let self = self else { return }
            PageCropStore.save(nil, bookID: self.book.id)
            self.applyCrop()
        }
        let navigation = UINavigationController(rootViewController: editor)
        navigation.modalPresentationStyle = .fullScreen
        present(navigation, animated: true)
    }

    /// P4: byter till txt-filen bredvid PDF:en, på samma sida (kapitel n är PDF:ens sida n).
    @objc fileprivate func showTextMode() {
        guard let url = PDFTextCompanion.textURL(forPDF: book.url) else { return }
        guard let textBook = LibraryStore.shared.book(at: url) else {
            showToast("Texten läses fortfarande in. Försök igen om en stund.")
            return
        }
        let count = OCRPagedText.pageCount(at: url) ?? 1
        let chapter = min(max(currentIndex, 0), max(count - 1, 0))
        LibraryStore.shared.savePageIndex(currentIndex, for: book)
        LibraryStore.shared.saveLocation(ReflowLocation(chapter: chapter, progression: 0), for: textBook)
        AppLog.shared.write("Textläge (P4): sida \(currentIndex + 1) till kapitel \(chapter + 1) av \(count)")
        PDFTextCompanion.replace(self, with: ReflowReaderViewController(book: textBook))
    }

    /// Självtestet (P4): sidan som visas.
    var photoTestPageIndex: Int {
        currentIndex
    }

    /// Våg 10b: beskärningen (P3), textläget (P4) och provet med Apples Vision (P5), med foto-text.pdf och
    /// foto-text.txt från make_books.py.
    fileprivate func selfTestPhotoPages() async {
        PhotoPagesSelfTest.running = true
        PageCropStore.save(nil, bookID: book.id)
        applyCrop()
        _ = await waitForCrop()
        await pause(0.6)
        SelfTest.saveScreen(view, name: "01-hela-sidan")
        let fullFrame = visiblePages.first(where: { !$0.isBlank })?.imageFrame ?? .zero
        let fullOK = selfTestCropWord("hela sidan")

        // Rutan: förslaget efter var texten ligger, sedan Klar.
        showCropEditor()
        guard let editor = await waitForPresented(PageCropViewController.self) else {
            SelfTest.log("FEL: rutan för beskärningen öppnades inte")
            return
        }
        for _ in 0..<80 where !editor.hasImage {
            await pause(0.1)
        }
        await pause(0.5)
        let suggestion: PageCrop? = await withCheckedContinuation { continuation in
            editor.requestSuggestion { continuation.resume(returning: $0) }
        }
        SelfTest.log("Förslaget (P3) över fem sidor: \(suggestion.map { PageCropStore.format(.init(crop: $0, isOn: true)) } ?? "inget") "
                     + "(papperet i provboken är 0,10 till 0,90 brett, texten cirka 0,18 till 0,81 och 0,15 till 0,65 högt)")
        let chosen = suggestion ?? PageCrop(rect: CGRect(x: 0.15, y: 0.12, width: 0.7, height: 0.76))
        editor.setCrop(chosen)
        await pause(0.4)
        if let shown = presentedViewController?.view {
            SelfTest.saveScreen(shown, name: "02-ramen")
        }
        editor.doneTapped()
        await pause(0.8)
        let cropped = await waitForCrop()
        view.layoutIfNeeded()
        visiblePages.forEach { $0.view.layoutIfNeeded() }
        await pause(0.4)
        let croppedFrame = visiblePages.first(where: { !$0.isBlank })?.imageFrame ?? .zero
        let growth = fullFrame.width > 0 ? croppedFrame.width / max(chosen.rect.width, 0.01) / fullFrame.width : 0
        SelfTest.log("Beskuren (P3): \(cropped ? "ny sidbild" : "FEL, ingen ny sidbild"), sparad "
                     + "\(UserDefaults.standard.string(forKey: PageCropStore.prefix + book.id) ?? "INGET"), bildruta "
                     + "\(Int(fullFrame.width)) x \(Int(fullFrame.height)) till \(Int(croppedFrame.width)) x "
                     + "\(Int(croppedFrame.height)), texten \(String(format: "%.2f", Double(growth))) gånger större, "
                     + "variant på disk: \(renderer.diskCount()) sidbilder")
        let cropOK = selfTestCropWord("beskuren")
        SelfTest.saveScreen(view, name: "03-beskuren")
        if let page = visiblePages.first(where: { !$0.isBlank }), let pdfPage = document.page(at: page.pageIndex),
           let string = pdfPage.string {
            let range = (string as NSString).range(of: "kunskap", options: [.caseInsensitive])
            if range.location != NSNotFound {
                page.flash(PDFTextRanges.rects(on: pdfPage, range: range))
                await pause(0.3)
                SelfTest.saveScreen(view, name: "04-beskuren-sokruta")
            }
        }
        turnPage(forward: true)
        await pause(1.4)
        _ = await waitForCrop()
        SelfTest.saveScreen(view, name: "05-nasta-sida")
        let nextOK = selfTestCropWord("nästa sida")

        // Ett tryck visar hela sidan, ett till beskär igen.
        setCropOn(false)
        let backToFull = await waitForCrop()
        view.layoutIfNeeded()
        let offFrame = visiblePages.first(where: { !$0.isBlank })?.imageFrame ?? .zero
        setCropOn(true)
        let again = await waitForCrop()
        SelfTest.log("Visa hela sidan (P3): \(backToFull ? "ok" : "FEL"), bildruta \(Int(offFrame.width)) x "
                     + "\(Int(offFrame.height)), beskär igen \(again ? "ok" : "FEL"), ramen kvar "
                     + "\(PageCropStore.saved(bookID: book.id)?.isOn == true ? "på" : "FEL")")
        let backup = Backup.positionSnapshot()[PageCropStore.prefix + book.id] != nil
        SelfTest.log("Ramen i säkerhetskopian (P3): \(backup ? "ja" : "FEL, saknas")")
        SelfTest.log("Beskärningen (P3) sammanfattat: \(fullOK && cropOK && nextOK && cropped && backToFull ? "ok" : "FEL")")

        // P5: Apples Vision med tyska på svensk text.
        SelfTest.log("Vision (P5), språk i simulatorn: \(VisionProbe.supportedLanguagesSummary())")
        for line in await VisionProbe.swedishProbe() {
            SelfTest.log("Vision (P5): " + line)
        }

        await selfTestTextMode()
    }

    /// P4: biblioteket döljer txt-filen, Visa texten öppnar samma sida och Visa sidbilden tar tillbaka.
    fileprivate func selfTestTextMode() async {
        let hidden = PDFTextCompanion.companionTextIDs(in: LibraryStore.shared.allBooks())
        let txtBook = PDFTextCompanion.textURL(forPDF: book.url).flatMap { LibraryStore.shared.book(at: $0) }
        SelfTest.log("Biblioteket (P4): txt-filen \(txtBook == nil ? "FEL, finns inte i registret" : "finns"), "
                     + "dold i biblioteket: \(txtBook.map { hidden.contains($0.id) ? "ja" : "FEL, nej" } ?? "-")")
        guard let navigation = navigationController else {
            SelfTest.log("FEL: ingen navigering för textläget")
            return
        }
        jump(to: 2)
        await pause(0.6)
        showTextMode()
        var text: ReflowReaderViewController?
        for _ in 0..<60 {
            text = navigation.topViewController as? ReflowReaderViewController
            if text != nil {
                break
            }
            await pause(0.1)
        }
        guard let reader = text else {
            SelfTest.log("FEL: textläget öppnades inte")
            return
        }
        await pause(4)
        let shown = reader.photoTestChapter
        SelfTest.log("Visa texten (P4) från PDF:ens sida 3: kapitel \(shown.index + 1), rubrik \(shown.title ?? "ingen") "
                     + "(väntat kapitel 3, Sida 13): \(shown.index == 2 && shown.title == "Sida 13" ? "ok" : "FEL")")
        SelfTest.saveScreen(navigation.view, name: "06-textlage")
        reader.photoTestJump(chapter: 3)
        await pause(3)
        SelfTest.saveScreen(navigation.view, name: "07-textlage-sida-14")
        reader.showPageImage()
        var pdf: PDFCurlReaderViewController?
        for _ in 0..<60 {
            pdf = navigation.topViewController as? PDFCurlReaderViewController
            if pdf != nil {
                break
            }
            await pause(0.1)
        }
        guard let back = pdf else {
            SelfTest.log("FEL: Visa sidbilden öppnade inte PDF:en")
            return
        }
        await pause(2.5)
        SelfTest.log("Visa sidbilden (P4) från kapitel 4: PDF:ens sida \(back.photoTestPageIndex + 1) (väntat 4): "
                     + "\(back.photoTestPageIndex == 3 ? "ok" : "FEL"), ramen \(back.renderer.crop.isFull ? "FEL, borta" : "kvar")")
        SelfTest.saveScreen(navigation.view, name: "08-tillbaka-till-sidbilden")
    }

    /// P3: ordet kunskap på sidan som syns. Ordet under fingret mitt på ordets ruta ska vara kunskap, och
    /// sidbilden ska ha bläck i rutan men inte två rader ovanför, så att bilden och omräkningen stämmer.
    fileprivate func selfTestCropWord(_ label: String) -> Bool {
        guard let page = visiblePages.first(where: { !$0.isBlank }), let pdfPage = document.page(at: page.pageIndex),
              let pageFrame = page.pageFrame, let imageFrame = page.imageFrame, let string = pdfPage.string else {
            SelfTest.log("FEL (\(label)): ingen sida med text")
            return false
        }
        let range = (string as NSString).range(of: "kunskap", options: [.caseInsensitive])
        guard range.location != NSNotFound, let rect = PDFTextRanges.rects(on: pdfPage, range: range).first,
              let shown = page.viewRect(forPageRect: rect) else {
            SelfTest.log("FEL (\(label)): hittade inte ordet kunskap")
            return false
        }
        let finger = CGPoint(x: shown.midX, y: shown.midY)
        let word = Self.word(on: pdfPage, at: finger, imageFrame: pageFrame).map { (string as NSString).substring(with: $0) }
        let ink = Self.inkShare(in: page.view, rect: shown)
        let above = Self.inkShare(in: page.view, rect: shown.offsetBy(dx: 0, dy: -2.2 * shown.height))
        let trimmed = word?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ok = trimmed == "kunskap" && ink > 0.04 && above < ink / 3 && imageFrame.contains(finger)
        SelfTest.log("Ordet kunskap (\(label), sida \(page.pageIndex + 1)): bildruta \(Int(imageFrame.minX)),"
                     + "\(Int(imageFrame.minY)) \(Int(imageFrame.width)) x \(Int(imageFrame.height)), ordets ruta "
                     + "\(Int(shown.minX)),\(Int(shown.minY)) \(Int(shown.width)) x \(Int(shown.height)), under fingret "
                     + "\(trimmed ?? "inget"), bläck i rutan \(String(format: "%.1f", ink * 100)) %, två rader ovanför "
                     + "\(String(format: "%.1f", above * 100)) %: \(ok ? "ok" : "FEL")")
        return ok
    }

    /// Andelen mörka punkter i en ruta av en vy, till självtestet.
    fileprivate static func inkShare(in view: UIView, rect: CGRect) -> Double {
        let width = max(Int(rect.width.rounded()), 1)
        let height = max(Int(rect.height.rounded()), 1)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { _ in
            _ = view.drawHierarchy(in: CGRect(x: -rect.minX, y: -rect.minY, width: view.bounds.width,
                                              height: view.bounds.height), afterScreenUpdates: true)
        }
        guard let cg = image.cgImage else { return -1 }
        var pixels = [UInt8](repeating: 255, count: width * height)
        let dark: Int = pixels.withUnsafeMutableBytes { buffer -> Int in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return -1 }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return buffer.bindMemory(to: UInt8.self).filter { $0 < 110 }.count
        }
        return dark < 0 ? -1 : Double(dark) / Double(width * height)
    }

    /// Väntar tills sidorna som syns har bilder ritade med ramen som gäller.
    fileprivate func waitForCrop() async -> Bool {
        for _ in 0..<150 {
            if !visiblePages.isEmpty,
               visiblePages.allSatisfy({ $0.isBlank || ($0.imageFrame != nil && $0.shownCrop == renderer.crop) }) {
                view.layoutIfNeeded()
                return true
            }
            await pause(0.1)
        }
        return false
    }

    // MARK: Tillbaka och historik (V4)

    private func setUpBackStack() {
        backStack.install(in: view, above: bottomBar)
        chrome.backControl = backStack.control
        backStack.apply(Theme.palette(for: theme))
        backStack.onGo = { [weak self] index in
            self?.jump(to: index)
        }
        backStack.onChange = { [weak self] in
            guard let self = self else { return }
            self.chrome.setHistory(self.backStack.recentLabels) { [weak self] offset in
                self?.backStack.goBack(offset)
            }
        }
    }

    /// Ett hopp som användaren gör (innehåll, sök, markering, bokmärke, gå till sida, reglaget, länk, miniatyr):
    /// sidan man lämnar sparas, så att Tillbaka hittar dit. `sticky` (V3): Tillbaka ligger kvar när man bläddrar.
    private func hop(to index: Int, sticky: Bool = false) {
        let target = min(max(index, 0), renderer.pageCount - 1)
        if !visibleIndices.contains(target) {
            backStack.record(currentIndex, label: placeLabel(currentIndex), sticky: sticky)
        }
        jump(to: target)
    }

    /// Sidan som den står i Tillbaka: bokens eget sidnummer om det finns.
    private func placeLabel(_ index: Int) -> String {
        "s. \(printedLabel(for: index) ?? String(index + 1))"
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
        slider.accessibilityStep = 1
        // V3: håll på tidslinjen för miniatyrerna.
        slider.onLongPress = { [weak self] in
            self?.showThumbnails()
        }

        bottomBar.pageButton.addTarget(self, action: #selector(showGoToPage), for: .touchUpInside)
        bottomBar.infoButton.addTarget(self, action: #selector(toggleRemaining), for: .touchUpInside)
        if chapterStarts.isEmpty {
            // V1: en PDF utan innehållsförteckning visar sidorna kvar i boken, och trycket växlar inget.
            bottomBar.infoButton.accessibilityHint = nil
        }
        updatePageLabel()
        updateTimelineMarks()
        updateReadRanges()
    }

    /// V2: kapitelgränserna ur PDF:ens innehåll, markeringarna och bokmärkena på tidslinjen. Ritas om bara när
    /// de ändras, inte när sidan vänds.
    @objc private func updateTimelineMarks() {
        let last = Double(max(renderer.pageCount - 1, 1))
        let timeline = bottomBar.slider
        timeline.chapters = chapterStarts.map { Double($0.index) / last }
        timeline.dots = AnnotationStore.shared.highlights(book: bookKey).map {
            ReaderTimeline.Dot(position: Double($0.section) / last, color: $0.color.solid)
        }
        timeline.bookmarks = AnnotationStore.shared.bookmarks(book: bookKey).map { Double($0.section) / last }
    }

    /// V1: ett tryck på sidor kvar växlar mellan kapitlet och boken.
    @objc private func toggleRemaining() {
        PageInfo.toggle(hasChapters: !chapterStarts.isEmpty)
        updatePageLabel()
    }

    /// V1: sidorna kvar efter den sista sidan som syns, i kapitlet (ur PDF:ens innehåll) eller i boken.
    private func remainingText(lastShown: Int) -> String {
        switch PageInfo.effectiveScope(hasChapters: !chapterStarts.isEmpty) {
        case .chapter:
            let end = chapterStarts.first { $0.index > lastShown }?.index ?? renderer.pageCount
            return PageInfo.text(left: PageInfo.pagesLeft(lastShown: lastShown, end: end), scope: .chapter)
        case .book:
            return PageInfo.text(left: PageInfo.pagesLeft(lastShown: lastShown, end: renderer.pageCount), scope: .book)
        }
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

        let link = UITapGestureRecognizer(target: self, action: #selector(handleLinkTap(_:)))
        link.delegate = self
        view.addGestureRecognizer(link)
        linkTap = link

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
        bottomBar.infoButton.setTitle(remainingText(lastShown: indices.max() ?? currentIndex), for: .normal)
        bottomBar.chapterLabel.text = chapterTitle(for: indices.first ?? currentIndex)
        chrome.setSubtitle(chapterTitle(for: indices.first ?? currentIndex))
        if !bottomBar.slider.isTracking {
            bottomBar.slider.value = Float(currentIndex)
        }
        reportReadingStatus(indices)
        logReading(indices)
        updateSideNotes()
    }

    /// K12: anteckningen för sidan som syns (den vänstra i ett uppslag).
    fileprivate func updateSideNotes() {
        guard let panel = sideNotes else { return }
        let indices = visibleIndices.isEmpty ? [currentIndex] : visibleIndices
        let index = indices.min() ?? currentIndex
        panel.show(book: bookKey, section: index, title: placeLabel(index))
    }

    /// K10: sidorna som syns, till läsloggen (bara i minnet, databasen skrivs högst en gång i minuten).
    private func logReading(_ indices: [Int]) {
        let last = Double(max(renderer.pageCount - 1, 1))
        ReadingLog.shared.pageShown(book: bookKey, pages: indices.map {
            ReadingLog.Page(key: String($0), position: Double($0) / last)
        })
    }

    /// K10: det man läst i boken, mörkare på tidslinjen.
    @objc private func updateReadRanges() {
        let last = Double(max(renderer.pageCount - 1, 1))
        bottomBar.slider.readRanges = ReadingLog.shared.readRanges(book: bookKey, step: 1 / last)
    }

    /// Var man är, till biblioteket (B1, B2): andel läst, kapitlet, sidan och sidantalet.
    private func reportReadingStatus(_ indices: [Int]) {
        let count = renderer.pageCount
        guard count > 0 else { return }
        let index = min(max(indices.max() ?? currentIndex, 0), count - 1)
        LibraryStore.shared.saveStatus(ReadingStatus(progress: Double(index + 1) / Double(count),
                                                     chapter: chapterTitle(for: index) ?? "",
                                                     page: index + 1, pages: count), for: book)
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

    /// "s. 52 av 300", eller med bokens egna sidnummer när de skiljer sig: "s. 45 (52 av 300)".
    private func pageText(for indices: [Int]) -> String {
        let numbers = indices.map { String($0 + 1) }.joined(separator: " och ")
        let printed = indices.compactMap { printedLabel(for: $0) }
        if !printed.isEmpty, printed.count == indices.count {
            return "s. \(printed.joined(separator: " och ")) (\(numbers) av \(renderer.pageCount))"
        }
        return "s. \(numbers) av \(renderer.pageCount)"
    }

    /// Sidnumret som står i boken, om det skiljer sig från sidans plats i filen (K2: inställningen för boken,
    /// förslaget ur filnamnet eller PDF:ens sidetiketter).
    fileprivate func printedLabel(for index: Int) -> String? {
        pageNumbering.printed(for: index, pdfLabel: pdfLabel(for: index))
    }

    /// PDF:ens egen sidetikett för sidan, om den finns.
    private func pdfLabel(for index: Int) -> String? {
        guard let label = document.page(at: index)?.label?.trimmingCharacters(in: .whitespaces),
              !label.isEmpty,
              label != String(index + 1) else {
            return nil
        }
        return label
    }

    private lazy var hasPDFLabels: Bool = {
        let limit = min(self.document.pageCount, 60)
        return (0..<limit).contains { self.pdfLabel(for: $0) != nil }
    }()

    /// K2: bokens egna sidnummer. Läses om när inställningen ändras i Bokens sidnummer.
    fileprivate lazy var pageNumbering: BookPageNumbering = makePageNumbering()

    private func makePageNumbering() -> BookPageNumbering {
        var info = BookInfoStore.shared.info(book: bookKey)
        // D4-6: första gången boken öppnas sparas det automatiska valet, så att ett nytt filnamn eller en ny
        // version av filen inte räknar om sidnumren utan att läsaren ändrar dem själv.
        if info.pageFirst == BookPageNumbering.notChosen,
           let automatic = BookPageNumbering.automaticSetting(fileName: book.url.lastPathComponent,
                                                              pageCount: document.pageCount, hasPDFLabels: hasPDFLabels) {
            info.pageFirst = automatic.first
            info.pageSpread = automatic.spread
            BookInfoStore.shared.save(info, book: bookKey)
            AppLog.shared.write("K2: bokens sidnummer valda automatiskt och sparade (\(automatic.first), uppslag \(automatic.spread))")
        }
        return BookPageNumbering.resolve(first: info.pageFirst, spread: info.pageSpread,
                                         fileName: book.url.lastPathComponent, pageCount: document.pageCount,
                                         hasPDFLabels: hasPDFLabels)
    }

    /// K3: bokens sidnummer för en markering. I ett uppslag avgör markeringens plats på bilden vilken sida.
    fileprivate func citationPage(for highlight: Highlight) -> String? {
        var half: Int?
        if case let .offset(_, spread) = pageNumbering.source, spread, let page = document.page(at: highlight.section) {
            // D4-7: alla markeringens rutor, i sidans visade koordinater. Över mitten eller på båda: "N f.".
            half = BookPageNumbering.spreadHalf(rects: highlight.rects, bounds: page.bounds(for: .cropBox),
                                                rotation: page.rotation)
        }
        return pageNumbering.citationPage(for: highlight.section, half: half,
                                          pdfLabel: pdfLabel(for: highlight.section))
    }

    // MARK: Reglaget

    @objc private func sliderMoved() {
        let index = Int(bottomBar.slider.value.rounded())
        if bottomBar.slider.isTracking {
            bottomBar.pageButton.setTitle(pageText(for: [index]), for: .normal)
            // V2: kapitlet och sidan i bubblan ovanför fingret.
            let page = pageText(for: [index])
            bottomBar.slider.bubbleText = chapterTitle(for: index).map { "\($0)\n\(page)" } ?? page
        } else {
            // VoiceOver ändrar värdet utan att dra.
            jump(to: index)
        }
    }

    @objc private func sliderReleased() {
        hop(to: Int(bottomBar.slider.value.rounded()))
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

    /// Kapitlets rubrik (eller sidan, i en PDF utan innehåll) och de tre senaste markeringarna i boken.
    @discardableResult
    private func showResumeCard(lastRead: Date?) -> ReaderResumeCard {
        let latest = AnnotationStore.shared.highlights(book: bookKey).sorted { $0.created > $1.created }
        let card = ReaderResumeCard(chapter: chapterTitle(for: currentIndex) ?? pageName(currentIndex), lastRead: lastRead,
                                    highlights: Array(latest.prefix(3)))
        card.show(in: view)
        return card
    }

    // MARK: Fotnoter och länkar (V5)

    /// Läser sidans interna länkar på renderingskön en gång. Kamerafoton har inga, och då händer inget.
    private func loadLinks(onPage index: Int) {
        guard linksCache[index] == nil, linksInFlight.insert(index).inserted else { return }
        renderer.links(onPage: index) { [weak self] links in
            self?.linksInFlight.remove(index)
            self?.linksCache[index] = links
        }
    }

    /// Länken under en punkt och sidan den står på.
    private func linkHit(at point: CGPoint) -> (link: PDFInternalLink, page: PDFPageViewController)? {
        for page in visiblePages where !page.isBlank {
            guard let links = linksCache[page.pageIndex], !links.isEmpty else { continue }
            let local = page.view.convert(point, from: view)
            guard page.view.bounds.contains(local) else { continue }
            for link in links {
                if let shown = page.viewRect(forPageRect: link.rect), shown.insetBy(dx: -8, dy: -6).contains(local) {
                    return (link, page)
                }
            }
        }
        return nil
    }

    @objc private func handleLinkTap(_ tap: UITapGestureRecognizer) {
        guard let hit = linkHit(at: tap.location(in: view)) else { return }
        openLink(hit.link, on: hit.page)
    }

    /// En fotnotssiffra visar noten i en ruta (texten läses på renderingskön). Andra länkar, och noter vars text
    /// inte går att läsa, hoppar dit som ett vanligt hopp med Tillbaka.
    private func openLink(_ link: PDFInternalLink, on page: PDFPageViewController) {
        guard link.isNote, presentedViewController == nil else {
            hop(to: link.page)
            return
        }
        let anchor = page.viewRect(forPageRect: link.rect).map { view.convert($0, from: page.view) }
            ?? CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        let started = CACurrentMediaTime()
        renderer.noteText(onPage: link.page, at: link.point) { [weak self] text in
            guard let self = self, self.presentedViewController == nil else { return }
            guard let text = text else {
                self.hop(to: link.page)
                return
            }
            self.lastNoteMilliseconds = Int(((CACurrentMediaTime() - started) * 1000).rounded())
            // Bara siffran i rubriken: länkens ruta kan ta med en punkt eller en hakparentes bredvid.
            let number = link.label.filter(\.isNumber)
            NotePopoverViewController.present(from: self, sourceView: self.view, sourceRect: anchor,
                                              heading: number.isEmpty ? "Not" : "Not \(number)", text: text) { [weak self] in
                self?.hop(to: link.page)
            }
        }
    }

    // MARK: Miniatyrer (V3)

    /// Rutnätet med små sidbilder. Ett tryck på en sida hoppar dit, och Tillbaka till sidan man var på ligger kvar
    /// tills man går tillbaka eller trycker på krysset (Stanna här).
    @objc private func showThumbnails() {
        guard presentedViewController == nil else { return }
        let first = document.page(at: 0)
        let box = first?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 1, height: 1.414)
        let rotated = (first?.rotation ?? 0) % 180 != 0
        let aspect = rotated ? box.width / max(box.height, 1) : box.height / max(box.width, 1)
        let grid = PDFThumbnailsViewController(renderer: renderer, pageCount: renderer.pageCount,
                                               currentIndex: currentIndex, aspect: aspect) { [weak self] index in
            self?.placeLabel(index) ?? "s. \(index + 1)"
        }
        grid.onSelect = { [weak self] index in
            self?.dismiss(animated: true)
            self?.hop(to: index, sticky: true)
        }
        let navigation = UINavigationController(rootViewController: grid)
        navigation.modalPresentationStyle = .fullScreen
        present(navigation, animated: true)
    }

    // MARK: Innehåll och Gå till sida

    @objc private func showContents() {
        let outline = OutlineViewController(document: document, currentIndex: currentIndex)
        outline.pageText = { [weak self] index in
            self?.printedLabel(for: index) ?? String(index + 1)
        }
        outline.pageCount = document.pageCount
        outline.readPages = Set(ReadingLog.shared.readPageKeys(book: bookKey).compactMap { Int($0) })
        outline.onSelectPage = { [weak self] index in
            self?.dismiss(animated: true)
            self?.hop(to: index)
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
        let message = pageNumbering.usesBookNumbers
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
                self.hop(to: index)
            } else {
                self.showMessage(title: "Sidan finns inte",
                                 message: "Hittade ingen sida \(text) i boken.")
            }
        })
        present(alert, animated: true)
    }

    /// Bokens egna sidnummer först (som "xii" eller "45"), annars sidans plats i filen (K2).
    private func pageIndex(forTyped text: String) -> Int? {
        pageNumbering.index(forTyped: text, pageCount: document.pageCount) { [weak self] index in
            self?.document.page(at: index)?.label
        }
    }

    /// K2: Bokens sidnummer i Mer. Filens första sida som bokens sida, en eller två boksidor per bild.
    @objc fileprivate func showBookPages() {
        guard presentedViewController == nil else { return }
        var info = BookInfoStore.shared.info(book: bookKey)
        let suggestion = BookPageNumbering.suggestion(fileName: book.url.lastPathComponent,
                                                      pageCount: document.pageCount)
        var message = pageNumbering.summary
        if let suggestion = suggestion {
            message += "\n\nFörslag ur filnamnet: sidorna \(suggestion.first) till \(suggestion.last)"
                + (suggestion.spread ? ", uppslag." : ".")
            if !suggestion.matches {
                message += " Filen har \(document.pageCount) sidor, och det stämmer inte med intervallet. Kontrollera mot "
                    + "en sida innan du sparar."
            }
        }
        if let printed = printedPageSuggestion {
            message += "\n\nFörslag ur sidornas text: filens första sida är s. \(printed.first) (tryckta sidnummer på "
                + "\(printed.votes) sidor). Kontrollera mot en sida innan du sparar."
        }
        message += "\n\nSkriv bokens sidnummer för filens första sida."
        let alert = UIAlertController(title: "Bokens sidnummer", message: message, preferredStyle: .alert)
        let current: Int?
        if case let .offset(first, _) = pageNumbering.source {
            current = first
        } else {
            current = suggestion?.first ?? printedPageSuggestion?.first
        }
        alert.addTextField { field in
            field.keyboardType = .numberPad
            field.placeholder = "Till exempel 63"
            field.text = current.map { String($0) }
            field.clearButtonMode = .whileEditing
        }
        let save: (Bool) -> Void = { [weak self, weak alert] spread in
            guard let self = self else { return }
            let typed = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespaces) ?? ""
            guard let first = Int(typed), first > 0, first < 100_000 else {
                self.showMessage(title: "Skriv ett sidnummer", message: "Sidnumret ska vara ett tal, till exempel 63.")
                return
            }
            info.pageFirst = first
            info.pageSpread = spread
            self.applyBookPages(info)
        }
        alert.addAction(UIAlertAction(title: "En boksida per sida i filen", style: .default) { _ in save(false) })
        alert.addAction(UIAlertAction(title: "Två boksidor per sida (uppslag)", style: .default) { _ in save(true) })
        if hasPDFLabels, info.pageFirst != BookPageNumbering.labelNumbers {
            alert.addAction(UIAlertAction(title: "Sidnumren som står i PDF:en", style: .default) { [weak self] _ in
                info.pageFirst = BookPageNumbering.labelNumbers
                info.pageSpread = false
                self?.applyBookPages(info)
            })
        }
        if info.pageFirst != BookPageNumbering.fileNumbers {
            alert.addAction(UIAlertAction(title: "Filens sidnummer är bokens", style: .default) { [weak self] _ in
                info.pageFirst = BookPageNumbering.fileNumbers
                info.pageSpread = false
                self?.applyBookPages(info)
            })
        }
        alert.addAction(UIAlertAction(title: "Avbryt", style: .cancel))
        present(alert, animated: true)
    }

    /// D4-1: varför citatet saknar sida, med förslaget ur sidornas text om det finns.
    fileprivate func missingPageHint(for highlight: Highlight) -> String {
        var text = "Bokens sidnummer är inte inställt, så citatet har ingen sida. Markeringen står på filens sida "
            + "\(highlight.section + 1)."
        if let printed = printedPageSuggestion {
            text += " Sidornas text tyder på s. \(printed.first + highlight.section) i boken."
        }
        if let suggestion = BookPageNumbering.suggestion(fileName: book.url.lastPathComponent,
                                                         pageCount: document.pageCount), !suggestion.matches {
            text += " Filnamnet säger s. \(suggestion.first) till \(suggestion.last), men filen har \(document.pageCount) sidor."
        }
        return text
    }

    /// D4-1: letar efter tryckta sidnummer i sidornas text i bakgrunden, med ett eget dokument, när bokens
    /// sidnummer inte är inställt. Resultatet är bara ett förslag i Bokens sidnummer och citatrutan.
    fileprivate func startPrintedPageDetection() {
        guard pageNumbering.source == .file, printedPageSuggestion == nil else { return }
        let url = book.url
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let document = PDFDocument(url: url), !document.isLocked else { return }
            let count = min(document.pageCount, 24)
            var pages: [(index: Int, numbers: [Int])] = []
            for index in 0..<count {
                let text = document.page(at: index)?.string ?? ""
                pages.append((index, PrintedPageNumbers.candidates(in: text)))
            }
            let found = PrintedPageNumbers.firstPage(pages)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.printedPageSuggestion = found
                AppLog.shared.write("D4-1: tryckta sidnummer i textlagret \(found.map { "ger s. \($0.first) (\($0.votes) sidor)" } ?? "hittades inte")")
            }
        }
    }

    /// K12: panelen Anteckningar bredvid texten, av och på i Mer.
    @objc fileprivate func toggleSideNotes() {
        if let panel = sideNotes {
            panel.remove()
            sideNotes = nil
            return
        }
        let panel = SideNotesPanel()
        panel.onClose = { [weak self] in
            self?.toggleSideNotes()
        }
        SideNotesPanel.install(panel, in: view)
        sideNotes = panel
        updateSideNotes()
    }

    /// K8: begreppsregistret. Ett tryck på ett begrepp söker efter det i boken.
    @objc fileprivate func showConcepts() {
        guard presentedViewController == nil else { return }
        let list = ConceptsViewController(book: book)
        list.onSearch = { [weak self] term in
            self?.lastQuery = term
            self?.showSearch()
        }
        let navigation = UINavigationController(rootViewController: list)
        navigation.modalPresentationStyle = traitCollection.userInterfaceIdiom == .pad ? .formSheet : .pageSheet
        present(navigation, animated: true)
    }

    /// K3: Bokinfo för citat i Mer.
    @objc fileprivate func showBookInfo() {
        guard presentedViewController == nil else { return }
        BookInfoEditor.present(book: book, from: self) {}
    }

    private func applyBookPages(_ info: BookInfo) {
        BookInfoStore.shared.save(info, book: bookKey)
        pageNumbering = makePageNumbering()
        updatePageLabel()
        AppLog.shared.write("K2: bokens sidnummer ändrade (\(pageNumbering.summary))")
    }

    private func showMessage(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: Zoom

    /// Aa: bakgrunderna och Zooma sidan (U2).
    @objc private func showAppearance() {
        guard presentedViewController == nil else { return }
        let controller = AppearanceViewController(theme: theme, typography: nil)
        controller.onTheme = { [weak self] option in
            self?.setTheme(option)
        }
        controller.onZoom = { [weak self] in
            self?.zoomCurrentPage()
        }
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .popover
        navigation.popoverPresentationController?.barButtonItem = chrome.readerItem
        present(navigation, animated: true)
    }

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
              let imageFrame = page.pageFrame else {
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
        backStack.pageTurned()
    }
}

// MARK: Tryckzoner

extension PDFCurlReaderViewController: UIGestureRecognizerDelegate {

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Reglaget och sidnumret har egna tryck, liksom raden som visas medan man markerar.
        if let touched = touch.view, touched.isDescendant(of: bottomBar) || touched.isDescendant(of: backStack.control) {
            return false
        }
        if let bar = markBar, let touched = touch.view, touched.isDescendant(of: bar) {
            return false
        }
        if let panel = sideNotes, let touched = touch.view, touched.isDescendant(of: panel) {
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
        // V5: en länk inom filen (en fotnotssiffra) går före ett ordstreck (O4), en markering och bläddringen.
        let onLink = !markMode && linkHit(at: touch.location(in: view)) != nil
        if gestureRecognizer === linkTap {
            return onLink
        }
        if onLink {
            return gestureRecognizer === wordPress
        }
        let onMark = markHit(at: touch.location(in: view)).map { hit in
            // O4: ett sparat ord tar trycket bara mitt på sidan, så att kanterna alltid bläddrar.
            !SavedWordMarks.isWordID(hit.id) || Self.isMiddle(touch.location(in: view).x, width: view.bounds.width)
        } ?? false
        if gestureRecognizer === markTap {
            return !markMode && onMark
        }
        if onMark, gestureRecognizer is UITapGestureRecognizer {
            // Ett tryck på en markering öppnar markeringens ruta, inte menyn eller nästa sida.
            return false
        }
        let inMiddle = ReaderTapZones.isMiddle(touch.location(in: view).x, width: view.bounds.width)

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
        applyWordMarks(to: page)
        page.isBookmarked = bookmarkedPages.contains(page.pageIndex)
        page.showsRibbonHint = !chromeHidden
        loadLinks(onPage: page.pageIndex)
        if marksCache[page.pageIndex]?.isEmpty == false {
            markSetupTimes = Array((markSetupTimes + [(CACurrentMediaTime() - started) * 1000]).suffix(200))
        }
    }

    /// O4: strecken under sparade ord. Sidans text läses på renderingskön, aldrig under en vikning.
    fileprivate func applyWordMarks(to page: PDFPageViewController) {
        let marks = SavedWordMarks.shared
        let forms = marks.forms
        guard !forms.isEmpty else {
            page.setWordMarks([])
            return
        }
        if wordMarksVersion != marks.version {
            wordMarksCache.removeAll()
            wordMarksInFlight.removeAll()
            wordMarksVersion = marks.version
        }
        let index = page.pageIndex
        if let cached = wordMarksCache[index] {
            page.setWordMarks(cached)
            return
        }
        guard wordMarksInFlight.insert(index).inserted else { return }
        let version = marks.version
        renderer.wordRects(onPage: index, forms: forms) { [weak self] result in
            guard let self = self, self.wordMarksVersion == version, self.wordMarksInFlight.remove(index) != nil else {
                return
            }
            self.wordMarksCache[index] = result
            for shown in self.visiblePages where shown.pageIndex == index {
                shown.setWordMarks(SavedWordMarks.shared.isEnabled ? result : [])
            }
        }
    }

    @objc fileprivate func savedWordMarksChanged() {
        for page in visiblePages where !page.isBlank {
            applyWordMarks(to: page)
        }
    }

    /// Mitten av sidan, där ett tryck inte bläddrar (G12, `ReaderTapZones`).
    fileprivate static func isMiddle(_ x: CGFloat, width: CGFloat) -> Bool {
        ReaderTapZones.isMiddle(x, width: width)
    }

    /// O4: ett tryck på ett streck visar ordkortet för det sparade ordet, med meningen det sparades i.
    fileprivate func presentSavedWord(id: String, page: PDFPageViewController, at point: CGPoint) {
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

    /// Markeringarna på en sida har ändrats: läs om dem ur databasen.
    fileprivate func refreshMarks(onPage index: Int) {
        updateTimelineMarks()
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
                  let frame = page.pageFrame else { return }
            let local = page.view.convert(point, from: view)
            let tapped = page.markID(at: local).flatMap { SavedWordMarks.isWordID($0) ? nil : $0 }
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
                  let frame = selection.page.imageFrame, let pageFrame = selection.page.pageFrame else { return }
            if !selection.moved, hypot(point.x - selection.startPoint.x, point.y - selection.startPoint.y) > 6 {
                selection.moved = true
            }
            var local = selection.page.view.convert(point, from: view)
            local.x = min(max(local.x, frame.minX + 1), frame.maxX - 1)
            local.y = min(max(local.y, frame.minY + 1), frame.maxY - 1)
            let previous = selection.current
            if let word = PDFCurlReaderViewController.word(on: selection.pdfPage, at: local, imageFrame: pageFrame) {
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
        menu.onConcept = { [weak self] in
            guard let self = self, let current = AnnotationStore.shared.highlight(id: id) else { return }
            ConceptEditor.add(from: current, presenter: self)
        }
        menu.onCite = { [weak self] in
            guard let self = self, let current = AnnotationStore.shared.highlight(id: id) else { return }
            let page = self.citationPage(for: current)
            CitationViewController.present(book: self.book, text: current.text, page: page,
                                           pageHint: page == nil ? self.missingPageHint(for: current) : nil,
                                           onSetPages: { [weak self] in self?.showBookPages() },
                                           from: self, sourceView: self.view, sourceRect: anchor)
        }
        menu.onExplain = { [weak self] in
            // A1: meningarna runt markeringen på sidan, ur ett eget dokument i bakgrunden.
            guard let self = self, let current = AnnotationStore.shared.highlight(id: id) else { return }
            PassageExplain.present(highlight: current, book: self.book, chapter: self.chapterTitle(for: current.section),
                                   source: .pdf(self.book.url), from: self, sourceView: self.view, sourceRect: anchor,
                                   onSaved: { [weak self] in self?.refreshMarks(onPage: current.section) })
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
        updateTimelineMarks()
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
        toggleBookmarks(onIndices: visibleIndices.isEmpty ? [currentIndex] : visibleIndices)
    }

    /// Bandet i sidans hörn (U3): ett tryck där bokmärker just den sidan.
    @objc fileprivate func handleRibbonTap(_ tap: UITapGestureRecognizer) {
        guard let page = ribbonPage(at: tap.location(in: view)) else { return }
        toggleBookmarks(onIndices: [page.pageIndex])
        SelfTest.log("Bandet i hörnet: sidan \(page.pageIndex + 1) \(bookmarkedPages.contains(page.pageIndex) ? "har" : "har inte") bokmärke")
    }

    fileprivate func ribbonPage(at point: CGPoint) -> PDFPageViewController? {
        visiblePages.first { page in
            guard !page.isBlank, let zone = page.ribbonZone else { return false }
            return page.view.convert(zone, to: view).contains(point)
        }
    }

    /// Självtestet (granskning 2, N7): bokmärket tas bort med raden Ångra, och Ångra tar tillbaka det.
    fileprivate func selfTestUndoBookmark() async {
        let before = bookmarks.count
        toggleBookmark()
        try? await Task.sleep(nanoseconds: 300_000_000)
        let removed = bookmarks.count
        let shown = UndoBar.current != nil
        SelfTest.saveScreen(view, name: "03e-bokmarke-angra")
        UndoBar.current?.performUndo()
        try? await Task.sleep(nanoseconds: 300_000_000)
        let ok = before > 0 && removed == before - 1 && shown && bookmarks.count == before
        SelfTest.log("Bokmärket bort med bandet (N7): \(before) före, \(removed) efter, raden Ångra "
                     + "\(shown ? "visas" : "saknas"), \(bookmarks.count) efter Ångra. \(ok ? "Rätt" : "FEL")")
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
        let index = min(renderer.pageCount - 1, 5)
        let shown = timeline.value
        timeline.value = Float(index)
        timeline.previewBubble(chapterTitle(for: index).map { "\($0)\n\(pageText(for: [index]))" } ?? pageText(for: [index]))
        SelfTest.saveScreen(view, name: "03b-tidslinje")
        timeline.previewBubble(nil)
        timeline.value = shown
    }

    fileprivate func toggleBookmarks(onIndices shown: [Int]) {
        let existing = bookmarks.filter { shown.contains($0.section) }
        if existing.isEmpty {
            let index = shown.first ?? currentIndex
            let text = AnnotationFormat.excerpt(PDFTextRanges.clean(document.page(at: index)?.string ?? ""))
            let label = text.isEmpty ? pageName(index) : "\(pageName(index)): \(text)"
            AnnotationStore.shared.addBookmark(book: bookKey, section: index, progression: 0, label: label)
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

    /// K1: anteckningsboken för boken, med läsarens kapitel och sidnummer.
    @objc fileprivate func showNotebook() {
        guard presentedViewController == nil else { return }
        let notebook = NotebookViewController(scope: .book(book, chapter: { [weak self] highlight in
            self?.chapterTitle(for: highlight.section) ?? ""
        }, page: { [weak self] highlight in
            self?.citationPage(for: highlight)
        }))
        notebook.onSelect = { [weak self] highlight in
            if highlight.id.hasPrefix(NotebookEntry.pageNotePrefix) {
                self?.hop(to: highlight.section)
            } else {
                self?.openAnnotation(.highlights, id: highlight.id)
            }
        }
        let navigation = UINavigationController(rootViewController: notebook)
        navigation.modalPresentationStyle = traitCollection.userInterfaceIdiom == .pad ? .formSheet : .pageSheet
        present(navigation, animated: true)
    }

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
            hop(to: bookmark.section)
        case .highlights:
            guard let highlight = AnnotationStore.shared.highlight(id: id) else { return }
            hop(to: highlight.section)
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
            self?.hop(to: hit.section)
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
        guard SelfTest.isActive, !selfTestStarted, !PhotoPagesSelfTest.running,
              SelfTest.bookName?.lowercased().hasSuffix(".pdf") == true else { return }
        selfTestStarted = true
        Task { @MainActor [weak self] in
            await self?.runSelfTest()
        }
    }

    fileprivate func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Edvin 8 nov: menyn täckte text. I PDF mäts hur mycket av sidbilden som menyraden och nederkanten täcker
    /// med menyn framme (sidans egen marginal är oftast vit, så siffran är ett tak för täckt text).
    fileprivate func selfTestChromeCoverage() {
        let wasHidden = chromeHidden
        setChromeHidden(false, animated: false)
        navigationController?.view.layoutIfNeeded()
        view.layoutIfNeeded()
        guard let bar = navigationController?.navigationBar,
              let page = visiblePages.first(where: { !$0.isBlank && $0.imageFrame != nil }),
              let local = page.imageFrame else {
            SelfTest.log("FEL: ingen menyrad eller sidbild för mätningen (U3)")
            return
        }
        let frame = page.view.convert(local, to: view)
        let barBottom = bar.convert(bar.bounds, to: view).maxY
        let bottomTop = bottomBar.convert(bottomBar.bounds, to: view).minY
        let top = max(barBottom - frame.minY, 0)
        let bottom = max(frame.maxY - bottomTop, 0)
        let share = { (value: CGFloat) in Int((value / max(frame.height, 1) * 100).rounded()) }
        SelfTest.log("Menyn över PDF-sidan (U3): sidbilden \(Int(frame.minY)) till \(Int(frame.maxY)), menyraden täcker "
                     + "\(Int(top)) punkter (\(share(top)) procent av sidhöjden), nederkanten \(Int(bottom)) punkter "
                     + "(\(share(bottom)) procent)")
        if wasHidden {
            setChromeHidden(true, animated: false)
        }
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
        if SelfTest.bookName == PhotoPagesSelfTest.bookName {
            await selfTestPhotoPages()
            SelfTest.finish()
            return
        }
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
        selfTestChromeCoverage()

        let drawsBefore = ReaderTimeline.trackDraws
        turnPage(forward: true)
        await pause(1.5)
        _ = await waitForImages()
        SelfTest.log("Efter en sida: \(bottomBar.pageButton.title(for: .normal) ?? "")")
        SelfTest.log("Tidslinjen (V2) när sidan vändes: \(ReaderTimeline.trackDraws == drawsBefore ? "bara markören flyttad" : "FEL, linjen ritades om"), "
                     + "linjen ritad \(ReaderTimeline.trackDraws) gånger hittills")
        // V1: sidor kvar, ett tryck växlar mellan kapitlet och boken (PDF:en har innehåll i testet).
        let remaining = bottomBar.infoButton.title(for: .normal) ?? "inget"
        toggleRemaining()
        SelfTest.log("Sidor kvar (V1): \(remaining), efter ett tryck \(bottomBar.infoButton.title(for: .normal) ?? "inget"), "
                     + "kapitel i innehållet \(chapterStarts.count)")
        toggleRemaining()

        // Ordet under en punkt, som när fingret börjar markera.
        guard let page = visiblePages.first(where: { !$0.isBlank }),
              let pdfPage = document.page(at: page.pageIndex),
              let frame = page.pageFrame,
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

        // O4: ett sparat ord får ett streck under sig, och ett tryck på strecket hittar ordet.
        UserWords.shared.save(word: "kunskap", lemma: "kunskap", language: .swedish,
                              sentence: "Kunskap kommer sällan av sig själv.", book: book.title, pageIndex: page.pageIndex,
                              bookID: book.id)
        for _ in 0..<40 where page.markRects(id: SavedWordMarks.idPrefix + "sv|kunskap").isEmpty {
            await pause(0.2)
        }
        let wordRect = page.markRects(id: SavedWordMarks.idPrefix + "sv|kunskap").first
        let wordHit = wordRect.map { markHit(at: view.convert(CGPoint(x: $0.midX, y: $0.midY), from: page.view))?.id }
        SelfTest.log("Dina ord i texten (O4): \(page.wordMarkCount) streck på sidan, former \(SavedWordMarks.shared.forms.count), "
                     + "tryck på kunskap hittar \((wordHit ?? nil) ?? "INGET")")
        SelfTest.saveScreen(view, name: "02c-ordstreck")

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
        await selfTestUndoBookmark()

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
                await selfTestHistory()
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
        await pause(0.4)
        // U2: Aa i PDF har bara bakgrunderna och Zooma sidan. Rutans egen vy sparas (glas i iOS 26).
        showAppearance()
        await pause(0.9)
        if let navigation = presentedViewController as? UINavigationController {
            SelfTest.saveScreen(navigation.view, name: "11-utseende")
            // Edvin 8 nov: sidan blev blank efter Aa. Bakgrunderna byts med rutan öppen, en i taget och
            // tätt efter varandra, och bläcket på sidan räknas efter varje byte.
            if let panel = navigation.viewControllers.first as? AppearanceViewController {
                let steps: [(String, [ReaderTheme])] = [("Mörkt", [.dark]), ("Vitt", [.white]), ("Sepia", [.sepia]),
                                                        ("Tätt efter varandra", [.dark, .paper, .white, .dark, .paper])]
                for (name, themes) in steps {
                    for option in themes {
                        panel.perform(.theme(option))
                        await pause(0.12)
                    }
                    await pause(0.6)
                    let shown = await waitForImages()
                    let ink = SelfTest.inkPercent(in: view, paper: theme.paperColor)
                    SelfTest.log("Aa med rutan öppen, \(name): \(shown ? "sidan klar" : "FEL, sidan kom inte"), "
                                 + "bläck \(String(format: "%.1f", ink)) %\(ink < 0.5 ? " FEL, BLANK" : "")")
                }
            }
        } else {
            SelfTest.log("FEL: utseenderutan öppnades inte")
        }
        dismiss(animated: false)
        await pause(0.3)
        setTheme(savedTheme)
        await pause(0.4)

        await selfTestStudy()
        await selfTestFoldWork()
        await selfTestResumeCard()

        let after = AnnotationStore.shared.totalCounts()
        SelfTest.log("Sparat nu: \(after.highlights) markeringar, \(after.notes) anteckningar, \(after.bookmarks) bokmärken")
        SelfTest.finish()
    }

    /// Våg 7 (Plugget): bokens sidnummer (K2), citatet (K3), anteckningsboken (K1), anteckningarna bredvid
    /// texten (K12), begreppen (K8) och läsloggen (K10).
    fileprivate func selfTestStudy() async {
        // K2: förskjutningen gör filens sida 1 till bokens sida 63, och Gå till sida 70 hittar filens sida 8.
        let originalInfo = BookInfoStore.shared.info(book: bookKey)
        SelfTest.log("Bokens sidnummer (K2) från början: \(pageNumbering.summary) Sidraden: \(pageText(for: [0]))")
        var info = originalInfo
        info.pageFirst = 63
        info.pageSpread = false
        applyBookPages(info)
        let typed = pageIndex(forTyped: "70").map { "filens sida \($0 + 1)" } ?? "ingen"
        SelfTest.log("Bokens sidnummer (K2) med 63: sidraden \(pageText(for: [0])), Gå till sida 70 ger \(typed) (ska vara filens sida 8), "
                     + "bokmärkets namn \(pageName(2))")
        info.pageSpread = true
        applyBookPages(info)
        SelfTest.log("Bokens sidnummer (K2) som uppslag: \(pageText(for: [1]))")
        applyBookPages(originalInfo)

        // K3: citatet för bokens första markering, i alla tre stilarna, och rutan.
        if let highlight = AnnotationStore.shared.highlights(book: bookKey).first {
            let source = CitationSources.source(for: book)
            for style in CitationStyle.allCases {
                SelfTest.log("Citat (K3) \(style.title): \(Citation.quote(highlight.text, style: style, source: source, page: citationPage(for: highlight)).prefix(160))")
            }
            // Som knappen Citat: utan inställt sidnummer får rutan förklaringen och knappen till Bokens sidnummer (D4-1).
            let page = citationPage(for: highlight)
            CitationViewController.present(book: book, text: highlight.text, page: page,
                                           pageHint: page == nil ? missingPageHint(for: highlight) : nil,
                                           onSetPages: { [weak self] in self?.showBookPages() }, from: self,
                                           sourceView: view, sourceRect: CGRect(x: view.bounds.midX, y: 120, width: 2, height: 2))
            await pause(0.9)
            if let navigation = presentedViewController as? UINavigationController {
                SelfTest.saveScreen(navigation.view, name: "12-citat")
            } else {
                SelfTest.log("FEL: citatrutan öppnades inte")
            }
            await dismissPresented()

            // K8: ett begrepp ur markeringen, och registret.
            let concept = ConceptStore.shared.add(book: bookKey, term: ConceptLogic.term(from: highlight.text),
                                                  definition: "Självtestets definition", highlight: highlight.id)
            showConcepts()
            await pause(0.9)
            if let navigation = presentedViewController as? UINavigationController,
               let list = navigation.viewControllers.first as? ConceptsViewController {
                SelfTest.log("Begrepp (K8): \(list.count) i registret, det nya heter \(concept.term)")
                SelfTest.saveScreen(navigation.view, name: "12d-begrepp")
            } else {
                SelfTest.log("FEL: begreppsregistret öppnades inte")
            }
            await dismissPresented()
        } else {
            SelfTest.log("FEL: ingen markering att citera (K3)")
        }

        // K12: panelen bredvid texten, en anteckning till sidan som syns.
        toggleSideNotes()
        await pause(0.5)
        if let panel = sideNotes {
            panel.typeForSelfTest("Självtest: en fråga till sidan")
            let before = PageNoteStore.shared.note(book: bookKey, section: panel.shownSection)
            await pause(1.5)
            let saved = PageNoteStore.shared.note(book: bookKey, section: panel.shownSection)
            SelfTest.log("Anteckningar bredvid texten (K12): sidan \(panel.shownSection + 1), före fördröjningen \"\(before)\", "
                         + "sparat medan man skriver (D4-3) \"\(saved)\", sparningar \(panel.savesWhileTyping)")
            SelfTest.saveScreen(view, name: "12c-bredvid")
        } else {
            SelfTest.log("FEL: panelen Anteckningar bredvid texten öppnades inte")
        }
        toggleSideNotes()
        await pause(0.4)

        // K1: anteckningsboken med markeringarna och anteckningen bredvid texten.
        showNotebook()
        await pause(1.0)
        if let navigation = presentedViewController as? UINavigationController,
           let notebook = navigation.viewControllers.first as? NotebookViewController {
            SelfTest.log("Anteckningsbok (K1): \(notebook.visibleCount) rader, färgerna \(HighlightColorNames.all().values.sorted().joined(separator: ", "))")
            SelfTest.saveScreen(navigation.view, name: "12b-anteckningsbok")
        } else {
            SelfTest.log("FEL: anteckningsboken öppnades inte")
        }
        await dismissPresented()

        // K10: läsloggen sparas och de lästa delarna ritas på tidslinjen.
        ReadingLog.shared.flush()
        let today = ReadingWeek.dayKey(Date())
        let day = ReadingLog.shared.days(from: today)[today]
        updateReadRanges()
        SelfTest.log("Läsloggen (K10): i dag \(day.map { "\(Int($0.seconds)) s och \($0.pages) sidor" } ?? "inget"), "
                     + "\(bottomBar.slider.readRanges.count) lästa sträckor på tidslinjen")
        SelfTest.saveScreen(view, name: "12e-tidslinje")
    }

    /// V4: hoppen sparar platsen man lämnade, Tillbaka tar dig dit och ett långt tryck visar de senaste.
    fileprivate func selfTestHistory() async {
        dismiss(animated: false)
        await pause(0.3)
        let before = currentIndex
        hop(to: renderer.pageCount - 1)
        _ = await waitForImages()
        hop(to: 3)
        _ = await waitForImages()
        SelfTest.log("Tillbaka (V4): \(backStack.isShowing ? "syns" : "FEL, syns inte"), knappen visar "
                     + "\(backStack.control.title ?? "inget"), senaste platser \(backStack.recentLabels.joined(separator: ", ")), "
                     + "listan i knappen har \(backStack.control.backButton.menu?.children.count ?? 0) rader")
        SelfTest.saveScreen(view, name: "06b-tillbaka")
        backStack.goBack()
        _ = await waitForImages()
        let expected = renderer.pageCount - 1
        SelfTest.log("Efter Tillbaka: sidan \(currentIndex + 1) (ska vara \(expected + 1)), "
                     + "Tillbaka \(backStack.isShowing ? "FEL, syns" : "dold"), kvar i historiken \(backStack.recentLabels.count)")
        backStack.goBack()
        _ = await waitForImages()
        SelfTest.log("Två steg tillbaka: sidan \(currentIndex + 1) (ska vara \(before + 1))")
        await selfTestThumbnails()
    }

    /// V3: miniatyrerna ritas bara för synliga celler, ett tryck hoppar och Tillbaka ligger kvar när man bläddrar.
    fileprivate func selfTestThumbnails() async {
        let start = currentIndex
        let memoryBefore = MemoryUsage.megabytes
        showThumbnails()
        guard let navigation = presentedViewController as? UINavigationController,
              let grid = navigation.viewControllers.first as? PDFThumbnailsViewController else {
            SelfTest.log("FEL: miniatyrerna öppnades inte")
            return
        }
        for _ in 0..<100 where grid.fullAfterMilliseconds == nil {
            await pause(0.1)
        }
        let state = grid.visibleState
        SelfTest.log("Miniatyrer (V3): \(state.visible) celler syns, \(state.withImage) med bild, \(grid.drawn) ritade av \(renderer.pageCount) sidor, "
                     + "alla synliga efter \(grid.fullAfterMilliseconds.map { "\($0) ms" } ?? "FEL, blev inte klart"), minnet "
                     + String(format: "%.0f till %.0f MB", memoryBefore, MemoryUsage.megabytes))
        SelfTest.saveScreen(navigation.view, name: "06c-miniatyrer")
        let target = renderer.pageCount - 2
        grid.onSelect?(target)
        await pause(0.8)
        _ = await waitForImages()
        SelfTest.log("Efter tryck på en miniatyr: sidan \(currentIndex + 1) (ska vara \(target + 1)), Tillbaka visar "
                     + "\(backStack.isShowing ? backStack.control.title ?? "inget" : "FEL, ingen knapp")")
        for _ in 0..<3 {
            turnPage(forward: false)
            await pause(0.9)
            backStack.pageTurned()
        }
        SelfTest.log("Efter tre vikningar: Tillbaka \(backStack.isShowing ? "ligger kvar" : "FEL, försvann")")
        SelfTest.saveScreen(view, name: "06d-tillbaka-miniatyr")
        backStack.goBack()
        _ = await waitForImages()
        SelfTest.log("Tillbaka från miniatyren: sidan \(currentIndex + 1) (ska vara \(start + 1))")
        await selfTestNote()
    }

    /// V6: kortet Här var du med kapitlet och de tre senaste markeringarna, och ett tryck stänger det.
    fileprivate func selfTestResumeCard() async {
        SelfTest.log("Här var du (V6): boken lästes senast \(lastReadDate.map { "\($0)" } ?? "aldrig"), kortet skulle "
                     + (ReaderResumeCard.shouldShow(lastRead: lastReadDate) ? "visas" : "inte visas")
                     + ", efter två dygn \(ReaderResumeCard.shouldShow(lastRead: Date().addingTimeInterval(-2 * 86_400)) ? "visas det" : "FEL, visas det inte")")
        let card = showResumeCard(lastRead: Date().addingTimeInterval(-3 * 86_400))
        await pause(0.6)
        SelfTest.log("Kortet: \(card.summary)")
        SelfTest.saveScreen(view, name: "12-har-var-du")
        card.close()
        await pause(0.5)
        SelfTest.log("Efter ett tryck: kortet \(card.superview == nil ? "stängt" : "FEL, ligger kvar")")
    }

    /// V5: fotnotssiffran på sida 3 i testboken har en intern länk till noten nederst på sida 8.
    fileprivate func selfTestNote() async {
        jump(to: 2)
        _ = await waitForImages()
        for _ in 0..<40 where linksCache[2] == nil {
            await pause(0.1)
        }
        guard let link = linksCache[2]?.first, let page = visiblePages.first(where: { $0.pageIndex == 2 }),
              let shown = page.viewRect(forPageRect: link.rect) else {
            SelfTest.log("Fotnoten (V5): FEL, ingen intern länk på sida 3 (länkar: \(linksCache[2]?.count ?? -1))")
            return
        }
        let center = view.convert(CGPoint(x: shown.midX, y: shown.midY), from: page.view)
        SelfTest.log("Fotnoten (V5): länk på sida 3 med texten \"\(link.label)\" till sidan \(link.page + 1), "
                     + "not \(link.isNote ? "ja" : "FEL, nej"), trycket hittar länken \(linkHit(at: center) != nil ? "ja" : "FEL, nej")")
        lastNoteMilliseconds = nil
        openLink(link, on: page)
        for _ in 0..<40 where !(presentedViewController is NotePopoverViewController) {
            await pause(0.1)
        }
        if let note = presentedViewController as? NotePopoverViewController {
            await pause(0.5)
            SelfTest.log("Fotnoten i rutan: \"\(note.noteText.prefix(80))\" efter \(lastNoteMilliseconds.map { "\($0)" } ?? "?") ms")
            SelfTest.saveScreen(note.view, name: "06e-fotnot")
            SelfTest.saveScreen(view.window ?? view, name: "06f-fotnot-sidan")
            dismiss(animated: false)
            await pause(0.3)
        } else {
            SelfTest.log("FEL: fotnoten visades inte i en ruta")
        }
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
        let pagePoint = page.pageFrame.flatMap { PDFPageGeometry.pagePoint(for: local, imageFrame: $0, page: pdfPage) }
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
