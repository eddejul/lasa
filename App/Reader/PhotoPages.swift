import PDFKit
import UIKit

// Våg 10b: fotade sidor. P3 beskär marginalerna, P4 textläget (txt-filen från OCR-flödet bredvid PDF:en).
// Det som rör läsarnas inre ligger i läsarna, i avsnittet Beskärning och textläge (P3, P4).

// MARK: P3 Ramen

/// P3: den del av varje sida som visas, som andelar (0 till 1) av sidan som den syns (rotationen inräknad,
/// origo uppe till vänster). En ram gäller hela boken. `full` är hela sidan.
struct PageCrop: Equatable {

    var rect: CGRect

    static let full = PageCrop(rect: CGRect(x: 0, y: 0, width: 1, height: 1))
    /// Minsta bredd och höjd, så att en ram inte kan dras ihop till nästan ingenting.
    static let minimumSide: CGFloat = 0.3
    /// Hela sidan ritas högst så här många gånger större (till ytan) än sidbilden, för minnets skull
    /// (iPad Air 2 har 2 GB). En mycket liten ram ger då en något mindre skarp bild, aldrig mer minne.
    static let maxOversize: CGFloat = 2.25

    var isFull: Bool {
        rect.minX <= 0.001 && rect.minY <= 0.001 && rect.maxX >= 0.999 && rect.maxY >= 0.999
    }

    /// Ramen inom sidan och inte mindre än `minimumSide`.
    func clamped() -> PageCrop {
        let source = rect.standardized
        let width = min(max(source.width, Self.minimumSide), 1)
        let height = min(max(source.height, Self.minimumSide), 1)
        let x = min(max(source.minX, 0), 1 - width)
        let y = min(max(source.minY, 0), 1 - height)
        return PageCrop(rect: CGRect(x: x, y: y, width: width, height: height))
    }

    /// Tillägget i sidbildernas variant (G5), så att bilder med en annan ram aldrig visas. Tomt för hela
    /// sidan, så att sidbilderna som redan ligger på disken gäller som förut.
    var variantSuffix: String {
        guard !isFull else { return "" }
        let values = [rect.minX, rect.minY, rect.width, rect.height].map { Int(($0 * 1000).rounded()) }
        return "-b" + values.map { String(format: "%03d", $0) }.joined(separator: ".")
    }

    /// Var hela sidan skulle ligga när den beskurna delen fyller `imageFrame`. Omräkningen mellan sidans
    /// koordinater och bladet (`PDFPageGeometry`) får den här rutan, så att markeringar, ordtryck och sök
    /// hamnar rätt på en beskuren sida.
    func pageFrame(for imageFrame: CGRect) -> CGRect {
        guard !isFull, rect.width > 0, rect.height > 0 else { return imageFrame }
        let width = imageFrame.width / rect.width
        let height = imageFrame.height / rect.height
        return CGRect(x: imageFrame.minX - rect.minX * width, y: imageFrame.minY - rect.minY * height,
                      width: width, height: height)
    }

    /// Storleken som hela sidan ska ritas i, så att den beskurna delen fyller `area`. `page` är sidans
    /// synliga storlek (rotationen inräknad).
    func fullPageSize(fitting area: CGSize, page: CGSize) -> CGSize {
        guard !isFull, page.width > 0, page.height > 0, area.width > 0, area.height > 0 else { return area }
        let cropWidth = page.width * rect.width
        let cropHeight = page.height * rect.height
        let scale = min(area.width / cropWidth, area.height / cropHeight)
        var size = CGSize(width: page.width * scale, height: page.height * scale)
        let limit = area.width * area.height * Self.maxOversize
        let actual = size.width * size.height
        if actual > limit {
            let factor = (limit / actual).squareRoot()
            size = CGSize(width: size.width * factor, height: size.height * factor)
        }
        return size
    }

