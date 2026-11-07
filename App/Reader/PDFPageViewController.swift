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
    private var paperColor: UIColor
    private var contentInsets: UIEdgeInsets

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
        renderer.requestImage(for: index) { [weak self] image in
            guard let self = self, self.pageIndex == index else { return }
            self.imageView.image = image
            self.view.setNeedsLayout()
        }
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
