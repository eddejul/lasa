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
    /// V5: en fotnotssiffra eller hänvisning, som visas i en ruta i stället för att boken hoppar.
    var isNote = false
}

/// En färdig sidbild och länkarna på sidan.
struct ReflowSnapshot {
    let image: UIImage
    let links: [ReflowLink]
    /// Markeringarnas rutor på sidan (fas 4).
    var marks: [ReflowMarkRect] = []
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
    /// Ett kapitel som inte gått att ladda eller mäta så här många gånger i följd ges upp. Läsaren visar
    /// då Kapitlet kunde inte visas med Försök igen (G2). Räknaren nollställs när kapitlet väl mätts.
    private static let maxFailures = 3
    /// Efter en minnesvarning hålls bara kapitlet man läser laddat så här länge (G2).
    private static let lowMemorySeconds: CFTimeInterval = 60

    let book: ReflowableBook
    /// Ett kapitel har delats i sidor, eller fått ett nytt sidantal.
    var onChapterMeasured: ((Int) -> Void)?
    /// Markeringarna i ett kapitel, som läggs in när kapitlet laddas (fas 4).
    var marksProvider: ((Int) -> [[String: Any]])?
    /// O4: sparade ord som får ett streck (form till värde, se `SavedWordMarks.forms`).
    var wordsProvider: (() -> [String: String])?

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
    /// Kapitel som gavs upp innan de mättes. De får sidantalet 1 så att läsaren kan visa felsidan.
    private var placeholders = Set<Int>()
    /// Kapitlens storlek i byte, för vaktens väntetid.
    private var chapterBytes: [Int: Int] = [:]
    /// Till och med den här tiden hålls bara kapitlet man läser laddat, efter en minnesvarning.
    private var lowMemoryUntil: CFTimeInterval = 0
    /// Självtestet: så många mätningar i följd av ett kapitel som ska misslyckas.
    private var simulatedFailures: [Int: Int] = [:]
    private var images: [ReflowPage: ReflowSnapshot] = [:]
    private var recentlyUsed: [ReflowPage] = []
    private var workingSet: [ReflowPage] = []
    private var waiting: [ReflowPage: [(ReflowSnapshot) -> Void]] = [:]
    /// Anropas för väntande sidor i ett kapitel som gavs upp.
    private var waitingFailures: [ReflowPage: [() -> Void]] = [:]
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
            // En ny layout är ett nytt försök för kapitel som gavs upp.
            placeholders.removeAll()
            failuresByChapter.removeAll()
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

    /// Sidantalet om kapitlet verkligen har mätts, inte bara getts upp med en ersättningssida.
    func measuredPageCount(of chapter: Int) -> Int? {
        placeholders.contains(chapter) ? nil : counts[chapter]
    }

    /// Kapitlet har inte gått att visas och väntar på Försök igen (G2).
    func isChapterBroken(_ chapter: Int) -> Bool {
        isBroken(chapter)
    }

    /// Försök igen med ett kapitel som gavs upp. Det får ett försök till, går det inte heller visas felet igen.
    func retry(chapter: Int) {
        guard isBroken(chapter) else { return }
        failuresByChapter[chapter] = Self.maxFailures - 1
        AppLog.shared.write("Kapitel \(chapter + 1): försöker igen")
        pump()
    }

    /// Självtestet: nästa `count` mätningar av kapitlet misslyckas. Är kapitlet redan laddat (som granne
    /// till ett kapitel man läst) glöms det, så att det verkligen laddas och mäts igen.
    func simulateFailures(_ count: Int, inChapter chapter: Int) {
        simulatedFailures[chapter] = count
        for view in views where view.chapter == chapter && view.state != .idle {
            jobs[ObjectIdentifier(view)] = nil
            jobAborts.removeValue(forKey: ObjectIdentifier(view))?()
            view.markFailed()
        }
        counts[chapter] = nil
        invalidate(chapter: chapter)
    }

    /// Självtestet: som när iOS stänger webbvyns process för ett laddat kapitel. Sant om kapitlet var laddat.
    @discardableResult
    func simulateTermination(ofChapter chapter: Int) -> Bool {
        guard let view = views.first(where: { $0.chapter == chapter && $0.state == .loaded }) else { return false }
        view.webViewWebContentProcessDidTerminate(view.webView)
        return true
    }

    /// Antalet fel som räknats för ett kapitel, till självtestet.
    func failureCount(inChapter chapter: Int) -> Int {
        failuresByChapter[chapter] ?? 0
    }

    /// Antalet laddade webbvyer, till självtestet och loggen.
    var loadedViewCount: Int {
        views.filter { $0.state == .loaded || $0.state == .loading }.count
    }

