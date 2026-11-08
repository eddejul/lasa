import PDFKit
import UIKit

/// Ett blad i pappersvikningen. Visar en färdigritad bild av en PDF-sida, eller ett tomt blad.
///
/// Bilden kommer från renderaren. Är den inte ritad än visas papperet tills den är klar,
/// så att huvudtråden aldrig ritar under en vikning.
final class PDFPageViewController: UIViewController {

    /// Var bladet sitter: ensamt (stående) eller som vänster eller höger sida i ett uppslag.
    enum Side {
        case single, left, right
    }

    /// Marginal runt sidan, i punkter.
    static let margin: CGFloat = 12

    /// Sidans plats i PDF:en. Ett index utanför boken är ett tomt blad, till exempel före omslaget i ett uppslag.
    let pageIndex: Int
    let side: Side

    private let renderer: PDFPageRenderer
    private let imageView = UIImageView()
    private let spineShade = CAGradientLayer()
    private var highlightViews: [UIView] = []
    private var paperColor: UIColor
    private var contentInsets: UIEdgeInsets

    /// En markering på sidan (fas 4). Rutorna är i sidans koordinater.
    struct Mark {
        let id: String
        let rects: [CGRect]
        let color: HighlightColor
        let hasNote: Bool
    }

    /// Sidan i läsarens dokument, för att räkna om markeringarnas rutor. Används bara på huvudtråden.
    var pdfPage: PDFPage?
    var isBookmarked = false {
        didSet {
            guard isBookmarked != oldValue else { return }
            overlaysDirty = true
            if isViewLoaded {
                view.setNeedsLayout()
            }
        }
    }
    private var marks: [Mark] = []
    private var darkMarks = false
    private let marksView = UIView()
    private let ribbon = UIImageView(image: UIImage(systemName: "bookmark.fill"))
    private var previewViews: [UIView] = []
    private var flashRects: [CGRect] = []
    private var flashViews: [UIView] = []
    private var overlaysDirty = true
    private var overlayFrame: CGRect = .null

    init(pageIndex: Int,
         side: Side,
         renderer: PDFPageRenderer,
         paperColor: UIColor,
         contentInsets: UIEdgeInsets) {
        self.pageIndex = pageIndex
        self.side = side
        self.renderer = renderer
        self.paperColor = paperColor
        self.contentInsets = contentInsets
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    var isBlank: Bool {
        pageIndex < 0 || pageIndex >= renderer.pageCount
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = paperColor
        imageView.contentMode = .scaleToFill
        view.addSubview(imageView)
        marksView.isUserInteractionEnabled = false
        view.addSubview(marksView)
        ribbon.tintColor = .systemRed
        ribbon.contentMode = .scaleAspectFit
        ribbon.isHidden = true
        ribbon.isAccessibilityElement = true
        ribbon.accessibilityLabel = "Bokmärke"
        view.addSubview(ribbon)

        if side != .single {
            // Svag skugga mot ryggen, som i en riktig bok.
            spineShade.colors = [UIColor(white: 0, alpha: 0.12).cgColor, UIColor(white: 0, alpha: 0).cgColor]
            spineShade.startPoint = CGPoint(x: side == .left ? 1 : 0, y: 0.5)
            spineShade.endPoint = CGPoint(x: side == .left ? 0 : 1, y: 0.5)
            view.layer.addSublayer(spineShade)
        }
        loadImage()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutImage()
        layoutOverlays()
    }

    /// Var sidbilden ligger i bladet. Nil när bilden inte är ritad än, då går det inte att slå upp ord.
    var imageFrame: CGRect? {
        guard isViewLoaded, !isBlank, imageView.image != nil else { return nil }
        return imageView.frame
    }

    /// Markerar ett ord som slås upp. Rutorna är i bladets koordinater.
    func showHighlight(_ rects: [CGRect]) {
        clearHighlight()
        for rect in rects {
            let highlight = UIView(frame: rect.insetBy(dx: -2, dy: -1))
            highlight.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.35)
            highlight.layer.cornerRadius = 3
            highlight.isUserInteractionEnabled = false
            view.addSubview(highlight)
            highlightViews.append(highlight)
        }
    }

