import UIKit

/// En sida i pappersvikningen. Visar en färdigritad bild av PDF-sidan.
final class PDFPageViewController: UIViewController {

    /// Marginal runt sidan, i punkter.
    static let margin: CGFloat = 12

    /// Storleken sidbilden ritas i. Den beror bara på vyns storlek och inte på menyraden,
    /// så att inget behöver ritas om när menyn visas eller döljs.
    static func renderSize(for bounds: CGSize) -> CGSize {
        CGSize(width: max(bounds.width - margin * 2, 1),
               height: max(bounds.height - margin * 2, 1))
    }

    let pageIndex: Int

    private let renderer: PDFPageRenderer
    private let imageView = UIImageView()
    private var renderedSize: CGSize = .zero
    private var renderedScale: CGFloat = 0

    init(pageIndex: Int, renderer: PDFPageRenderer) {
        self.pageIndex = pageIndex
        self.renderer = renderer
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .white
        view.addSubview(imageView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        imageView.frame = view.bounds
            .inset(by: view.safeAreaInsets)
            .insetBy(dx: Self.margin, dy: Self.margin)

        let size = Self.renderSize(for: view.bounds.size)
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
        if size != renderedSize || scale != renderedScale {
            renderedSize = size
            renderedScale = scale
            imageView.image = renderer.image(for: pageIndex, size: size, scale: scale)
        }
    }
}