    /// Den beskurna delen av en bild av hela sidan. Sidan antas ligga centrerad i bilden, som i
    /// `PDFPageGeometry`. Ritas om i en egen bild, så att hela sidans minne släpps direkt.
    func cut(_ image: UIImage, page: CGSize) -> UIImage? {
        let bounds = CGRect(origin: .zero, size: image.size)
        guard bounds.width >= 1, bounds.height >= 1, page.width > 0, page.height > 0 else { return nil }
        let scale = min(bounds.width / page.width, bounds.height / page.height)
        let content = CGRect(x: (bounds.width - page.width * scale) / 2, y: (bounds.height - page.height * scale) / 2,
                             width: page.width * scale, height: page.height * scale)
        let area = CGRect(x: content.minX + rect.minX * content.width,
                          y: content.minY + rect.minY * content.height,
                          width: rect.width * content.width,
                          height: rect.height * content.height).intersection(bounds)
        guard !area.isNull, area.width >= 1, area.height >= 1 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: area.size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: area.size))
            image.draw(at: CGPoint(x: -area.minX, y: -area.minY))
        }
    }
}

/// P3: ramen sparas per bok i UserDefaults (`bookCrop.<bokens id>`), som läspositionerna, och följer med i
/// säkerhetskopian (`Backup`). Värdet är "1;x;y;b;h" (på) eller "0;x;y;b;h" (sparad men avstängd, ett tryck
/// visar hela sidan och ett till beskär igen).
enum PageCropStore {

    static let prefix = "bookCrop."

    struct Saved: Equatable {
        var crop: PageCrop
        var isOn: Bool
    }

    static func saved(bookID: String) -> Saved? {
        UserDefaults.standard.string(forKey: prefix + bookID).flatMap(parse)
    }

    static func save(_ saved: Saved?, bookID: String) {
        // Utan registret är bokens id tillfälligt (som för läspositionen, granskningens fynd 9).
        guard BookRegistry.shared.isAvailable else { return }
        if let saved = saved, !saved.crop.isFull {
            UserDefaults.standard.set(format(saved), forKey: prefix + bookID)
        } else {
            UserDefaults.standard.removeObject(forKey: prefix + bookID)
        }
    }

    /// Ramen som gäller: den sparade när den är på, annars hela sidan.
    static func active(bookID: String) -> PageCrop {
        guard let saved = saved(bookID: bookID), saved.isOn else { return .full }
        return saved.crop
    }

    static func parse(_ text: String) -> Saved? {
        let parts = text.split(separator: ";").map(String.init)
        guard parts.count == 5, parts[0] == "0" || parts[0] == "1",
              let x = Double(parts[1]), let y = Double(parts[2]),
              let width = Double(parts[3]), let height = Double(parts[4]),
              width > 0, height > 0 else { return nil }
        let crop = PageCrop(rect: CGRect(x: x, y: y, width: width, height: height)).clamped()
        return Saved(crop: crop, isOn: parts[0] == "1")
    }

    static func format(_ saved: Saved) -> String {
        let rect = saved.crop.rect
        let values = [rect.minX, rect.minY, rect.width, rect.height].map { String(format: "%.4f", Double($0)) }
        return ([saved.isOn ? "1" : "0"] + values).joined(separator: ";")
    }
}

/// P3: ett förslag på ram efter var texten ligger, räknat på en nedskalad bild i bakgrunden. Först papperet
/// (ljusa kolumner och rader, så att bord och skuggor runt boken försvinner), sedan texten på papperet.
/// Bara ett förslag: ramen syns i rutan och sparas först när man trycker Klar.
enum PageCropSuggestion {

    /// Nil när texten redan fyller nästan hela sidan eller inget papper hittas.
    static func suggest(from image: UIImage) -> PageCrop? {
        guard let cg = image.cgImage else { return nil }
        let width = 240
        let height = max(Int((Double(width) * Double(cg.height) / Double(max(cg.width, 1))).rounded()), 1)
        guard height > 20, height < 2000 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return suggest(gray: pixels, width: width, height: height)
    }

