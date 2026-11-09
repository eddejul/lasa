import ImageIO
import PDFKit
import UIKit

/// Håller färdigritade sidbilder och ritar nya i bakgrunden, så att huvudtråden aldrig väntar på ritandet.
///
/// Används bara från huvudtråden. Själva ritandet sker på en egen kö med ett eget PDFDocument,
/// så att läsarens dokument (innehåll, zoom) aldrig används från två trådar samtidigt.
/// Högst fem bilder i minnet (iPad Air 2 har 2 GB RAM), även i uppslag.
final class PDFPageRenderer {

    static let maxImages = 5

    let pageCount: Int

    private let worker: PDFRenderWorker
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "se.edvin.lasa.pdf-render"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private var size: CGSize = .zero
    private var scale: CGFloat = 0
    private var theme: ReaderTheme = .white
    /// P3: den del av sidan som ritas, för hela boken. Ingår i varianten på disken.
    private(set) var crop: PageCrop = .full
    /// Räknas upp när storlek eller tema ändras. Bilder från en äldre omgång kastas.
    private var generation = 0

    private var images: [Int: UIImage] = [:]
    /// Index i den ordning de senast användes, äldst först.
    private var recentlyUsed: [Int] = []
    /// Sidorna som ska finnas färdiga, viktigast först.
    private var workingSet: [Int] = []
    private var pending: [Int: PendingRender] = [:]
    private var memoryObserver: NSObjectProtocol?

    private final class PendingRender {
        let operation: Operation
        /// 0 första gången, 1 när ritningen görs om efter ett fel.
        let attempt: Int
        var completions: [(UIImage) -> Void] = []
        /// Anropas om sidan inte gick att rita, inte ens andra gången.
        var failures: [() -> Void] = []
        /// En sida som visas just nu och väntar på sin bild. Den får aldrig avbrytas som onödig förritning.
        var requested = false

        init(operation: Operation, attempt: Int) {
            self.operation = operation
            self.attempt = attempt
        }
    }

    /// Självtestet: så många ritningar i följd av en sida som ska misslyckas.
    private var simulatedFailures: [Int: Int] = [:]

    /// Hur lång tid varje sidbild tog att rita, i millisekunder, till loggen (G4).
    private(set) var renderTimes: [Double] = []
    /// Hur lång tid varje sidbild tog att läsa från diskcachen (G5).
    private(set) var diskTimes: [Double] = []

    /// Färdiga sidbilder på disk (G5), eller nil om boken inte har något id.
    private let diskCache: PageDiskCache?
    /// Förritning till disken som väntar. Avbryts när läsaren flyttar sig.
    private var prefills: [Operation] = []
    /// Hur många sidor åt varje håll som förritas till disken.
    static let prefillRadius = 10
    /// Självtestet stänger av förritningen för att mäta hur lång tid en sida tar att rita.
    var prefillEnabled = true

    /// "40 sidbilder, mittvärde 85 ms, längsta 420 ms. 12 från disken, mittvärde 9 ms."
    var statsSummary: String {
        func median(_ values: [Double]) -> Int {
            Int(values.sorted()[values.count / 2].rounded())
        }
        var parts: [String] = []
        if renderTimes.isEmpty {
            parts.append("Inga sidbilder ritade.")
        } else {
            parts.append("\(renderTimes.count) sidbilder, mittvärde \(median(renderTimes)) ms, "
                         + "längsta \(Int((renderTimes.max() ?? 0).rounded())) ms.")
        }
        if !diskTimes.isEmpty {
            parts.append("\(diskTimes.count) från disken, mittvärde \(median(diskTimes)) ms, "
                         + "längsta \(Int((diskTimes.max() ?? 0).rounded())) ms.")
        }
        return parts.joined(separator: " ")
    }

