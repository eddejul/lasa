import UIKit
import WebKit

/// En sida i en EPUB eller textfil: kapitlet och sidan i kapitlet, båda från 0.
struct ReflowPage: Hashable {
    let chapter: Int
    let page: Int
}

/// En länk på en sida, med rutan i sidans koordinater.
struct ReflowLink {
    let rect: CGRect
    let url: URL
}

/// En färdig sidbild och länkarna på sidan.
struct ReflowSnapshot {
    let image: UIImage
    let links: [ReflowLink]
}

/// Ordet under fingret: ordet, texten före och efter i samma stycke, och ordets rutor i sidans koordinater.
struct ReflowWord {
    let word: String
    let before: String
    let after: String
    let rects: [CGRect]
}

/// Sidans storlek, marginaler och typografi. Ändras något av dem delas kapitlen om i sidor.
struct ReflowLayout: Equatable {
    let pageSize: CGSize
    let padding: UIEdgeInsets
    let typography: ReaderTypography

    var key: String {
        let size = "\(Int(pageSize.width.rounded()))x\(Int(pageSize.height.rounded()))"
        let margins = [padding.top, padding.left, padding.bottom, padding.right]
            .map { String(Int($0.rounded())) }
            .joined(separator: ",")
        return "\(size)-\(margins)-\(typography.key)"
    }
}

/// Gör sidbilder av kapitlen i EPUB och textfiler.
///
/// Högst tre kapitel är laddade samtidigt, vart och ett i en egen webbvy som ligger dold bakom sidorna:
/// kapitlet man läser, nästa och förra. En webbvy har samma storlek som en sida och visar en kolumn i taget.
/// En sidbild tas genom att flytta kapitlet till rätt kolumn och ta en ögonblicksbild (`takeSnapshot`).
/// Själva ritandet sker i webbvyns egen process, inte på huvudtråden. Högst fem bilder sparas.
@MainActor
final class ReflowRenderer {

    static let maxImages = 5
    static let maxViews = 3
    /// Ett kapitel som inte gått att ladda eller mäta så här många gånger ges upp (visas som en tom sida).
    private static let maxFailures = 3

    let book: ReflowableBook
    /// Ett kapitel har delats i sidor, eller fått ett nytt sidantal.
    var onChapterMeasured: ((Int) -> Void)?

    /// Sant medan fingret viker en sida. Då görs bara bilder som syns just nu, ingen förritning.
    var isTurning = false {
        didSet {
            if !isTurning {
                pump()
            }
        }
    }

    private(set) var failures = 0
    /// När den första sidbilden blev klar, för att kunna visa hur lång tid det tar att öppna en bok.
    private(set) var firstSnapshotAt: CFTimeInterval?

    private let host: UIView
    private var views: [ChapterView] = []
    private var layout: ReflowLayout?
    private var theme: ReaderTheme
    private var css = ""
    private var styleKey = ""
    private var counts: [Int: Int] = [:]
    private var countStore: PageCountStore
    private var failuresByChapter: [Int: Int] = [:]
    private var images: [ReflowPage: ReflowSnapshot] = [:]
    private var recentlyUsed: [ReflowPage] = []
    private var workingSet: [ReflowPage] = []
    private var waiting: [ReflowPage: [(ReflowSnapshot) -> Void]] = [:]
    private var waitingOrder: [ReflowPage] = []
    private var queries: [Query] = []
    private var center = 0
    private var jobs: [ObjectIdentifier: Int] = [:]
    private var nextJob = 0
    private var snapshotTimes: [Double] = []
    private var scriptTimes: [Double] = []
    private var measureTimes: [Double] = []

    /// En fråga till ett kapitel (ord under fingret, var ett ankare ligger) som väntar på att kapitlet är klart.
    private final class Query {
        let chapter: Int
        let body: String
        let arguments: [String: Any]
        let created = CACurrentMediaTime()
        private var deliver: ((Any?) -> Void)?

        init(chapter: Int, body: String, arguments: [String: Any], deliver: @escaping (Any?) -> Void) {
            self.chapter = chapter
            self.body = body
            self.arguments = arguments
            self.deliver = deliver
        }