    /// Ren logik för XCTest: `gray` är en gråskalebild rad för rad uppifrån, 0 svart och 255 vitt.
    static func suggest(gray: [UInt8], width: Int, height: Int) -> PageCrop? {
        guard width > 10, height > 10, gray.count == width * height else { return nil }
        var sorted = gray.sorted()
        var gray = gray
        // Mörk bakgrund (Mörkt i Aa vänder sidbilden): papperet är det mesta av bilden, så en mörk mittpunkt
        // betyder ljus text på mörkt papper. Vänd bilden, så gäller samma regler.
        if sorted[sorted.count / 2] < 110 {
            gray = gray.map { 255 - $0 }
            sorted = gray.sorted()
        }
        // Papperets ljushet: den 85:e percentilen, så att text och mörka kanter inte drar ner den.
        let paper = Int(sorted[min(Int(Double(sorted.count) * 0.85), sorted.count - 1)])
        guard paper > 90 else { return nil }
        let bright = max(paper - 40, 0)
        let ink = max(paper - 80, 0)
        func value(_ x: Int, _ y: Int) -> Int { Int(gray[y * width + x]) }

        // 1. Papperet: den längsta följden kolumner, sedan rader, där mer än hälften är ljust.
        func longestRun(_ flags: [Bool]) -> Range<Int>? {
            var best: Range<Int>?
            var start: Int?
            for index in 0...flags.count {
                let flag = index < flags.count && flags[index]
                if flag, start == nil {
                    start = index
                } else if !flag, let begin = start {
                    if index - begin > (best?.count ?? 0) {
                        best = begin..<index
                    }
                    start = nil
                }
            }
            return best
        }
        let columns = (0..<width).map { x in
            (0..<height).filter { value(x, $0) >= bright }.count * 2 > height
        }
        guard let paperX = longestRun(columns), paperX.count > width / 3 else { return nil }
        let rows = (0..<height).map { y in
            paperX.filter { value($0, y) >= bright }.count * 2 > paperX.count
        }
        guard let paperY = longestRun(rows), paperY.count > height / 3 else { return nil }

        // 2. Texten på papperet: kolumner och rader med mörka punkter, utan en smal kant närmast papperets
        // ytterkant (skuggor och bokens kant).
        let insetX = max(paperX.count / 50, 1)
        let insetY = max(paperY.count / 50, 1)
        let innerX = (paperX.lowerBound + insetX)..<(paperX.upperBound - insetX)
        let innerY = (paperY.lowerBound + insetY)..<(paperY.upperBound - insetY)
        guard !innerX.isEmpty, !innerY.isEmpty else { return nil }
        let inkColumns = innerX.filter { x in innerY.filter { value(x, $0) < ink }.count >= 2 }
        let inkRows = innerY.filter { y in innerX.filter { value($0, y) < ink }.count >= 2 }
        guard let left = inkColumns.first, let right = inkColumns.last,
              let top = inkRows.first, let bottom = inkRows.last, right > left, bottom > top else { return nil }
        // Lite luft runt texten, så att inga bokstäver hamnar i kanten.
        let padX = Double(width) * 0.025
        let padY = Double(height) * 0.02
        let rect = CGRect(x: (Double(left) - padX) / Double(width),
                          y: (Double(top) - padY) / Double(height),
                          width: (Double(right - left + 1) + 2 * padX) / Double(width),
                          height: (Double(bottom - top + 1) + 2 * padY) / Double(height))
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let crop = PageCrop(rect: rect).clamped()
        // Mindre än tre procent att vinna åt båda hållen: inget förslag.
        guard crop.rect.width < 0.97 || crop.rect.height < 0.97 else { return nil }
        return crop
    }
}

// MARK: P3 Rutan där ramen dras

/// P3: hela sidan med ramen ovanpå. Hörn och kanter dras, mitten flyttar hela ramen. Klar sparar ramen för
/// hela boken, Hela sidan tar bort den och Föreslå räknar fram en ram efter var texten ligger.
final class PageCropViewController: UIViewController {

    var onSave: ((PageCrop) -> Void)?
    var onFullPage: (() -> Void)?

    private let imageView = UIImageView()
    private let frameView = CropFrameView()
    private let hint = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let loadImage: (@escaping (UIImage?) -> Void) -> Void
    private var image: UIImage?
    private(set) var crop: PageCrop

