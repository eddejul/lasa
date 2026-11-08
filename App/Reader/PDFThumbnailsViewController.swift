import UIKit

/// V3: bläddra i miniatyrer utan att tappa platsen. Ett rutnät med små sidbilder, cirka 150 punkter breda.
/// Bara celler som syns får en bild: den ritas på renderingskön med lägsta prioritet, och en cell som rullas
/// ur bild avbryter sin ritning. Några färdiga bilder sparas i en liten cache (iPad Air 2 har 2 GB RAM).
/// Ett tryck på en sida stänger rutnätet och läsaren hoppar dit, med Tillbaka till sidan man var på.
final class PDFThumbnailsViewController: UIViewController {

    static let thumbnailWidth: CGFloat = 150

    /// Sidan man trycker på, från 0.
    var onSelect: ((Int) -> Void)?

    private let renderer: PDFPageRenderer
    private let pageCount: Int
    private let currentIndex: Int
    private let pageLabel: (Int) -> String
    /// Sidornas höjd delad med bredden, ur första sidan. Rutnätet har samma höjd på alla celler.
    private let aspect: CGFloat
    private let cache = NSCache<NSNumber, UIImage>()
    private var collectionView: UICollectionView!
    private let openedAt = CACurrentMediaTime()
    private var loggedFull = false
    /// Hur många miniatyrer som ritats och hur lång tid det tog tills alla synliga fanns (till självtestet).
    private(set) var drawn = 0
    private(set) var fullAfterMilliseconds: Int?

    init(renderer: PDFPageRenderer, pageCount: Int, currentIndex: Int, aspect: CGFloat, pageLabel: @escaping (Int) -> String) {
        self.renderer = renderer
        self.pageCount = pageCount
        self.currentIndex = currentIndex
        self.aspect = min(max(aspect, 0.5), 2)
        self.pageLabel = pageLabel
        super.init(nibName: nil, bundle: nil)
        title = "Sidor"
        // Ungefär 30 miniatyrer på 150 punkter.
        cache.totalCostLimit = 16 * 1_048_576
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let palette = Theme.current
        view.backgroundColor = palette.canvas
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self,
                                                            action: #selector(close))

        let layout = UICollectionViewFlowLayout()
        let width = Self.thumbnailWidth
        layout.itemSize = CGSize(width: width, height: (width * aspect).rounded() + 24)
        layout.minimumInteritemSpacing = 16
        layout.minimumLineSpacing = 20
        layout.sectionInset = UIEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = palette.canvas
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(ThumbnailCell.self, forCellWithReuseIdentifier: ThumbnailCell.reuseID)
        view.addSubview(collectionView)

        NotificationCenter.default.addObserver(self, selector: #selector(memoryWarning),
                                               name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    }

    private var scrolledToCurrent = false

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !scrolledToCurrent, collectionView.bounds.width > 0, currentIndex < pageCount else { return }
        scrolledToCurrent = true
        collectionView.layoutIfNeeded()
        collectionView.scrollToItem(at: IndexPath(item: currentIndex, section: 0), at: .centeredVertically, animated: false)
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    @objc private func memoryWarning() {
        cache.removeAllObjects()
    }

    /// Antalet celler som syns och hur många av dem som har sin bild (till självtestet).
    var visibleState: (visible: Int, withImage: Int) {
        let cells = collectionView?.visibleCells.compactMap { $0 as? ThumbnailCell } ?? []
        return (cells.count, cells.filter { $0.hasImage }.count)
    }

    fileprivate func load(_ cell: ThumbnailCell, index: Int) {
        if let image = cache.object(forKey: NSNumber(value: index)) {
            cell.show(image)
            return
        }
        let scale = view.window?.screen.scale ?? UIScreen.main.scale
        cell.operation = renderer.thumbnail(for: index, width: Self.thumbnailWidth, scale: scale) { [weak self, weak cell] image in
            guard let self = self else { return }
            if let image = image {
                let bytes = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
                self.cache.setObject(image, forKey: NSNumber(value: index), cost: bytes)
                self.drawn += 1
            }
            if let cell = cell, cell.index == index {
                cell.operation = nil
                if let image = image {
                    cell.show(image)
                }
            }
            self.checkFull()
        }
    }

    /// Loggar en gång hur lång tid det tog tills alla synliga miniatyrer fanns (V3).
    private func checkFull() {
        guard !loggedFull else { return }
        let state = visibleState
        guard state.visible > 0, state.visible == state.withImage else { return }
        loggedFull = true
        let milliseconds = Int(((CACurrentMediaTime() - openedAt) * 1000).rounded())
        fullAfterMilliseconds = milliseconds
        AppLog.shared.write("Miniatyrer: \(state.visible) synliga ritade efter \(milliseconds) ms")
    }
}

extension PDFThumbnailsViewController: UICollectionViewDataSource, UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        pageCount
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ThumbnailCell.reuseID, for: indexPath)
        guard let thumbnail = cell as? ThumbnailCell else { return cell }
        thumbnail.configure(index: indexPath.item, label: pageLabel(indexPath.item),
                            isCurrent: indexPath.item == currentIndex, palette: Theme.current)
        return thumbnail
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        guard let thumbnail = cell as? ThumbnailCell, !thumbnail.hasImage else { return }
        load(thumbnail, index: indexPath.item)
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        // Bara synliga celler ritas: en cell som rullats ur bild avbryter sin ritning och släpper bilden.
        (cell as? ThumbnailCell)?.clear()
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        onSelect?(indexPath.item)
    }
}

/// En miniatyr med sidnumret under.
private final class ThumbnailCell: UICollectionViewCell {

    static let reuseID = "miniatyr"

    private let imageView = UIImageView()
    private let label = UILabel()
    private(set) var index = -1
    var operation: Operation?

    var hasImage: Bool {
        imageView.image != nil
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFit
        imageView.layer.borderWidth = 1 / UIScreen.main.scale
        imageView.layer.cornerRadius = 2
        imageView.clipsToBounds = true
        contentView.addSubview(imageView)
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textAlignment = .center
        contentView.addSubview(label)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = contentView.bounds
        imageView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - 24)
        label.frame = CGRect(x: 0, y: bounds.height - 20, width: bounds.width, height: 18)
    }

    func configure(index: Int, label text: String, isCurrent: Bool, palette: Palette) {
        if index != self.index {
            clear()
        }
        self.index = index
        label.text = text
        label.textColor = isCurrent ? palette.accent : palette.inkSoft
        imageView.backgroundColor = palette.page
        imageView.layer.borderColor = (isCurrent ? palette.accent : palette.rule).cgColor
        imageView.layer.borderWidth = isCurrent ? 2 : 1 / UIScreen.main.scale
        accessibilityLabel = isCurrent ? "\(text), här är du" : text
    }

    func show(_ image: UIImage) {
        imageView.image = image
    }

    func clear() {
        operation?.cancel()
        operation = nil
        imageView.image = nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        clear()
    }
}