        /// Svaret lämnas bara en gång, även om frågan både hinner svara och avbrytas.
        func finish(_ value: Any?) {
            let deliver = self.deliver
            self.deliver = nil
            deliver?(value)
        }
    }

    init(book: ReflowableBook, host: UIView, theme: ReaderTheme) {
        self.book = book
        self.host = host
        self.theme = theme
        self.countStore = PageCountStore(identifier: book.identifier)
    }

    // MARK: Inställningar

    /// Ny sidstorlek, typografi eller nytt tema. Bilderna kastas. Ändras layouten mäts kapitlen om.
    func configure(layout: ReflowLayout, theme: ReaderTheme) {
        let layoutChanged = layout != self.layout
        let newStyleKey = layout.key + "|" + theme.rawValue
        guard layoutChanged || newStyleKey != styleKey else { return }

        self.layout = layout
        self.theme = theme
        css = ReflowStyle.css(layout: layout, theme: theme)
        styleKey = newStyleKey
        images.removeAll()
        recentlyUsed.removeAll()

        if layoutChanged {
            counts.removeAll()
            host.frame = CGRect(origin: .zero, size: layout.pageSize)
            for view in views {
                view.webView.frame = host.bounds
                view.layoutKey = ""
            }
        }
        for view in views {
            view.styleKey = ""
            view.webView.backgroundColor = theme.paperColor
        }
        pump()
    }

    /// Kapitlet man läser. Det och grannkapitlen hålls laddade.
    func setWindow(center chapter: Int) {
        center = min(max(chapter, 0), book.chapters.count - 1)
        pump()
    }

    // MARK: Sidantal

    /// Antalet sidor i ett kapitel med den nuvarande layouten, när kapitlet har mätts.
    func pageCount(of chapter: Int) -> Int? {
        counts[chapter]
    }

    /// Sidantalen för alla kapitel, om alla är kända för den här layouten (mätta nu eller vid ett tidigare tillfälle).
    func allPageCounts() -> [Int]? {
        guard let key = layout?.key else { return nil }
        var result: [Int] = []
        for chapter in book.chapters.indices {
            guard let count = counts[chapter] ?? countStore.count(chapter: chapter, key: key) else { return nil }
            result.append(count)
        }
        return result
    }

    // MARK: Bilder

    /// Bilden om den redan finns. Gör aldrig något arbete själv.
    func cachedSnapshot(for page: ReflowPage) -> ReflowSnapshot? {
        guard let snapshot = images[page] else { return nil }
        touch(page)
        return snapshot
    }

    /// Bilden för en sida som visas. Finns den kommer den direkt, annars när den är klar. Går före förritning.
    func requestImage(for page: ReflowPage, completion: @escaping (ReflowSnapshot) -> Void) {
        if let snapshot = cachedSnapshot(for: page) {
            completion(snapshot)
            return
        }
        waiting[page, default: []].append(completion)
        if !waitingOrder.contains(page) {
            waitingOrder.append(page)
        }
        pump()
    }

    /// Sidorna som ska finnas färdiga, viktigast först. Väntande sidor som inte längre behövs släpps.
    func keep(_ pages: [ReflowPage]) {
        var seen = Set<ReflowPage>()
        workingSet = Array(pages.filter { seen.insert($0).inserted }.prefix(Self.maxImages))
        let wanted = Set(workingSet)
        for page in waitingOrder where !wanted.contains(page) {
            waiting[page] = nil
        }
        waitingOrder.removeAll { !wanted.contains($0) }
        trim()
        pump()
    }

    /// Lite minne kvar: behåll bara sidorna som syns.
    func releaseMemory() {
        let keep = Set(workingSet.prefix(2))
        for page in Array(images.keys) where !keep.contains(page) {
            images[page] = nil
        }
        recentlyUsed.removeAll { !keep.contains($0) }
    }

    // MARK: Frågor