    /// `loadImage` ritar hela sidan i bakgrunden (renderarens miniatyr) och svarar på huvudtråden.
    init(crop: PageCrop, loadImage: @escaping (@escaping (UIImage?) -> Void) -> Void) {
        self.crop = crop
        self.loadImage = loadImage
        super.init(nibName: nil, bundle: nil)
        title = "Beskär marginalerna"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let palette = Theme.current
        view.backgroundColor = palette.canvas
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self,
                                                           action: #selector(cancelTapped))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Klar", style: .done, target: self,
                                                            action: #selector(doneTapped))
        let full = UIBarButtonItem(title: "Hela sidan", style: .plain, target: self, action: #selector(fullTapped))
        let suggest = UIBarButtonItem(title: "Föreslå", style: .plain, target: self, action: #selector(suggestTapped))
        toolbarItems = [full, UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil), suggest]

        imageView.contentMode = .scaleToFill
        imageView.layer.shadowColor = UIColor.black.cgColor
        imageView.layer.shadowOpacity = 0.15
        imageView.layer.shadowRadius = 6
        imageView.layer.shadowOffset = CGSize(width: 0, height: 2)
        view.addSubview(imageView)
        frameView.crop = crop.rect
        frameView.onChange = { [weak self] rect in
            self?.crop = PageCrop(rect: rect)
        }
        view.addSubview(frameView)

        hint.text = "Dra i hörnen och kanterna så att bara texten är kvar. Ramen gäller alla sidor i boken."
        hint.numberOfLines = 0
        hint.textAlignment = .center
        hint.font = .preferredFont(forTextStyle: .footnote)
        hint.adjustsFontForContentSizeCategory = true
        hint.textColor = palette.inkSoft
        view.addSubview(hint)
        spinner.color = palette.inkSoft
        view.addSubview(spinner)
        spinner.startAnimating()

        loadImage { [weak self] image in
            guard let self = self else { return }
            self.spinner.stopAnimating()
            self.image = image
            self.imageView.image = image
            self.view.setNeedsLayout()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(false, animated: false)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.bounds.inset(by: view.safeAreaInsets)
        let hintWidth = min(safe.width - 32, 520)
        let hintHeight = hint.sizeThatFits(CGSize(width: hintWidth, height: .greatestFiniteMagnitude)).height
        hint.frame = CGRect(x: safe.midX - hintWidth / 2, y: safe.maxY - hintHeight - 10, width: hintWidth,
                            height: hintHeight)
        let area = CGRect(x: safe.minX + 24, y: safe.minY + 20, width: safe.width - 48,
                          height: hint.frame.minY - safe.minY - 36)
        spinner.center = CGPoint(x: area.midX, y: area.midY)
        guard let image = image, image.size.width > 0, image.size.height > 0, area.width > 0, area.height > 0 else {
            frameView.isHidden = true
            return
        }
        let scale = min(area.width / image.size.width, area.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let frame = CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width,
                           height: size.height)
        imageView.frame = frame
        frameView.frame = frame
        frameView.isHidden = false
    }

    /// Självtestet och Föreslå: ramen som syns.
    func setCrop(_ crop: PageCrop) {
        self.crop = crop.clamped()
        frameView.crop = self.crop.rect
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc func doneTapped() {
        let result = crop.clamped()
        dismiss(animated: true)
        if result.isFull {
            onFullPage?()
        } else {
            onSave?(result)
        }
    }

    @objc private func fullTapped() {
        setCrop(.full)
    }

    @objc private func suggestTapped() {
        guard let image = image else { return }
        spinner.startAnimating()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let suggestion = PageCropSuggestion.suggest(from: image)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.spinner.stopAnimating()
                if let suggestion = suggestion {
                    self.setCrop(suggestion)
                } else {
                    self.hint.text = "Hittade ingen tydlig marginal att ta bort. Dra ramen för hand."
                    self.view.setNeedsLayout()
                }
            }
        }
    }

    /// Självtestet: förslaget för sidan som visas, räknat på samma sätt som Föreslå.
    func suggestion() -> PageCrop? {
        image.flatMap { PageCropSuggestion.suggest(from: $0) }
    }

    var hasImage: Bool {
        image != nil
    }
}

/// Ramen i rutan: mörkare utanför, en linje runt och hörn att dra i.
private final class CropFrameView: UIView {