    /// Sidantalen för alla kapitel, om alla är kända för den här layouten (mätta nu eller vid ett tidigare tillfälle).
    func allPageCounts() -> [Int]? {
        guard let key = layout?.key else { return nil }
        var result: [Int] = []
        for chapter in book.chapters.indices {
            guard !placeholders.contains(chapter),
                  let count = counts[chapter] ?? countStore.count(chapter: chapter, key: key) else { return nil }
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
    /// Har kapitlet getts upp anropas `failure` i stället (G2), direkt eller när det händer.
    func requestImage(for page: ReflowPage,
                      completion: @escaping (ReflowSnapshot) -> Void,
                      failure: (() -> Void)? = nil) {
        if let snapshot = cachedSnapshot(for: page) {
            completion(snapshot)
            return
        }
        if isBroken(page.chapter) {
            failure?()
            return
        }
        waiting[page, default: []].append(completion)
        if let failure = failure {
            waitingFailures[page, default: []].append(failure)
        }
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
            waitingFailures[page] = nil
        }
        waitingOrder.removeAll { !wanted.contains($0) }
        trim()
        pump()
    }

    /// Lite minne kvar: behåll bara sidorna som syns, och stäng de dolda webbvyerna utom kapitlet man läser
    /// (G2). Under en minut därefter laddas bara det kapitlet, så att iOS inte behöver stänga webbvyerna själv.
    func releaseMemory() {
        let keep = Set(workingSet.prefix(2))
        for page in Array(images.keys) where !keep.contains(page) {
            images[page] = nil
        }
        recentlyUsed.removeAll { !keep.contains($0) }

        lowMemoryUntil = CACurrentMediaTime() + Self.lowMemorySeconds
        let closing = views.filter { $0.chapter != center && !$0.busy && $0.state != .loading }
        for view in closing {
            jobs[ObjectIdentifier(view)] = nil
            jobAborts[ObjectIdentifier(view)] = nil
            view.close()
            view.webView.removeFromSuperview()
        }
        views.removeAll { view in closing.contains { $0 === view } }
        AppLog.shared.write("Minnesvarning i läsaren: \(closing.count) dolda webbvyer stängdes, \(views.count) kvar")
    }

    private var isLowOnMemory: Bool {
        CACurrentMediaTime() < lowMemoryUntil
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
        let chapters = isLowOnMemory ? [center] : [center, center + 1, center - 1]
        return chapters.filter { $0 >= 0 && $0 < book.chapters.count }
    }

    private var viewLimit: Int {
        isLowOnMemory ? 1 : Self.maxViews
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

        // Sidor som väntar i ett kapitel som getts upp får veta det, så att läsaren kan visa felet.
        for page in waitingOrder where isBroken(page.chapter) {
            waiting[page] = nil
            let callbacks = waitingFailures.removeValue(forKey: page) ?? []
            callbacks.forEach { $0() }
        }
        waitingOrder.removeAll { isBroken($0.chapter) }

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
                waitingFailures[page] = nil
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
        guard views.count < viewLimit else { return nil }
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
        // Ett jobb som pågår i webbvyn räknas inte som ett fel till när dess svar kommer (en krasch är ett fel).
        jobs[ObjectIdentifier(view)] = nil
        jobAborts.removeValue(forKey: ObjectIdentifier(view))?()
        view.markFailed()
        guard chapter >= 0 else { return }
        failuresByChapter[chapter, default: 0] += 1
        AppLog.shared.write("Kapitel \(chapter + 1) kunde inte laddas eller mätas "
                            + "(fel \(failuresByChapter[chapter, default: 0]) i följd i kapitlet)")
        if isBroken(chapter) {
            AppLog.shared.write("Kapitel \(chapter + 1) ges upp tills man trycker på Försök igen")
            if counts[chapter] == nil {
                // Läsaren får en sida som säger att kapitlet inte kunde visas, i stället för att vänta för evigt.
                counts[chapter] = 1
                placeholders.insert(chapter)
                onChapterMeasured?(chapter)
            }
        }
    }

    /// Hur länge ett jobb i ett kapitel får ta innan kapitlet laddas om: 8 sekunder, plus 4 sekunder per
    /// 100 kB, högst 40 sekunder. Stora kapitel i Calibre-EPUB:er hinner annars inte mätas på A8X (G2).
    private func timeout(forChapter chapter: Int) -> Double {
        guard chapter >= 0, chapter < book.chapters.count else { return 8 }
        let bytes: Int
        if let known = chapterBytes[chapter] {
            bytes = known
        } else {
            let values = try? book.chapters[chapter].url.resourceValues(forKeys: [.fileSizeKey])
            bytes = values?.fileSize ?? 0
            chapterBytes[chapter] = bytes
        }
        return min(8 + 4 * Double(bytes) / 100_000, 40)
    }

    private func dropOldQueries() {
        let now = CACurrentMediaTime()
        let old = queries.filter { now - $0.created > 10 }
        guard !old.isEmpty else { return }
        queries.removeAll { now - $0.created > 10 }
        old.forEach { $0.finish(nil) }
    }

    // MARK: Jobb i en webbvy

    /// Ett jobb i taget per webbvy. Svarar den inte i tid (8 sekunder och mer för stora kapitel) laddas kapitlet om.
    private func beginJob(on view: ChapterView, onTimeout: (() -> Void)? = nil) -> Int {
        nextJob += 1
        let job = nextJob
        jobs[ObjectIdentifier(view)] = job
        jobAborts[ObjectIdentifier(view)] = onTimeout
        view.busy = true
        let seconds = timeout(forChapter: view.chapter)
        Task { @MainActor [weak self, weak view] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self = self, let view = view, self.jobs[ObjectIdentifier(view)] == job else { return }
            self.jobs[ObjectIdentifier(view)] = nil
            view.busy = false
            self.fail(view)
            self.pump()
        }
        return job
    }

    /// Det som ska göras om ett jobb avbryts, till exempel att en fråga får svaret nil.
    private var jobAborts: [ObjectIdentifier: () -> Void] = [:]

    private func isCurrent(_ job: Int, on view: ChapterView) -> Bool {
        jobs[ObjectIdentifier(view)] == job
    }

    private func endJob(_ job: Int, on view: ChapterView) -> Bool {
        guard jobs[ObjectIdentifier(view)] == job else { return false }
        jobs[ObjectIdentifier(view)] = nil
        jobAborts[ObjectIdentifier(view)] = nil
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
            "marks": marksProvider?(chapter) ?? [],
            "words": wordsProvider?() ?? [:],
        ]
        view.call(ReflowMarks.installScript, ["css": ReflowMarks.css]) { [weak self, weak view] _ in
            guard let self = self, let view = view, self.isCurrent(job, on: view) else { return }
            view.call(ReflowMarks.setupBody, arguments) { [weak self, weak view] value in
                guard let self = self, let view = view, self.endJob(job, on: view) else { return }
                guard view.chapter == chapter, key == self.layout?.key else {
                    self.pump()
                    return
                }
                if let left = self.simulatedFailures[chapter], left > 0 {
                    self.simulatedFailures[chapter] = left - 1
                    self.fail(view)
                    self.pump()
                    return
                }
                if let count = ReflowValues.pageCount(from: value) {
                    view.layoutKey = key
                    view.styleKey = style
                    view.pageCount = count
                    // Kapitlet gick att mäta: tidigare fel glöms (G2).
                    self.failuresByChapter[chapter] = nil
                    self.placeholders.remove(chapter)
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
            let marks = ReflowMarks.markRects(from: value)
            let configuration = WKSnapshotConfiguration()
            configuration.afterScreenUpdates = true
            view.webView.takeSnapshot(with: configuration) { [weak self, weak view] image, _ in
                guard let self = self, let view = view, self.endJob(job, on: view) else { return }
                if let image = image, style == self.styleKey, view.chapter == page.chapter, view.styleKey == style {
                    self.snapshotTimes = Array((self.snapshotTimes + [(CACurrentMediaTime() - started) * 1000]).suffix(50))
                    self.store(ReflowSnapshot(image: image, links: links, marks: marks), for: page)
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
        waitingFailures[page] = nil
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
            return ReflowLink(rect: rect, url: url, isNote: entry["note"] as? Bool ?? false)
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

    /// Stängs för gott vid en minnesvarning (G2). Webbvyns process släpps när vyn försvinner.
    func close() {
        onLoaded = nil
        navigation = nil
        state = .idle
        chapter = -1
        busy = false
        webView.stopLoading()
        webView.navigationDelegate = nil
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
        AppLog.shared.write("Webbvyns process för kapitel \(chapter + 1) stängdes av iOS")
        guard state == .loading || state == .loaded else { return }
        onLoaded?(self, false)
    }
}

// MARK: Markeringar och sökning (fas 4)

extension ReflowRenderer {

    /// Kör en funktionskropp i ett kapitels webbvy när kapitlet är klart, på samma sätt som orden under fingret.
    /// Svaret är nil om kapitlet inte hann bli klart inom tio sekunder.
    func evaluate(_ body: String, arguments: [String: Any], in chapter: Int, completion: @escaping (Any?) -> Void) {
        let query = Query(chapter: chapter, body: body, arguments: arguments, deliver: completion)
        queries.append(query)
        pump()
    }

    /// Kapitlen som ligger laddade i webbvyerna (O4: strecken läggs in i dem igen när orden ändras).
    var loadedChapters: [Int] {
        views.filter { $0.state == .loaded }.map(\.chapter)
    }

    /// Lägger in ett kapitels markeringar på nytt och kastar kapitlets sidbilder, så att de ritas om.
    func reloadMarks(in chapter: Int, completion: @escaping () -> Void) {
        guard views.contains(where: { $0.chapter == chapter && $0.state == .loaded }) else {
            // Kapitlet är inte laddat: markeringarna läggs in när det laddas.
            invalidate(chapter: chapter)
            completion()
            return
        }
        let marks = marksProvider?(chapter) ?? []
        let words = wordsProvider?() ?? [:]
        evaluate(ReflowMarks.reloadBody, arguments: ["marks": marks, "words": words], in: chapter) { [weak self] _ in
            self?.invalidate(chapter: chapter)
            completion()
        }
    }

    /// Kastar ett kapitels färdiga sidbilder. De som syns görs om när bladen ber om dem.
    func invalidate(chapter: Int) {
        for page in Array(images.keys) where page.chapter == chapter {
            images[page] = nil
        }
        recentlyUsed.removeAll { $0.chapter == chapter }
        pump()
    }
}