    /// Ordet närmast en punkt på en sida (i sidans koordinater), eller nil om inget ord ligger inom `tolerance` punkter.
    func word(at point: CGPoint,
              on page: ReflowPage,
              tolerance: CGFloat = 8,
              completion: @escaping (ReflowWord?) -> Void) {
        let arguments: [String: Any] = ["index": page.page, "x": Double(point.x), "y": Double(point.y),
                                        "tolerance": Double(tolerance)]
        let query = Query(chapter: page.chapter,
                          body: "return lasa.wordAt(index, x, y, tolerance);",
                          arguments: arguments) { value in
            completion(ReflowValues.word(from: value))
        }
        queries.append(query)
        pump()
    }

    /// Sidan i kapitlet där ett ankare (till exempel en fotnot) står.
    func page(ofFragment fragment: String, in chapter: Int, completion: @escaping (Int?) -> Void) {
        let query = Query(chapter: chapter,
                          body: "return lasa.pageOf(id);",
                          arguments: ["id": fragment]) { value in
            let page = ReflowValues.number(value).map { Int($0) }
            completion(page.flatMap { $0 >= 0 ? $0 : nil })
        }
        queries.append(query)
        pump()
    }

    // MARK: Mätvärden

    var statsSummary: String {
        func median(_ values: [Double]) -> Int {
            values.isEmpty ? 0 : Int(values.sorted()[values.count / 2].rounded())
        }
        let loaded = views.filter { $0.state == .loaded }.count
        return "Sidbild \(median(snapshotTimes)) ms, varav \(median(scriptTimes)) ms att flytta till sidan, "
            + "kapitel \(median(measureTimes)) ms (mittvärden för \(snapshotTimes.count) bilder), "
            + "\(failures) fel, \(loaded) av \(Self.maxViews) webbvyer laddade, "
            + "appen använder \(Int(MemoryUsage.megabytes.rounded())) MB."
    }

    // MARK: Arbetet

    private var desiredChapters: [Int] {
        [center, center + 1, center - 1].filter { $0 >= 0 && $0 < book.chapters.count }
    }

    /// Startar det som kan startas: laddning, mätning, frågor och sidbilder. Anropas efter varje händelse.
    private func pump() {
        guard let layout = layout else { return }
        dropOldQueries()

        // Ett kapitel laddas åt gången, det man läser först.
        if !views.contains(where: { $0.state == .loading }),
           let chapter = desiredChapters.first(where: { activeView(for: $0) == nil && !isBroken($0) }),
           let view = freeView() {
            view.load(chapter: chapter, url: book.chapters[chapter].url, readAccess: book.rootDirectory)
        }

        // Nyladdade kapitel delas i sidor, och kapitel med gammal stil får den nya.
        for view in views where view.state == .loaded && !view.busy {
            if view.layoutKey != layout.key {
                setUp(view)
            } else if view.styleKey != styleKey {
                restyle(view)
            }
        }

        // Ord och ankare som användaren väntar på.
        var remaining: [Query] = []
        for query in queries {
            if let view = readyView(for: query.chapter), !view.busy {
                run(query, on: view)
            } else {
                remaining.append(query)
            }
        }
        queries = remaining

        // Sidbilder: först de som syns, sedan förritning.
        let wanted = waitingOrder + (isTurning ? [] : workingSet)
        for page in wanted where images[page] == nil {
            guard let view = readyView(for: page.chapter), !view.busy, view.styleKey == styleKey else { continue }
            guard page.page >= 0, page.page < view.pageCount else {
                waiting[page] = nil
                waitingOrder.removeAll { $0 == page }
                continue
            }
            snapshot(page, on: view)
        }
    }

    private func activeView(for chapter: Int) -> ChapterView? {
        views.first { $0.chapter == chapter && ($0.state == .loading || $0.state == .loaded) }
    }

    private func readyView(for chapter: Int) -> ChapterView? {
        guard let key = layout?.key else { return nil }
        return views.first { $0.chapter == chapter && $0.state == .loaded && $0.layoutKey == key }
    }

    private func isBroken(_ chapter: Int) -> Bool {
        (failuresByChapter[chapter] ?? 0) >= Self.maxFailures
    }

