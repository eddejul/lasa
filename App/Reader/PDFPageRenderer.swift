import PDFKit
import UIKit

/// Ritar PDF-sidor till bilder på en egen tråd, så att pappersvikningen aldrig väntar på ritandet.
/// Håller högst fem bilder i minnet (iPad Air 2 har 2 GB RAM).
final class PDFPageRenderer {

    let pageCount: Int

    private let document: PDFDocument
    private let queue = DispatchQueue(label: "se.edvin.lasa.pdf-render", qos: .userInitiated)
    private let cache = NSCache<NSNumber, UIImage>()

    // Används bara på `queue`.
    private var cachedKey = RenderKey(size: .zero, scale: 0)
    private var pixelsPerThumbnailPoint: CGFloat?

    private struct RenderKey: Equatable {
        var size: CGSize
        var scale: CGFloat
    }

    init(document: PDFDocument) {
        self.document = document
        self.pageCount = document.pageCount
        cache.countLimit = 5
    }

    /// Bilden för en sida. Tas från förrådet om den redan är ritad, annars ritas den nu.
    func image(for index: Int, size: CGSize, scale: CGFloat) -> UIImage? {
        let key = RenderKey(size: size, scale: scale)
        return queue.sync {
            render(index, key: key)
        }
    }

    /// Ritar sidorna runt den aktuella i förväg. Nästa sida först, eftersom man oftast bläddrar framåt.
    func prefetch(around index: Int, size: CGSize, scale: CGFloat) {
        let key = RenderKey(size: size, scale: scale)
        for neighbour in [index + 1, index - 1, index + 2] where neighbour >= 0 && neighbour < pageCount {
            queue.async { [weak self] in
                _ = self?.render(neighbour, key: key)
            }
        }
    }

    // Körs alltid på `queue`.
    private func render(_ index: Int, key: RenderKey) -> UIImage? {
        guard key.size.width >= 1, key.size.height >= 1, key.scale > 0 else { return nil }

        if key != cachedKey {
            cache.removeAllObjects()
            cachedKey = key
        }

        let cacheKey = NSNumber(value: index)
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }

        guard let page = document.page(at: index) else { return nil }

        let factor = thumbnailFactor(using: page)
        let requested = CGSize(width: key.size.width * key.scale / factor,
                               height: key.size.height * key.scale / factor)
        let image = page.thumbnail(of: requested, for: .mediaBox)
        cache.setObject(image, forKey: cacheKey)
        return image
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
