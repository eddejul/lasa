import ImageIO
import PDFKit
import UIKit

/// Det som läses ur en bokfil i bakgrunden (B1): titel, författare, omslaget och, för andelen läst i böcker
/// som inte öppnats sedan B1, sidantalet (PDF) eller kapitlens storlek (EPUB).
struct BookFileInfo {
    var title = ""
    var author = ""
    var cover: CGImage?
    var pageCount = 0
    var chapterWeights: [Int] = []
}

/// Läser titel, författare och omslag ur en bokfil. Bara från en bakgrundskö, aldrig från huvudtråden.
enum BookFileReader {

    /// Omslagets höjd i pixlar. Bredden följer sidan, oftast cirka 300 px, cirka 40 till 60 kB som JPEG.
    static let coverPixelHeight: CGFloat = 450

    static func read(url: URL, kind: Book.Kind, coverPage: Int) -> BookFileInfo {
        switch kind {
        case .pdf: return readPDF(url: url, coverPage: coverPage)
        case .epub: return readEPUB(url: url)
        case .text: return readText(url: url)
        case .other: return BookFileInfo()
        }
    }

    // MARK: PDF

    private static func readPDF(url: URL, coverPage: Int) -> BookFileInfo {
        var info = BookFileInfo()
        guard let document = PDFDocument(url: url), !document.isLocked else { return info }
        info.pageCount = document.pageCount
        let attributes = document.documentAttributes ?? [:]
        info.title = usableTitle(attributes[PDFDocumentAttribute.titleAttribute] as? String)
        info.author = clean(attributes[PDFDocumentAttribute.authorAttribute] as? String ?? "")
        let index = coverPage >= 0 && coverPage < document.pageCount ? coverPage : 0
        if let page = document.page(at: index) {
            info.cover = pageImage(page)
        }
        return info
    }