    /// En webbvy som kan ta ett nytt kapitel: en tom, en som misslyckats, eller den med kapitlet längst bort.
    private func freeView() -> ChapterView? {
        let desired = Set(desiredChapters)
        let candidates = views.filter { view in
            guard !view.busy, view.state != .loading else { return false }
            return view.state != .loaded || !desired.contains(view.chapter)
        }
        if let best = candidates.max(by: { distance(of: $0) < distance(of: $1) }) {
            return best
        }
        guard views.count < Self.maxViews else { return nil }
        let view = ChapterView(frame: host.bounds)
        view.webView.backgroundColor = theme.paperColor
        view.onLoaded = { [weak self] view, success in
            guard let self = self else { return }
            if !success {
                self.fail(view)
            }
            self.pump()
        }
        host.addSubview(view.webView)
        views.append(view)
        return view
    }

    private func distance(of view: ChapterView) -> Int {
        view.state == .loaded ? abs(view.chapter - center) : Int.max
    }

    private func fail(_ view: ChapterView) {
        failures += 1
        let chapter = view.chapter
        view.markFailed()
        guard chapter >= 0 else { return }
        failuresByChapter[chapter, default: 0] += 1
        if isBroken(chapter), counts[chapter] == nil {
            // Läsaren får en tom sida i stället för att vänta för evigt.
            counts[chapter] = 1
            onChapterMeasured?(chapter)
        }
    }

    private func dropOldQueries() {
        let now = CACurrentMediaTime()
        let old = queries.filter { now - $0.created > 10 }
        guard !old.isEmpty else { return }
        queries.removeAll { now - $0.created > 10 }
        old.forEach { $0.finish(nil) }
    }

    // MARK: Jobb i en webbvy

    /// Ett jobb i taget per webbvy. Svarar den inte inom åtta sekunder laddas kapitlet om.
    private func beginJob(on view: ChapterView, onTimeout: (() -> Void)? = nil) -> Int {
        nextJob += 1
        let job = nextJob
        jobs[ObjectIdentifier(view)] = job
        view.busy = true
        Task { @MainActor [weak self, weak view] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self = self, let view = view, self.jobs[ObjectIdentifier(view)] == job else { return }
            self.jobs[ObjectIdentifier(view)] = nil
            view.busy = false
            self.fail(view)
            onTimeout?()
            self.pump()
        }
        return job
    }

    private func isCurrent(_ job: Int, on view: ChapterView) -> Bool {
        jobs[ObjectIdentifier(view)] == job
    }

    private func endJob(_ job: Int, on view: ChapterView) -> Bool {
        guard jobs[ObjectIdentifier(view)] == job else { return false }
        jobs[ObjectIdentifier(view)] = nil
        view.busy = false
        return true
    }

    /// Lägger in skriptet, sätter stilen och räknar kapitlets sidor.
    private func setUp(_ view: ChapterView) {
        guard let layout = layout else { return }
        let job = beginJob(on: view)
        let chapter = view.chapter
        let key = layout.key
        let style = styleKey
        let started = CACurrentMediaTime()
        let arguments: [String: Any] = [
            "css": css,
            "scale": layout.typography.scale,
            "w": Double(layout.pageSize.width),
            "h": Double(layout.pageSize.height),
        ]
        view.call(ReflowStyle.script) { [weak self, weak view] _ in
            guard let self = self, let view = view, self.isCurrent(job, on: view) else { return }
            view.call("return await lasa.setup(css, scale, w, h);", arguments) { [weak self, weak view] value in
                guard let self = self, let view = view, self.endJob(job, on: view) else { return }
                guard view.chapter == chapter, key == self.layout?.key else {
                    self.pump()
                    return
                }
                if let count = ReflowValues.pageCount(from: value) {
                    view.layoutKey = key
                    view.styleKey = style
                    view.pageCount = count
                    self.counts[chapter] = count
                    self.countStore.set(count, chapter: chapter, key: key)
                    self.measureTimes = Array((self.measureTimes + [(CACurrentMediaTime() - started) * 1000]).suffix(50))
                    self.onChapterMeasured?(chapter)
                } else {
                    self.fail(view)
                }
                self.pump()
            }
        }
    }

