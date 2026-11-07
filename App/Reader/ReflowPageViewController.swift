import UIKit

/// Ett blad i pappersvikningen för EPUB och textfiler: en färdig bild av en sida, eller ett tomt blad
/// (sist i ett kapitel med udda sidantal i ett uppslag). Bilden kommer från renderaren. Tills den är klar
/// visas papperet, så att huvudtråden aldrig ritar under en vikning.
final class ReflowPageViewController: UIViewController {

    enum Side {
        case single, left, right
    }

    let chapter: Int
    /// Bladets plats i kapitlet. Samma som sidan, utom för tomma blad efter kapitlets sista sida.
    let slot: Int
    /// Sidan i kapitlet, eller nil för ett tomt blad.
    let page: Int?
    let side: Side

    /// Sidans storlek i renderaren. Tryck och markeringar räknas om från bladets storlek till den.
    private let pageSize: CGSize
    private weak var renderer: ReflowRenderer?
    private let imageView = UIImageView()
    private let spineShade = CAGradientLayer()
    private var highlightViews: [UIView] = []
    private var paperColor: UIColor
    private(set) var links: [ReflowLink] = []
    private(set) var hasImage = false

    init(chapter: Int,
         slot: Int,
         page: Int?,
         side: Side,
         pageSize: CGSize,
         renderer: ReflowRenderer,
         paperColor: UIColor) {
        self.chapter = chapter
        self.slot = slot
        self.page = page
        self.side = side
        self.pageSize = pageSize
        self.renderer = renderer
        self.paperColor = paperColor
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    var isBlank: Bool {
        page == nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = paperColor
        imageView.contentMode = .scaleToFill
        view.addSubview(imageView)

        if side != .single {
            // Svag skugga mot ryggen, som i en riktig bok.
            spineShade.colors = [UIColor(white: 0, alpha: 0.10).cgColor, UIColor(white: 0, alpha: 0).cgColor]
            spineShade.startPoint = CGPoint(x: side == .left ? 1 : 0, y: 0.5)
            spineShade.endPoint = CGPoint(x: side == .left ? 0 : 1, y: 0.5)
            view.layer.addSublayer(spineShade)
        }
        loadImage()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        imageView.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let shadeWidth: CGFloat = 28
        spineShade.frame = CGRect(x: side == .left ? bounds.width - shadeWidth : 0,
                                  y: 0,
                                  width: shadeWidth,
                                  height: bounds.height)
        CATransaction.commit()
    }

    // MARK: Koordinater

    /// Från en punkt i bladet till sidans koordinater i renderaren.
    func pagePoint(_ point: CGPoint) -> CGPoint {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0, pageSize.width > 0, pageSize.height > 0 else { return point }
        return CGPoint(x: point.x * pageSize.width / bounds.width, y: point.y * pageSize.height / bounds.height)
    }

    /// Från en ruta i sidans koordinater till bladet.
    func viewRect(_ rect: CGRect) -> CGRect {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0, pageSize.width > 0, pageSize.height > 0 else { return rect }
        let sx = bounds.width / pageSize.width
        let sy = bounds.height / pageSize.height
        return CGRect(x: rect.minX * sx, y: rect.minY * sy, width: rect.width * sx, height: rect.height * sy)
    }

    /// Länken under en punkt i bladet, med lite marginal runt små länkar som fotnotsnummer.
    func link(at point: CGPoint) -> ReflowLink? {
        guard hasImage else { return nil }
        let location = pagePoint(point)
        return links.first { $0.rect.insetBy(dx: -8, dy: -6).contains(location) }
    }

    // MARK: Markering

    /// Markerar ett ord som slås upp. Rutorna är i sidans koordinater.
    func showHighlight(_ rects: [CGRect]) {
        clearHighlight()
        for rect in rects {
            let highlight = UIView(frame: viewRect(rect).insetBy(dx: -2, dy: -1))
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

    // MARK: Bilden

    /// Nytt tema. Den gamla bilden visas tills den nya är klar.
    func apply(paperColor: UIColor) {
        self.paperColor = paperColor
        guard isViewLoaded else { return }
        view.backgroundColor = paperColor
        loadImage()
    }

    private func loadImage() {
        guard let page = page, let renderer = renderer else {
            imageView.image = nil
            return
        }
        let address = ReflowPage(chapter: chapter, page: page)
        if let snapshot = renderer.cachedSnapshot(for: address) {
            show(snapshot)
            return
        }
        renderer.requestImage(for: address) { [weak self] snapshot in
            self?.show(snapshot)
        }
    }

    private func show(_ snapshot: ReflowSnapshot) {
        imageView.image = snapshot.image
        links = snapshot.links
        hasImage = true
    }
}