    /// En PDF-sida som liten bild. `thumbnail(of:)` hanterar sidans rotation. Storleken i anropet är punkter
    /// eller pixlar beroende på iOS, därför skalas bilden till rätt höjd efteråt.
    static func pageImage(_ page: PDFPage, height: CGFloat = coverPixelHeight) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        let aspect = rotated ? bounds.height / max(bounds.width, 1) : bounds.width / max(bounds.height, 1)
        guard aspect > 0.05, aspect < 20 else { return nil }
        let requested = CGSize(width: (height * aspect).rounded(), height: height)
        let image = page.thumbnail(of: requested, for: .mediaBox)
        guard let cgImage = image.cgImage else { return nil }
        return scaled(cgImage, height: height)
    }

    /// Titlar som PDF-program sätter av sig själva (filnamnet, Microsoft Word och liknande) räknas inte.
    static func usableTitle(_ raw: String?) -> String {
        var title = clean(raw ?? "")
        for prefix in ["Microsoft Word - ", "Microsoft PowerPoint - "] where title.hasPrefix(prefix) {
            title = String(title.dropFirst(prefix.count))
        }
        let lower = title.lowercased()
        let generated = ["untitled", "namnlös", "document", "dokument"]
        if title.count < 2 || generated.contains(lower) {
            return ""
        }
        for suffix in [".doc", ".docx", ".pdf", ".indd", ".ppt", ".pptx", ".tex", ".dvi", ".odt"]
            where lower.hasSuffix(suffix) {
            return ""
        }
        return title
    }

    // MARK: EPUB

    private static func readEPUB(url: URL) -> BookFileInfo {
        var info = BookFileInfo()
        guard let archive = try? ZipArchive(url: url),
              let containerEntry = archive.entry(named: "META-INF/container.xml"),
              let containerData = try? archive.contents(of: containerEntry),
              let container = XMLTree.parse(containerData),
              let rootPath = container.descendants(named: "rootfile").compactMap({ $0["full-path"] }).first,
              let packageEntry = archive.entry(named: rootPath),
              let packageData = try? archive.contents(of: packageEntry),
              let package = XMLTree.parse(packageData) else {
            return info
        }
        let metadata = package.descendants(named: "metadata").first
        info.title = clean(metadata?.descendants(named: "title").first?.text ?? "")
        let creators = (metadata?.descendants(named: "creator") ?? []).map { clean($0.text) }.filter { !$0.isEmpty }
        info.author = creators.prefix(3).joined(separator: ", ")

        let base = (rootPath as NSString).deletingLastPathComponent
        var manifest: [String: (path: String, type: String, properties: [String])] = [:]
        for item in package.descendants(named: "item") {
            guard let id = item["id"], let href = item["href"] else { continue }
            let path = resolve(href, base: base)
            manifest[id] = (path, (item["media-type"] ?? "").lowercased(),
                            (item["properties"] ?? "").split(separator: " ").map(String.init))
        }
        // Kapitlens storlek i ryggradens ordning, för andelen läst ur en sparad plats.
        if let spine = package.descendants(named: "spine").first {
            for reference in spine.children where reference.name == "itemref" {
                guard let id = reference["idref"], let item = manifest[id],
                      item.type.contains("html"), let entry = archive.entry(named: item.path) else { continue }
                info.chapterWeights.append(max(entry.uncompressedSize, 1))
            }
        }

        // Omslaget: EPUB 3 (properties="cover-image"), EPUB 2 (<meta name="cover">), annars en bild med cover
        // i namnet. SVG kan inte ritas utan webbvy, då ritar biblioteket ett eget omslag.
        var candidates: [(path: String, type: String)] = []
        if let item = manifest.values.first(where: { $0.properties.contains("cover-image") }) {
            candidates.append((item.path, item.type))
        }
        let coverMeta = (metadata?.descendants(named: "meta") ?? []).first(where: { $0["name"]?.lowercased() == "cover" })
        let metaCover = coverMeta?["content"]
        if let id = metaCover, let item = manifest[id] {
            candidates.append((item.path, item.type))
        }
        for (id, item) in manifest where item.type.hasPrefix("image/") && item.type != "image/svg+xml"
            && (id.lowercased().contains("cover") || item.path.lowercased().contains("cover")) {
            candidates.append((item.path, item.type))
        }
        for candidate in candidates where candidate.type != "image/svg+xml" {
            guard let entry = archive.entry(named: candidate.path), entry.uncompressedSize < 30_000_000,
                  let data = try? archive.contents(of: entry),
                  let image = thumbnail(data: data) else { continue }
            info.cover = image
            break
        }
        return info
    }

    /// En sökväg i EPUB:en relativ till OPF-filens mapp, med .. och procentkodning upplösta.
    static func resolve(_ href: String, base: String) -> String {
        let raw = href.split(separator: "#").first.map(String.init) ?? href
        let decoded = raw.removingPercentEncoding ?? raw
        var parts = base.isEmpty ? [] : base.split(separator: "/").map(String.init)
        for part in decoded.split(separator: "/").map(String.init) {
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
            } else if part != "." && !part.isEmpty {
                parts.append(part)
            }
        }
        return parts.joined(separator: "/")
    }

    // MARK: Text

    private static func readText(url: URL) -> BookFileInfo {
        var info = BookFileInfo()
        let ext = url.pathExtension.lowercased()
        guard ext == "md" || ext == "markdown",
              let handle = try? FileHandle(forReadingFrom: url) else { return info }
        defer { try? handle.close() }
        let head = handle.readData(ofLength: 8192)
        let text = String(decoding: head, as: UTF8.self)
        // Markdownens första rubrik.
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(40) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                info.title = clean(String(trimmed.dropFirst(2)))
                break
            }
        }
        return info
    }

    // MARK: Bilder

    /// En bild ur en fil som liten bild, utan att hela bilden avkodas (ImageIO).
    static func thumbnail(data: Data, height: CGFloat = coverPixelHeight) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(height * 1.2),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return scaled(image, height: height)
    }

    /// Skalar ner en bild till en höjd (aldrig upp).
    static func scaled(_ image: CGImage, height: CGFloat) -> CGImage? {
        guard CGFloat(image.height) > height + 1 else { return image }
        let factor = height / CGFloat(image.height)
        let width = max(Int((CGFloat(image.width) * factor).rounded()), 1)
        let target = Int(height)
        guard let context = CGContext(data: nil, width: width, height: target, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: target))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: target))
        return context.makeImage()
    }

    static func clean(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// Omslagen i biblioteket (B1): små JPEG i `Library/Caches/Omslag/`, som får tas bort av iOS och då ritas om.
/// Ritningen sker på en egen kö med en bok i taget och lägsta prioritet som syns (A8X, 2 GB RAM). Det enda som
/// inte kan ritas om, sidan läsaren valt som omslag i en PDF, ligger i bokregistret. Används från huvudtråden.
final class CoverStore {

    static let shared = CoverStore()

    /// Skickas på huvudtråden när en boks omslag eller titel är klar. `object` är bokens id.
    static let didUpdate = Notification.Name("CoverStoreDidUpdate")

    /// Filnamnet i registret för en bok som inte har någon omslagsbild (text, SVG): biblioteket ritar ett.
    static let noImage = "ingen"

    let directory: URL
    private let memory = NSCache<NSString, UIImage>()
    private let renderQueue = OperationQueue()
    private let diskQueue = OperationQueue()
    private var queued = Set<String>()
    /// Antal omslag som ritats och lästs från disken sedan start, till självtestet och loggen.
    private(set) var rendered = 0
    private(set) var loaded = 0

    private init() {
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Omslag", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.countLimit = 80
        renderQueue.maxConcurrentOperationCount = 1
        renderQueue.qualityOfService = .utility
        renderQueue.name = "Omslag"
        diskQueue.maxConcurrentOperationCount = 2
        diskQueue.qualityOfService = .userInitiated
        diskQueue.name = "Omslag från disken"
    }

    /// Omslagets filnamn för bokens fil just nu: ändras när filen eller den valda sidan ändras.
    static func fileName(for record: BookRecord) -> String {
        "\(record.id)-\(record.size)-\(record.modified)-\(record.coverPage).jpg"
    }

    /// Omslaget om det redan finns i minnet. Annars nil, och det läses eller ritas i bakgrunden
    /// (och `didUpdate` skickas när det är klart).
    func image(for book: Book, record: BookRecord?) -> UIImage? {
        guard let record = record else { return nil }
        let name = Self.fileName(for: record)
        if let image = memory.object(forKey: name as NSString) {
            return image
        }
        if record.cover == Self.noImage, record.metaKey == record.currentMetaKey {
            return nil
        }
        prepare(book, record: record)
        return nil
    }

    /// Sant om boken saknar egen omslagsbild (text, SVG-omslag): biblioteket ritar ett.
    func hasNoImage(_ record: BookRecord?) -> Bool {
        guard let record = record else { return true }
        return record.cover == Self.noImage && record.metaKey == record.currentMetaKey
    }

    /// Läser titel och författare om filen ändrats, och läser eller ritar omslaget om det inte finns i minnet.
    func prepare(_ book: Book, record: BookRecord) {
        let name = Self.fileName(for: record)
        let needsMetadata = record.metaKey != record.currentMetaKey
        guard memory.object(forKey: name as NSString) == nil || needsMetadata,
              !queued.contains(book.id) else { return }
        queued.insert(book.id)
        let fileURL = directory.appendingPathComponent(name)
        let hasFile = record.cover == name
        let id = book.id
        let url = book.url
        let kind = book.kind
        let coverPage = record.coverPage
        if hasFile && !needsMetadata {
            diskQueue.addOperation { [weak self] in
                let image = UIImage(contentsOfFile: fileURL.path)?.preparingForDisplay()
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.queued.remove(id)
                    if let image = image {
                        self.loaded += 1
                        self.memory.setObject(image, forKey: name as NSString)
                        NotificationCenter.default.post(name: Self.didUpdate, object: id)
                    } else {
                        // Filen är borta (iOS rensar cachen): rita om.
                        BookRegistry.shared.setCover(id: id, file: "")
                        if let fresh = BookRegistry.shared.record(id: id) {
                            self.prepare(book, record: fresh)
                        }
                    }
                }
            }
            return
        }
        let key = record.currentMetaKey
        renderQueue.addOperation { [weak self] in
            let started = CACurrentMediaTime()
            let info = autoreleasepool { BookFileReader.read(url: url, kind: kind, coverPage: coverPage) }
            var image: UIImage?
            if let cover = info.cover {
                let uiImage = UIImage(cgImage: cover)
                if let data = uiImage.jpegData(compressionQuality: 0.78),
                   (try? data.write(to: fileURL, options: .atomic)) != nil {
                    image = uiImage.preparingForDisplay() ?? uiImage
                }
            }
            let milliseconds = Int(((CACurrentMediaTime() - started) * 1000).rounded())
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.queued.remove(id)
                self.rendered += 1
                if needsMetadata {
                    BookRegistry.shared.setMetadata(id: id, title: info.title, author: info.author, key: key)
                    self.setInitialProgress(book, info: info)
                }
                if let image = image {
                    self.memory.setObject(image, forKey: name as NSString)
                    BookRegistry.shared.setCover(id: id, file: name)
                } else {
                    BookRegistry.shared.setCover(id: id, file: Self.noImage)
                }
                if milliseconds > 1500 {
                    AppLog.shared.write("Omslaget för \(url.lastPathComponent) tog \(milliseconds) ms")
                }
                NotificationCenter.default.post(name: Self.didUpdate, object: id)
            }
        }
    }

    /// En bok som lästs innan andelen sparades (före B1) får sin andel ur den sparade läspositionen,
    /// en gång, så att stapeln stämmer innan boken öppnats igen.
    private func setInitialProgress(_ book: Book, info: BookFileInfo) {
        guard let record = BookRegistry.shared.record(id: book.id), record.progress <= 0, record.page == 0,
              LibraryStore.shared.positionDate(for: book) != nil else { return }
        switch book.kind {
        case .pdf:
            guard info.pageCount > 0 else { return }
            let index = LibraryStore.shared.savedPageIndex(for: book)
            BookRegistry.shared.setInitialProgress(id: book.id, progress: Double(index + 1) / Double(info.pageCount),
                                                   pages: info.pageCount)
        case .epub:
            guard let location = LibraryStore.shared.savedLocation(for: book),
                  location.chapter < info.chapterWeights.count else { return }
            let total = Double(info.chapterWeights.reduce(0, +))
            let before = Double(info.chapterWeights.prefix(location.chapter).reduce(0, +))
            let current = Double(info.chapterWeights[location.chapter]) * location.progression
            guard total > 0 else { return }
            BookRegistry.shared.setInitialProgress(id: book.id, progress: (before + current) / total, pages: 0)
        case .text, .other:
            break
        }
    }

    /// Glömmer omslag i minnet (minnesvarning).
    func releaseMemory() {
        memory.removeAllObjects()
    }

    /// Tar bort en boks omslag (Välj omslag, eller boken togs bort).
    func forget(_ record: BookRecord) {
        memory.removeObject(forKey: Self.fileName(for: record) as NSString)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(Self.fileName(for: record)))
    }
}