    /// Ramen som andelar av vyn.
    var crop = CGRect(x: 0, y: 0, width: 1, height: 1) {
        didSet {
            setNeedsLayout()
        }
    }
    var onChange: ((CGRect) -> Void)?

    private let dim = CAShapeLayer()
    private let border = CAShapeLayer()
    private let corners = CAShapeLayer()
    private var grab: Grab?
    private var startCrop = CGRect.zero
    private var startPoint = CGPoint.zero

    private struct Grab {
        var left = false
        var right = false
        var top = false
        var bottom = false

        var moves: Bool {
            !left && !right && !top && !bottom
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let palette = Theme.current
        dim.fillRule = .evenOdd
        dim.fillColor = palette.ink.withAlphaComponent(0.45).cgColor
        layer.addSublayer(dim)
        border.fillColor = nil
        border.strokeColor = palette.ink.cgColor
        border.lineWidth = 1.5
        layer.addSublayer(border)
        corners.fillColor = nil
        corners.strokeColor = palette.ink.cgColor
        corners.lineWidth = 5
        corners.lineCap = .round
        layer.addSublayer(corners)
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan(_:))))
        isAccessibilityElement = true
        accessibilityLabel = "Ram"
        accessibilityHint = "Dra i hörnen och kanterna för att ändra ramen"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    private var shown: CGRect {
        CGRect(x: crop.minX * bounds.width, y: crop.minY * bounds.height,
               width: crop.width * bounds.width, height: crop.height * bounds.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let rect = shown
        let outside = UIBezierPath(rect: bounds.insetBy(dx: -1, dy: -1))
        outside.append(UIBezierPath(rect: rect))
        dim.path = outside.cgPath
        border.path = UIBezierPath(rect: rect).cgPath
        let arm = min(22, rect.width / 3, rect.height / 3)
        let path = UIBezierPath()
        let specs: [(CGPoint, CGFloat, CGFloat)] = [(CGPoint(x: rect.minX, y: rect.minY), 1, 1),
                                                    (CGPoint(x: rect.maxX, y: rect.minY), -1, 1),
                                                    (CGPoint(x: rect.minX, y: rect.maxY), 1, -1),
                                                    (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1)]
        for (corner, dx, dy) in specs {
            path.move(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
        }
        corners.path = path.cgPath
        CATransaction.commit()
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // Hörnen går att ta i även en bit utanför sidan.
        bounds.insetBy(dx: -30, dy: -30).contains(point)
    }

    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            grab = grabbing(at: point)
            startCrop = crop
            startPoint = point
        case .changed:
            guard let grab = grab, bounds.width > 0, bounds.height > 0 else { return }
            let dx = (point.x - startPoint.x) / bounds.width
            let dy = (point.y - startPoint.y) / bounds.height
            crop = adjusted(startCrop, grab, dx: dx, dy: dy)
            onChange?(crop)
        default:
            grab = nil
        }
    }

    private func grabbing(at point: CGPoint) -> Grab? {
        let rect = shown
        let reach: CGFloat = 36
        guard point.x > rect.minX - reach, point.x < rect.maxX + reach,
              point.y > rect.minY - reach, point.y < rect.maxY + reach else { return nil }
        var grab = Grab()
        let toLeft = abs(point.x - rect.minX)
        let toRight = abs(point.x - rect.maxX)
        let toTop = abs(point.y - rect.minY)
        let toBottom = abs(point.y - rect.maxY)
        if min(toLeft, toRight) < reach {
            grab.left = toLeft <= toRight
            grab.right = toLeft > toRight
        }
        if min(toTop, toBottom) < reach {
            grab.top = toTop <= toBottom
            grab.bottom = toTop > toBottom
        }
        if grab.moves, !rect.contains(point) {
            return nil
        }
        return grab
    }