    func clearHighlight() {
        highlightViews.forEach { $0.removeFromSuperview() }
        highlightViews.removeAll()
    }

    // MARK: Markeringar och bokmärke (fas 4)

    func setMarks(_ marks: [Mark], dark: Bool) {
        self.marks = marks
        darkMarks = dark
        overlaysDirty = true
        if isViewLoaded {
            view.setNeedsLayout()
        }
    }

    /// En ruta i sidans koordinater omräknad till bladet, när sidbilden finns.
    func viewRect(forPageRect rect: CGRect) -> CGRect? {
        guard let frame = imageFrame, let page = pdfPage else { return nil }
        return PDFPageGeometry.viewRect(for: rect, imageFrame: frame, page: page)
    }

    /// Markeringen under en punkt i bladet.
    /// Rutorna för en markering på sidan, i sidvyns koordinater (U5: markeringsraden pekar på dem).
    func markRects(id: String) -> [CGRect] {
        marks.filter { $0.id == id }.flatMap { $0.rects }.compactMap { viewRect(forPageRect: $0) }
    }

    func markID(at point: CGPoint) -> String? {
        for mark in marks.reversed() {
            for rect in mark.rects {
                if let shown = viewRect(forPageRect: rect), shown.insetBy(dx: -4, dy: -4).contains(point) {
                    return mark.id
                }
            }
        }
        return nil
    }

    /// Visar vad som markeras medan fingret drar. Rutorna är i sidans koordinater.
    func showPreview(_ rects: [CGRect], color: HighlightColor) {
        clearPreview()
        for rect in rects {
            guard let shown = viewRect(forPageRect: rect) else { continue }
            let preview = UIView(frame: shown.insetBy(dx: -1.5, dy: -1))
            preview.backgroundColor = color.overlay(dark: darkMarks).withAlphaComponent(0.5)
            preview.layer.cornerRadius = 2
            preview.isUserInteractionEnabled = false
            view.addSubview(preview)
            previewViews.append(preview)
        }
    }

    func clearPreview() {
        previewViews.forEach { $0.removeFromSuperview() }
        previewViews.removeAll()
    }

    /// Visar en sökträff eller en markering man hoppat till en kort stund. Rutorna är i sidans koordinater.
    func flash(_ rects: [CGRect]) {
        flashRects = rects
        overlaysDirty = true
        if isViewLoaded {
            view.setNeedsLayout()
        }
    }