    /// Nytt tema i ett kapitel som redan är delat i sidor. Sidantalet ska inte ändras, men kontrolleras.
    private func restyle(_ view: ChapterView) {
        guard let layout = layout else { return }
        let job = beginJob(on: view)
        let chapter = view.chapter
        let key = layout.key
        let style = styleKey
        let arguments: [String: Any] = ["css": css, "scale": layout.typography.scale]
        view.call("return await lasa.restyle(css, scale);", arguments) { [weak self, weak view] value in
            guard let self = self, let view = view, self.endJob(job, on: view) else { return }
            guard view.chapter == chapter, view.layoutKey == key else {
                self.pump()
                return
            }
            if let count = ReflowValues.pageCount(from: value) {
                view.styleKey = style
                if count != view.pageCount {
                    view.pageCount = count
                    self.counts[chapter] = count
                    self.countStore.set(count, chapter: chapter, key: key)
                    self.onChapterMeasured?(chapter)
                }
            } else {
                self.fail(view)
            }
            self.pump()
        }
    }

    private func run(_ query: Query, on view: ChapterView) {
        let job = beginJob(on: view) {
            query.finish(nil)
        }
        view.call(query.body, query.arguments) { [weak self, weak view] value in
            query.finish(value)
            guard let self = self, let view = view, self.endJob(job, on: view) else { return }
            self.pump()
        }
    }

    private func snapshot(_ page: ReflowPage, on view: ChapterView) {
        let job = beginJob(on: view)
        let style = styleKey
        let started = CACurrentMediaTime()
        view.call("return await lasa.showPage(index);", ["index": page.page]) { [weak self, weak view] value in
            guard let self = self, let view = view, self.isCurrent(job, on: view) else { return }
            self.scriptTimes = Array((self.scriptTimes + [(CACurrentMediaTime() - started) * 1000]).suffix(50))
            let links = ReflowValues.links(from: value)
            let configuration = WKSnapshotConfiguration()
            configuration.afterScreenUpdates = true
            view.webView.takeSnapshot(with: configuration) { [weak self, weak view] image, _ in
                guard let self = self, let view = view, self.endJob(job, on: view) else { return }
                if let image = image, style == self.styleKey, view.chapter == page.chapter, view.styleKey == style {
                    self.snapshotTimes = Array((self.snapshotTimes + [(CACurrentMediaTime() - started) * 1000]).suffix(50))
                    self.store(ReflowSnapshot(image: image, links: links), for: page)
                } else if image == nil {
                    self.failures += 1
                }
                self.pump()
            }
        }
    }

    // MARK: Bildminnet

    private func store(_ snapshot: ReflowSnapshot, for page: ReflowPage) {
        if firstSnapshotAt == nil {
            firstSnapshotAt = CACurrentMediaTime()
        }
        let callbacks = waiting.removeValue(forKey: page) ?? []
        waitingOrder.removeAll { $0 == page }
        if !callbacks.isEmpty || workingSet.contains(page) {
            images[page] = snapshot
            touch(page)
            trim()
        }
        callbacks.forEach { $0(snapshot) }
    }

    private func touch(_ page: ReflowPage) {
        recentlyUsed.removeAll { $0 == page }
        recentlyUsed.append(page)
    }

    /// Släpper bilder tills högst fem finns kvar. Först sådant som inte ska behållas, äldst först.
    private func trim() {
        while images.count > Self.maxImages {
            let victim = recentlyUsed.first { !workingSet.contains($0) } ?? recentlyUsed.first
            guard let page = victim ?? images.keys.first else { break }
            images[page] = nil
            recentlyUsed.removeAll { $0 == page }
        }
    }
}

/// Tolkar svaren från skripten i webbvyn.
enum ReflowValues {

    static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    static func pageCount(from value: Any?) -> Int? {
        guard let info = value as? [String: Any], let count = number(info["count"]), count >= 1 else { return nil }
        return Int(count.rounded())
    }

