import PDFKit
import UIKit

/// Välj omslag (B1): sidorna i en PDF som miniatyrer. Den sida man trycker på blir bokens omslag. Till fotade
/// PDF:er, där första fotot ofta är fult. Miniatyrerna ritas i bakgrunden med ett eget `PDFDocument`, en i taget,
/// och bara för sidor som syns.
final class CoverPageViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate {

    /// Dokumentet används bara på ritkön.
    private final class DocumentBox {
        var document: PDFDocument?
    }

    private let book: Book
    private let selected: Int
    private let onPick: (Int) -> Void
    private var pageCount = 0
    private var collectionView: UICollectionView!
    private let queue = OperationQueue()
    private let box = DocumentBox()
    private let cache = NSCache<NSNumber, UIImage>()
    private var pending: [Int: Operation] = [:]

    init(book: Book, selected: Int, onPick: @escaping (Int) -> Void) {
        self.book = book
        self.selected = selected
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        cache.countLimit = 60
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    deinit {
        queue.cancelAllOperations()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Välj omslag"
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self,
                                                           action: #selector(cancel))
        let palette = Theme.current
        view.backgroundColor = palette.canvas
        let layout = UICollectionViewCompositionalLayout { _, environment in
            let width = environment.container.effectiveContentSize.width
            let columns = max(3, Int((width - 32) / 130))
            let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                                                                  heightDimension: .fractionalHeight(1)))
            let itemWidth = (width - 32 - CGFloat(columns - 1) * 12) / CGFloat(columns)
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                                   heightDimension: .absolute((itemWidth * 1.42).rounded() + 24)),
                subitem: item, count: columns)
            group.interItemSpacing = .fixed(12)
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 16
            section.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 16, bottom: 24, trailing: 16)
            return section
        }
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = palette.canvas
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(PageThumbCell.self, forCellWithReuseIdentifier: PageThumbCell.id)
        view.addSubview(collectionView)

        let url = book.url
        let box = self.box
        queue.addOperation { [weak self] in
            let document = PDFDocument(url: url)
            box.document = document
            let count = document?.pageCount ?? 0
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.pageCount = count
                self.collectionView.reloadData()
                if self.selected > 0, self.selected < count {
                    self.collectionView.scrollToItem(at: IndexPath(item: self.selected, section: 0),
                                                     at: .centeredVertically, animated: false)
                }
            }
        }
    }

    @objc private func cancel() {
        dismiss(animated: true)
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        pageCount
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PageThumbCell.id,
                                                      for: indexPath) as! PageThumbCell
        let index = indexPath.item
        cell.configure(number: index + 1, image: cache.object(forKey: NSNumber(value: index)),
                       selected: index == selected, palette: Theme.current)
        if cache.object(forKey: NSNumber(value: index)) == nil {
            render(index)
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        // Sidor som rullats förbi ritas inte.
        if let operation = pending.removeValue(forKey: indexPath.item) {
            operation.cancel()
        }
    }

    private func render(_ index: Int) {
        guard pending[index] == nil else { return }
        let box = self.box
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard operation?.isCancelled == false, let page = box.document?.page(at: index) else { return }
            let image = autoreleasepool { BookFileReader.pageImage(page, height: 300).map { UIImage(cgImage: $0) } }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.pending[index] = nil
                guard let image = image else { return }
                self.cache.setObject(image, forKey: NSNumber(value: index))
                if let cell = self.collectionView.cellForItem(at: IndexPath(item: index, section: 0)) as? PageThumbCell {
                    cell.configure(number: index + 1, image: image, selected: index == self.selected,
                                   palette: Theme.current)
                }
            }
        }
        pending[index] = operation
        queue.addOperation(operation)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let page = indexPath.item
        dismiss(animated: true) { [onPick] in
            onPick(page)
        }
    }
}

/// En sida i Välj omslag: miniatyren och sidnumret. Den valda sidan har en ram i accentfärgen.
final class PageThumbCell: UICollectionViewCell {

    static let id = "sida"

    private let imageView = UIImageView()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFit
        imageView.layer.cornerRadius = 3
        imageView.clipsToBounds = true
        contentView.addSubview(imageView)
        label.textAlignment = .center
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        contentView.addSubview(label)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    func configure(number: Int, image: UIImage?, selected: Bool, palette: Palette) {
        imageView.image = image
        imageView.backgroundColor = palette.surfaceSunk
        imageView.layer.borderWidth = selected ? 3 : 1
        imageView.layer.borderColor = (selected ? palette.accent : palette.rule).cgColor
        label.text = selected ? "Sida \(number), omslag" : "Sida \(number)"
        label.textColor = selected ? palette.accent : palette.inkSoft
        accessibilityLabel = label.text
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = CGRect(x: 0, y: 0, width: contentView.bounds.width, height: contentView.bounds.height - 22)
        label.frame = CGRect(x: 0, y: contentView.bounds.height - 18, width: contentView.bounds.width, height: 16)
    }
}