    private func layoutOverlays() {
        let frame = imageFrame ?? .null
        guard overlaysDirty || frame != overlayFrame else { return }
        overlaysDirty = false
        overlayFrame = frame
        marksView.frame = view.bounds
        marksView.subviews.forEach { $0.removeFromSuperview() }
        guard !frame.isNull, let page = pdfPage else {
            ribbon.isHidden = true
            return
        }
        for mark in marks {
            for rect in mark.rects {
                let shown = PDFPageGeometry.viewRect(for: rect, imageFrame: frame, page: page)
                let fill = UIView(frame: shown.insetBy(dx: -1.5, dy: -1))
                fill.backgroundColor = mark.color.overlay(dark: darkMarks)
                fill.layer.cornerRadius = 2
                marksView.addSubview(fill)
                if mark.hasNote {
                    let line = UIView(frame: CGRect(x: shown.minX, y: shown.maxY + 0.5, width: shown.width, height: 2))
                    line.backgroundColor = mark.color.solid
                    marksView.addSubview(line)
                }
            }
        }
        ribbon.isHidden = !isBookmarked
        ribbon.frame = CGRect(x: frame.maxX - 34, y: frame.minY - 3, width: 20, height: 30)

        if !flashRects.isEmpty {
            let rects = flashRects
            flashRects = []
            flashViews.forEach { $0.removeFromSuperview() }
            flashViews = rects.map { rect in
                let shown = PDFPageGeometry.viewRect(for: rect, imageFrame: frame, page: page).insetBy(dx: -3, dy: -2)
                let box = UIView(frame: shown)
                box.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.25)
                box.layer.borderColor = UIColor.systemOrange.cgColor
                box.layer.borderWidth = 2
                box.layer.cornerRadius = 4
                box.isUserInteractionEnabled = false
                view.addSubview(box)
                return box
            }
            let boxes = flashViews
            UIView.animate(withDuration: 0.6, delay: 2.2, options: [.allowUserInteraction]) {
                boxes.forEach { $0.alpha = 0 }
            } completion: { _ in
                boxes.forEach { $0.removeFromSuperview() }
            }
        }
    }

    /// Nytt tema eller ny storlek. Den gamla bilden visas tills den nya är ritad.
    func apply(paperColor: UIColor, contentInsets: UIEdgeInsets) {
        self.paperColor = paperColor
        self.contentInsets = contentInsets
        guard isViewLoaded else { return }
        view.backgroundColor = paperColor
        loadImage()
        view.setNeedsLayout()
    }

    private func loadImage() {
        guard !isBlank else {
            imageView.image = nil
            return
        }
        if let image = renderer.cachedImage(for: pageIndex) {
            imageView.image = image
            view.setNeedsLayout()
            return
        }
        let index = pageIndex
        renderer.requestImage(for: index, completion: { [weak self] image in
            guard let self = self, self.pageIndex == index else { return }
            self.imageView.image = image
            self.setFailureShown(false)
            self.view.setNeedsLayout()
        }, failure: { [weak self] in
            // Renderaren har redan försökt två gånger. Står en äldre bild kvar (efter byte av tema) får den stå kvar.
            guard let self = self, self.pageIndex == index, self.imageView.image == nil else { return }
            self.setFailureShown(true)
        })
    }

    /// Texten som visas på en sida som inte kunde ritas.
    private var failureLabel: UILabel?

    var showsFailure: Bool {
        failureLabel != nil
    }

    private func setFailureShown(_ shown: Bool) {
        guard shown != showsFailure else { return }
        if !shown {
            failureLabel?.removeFromSuperview()
            failureLabel = nil
            return
        }
        let label = UILabel()
        label.text = "Sidan kunde inte visas.\nBläddra bort och tillbaka för att försöka igen."
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .callout)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.isUserInteractionEnabled = false
        view.addSubview(label)
        failureLabel = label
        view.setNeedsLayout()
    }

    /// Ytan som sidan får. Den beror bara på vyns storlek och läsarens fasta marginaler,
    /// aldrig på om menyraden eller statusfältet syns, så sidan står still när menyn visas.
    private func pageArea() -> CGRect {
        let bounds = view.bounds
        let margin = Self.margin
        let top = contentInsets.top + margin
        let height = bounds.height - contentInsets.top - contentInsets.bottom - margin * 2
        switch side {
        case .single:
            return CGRect(x: contentInsets.left + margin,
                          y: top,
                          width: bounds.width - contentInsets.left - contentInsets.right - margin * 2,
                          height: height)
        case .left:
            return CGRect(x: contentInsets.left + margin,
                          y: top,
                          width: bounds.width - contentInsets.left - margin,
                          height: height)
        case .right:
            return CGRect(x: 0,
                          y: top,
                          width: bounds.width - contentInsets.right - margin,
                          height: height)
        }
    }

    private func layoutImage() {
        let bounds = view.bounds
        let area = pageArea()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let shadeWidth: CGFloat = 28
        spineShade.frame = CGRect(x: side == .left ? bounds.width - shadeWidth : 0,
                                  y: 0,
                                  width: shadeWidth,
                                  height: bounds.height)
        CATransaction.commit()

        if let label = failureLabel, area.width > 0 {
            let width = min(area.width - 32, 420)
            let height = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            label.frame = CGRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
        }

        guard area.width > 0, area.height > 0,
              let image = imageView.image,
              image.size.width > 0, image.size.height > 0 else {
            imageView.frame = area.width > 0 && area.height > 0 ? area : bounds
            return
        }

        // Sidan i rätt proportioner. I ett uppslag ligger sidorna an mot ryggen.
        let ratio = min(area.width / image.size.width, area.height / image.size.height)
        let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let x: CGFloat
        switch side {
        case .single: x = area.midX - size.width / 2
        case .left: x = area.maxX - size.width
        case .right: x = area.minX
        }
        imageView.frame = CGRect(x: x, y: area.midY - size.height / 2, width: size.width, height: size.height)
    }
}
