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

    /// "40 sidbilder, mittvärde 85 ms, längsta 420 ms."
    var statsSummary: String {
        guard !renderTimes.isEmpty else { return "Inga sidbilder ritade." }
        let sorted = renderTimes.sorted()
        return "\(sorted.count) sidbilder, mittvärde \(Int(sorted[sorted.count / 2].rounded())) ms, "
            + "längsta \(Int((sorted.last ?? 0).rounded())) ms."
    }

    init?(url: URL, pageCount: Int) {
        guard let worker = PDFRenderWorker(url: url) else { return nil }
        self.worker = worker
        self.pageCount = pageCount
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
        generation += 1
        queue.cancelAllOperations()
        pending.removeAll()
        images.removeAll()
        recentlyUsed.removeAll()
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

        let operation = BlockOperation()
        operation.queuePriority = priority
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let operation = operation, !operation.isCancelled else { return }
            let started = CACurrentMediaTime()
            let image = worker.render(index: index, size: size, scale: scale, theme: theme)
            let milliseconds = (CACurrentMediaTime() - started) * 1000
            DispatchQueue.main.async {
                self?.record(milliseconds, index: index, ok: image != nil)
                self?.finish(index, image: image, generation: generation)
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

    func render(index: Int, size: CGSize, scale: CGFloat, theme: ReaderTheme) -> UIImage? {
        guard size.width >= 1, size.height >= 1, scale > 0,
              let page = document.page(at: index) else {
            return nil
        }
        let factor = thumbnailFactor(using: page)
        let requested = CGSize(width: size.width * scale / factor,
                               height: size.height * scale / factor)
        let image = page.thumbnail(of: requested, for: .mediaBox)
        // En tom bild betyder att ritningen misslyckades.
        guard image.size.width >= 1, image.size.height >= 1, image.cgImage != nil || image.ciImage != nil else {
            return nil
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
        let probe = page.thumbnail(of: CGSize(width: probeSide, height: probeSide), for: .mediaBox)
        let pixels = max(probe.size.width, probe.size.height) * probe.scale
        let factor = max(pixels / probeSide, 1)
        pixelsPerThumbnailPoint = factor
        return factor
    }
}