    /// `cacheKey` är bokens id plus filens storlek och ändringstid, så att en ny version av filen inte
    /// visar gamla sidbilder. Utan nyckel används ingen diskcache.
    init?(url: URL, pageCount: Int, cacheKey: String? = nil) {
        guard let worker = PDFRenderWorker(url: url) else { return nil }
        self.worker = worker
        self.pageCount = pageCount
        diskCache = cacheKey.map { PageDiskCache(book: $0) }
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.releaseMemory()
        }
    }

    deinit {
        queue.cancelAllOperations()
        if let memoryObserver = memoryObserver {
            NotificationCenter.default.removeObserver(memoryObserver)
        }
    }

    /// Storlek, skala och tema för alla sidor. Ändras något kastas de ritade bilderna.
    func configure(size: CGSize, scale: CGFloat, theme: ReaderTheme) {
        guard size != self.size || scale != self.scale || theme != self.theme else { return }
        self.size = size
        self.scale = scale
        self.theme = theme
        discardImages()
    }

    /// P3: ramen för hela boken. Ändras den kastas de ritade bilderna, som när storleken ändras.
    func setCrop(_ crop: PageCrop) {
        guard crop != self.crop else { return }
        self.crop = crop
        discardImages()
    }

    private func discardImages() {
        generation += 1
        queue.cancelAllOperations()
        pending.removeAll()
        prefills.removeAll()
        images.removeAll()
        recentlyUsed.removeAll()
    }

    /// Variantens namn i diskcachen: storlek, skala, tema och ramen (P3, tom för hela sidan).
    private var variant: String {
        "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))@\(Int((scale * 10).rounded()))-\(theme.rawValue)"
            + crop.variantSuffix
    }

    /// Bilden om den redan är ritad. Ritar aldrig något själv.
    func cachedImage(for index: Int) -> UIImage? {
        guard let image = images[index] else { return nil }
        touch(index)
        return image
    }

    /// Bilden för en sida som ska visas. Finns den kommer den direkt, annars så fort den är ritad.
    /// Den går före all förritning. Misslyckas ritningen görs den om en gång, och går det inte heller
    /// anropas `failure`.
    func requestImage(for index: Int, completion: @escaping (UIImage) -> Void, failure: (() -> Void)? = nil) {
        guard isValid(index) else { return }
        if let image = cachedImage(for: index) {
            completion(image)
            return
        }
        let render = pending[index] ?? startRender(index, priority: .veryHigh)
        render.requested = true
        render.operation.queuePriority = .veryHigh
        render.completions.append(completion)
        if let failure = failure {
            render.failures.append(failure)
        }
    }

    /// Självtestet: nästa `count` ritningar av sidan misslyckas. Sidans bild glöms, så att den ritas igen.
    func simulateFailures(_ count: Int, at index: Int) {
        simulatedFailures[index] = count
        images[index] = nil
        recentlyUsed.removeAll { $0 == index }
        pending.removeValue(forKey: index)?.operation.cancel()
    }

    /// Sidorna som ska ritas i förväg, viktigast först. Förritning som inte längre behövs avbryts.
    func keep(_ indices: [Int]) {
        var seen = Set<Int>()
        let wanted = indices.filter { isValid($0) && seen.insert($0).inserted }
        workingSet = Array(wanted.prefix(Self.maxImages))

        for (index, render) in pending where !render.requested && !workingSet.contains(index) {
            render.operation.cancel()
            pending[index] = nil
        }
        for (position, index) in workingSet.enumerated() where images[index] == nil && pending[index] == nil {
            _ = startRender(index, priority: position == 0 ? .high : .normal)
        }
        trim()
        prefill(around: workingSet.first)
    }

    /// Fyller diskcachen med de närmaste sidorna åt varje håll (G5), på lägsta prioritet efter allt annat.
    /// Sidor som redan finns på disken hoppas över direkt. Bilderna sparas inte i minnet.
    private func prefill(around center: Int?) {
        prefills.forEach { $0.cancel() }
        prefills.removeAll()
        guard prefillEnabled, let cache = diskCache, let center = center, size.width >= 1 else { return }
        let size = self.size
        let scale = self.scale
        let theme = self.theme
        let crop = self.crop
        let variant = self.variant
        let worker = self.worker
        var order: [Int] = []
        for distance in 1...Self.prefillRadius {
            order.append(center + distance)
            order.append(center - distance)
        }
        for index in order where isValid(index) && images[index] == nil && pending[index] == nil {
            let operation = BlockOperation()
            operation.queuePriority = .veryLow
            operation.qualityOfService = .utility
            operation.addExecutionBlock { [weak operation] in
                guard let operation = operation, !operation.isCancelled, !cache.contains(index, variant: variant),
                      let image = worker.render(index: index, size: size, scale: scale, theme: theme, crop: crop)
                else { return }
                cache.store(image, index: index, variant: variant)
            }
            prefills.append(operation)
            queue.addOperation(operation)
        }
    }

    /// Markeringarnas rutor på en sida, räknade på renderingskön med renderarens eget dokument (G6), så att
    /// huvudtråden aldrig tar fram sidans text under en vikning. `completion` kommer på huvudtråden.
    func rects(onPage index: Int, ranges: [NSRange], completion: @escaping ([[CGRect]]) -> Void) {
        let worker = self.worker
        let operation = BlockOperation {
            let result = worker.rects(index: index, ranges: ranges)
            DispatchQueue.main.async {
                completion(result)
            }
        }
        operation.queuePriority = .low
        queue.addOperation(operation)
    }

    /// O4: sparade ord på en sida och deras rutor, räknade på renderingskön som markeringarnas (G6).
    /// `forms` som `SavedWordMarks.forms`. `completion` kommer på huvudtråden.
    func wordRects(onPage index: Int, forms: [String: String],
                   completion: @escaping ([PDFPageViewController.WordMark]) -> Void) {
        let worker = self.worker
        let operation = BlockOperation {
            let result = worker.wordRects(index: index, forms: forms)
            DispatchQueue.main.async {
                completion(result)
            }
        }
        operation.queuePriority = .veryLow
        queue.addOperation(operation)
    }

    /// V3: en liten sidbild till miniatyrerna, ritad på renderingskön med lägsta prioritet och med renderarens
    /// eget dokument. Sparas inte bland läsarens fem sidbilder. `width` i punkter. Operationen svaras, så att en
    /// miniatyr som rullats ur bild kan avbrytas innan den ritas. `completion` kommer på huvudtråden.
    @discardableResult
    func thumbnail(for index: Int, width: CGFloat, scale: CGFloat,
                   completion: @escaping (UIImage?) -> Void) -> Operation {
        let worker = self.worker
        let theme = self.theme
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak operation] in
            guard let operation = operation, !operation.isCancelled else { return }
            let image = worker.render(index: index, size: CGSize(width: width, height: width * 2), scale: scale, theme: theme)
            DispatchQueue.main.async {
                guard !operation.isCancelled else { return }
                completion(image)
            }
        }
        operation.queuePriority = .veryLow
        queue.addOperation(operation)
        return operation
    }

    /// V5: sidans interna länkar (till en annan sida i filen), lästa på renderingskön. `completion` på huvudtråden.
    func links(onPage index: Int, completion: @escaping ([PDFInternalLink]) -> Void) {
        let worker = self.worker
        let operation = BlockOperation {
            let result = worker.links(index: index)
            DispatchQueue.main.async {
                completion(result)
            }
        }
        operation.queuePriority = .low
        queue.addOperation(operation)
    }

    /// V5: texten där en länk pekar (fotnoten), läst på renderingskön före allt annat, eftersom någon väntar.
    func noteText(onPage index: Int, at point: CGPoint?, completion: @escaping (String?) -> Void) {
        let worker = self.worker
        let operation = BlockOperation {
            let result = worker.noteText(index: index, point: point)
            DispatchQueue.main.async {
                completion(result)
            }
        }
        operation.queuePriority = .veryHigh
        queue.addOperation(operation)
    }

    // MARK: Internt

    private func isValid(_ index: Int) -> Bool {
        index >= 0 && index < pageCount
    }

    private func startRender(_ index: Int, priority: Operation.QueuePriority, attempt: Int = 0) -> PendingRender {
        let generation = self.generation
        let size = self.size
        let scale = self.scale
        let theme = self.theme
        let worker = self.worker
        let cache = diskCache
        let variant = self.variant
        let crop = self.crop

        let operation = BlockOperation()
        operation.queuePriority = priority
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let operation = operation, !operation.isCancelled else { return }
            let started = CACurrentMediaTime()
            // Först diskcachen (G5): en färdig bild avkodas mycket snabbare än en fotad sida ritas.
            if let stored = cache?.image(index: index, variant: variant, scale: scale) {
                let milliseconds = (CACurrentMediaTime() - started) * 1000
                DispatchQueue.main.async {
                    self?.recordDisk(milliseconds)
                    self?.finish(index, image: stored, generation: generation)
                }
                return
            }
            let image = worker.render(index: index, size: size, scale: scale, theme: theme, crop: crop)
            let milliseconds = (CACurrentMediaTime() - started) * 1000
            DispatchQueue.main.async {
                self?.record(milliseconds, index: index, ok: image != nil)
                self?.finish(index, image: image, generation: generation)
            }
            // Till disken efter att bilden lämnats, så att sidan inte väntar på JPEG-kodningen.
            if let image = image {
                cache?.store(image, index: index, variant: variant)
            }
        }
        let render = PendingRender(operation: operation, attempt: attempt)
        pending[index] = render
        queue.addOperation(operation)
        return render
    }

    private func finish(_ index: Int, image: UIImage?, generation: Int) {
        guard generation == self.generation, let render = pending.removeValue(forKey: index) else { return }
        var image = image
        if let left = simulatedFailures[index], left > 0 {
            simulatedFailures[index] = left - 1
            image = nil
        }
        guard let image = image else {
            failed(index, render: render)
            return
        }
        if render.requested || workingSet.contains(index) {
            images[index] = image
            touch(index)
            trim()
        }
        render.completions.forEach { $0(image) }
    }

    private func recordDisk(_ milliseconds: Double) {
        diskTimes.append(milliseconds)
        if diskTimes.count > 2000 {
            diskTimes.removeFirst(1000)
        }
    }

    /// Självtestet: glömmer sidbilderna i minnet, så att nästa bild måste komma från disken eller ritas.
    func forgetImagesInMemory() {
        images.removeAll()
        recentlyUsed.removeAll()
    }

    /// Självtestet: tömmer tiderna, så att en ny mätning börjar från noll.
    func resetTimes() {
        renderTimes.removeAll()
        diskTimes.removeAll()
    }

    /// Väntar tills renderingskön (även förritningen till disken) är tom. Bara för självtestet.
    func waitUntilIdle() async {
        for _ in 0..<600 where queue.operationCount > 0 {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Antalet sidbilder i diskcachen för den här boken och storleken, till självtestet.
    func diskCount() -> Int {
        diskCache?.count(variant: variant) ?? 0
    }

    private func record(_ milliseconds: Double, index: Int, ok: Bool) {
        guard ok else { return }
        renderTimes.append(milliseconds)
        if renderTimes.count > 2000 {
            renderTimes.removeFirst(1000)
        }
        // Långsamma sidor syns var för sig i loggen, resten i sammanfattningen när boken stängs.
        if milliseconds > 400 {
            AppLog.shared.write("Sidbild \(index + 1) tog \(Int(milliseconds.rounded())) ms")
        }
    }

    /// En ritning som misslyckades görs om en gång. Andra gången får de väntande bladen veta det.
    private func failed(_ index: Int, render: PendingRender) {
        if render.attempt == 0, render.requested || workingSet.contains(index) {
            AppLog.shared.write("Sidbild \(index + 1) kunde inte ritas, försöker igen")
            let retry = startRender(index, priority: render.requested ? .veryHigh : .normal, attempt: 1)
            retry.requested = render.requested
            retry.completions = render.completions
            retry.failures = render.failures
            return
        }
        if render.attempt > 0 {
            AppLog.shared.write("Sidbild \(index + 1) kunde inte ritas efter ett nytt försök")
        }
        render.failures.forEach { $0() }
    }

    private func touch(_ index: Int) {
        recentlyUsed.removeAll { $0 == index }
        recentlyUsed.append(index)
    }

    /// Släpper bilder tills högst fem finns kvar. Först sådant som inte ska behållas, äldst först.
    private func trim() {
        while images.count > Self.maxImages {
            let victim = recentlyUsed.first { !workingSet.contains($0) } ?? recentlyUsed.first
            guard let index = victim ?? images.keys.first else { break }
            images[index] = nil
            recentlyUsed.removeAll { $0 == index }
        }
    }

    /// Lite minne kvar: behåll bara de sidor som syns.
    private func releaseMemory() {
        let keep = Set(workingSet.prefix(2))
        for index in Array(images.keys) where !keep.contains(index) {
            images[index] = nil
        }
        recentlyUsed.removeAll { !keep.contains($0) }
    }
}

/// V5: en länk inom PDF:en. `rect` i sidans koordinater, `page` och `point` där den pekar (point saknas när
/// länken pekar på hela sidan), `label` texten under länken (en fotnotssiffra är en kort text).
struct PDFInternalLink {
    let rect: CGRect
    let page: Int
    let point: CGPoint?
    let label: String

    /// En fotnotssiffra eller hänvisning som [12]: kort text under länken.
    var isNote: Bool {
        !label.isEmpty && label.count <= 6
    }
}

/// Ritar sidor till bilder. Används bara inne i renderarens kö, aldrig från huvudtråden.
private final class PDFRenderWorker {

    private let document: PDFDocument
    private var pixelsPerThumbnailPoint: CGFloat?

    init?(url: URL) {
        guard let document = PDFDocument(url: url) else { return nil }
        self.document = document
    }

    func rects(index: Int, ranges: [NSRange]) -> [[CGRect]] {
        guard let page = document.page(at: index) else { return ranges.map { _ in [] } }
        return ranges.map { PDFTextRanges.rects(on: page, range: $0) }
    }

    func wordRects(index: Int, forms: [String: String]) -> [PDFPageViewController.WordMark] {
        guard let page = document.page(at: index), let text = page.string else { return [] }
        return SavedWordMatcher.matches(in: text, forms: forms).prefix(400).compactMap { match in
            let rects = PDFTextRanges.rects(on: page, range: match.range)
            return rects.isEmpty ? nil : PDFPageViewController.WordMark(value: match.value, rects: rects)
        }
    }

    func links(index: Int) -> [PDFInternalLink] {
        guard let page = document.page(at: index) else { return [] }
        return page.annotations.prefix(300).compactMap { annotation in
            guard annotation.type == "Link", annotation.url == nil,
                  let destination = annotation.destination ?? (annotation.action as? PDFActionGoTo)?.destination,
                  let target = destination.page else { return nil }
            let targetIndex = document.index(for: target)
            guard targetIndex >= 0, targetIndex < document.pageCount else { return nil }
            let unspecified = CGFloat(kPDFDestinationUnspecifiedValue)
            let point = destination.point
            let label = page.selection(for: annotation.bounds)?.string?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return PDFInternalLink(rect: annotation.bounds, page: targetIndex,
                                   point: point.y == unspecified ? nil : point, label: label)
        }
    }

    /// Fotnoten där en länk pekar: raderna under punkten, till nästa not (en rad som börjar med en annan siffra).
    func noteText(index: Int, point: CGPoint?) -> String? {
        guard let point = point, let page = document.page(at: index) else { return nil }
        let box = page.bounds(for: .mediaBox)
        let top = min(point.y + 4, box.maxY)
        let bottom = max(top - 160, box.minY)
        guard top > bottom,
              let raw = page.selection(for: CGRect(x: box.minX, y: bottom, width: box.width, height: top - bottom))?.string
        else { return nil }
        let lines = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var kept: [String] = []
        for line in lines {
            if !kept.isEmpty, let first = line.first, first.isNumber {
                break
            }
            kept.append(line)
            if kept.joined(separator: " ").count > 800 {
                break
            }
        }
        let text = kept.joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    func render(index: Int, size: CGSize, scale: CGFloat, theme: ReaderTheme, crop: PageCrop = .full) -> UIImage? {
        guard size.width >= 1, size.height >= 1, scale > 0,
              let page = document.page(at: index) else {
            return nil
        }
        let factor = thumbnailFactor(using: page)
        // P3: med en ram ritas hela sidan så stor att ramens del fyller ytan, och den delen skärs ut.
        let shown = page.bounds(for: .mediaBox).applying(page.transform(for: .mediaBox)).standardized.size
        let target = crop.isFull ? size : crop.fullPageSize(fitting: size, page: shown)
        let requested = CGSize(width: target.width * scale / factor,
                               height: target.height * scale / factor)
        var image = page.thumbnail(of: requested, for: .mediaBox)
        // En tom bild betyder att ritningen misslyckades.
        guard image.size.width >= 1, image.size.height >= 1, image.cgImage != nil || image.ciImage != nil else {
            return nil
        }
        if !crop.isFull {
            guard let cut = crop.cut(image, page: shown) else { return nil }
            image = cut
        }
        return PageImageStyler.apply(theme, to: image)
    }

    /// `thumbnail(of:)` hanterar sidans rotation rätt, men det är inte dokumenterat
    /// om storleken räknas i punkter eller pixlar. Vi mäter en gång och räknar om,
    /// så att bilden blir skarp utan att bli onödigt stor.
    private func thumbnailFactor(using page: PDFPage) -> CGFloat {
        if let known = pixelsPerThumbnailPoint {
            return known
        }
        let probeSide: CGFloat = 100
        // En tom sida räcker för att mäta skalan. Bokens sida skulle avkoda ett helt foto i en fotad PDF (G5).
        let blank = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { _ in }
        let probe = (PDFPage(image: blank) ?? page).thumbnail(of: CGSize(width: probeSide, height: probeSide),
                                                              for: .mediaBox)
        let pixels = max(probe.size.width, probe.size.height) * probe.scale
        let factor = max(pixels / probeSide, 1)
        pixelsPerThumbnailPoint = factor
        return factor
    }
}

/// Färdiga sidbilder på disk (G5): `Library/Caches/Sidbilder/<bok>/<variant>/<sida>.jpg`. Cachen syns inte
/// i Filer, kommer inte med i säkerhetskopian och får tas bort av iOS. Högst cirka 300 MB, äldst bort först.
/// Används bara från renderingskön (och från förritningen på samma kö), aldrig från huvudtråden.
final class PageDiskCache {

    static let maxBytes = 300 * 1_048_576
    /// Rensningen tar cachen ner till så här mycket, så att den inte behöver rensas vid varje bild.
    static let targetBytes = 250 * 1_048_576

    static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sidbilder", isDirectory: true)
    }

    private let directory: URL
    private static var totalBytes: Int?
    private static let totalLock = NSLock()

    init(book: String) {
        let safe = book.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? String($0) : "_" }
            .joined()
        directory = Self.root.appendingPathComponent(String(safe.prefix(120)), isDirectory: true)
    }

    private func url(index: Int, variant: String) -> URL {
        directory.appendingPathComponent(variant, isDirectory: true).appendingPathComponent("\(index).jpg")
    }

    func contains(_ index: Int, variant: String) -> Bool {
        FileManager.default.fileExists(atPath: url(index: index, variant: variant).path)
    }

    func count(variant: String) -> Int {
        let folder = directory.appendingPathComponent(variant, isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".jpg") }.count
    }

    /// Bilden avkodad direkt (inte först när den visas), eller nil om den inte finns.
    func image(index: Int, variant: String, scale: CGFloat) -> UIImage? {
        let file = url(index: index, variant: variant)
        guard FileManager.default.fileExists(atPath: file.path),
              let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            return nil
        }
        // Senast använd: ändringstiden styr vilka bilder som rensas först.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return UIImage(cgImage: image, scale: max(scale, 1), orientation: .up)
    }

    func store(_ image: UIImage, index: Int, variant: String) {
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }
        let file = url(index: index, variant: variant)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            return
        }
        Self.add(data.count)
    }

    // MARK: Storleken

    private static func add(_ bytes: Int) {
        totalLock.lock()
        let current = (totalBytes ?? measure()) + bytes
        totalBytes = current
        totalLock.unlock()
        if current > maxBytes {
            trim()
        }
    }

    private static func measure() -> Int {
        files().reduce(0) { $0 + $1.size }
    }

    private static func files() -> [(url: URL, size: Int, date: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        var result: [(url: URL, size: Int, date: Date)] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isDirectory != true else { continue }
            result.append((url: url, size: values.fileSize ?? 0, date: values.contentModificationDate ?? .distantPast))
        }
        return result
    }

    /// Tar bort de äldsta bilderna tills cachen är under 250 MB.
    private static func trim() {
        var all = files().sorted { $0.date < $1.date }
        var total = all.reduce(0) { $0 + $1.size }
        let before = total
        while total > targetBytes, !all.isEmpty {
            let oldest = all.removeFirst()
            try? FileManager.default.removeItem(at: oldest.url)
            total -= oldest.size
        }
        totalLock.lock()
        totalBytes = total
        totalLock.unlock()
        AppLog.shared.write("Sidbilder på disk rensade: \(before / 1_048_576) MB till \(total / 1_048_576) MB")
    }
}