    private func adjusted(_ start: CGRect, _ grab: Grab, dx: CGFloat, dy: CGFloat) -> CGRect {
        if grab.moves {
            let x = min(max(start.minX + dx, 0), 1 - start.width)
            let y = min(max(start.minY + dy, 0), 1 - start.height)
            return CGRect(x: x, y: y, width: start.width, height: start.height)
        }
        let side = PageCrop.minimumSide
        var minX = start.minX
        var maxX = start.maxX
        var minY = start.minY
        var maxY = start.maxY
        if grab.left {
            minX = min(max(start.minX + dx, 0), maxX - side)
        }
        if grab.right {
            maxX = max(min(start.maxX + dx, 1), minX + side)
        }
        if grab.top {
            minY = min(max(start.minY + dy, 0), maxY - side)
        }
        if grab.bottom {
            maxY = max(min(start.maxY + dy, 1), minY + side)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

// MARK: P4 Texten bredvid PDF:en

/// P4: txt-filen från OCR-flödet ligger bredvid PDF:en med samma namn (Bok.pdf och Bok.txt). Kopplingen görs
/// bara med filnamnet. Txt-filen visas då inte som en egen bok i biblioteket, och läsarna får en knapp i Mer
/// som byter mellan sidbilden och texten.
enum PDFTextCompanion {

    /// Txt-filen bredvid en PDF, om den finns.
    static func textURL(forPDF url: URL) -> URL? {
        guard url.pathExtension.lowercased() == "pdf" else { return nil }
        return sibling(of: url, extensions: ["txt", "TXT"])
    }

    /// PDF:en bredvid en txt-fil, om den finns.
    static func pdfURL(forText url: URL) -> URL? {
        guard url.pathExtension.lowercased() == "txt" else { return nil }
        return sibling(of: url, extensions: ["pdf", "PDF"])
    }

    private static func sibling(of url: URL, extensions: [String]) -> URL? {
        let base = url.deletingPathExtension()
        for ext in extensions {
            let candidate = base.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Txt-böckerna som hör till en PDF i listan (samma sökväg i Böcker utom filändelsen).
    static func companionTextIDs(in books: [Book]) -> Set<String> {
        let pdfs = Set(books.filter { $0.kind == .pdf }.map { stem($0.path) })
        guard !pdfs.isEmpty else { return [] }
        return Set(books.filter { $0.url.pathExtension.lowercased() == "txt" && pdfs.contains(stem($0.path)) }.map(\.id))
    }

    /// Biblioteket utan de txt-filer som hör till en PDF.
    static func withoutCompanions(_ books: [Book]) -> [Book] {
        let hidden = companionTextIDs(in: books)
        return hidden.isEmpty ? books : books.filter { !hidden.contains($0.id) }
    }

    private static func stem(_ path: String) -> String {
        (path as NSString).deletingPathExtension.lowercased()
    }

    /// Byter läsaren mot en annan för samma bok (sidbilden eller texten), på samma plats i navigeringen.
    @MainActor
    static func replace(_ current: UIViewController, with next: UIViewController) {
        guard let navigation = current.navigationController else { return }
        var stack = navigation.viewControllers
        if let index = stack.firstIndex(of: current) {
            stack[index] = next
        } else {
            stack.append(next)
        }
        UIView.transition(with: navigation.view, duration: 0.25, options: [.transitionCrossDissolve], animations: {
            navigation.setViewControllers(stack, animated: false)
        })
    }
}

/// P4: txt-filen från Edvins OCR-flöde (`ocr_spalter.py` och `ocr_pdf.py` i Reta 30): en rad
/// "--- boksida 222 ---" (eller "--- sida 3 ---", "--- titelsida ---") före varje sida i PDF:en, i samma ordning.
/// Sida n i filen är därför PDF:ens sida n, oavsett numret i rubriken.
enum OCRPagedText {

    struct Page: Equatable {
        /// Etiketten i filen: "boksida 222", "sida 3" eller "titelsida".
        let label: String
        let text: String

        /// Rubriken i läsaren: "Sida 222", "Sida 3" eller "Titelsida".
        var heading: String {
            let words = label.split(separator: " ")
            if words.count == 2, ["boksida", "sida"].contains(words[0].lowercased()) {
                return "Sida \(words[1])"
            }
            return label.prefix(1).uppercased() + label.dropFirst()
        }
    }

    /// Etiketten om raden är en sidrubrik, annars nil.
    static func marker(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 8, trimmed.hasPrefix("--- "), trimmed.hasSuffix(" ---") else { return nil }
        let label = trimmed.dropFirst(4).dropLast(4).trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty, label.count <= 40, !label.contains("---") else { return nil }
        return label
    }

    /// Sidorna, eller nil om filen inte börjar med en sidrubrik.
    static func parse(_ text: String) -> [Page]? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        guard let first = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              marker(first) != nil else { return nil }
        var pages: [Page] = []
        var label: String?
        var body: [String] = []
        for line in lines {
            if let found = marker(line) {
                if let current = label {
                    pages.append(Page(label: current, text: body.joined(separator: "\n")))
                }
                label = found
                body = []
            } else if label != nil {
                body.append(line)
            }
        }
        if let current = label {
            pages.append(Page(label: current, text: body.joined(separator: "\n")))
        }
        return pages.isEmpty ? nil : pages
    }

    /// Hur många sidor filen har, utan att texten görs om (till bytet från sidbilden).
    static func pageCount(at url: URL) -> Int? {
        guard let text = try? TextBookConverter.readText(url), let pages = parse(text) else { return nil }
        return pages.count
    }

    /// Styckena på en sida. Tomma rader skiljer stycken, raderna i ett stycke slås ihop och ett ord som är
    /// avstavat i radslutet ("reto-" och "riken") blir helt igen.
    static func paragraphs(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                result.append(trimmed)
            }
            current = ""
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if current.isEmpty {
                current = line
            } else if current.hasSuffix("-"), current.dropLast().last?.isLetter == true,
                      line.first?.isLowercase == true {
                current = String(current.dropLast()) + line
            } else {
                current += " " + line
            }
        }
        flush()
        return result
    }
}

extension TextBookConverter {

    /// P4: en txt-fil från OCR-flödet bredvid sin PDF blir ett kapitel per sida i PDF:en, med sidans nummer
    /// överst. Kapitel n är då PDF:ens sida n, så att bytet mellan sidbilden och texten hamnar på samma sida.
    /// Rubriker inne på sidan (versaler) delar aldrig sidan.
    static func openPaged(_ book: Book, pages: [OCRPagedText.Page], text: String, directory: URL,
                          identifier: String) throws -> ReflowableBook {
        let language = languageCode(for: text)
        var chapters: [ReflowableBook.Chapter] = []
        var toc: [ReflowableBook.TOCEntry] = []
        for (index, page) in pages.enumerated() {
            var body = pageNumberStyle + "<h2 class=\"lasa-boksida\">\(escape(page.heading))</h2>\n"
            var length = page.heading.count
            for paragraph in OCRPagedText.paragraphs(page.text) {
                body += "<p>\(escape(paragraph))</p>\n"
                length += paragraph.count
            }
            let url = directory.appendingPathComponent(String(format: "sida-%04d.html", index + 1))
            try self.page(title: book.title, language: language, body: body).write(to: url, atomically: true,
                                                                                    encoding: .utf8)
            chapters.append(ReflowableBook.Chapter(url: url, weight: max(length, 1), title: page.heading))
            toc.append(ReflowableBook.TOCEntry(title: page.heading, level: 0, chapter: index, fragment: nil))
        }
        guard !chapters.isEmpty else { throw BookError.empty }
        return ReflowableBook(title: book.title,
                              identifier: identifier,
                              rootDirectory: directory,
                              chapters: chapters,
                              toc: toc,
                              isPlainText: true)
    }

    /// Sidans nummer i marginalen där sidan börjar: liten, grå och till höger, som en marginalanteckning.
    private static let pageNumberStyle = """
        <style>
        h2.lasa-boksida { font-family: -apple-system, "Helvetica Neue", sans-serif; font-size: 0.7em; \
        font-weight: 600; letter-spacing: 0.06em; text-transform: uppercase; text-align: right; opacity: 0.55; \
        margin: 0 0 1em 0; }
        </style>

        """
}