    static func rect(from value: Any?) -> CGRect? {
        guard let info = value as? [String: Any],
              let x = number(info["x"]), let y = number(info["y"]),
              let width = number(info["w"]), let height = number(info["h"]) else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func links(from value: Any?) -> [ReflowLink] {
        guard let info = value as? [String: Any], let list = info["links"] as? [Any] else { return [] }
        return list.compactMap { item in
            guard let entry = item as? [String: Any],
                  let href = entry["href"] as? String,
                  let url = URL(string: href),
                  let rect = rect(from: entry) else {
                return nil
            }
            return ReflowLink(rect: rect, url: url)
        }
    }

    static func word(from value: Any?) -> ReflowWord? {
        guard let info = value as? [String: Any], let word = info["word"] as? String, !word.isEmpty else { return nil }
        let rects = (info["rects"] as? [Any] ?? []).compactMap { rect(from: $0) }
        return ReflowWord(word: word,
                          before: info["before"] as? String ?? "",
                          after: info["after"] as? String ?? "",
                          rects: rects)
    }

    /// Meningen runt ordet, från texten före och efter i samma stycke, och var ordet står i den (UTF-16).
    static func sentence(before: String, word: String, after: String) -> (String, NSRange) {
        let ends: Set<Character> = [".", "!", "?", "…"]
        let head = Array(before)
        var start = 0
        var k = head.count - 2
        while k >= 0 {
            if ends.contains(head[k]), head[k + 1] == " " {
                start = k + 2
                break
            }
            k -= 1
        }
        let lead = String(String(head[start...]).drop { $0 == " " })

        let tail = Array(after)
        var end = tail.count
        var index = 0
        while index < tail.count {
            if ends.contains(tail[index]), index + 1 == tail.count || tail[index + 1] == " " {
                end = index + 1
                break
            }
            index += 1
        }
        var sentence = lead + word + String(tail[..<end])
        while sentence.last == " " {
            sentence.removeLast()
        }
        let range = NSRange(location: (lead as NSString).length, length: (word as NSString).length)
        return (sentence, range)
    }
}

/// En webbvy med ett kapitel. Ligger dold bakom sidorna och tar inga tryck.
@MainActor
final class ChapterView: NSObject, WKNavigationDelegate {

    enum State {
        case idle, loading, loaded, failed
    }

    let webView: WKWebView
    private(set) var chapter = -1
    private(set) var state = State.idle
    /// Layouten som sidantalet mättes för, och layout plus tema som stilen i kapitlet gäller.
    var layoutKey = ""
    var styleKey = ""
    var pageCount = 0
    /// Ett jobb körs i webbvyn. Renderaren startar bara ett åt gången.
    var busy = false
    var onLoaded: ((ChapterView, Bool) -> Void)?
    private var navigation: WKNavigation?

    init(frame: CGRect) {
        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = false
        configuration.allowsInlineMediaPlayback = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.dataDetectorTypes = []
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        webView = WKWebView(frame: frame, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.isUserInteractionEnabled = false
        webView.isOpaque = false
        webView.allowsLinkPreview = false
        webView.accessibilityElementsHidden = true
        let scrollView = webView.scrollView
        scrollView.isScrollEnabled = false
        scrollView.bounces = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
    }

    func load(chapter: Int, url: URL, readAccess: URL) {
        self.chapter = chapter
        state = .loading
        layoutKey = ""
        styleKey = ""
        pageCount = 0
        navigation = webView.loadFileURL(url, allowingReadAccessTo: readAccess)
    }

    func markFailed() {
        state = .failed
        layoutKey = ""
        styleKey = ""
        busy = false
        webView.stopLoading()
    }

    /// Kör en funktionskropp i läsarens egen JavaScript-värld. Svaret är nil om något gick fel.
    func call(_ body: String, _ arguments: [String: Any] = [:], completion: @escaping (Any?) -> Void) {
        webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .defaultClient) { result in
            switch result {
            case .success(let value):
                completion(value)
            case .failure:
                completion(nil)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === self.navigation, state == .loading else { return }
        state = .loaded
        onLoaded?(self, true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard navigation === self.navigation, state == .loading else { return }
        onLoaded?(self, false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard navigation === self.navigation, state == .loading else { return }
        onLoaded?(self, false)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard state == .loading || state == .loaded else { return }
        onLoaded?(self, false)
    }
}
