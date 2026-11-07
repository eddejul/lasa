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
    static let wordPressDuration: TimeInterval = 0.35

    private enum Mode: Equatable {
        case single, spread
    }

    private let book: Book
    /// Läsarens dokument: innehåll, sidnummer och zoom. Renderaren har ett eget.
    private let document: PDFDocument
    private let renderer: PDFPageRenderer

    private var pageController: UIPageViewController?
    private var mode: Mode = .single
    private var theme = ReaderTheme.current

    /// Sidan man läser. I ett uppslag en av de två sidorna som syns.
    private var currentIndex: Int
    private var chromeHidden = false

    private let bottomBar = ReaderBottomBar()
    private var chromeTap: UITapGestureRecognizer?
    private var zoomTap: UITapGestureRecognizer?
    private var wordPress: UILongPressGestureRecognizer?
    private var pressedWord: PressedWord?
    private weak var wordBubble: PaddedLabel?
    private weak var toastLabel: UILabel?
    private var contentsItem: UIBarButtonItem?
    private var themeItem: UIBarButtonItem?

    private var lastLayoutSize: CGSize = .zero
    private var seenTopInset: CGFloat = 0
    private var contentInsets: UIEdgeInsets = .zero

    init?(book: Book) {
        guard let document = PDFDocument(url: book.url),
              !document.isLocked,
              document.pageCount > 0,
              let renderer = PDFPageRenderer(url: book.url, pageCount: document.pageCount) else {
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
        setUpNavigationBar()
        setUpBottomBar()
        setUpTaps()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyThemeToChrome()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard isMovingFromParent else { return }
        if chromeHidden {
            navigationController?.setNavigationBarHidden(false, animated: animated)
        }
        navigationController?.overrideUserInterfaceStyle = .unspecified
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateLayoutIfNeeded()
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
        return PDFPageViewController(pageIndex: index,
                                     side: side,
                                     renderer: renderer,
                                     paperColor: theme.paperColor,
                                     contentInsets: contentInsets)
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
        keepNeighbours()
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

        let zoom = UIBarButtonItem(image: UIImage(systemName: "plus.magnifyingglass"),
                                   style: .plain,
                                   target: self,
                                   action: #selector(zoomCurrentPage))
        zoom.accessibilityLabel = "Zooma sidan"

        let themeButton = UIBarButtonItem(title: nil,
                                          image: UIImage(systemName: "circle.lefthalf.fill"),
                                          primaryAction: nil,
                                          menu: themeMenu())
        themeButton.accessibilityLabel = "Bakgrund"

        navigationItem.rightBarButtonItems = [themeButton, zoom, contents]
        contentsItem = contents
        themeItem = themeButton
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

        let press = UILongPressGestureRecognizer(target: self, action: #selector(handleWordPress(_:)))
        press.minimumPressDuration = Self.wordPressDuration
        press.delegate = self
        view.addGestureRecognizer(press)

        zoomTap = zoom
        chromeTap = chrome
        wordPress = press
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
        let indices = visibleIndices.isEmpty ? [currentIndex] : visibleIndices
        bottomBar.pageButton.setTitle(pageText(for: indices), for: .normal)
        if !bottomBar.slider.isTracking {
            bottomBar.slider.value = Float(currentIndex)
        }
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
        let navigation = UINavigationController(rootViewController: outline)
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

    /// Hur långt från fingret ett ord får ligga och ändå väljas, i punkter.
    static let fingerTolerance: CGFloat = 22

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
            hideWordBubble()
            if let pressed = pressedWord {
                lookUp(pressed)
            }
        default:
            hideWordBubble()
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
        let tolerance = Self.fingerTolerance * PDFPageGeometry.pageUnitsPerPoint(imageFrame: imageFrame, page: pdfPage)
        guard let found = PDFWordFinder.word(on: pdfPage, at: pagePoint, tolerance: tolerance) else {
            if pressedWord != nil {
                moveWordBubble(to: point)
            }
            return false
        }
        if let current = pressedWord, current.page === page, current.found.location == found.location {
            pressedWord = PressedWord(found: current.found, page: page, rects: current.rects, finger: local)
            moveWordBubble(to: point)
            return true
        }
        let rects = found.pageRects.map { PDFPageGeometry.viewRect(for: $0, imageFrame: imageFrame, page: pdfPage) }
        pressedWord?.page.clearHighlight()
        page.showHighlight(rects)
        pressedWord = PressedWord(found: found, page: page, rects: rects, finger: local)
        Haptics.shared.wordTapped()
        showWordBubble(found.candidates.first ?? "", at: point)
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

        if let lookup = lookup, let lemma = lookup.entries.first?.lemma {
            UserWords.shared.save(word: lookup.word, lemma: lemma, language: lookup.language,
                                  sentence: found.sentence, book: book.title, pageIndex: pageIndex)
        }

        let context = WordPopupViewController.Context(sentence: found.sentence,
                                                      rangeInSentence: found.rangeInSentence,
                                                      book: book.title,
                                                      pageIndex: pageIndex,
                                                      triedWord: found.candidates.first ?? "")
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

    // MARK: Bubblan ovanför fingret

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

    /// Avbryter pappersvikningens och menyns tryck som redan har börjat.
    private func cancelPageGestures() {
        var recognizers = pageController?.gestureRecognizers ?? []
        recognizers += [chromeTap, zoomTap].compactMap { $0 }
        for recognizer in recognizers where recognizer.isEnabled {
            recognizer.isEnabled = false
            recognizer.isEnabled = true
        }
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

    // MARK: Bakgrund

    private func themeMenu() -> UIMenu {
        let actions = ReaderTheme.allCases.map { option in
            UIAction(title: option.title,
                     image: UIImage(systemName: option.symbolName),
                     state: option == theme ? .on : .off) { [weak self] _ in
                self?.setTheme(option)
            }
        }
        return UIMenu(title: "Bakgrund", children: actions)
    }

    private func setTheme(_ newTheme: ReaderTheme) {
        guard newTheme != theme else { return }
        theme = newTheme
        ReaderTheme.current = newTheme
        themeItem?.menu = themeMenu()
        view.backgroundColor = newTheme.paperColor
        applyThemeToChrome()
        renderer.configure(size: renderSize(for: view.bounds.size, mode: mode), scale: displayScale, theme: newTheme)
        refreshVisiblePages()
        keepNeighbours()
    }

    /// Menyraden och reglaget följer bakgrunden: mörka på mörkt papper, ljusa annars.
    private func applyThemeToChrome() {
        let style: UIUserInterfaceStyle = theme.isDark ? .dark : .light
        overrideUserInterfaceStyle = style
        navigationController?.overrideUserInterfaceStyle = style
        setNeedsStatusBarAppearanceUpdate()
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
    }

    func pageViewController(_ pageViewController: UIPageViewController,
                            didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController],
                            transitionCompleted completed: Bool) {
        guard completed, let index = visibleIndices.first else { return }
        currentIndex = index
        LibraryStore.shared.savePageIndex(currentIndex, for: book)
        updatePageLabel()
        Haptics.shared.pageTurned()
        setChromeHidden(true, animated: true)
        keepNeighbours()
    }
}

// MARK: Tryckzoner

extension PDFCurlReaderViewController: UIGestureRecognizerDelegate {

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Reglaget och sidnumret har egna tryck.
        if let touched = touch.view, touched.isDescendant(of: bottomBar) {
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
