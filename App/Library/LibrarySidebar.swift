import UIKit

/// Vad biblioteket visar: alla böcker, Läser nu eller en kurs (B3).
enum LibraryScope: Equatable {
    case all
    case reading
    case course(String)
}

/// Sidopanelen (B3) som i Filer och Anteckningar: Alla böcker, Läser nu, kurserna med Ny kurs, och Ord med
/// Repetera (antalet ord som väntar) och Sparade ord. Ligger fast till vänster i liggande på iPad, och visas
/// som en ruta från knappen uppe till vänster annars.
final class LibrarySidebarViewController: UIViewController, UICollectionViewDelegate {

    enum Item: Hashable {
        case all, reading, course(String), newCourse, review, savedWords, aboutDictionary
    }

    struct Counts: Equatable {
        var all = 0
        var reading = 0
        var courses: [String: Int] = [:]
        var review = 0
        var saved = 0
    }

    var onSelectScope: ((LibraryScope) -> Void)?
    var onReview: (() -> Void)?
    var onSavedWords: (() -> Void)?
    var onAboutDictionary: (() -> Void)?
    var onNewCourse: (() -> Void)?
    /// Hållmenyn på en kurs: Byt namn, Färg och Ta bort.
    var courseMenu: ((Course) -> UIMenu?)?

    private(set) var courses: [Course] = []
    private(set) var counts = Counts()
    private(set) var selected: LibraryScope = .all
    private var sections: [(title: String?, items: [Item])] = []
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!

    override func viewDidLoad() {
        super.viewDidLoad()
        var configuration = UICollectionLayoutListConfiguration(appearance: .sidebar)
        configuration.headerMode = .supplementary
        configuration.showsSeparators = false
        configuration.backgroundColor = .clear
        let layout = UICollectionViewCompositionalLayout.list(using: configuration)
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        view.addSubview(collectionView)

        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            self?.configure(cell, item)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.sidebarHeader()
            content.text = self?.sections[safe: indexPath.section]?.title
            content.textProperties.color = Theme.current.inkSoft
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource<Int, Item>(collectionView: collectionView) { view, indexPath, item in
            view.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
        }
        dataSource.supplementaryViewProvider = { view, _, indexPath in
            view.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
        applyTheme()
        apply()
    }

    func applyTheme() {
        guard isViewLoaded else { return }
        view.backgroundColor = Theme.current.surfaceSunk
        if dataSource != nil {
            var snapshot = dataSource.snapshot()
            snapshot.reloadItems(snapshot.itemIdentifiers)
            dataSource.apply(snapshot, animatingDifferences: false)
        }
    }

    /// Nya kurser, antal och vald rad.
    func update(courses: [Course], counts: Counts, selected: LibraryScope) {
        let changed = courses != self.courses || counts != self.counts || selected != self.selected
        self.courses = courses
        self.counts = counts
        self.selected = selected
        guard isViewLoaded, changed else { return }
        apply()
    }

    private func apply() {
        sections = [
            (nil, [.all, .reading]),
            ("Kurser", courses.map { .course($0.id) } + [.newCourse]),
            ("Ord", [.review, .savedWords, .aboutDictionary]),
        ]
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        for (index, section) in sections.enumerated() {
            snapshot.appendSections([index])
            snapshot.appendItems(section.items, toSection: index)
        }
        snapshot.reloadItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
        let item: Item
        switch selected {
        case .all: item = .all
        case .reading: item = .reading
        case .course(let id): item = .course(id)
        }
        if let indexPath = dataSource.indexPath(for: item) {
            collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
        }
    }

    private func configure(_ cell: UICollectionViewListCell, _ item: Item) {
        let palette = Theme.current
        var content = UIListContentConfiguration.sidebarCell()
        var count: Int?
        var accessories: [UICellAccessory] = []
        switch item {
        case .all:
            content.text = "Alla böcker"
            content.image = UIImage(systemName: "books.vertical")
            count = counts.all
        case .reading:
            content.text = "Läser nu"
            content.image = UIImage(systemName: "book")
            count = counts.reading
        case .course(let id):
            let course = courses.first { $0.id == id }
            content.text = course?.name ?? ""
            if let tint = course?.tint {
                content.image = UIImage(systemName: "circle.fill")
                content.imageProperties.tintColor = tint
            } else {
                content.image = UIImage(systemName: "graduationcap")
            }
            count = counts.courses[id] ?? 0
        case .newCourse:
            content.text = "Ny kurs"
            content.image = UIImage(systemName: "plus")
            content.textProperties.color = palette.accent
        case .review:
            content.text = "Repetera"
            content.image = UIImage(systemName: "rectangle.stack")
            if counts.review > 0 {
                let badge = PaddedLabel()
                badge.insets = UIEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)
                badge.text = "\(counts.review)"
                badge.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
                badge.textColor = palette.surface
                badge.backgroundColor = palette.ribbon
                badge.layer.cornerRadius = 11
                badge.layer.masksToBounds = true
                badge.accessibilityLabel = "\(counts.review) ord väntar"
                badge.sizeToFit()
                accessories.append(.customView(configuration: .init(customView: badge, placement: .trailing())))
            }
        case .savedWords:
            content.text = "Sparade ord"
            content.image = UIImage(systemName: "bookmark")
            count = counts.saved
        case .aboutDictionary:
            content.text = "Om ordboken"
            content.image = UIImage(systemName: "info.circle")
        }
        if case .newCourse = item {} else {
            content.textProperties.color = palette.ink
        }
        if content.imageProperties.tintColor == nil {
            content.imageProperties.tintColor = palette.accent
        }
        if let count = count {
            accessories.append(.label(text: "\(count)", options: .init(tintColor: palette.inkSoft)))
        }
        cell.contentConfiguration = content
        cell.accessories = accessories
        cell.configurationUpdateHandler = { cell, state in
            var background = UIBackgroundConfiguration.listSidebarCell().updated(for: state)
            background.backgroundColor = state.isSelected || state.isHighlighted ? palette.accentSoft : .clear
            background.cornerRadius = 10
            cell.backgroundConfiguration = background
        }
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return false }
        switch item {
        case .all, .reading, .course:
            return true
        case .newCourse:
            onNewCourse?()
        case .review:
            onReview?()
        case .savedWords:
            onSavedWords?()
        case .aboutDictionary:
            onAboutDictionary?()
        }
        return false
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .all: selected = .all
        case .reading: selected = .reading
        case .course(let id): selected = .course(id)
        default: return
        }
        onSelectScope?(selected)
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath,
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard case .course(let id) = dataSource.itemIdentifier(for: indexPath),
              let course = courses.first(where: { $0.id == id }) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.courseMenu?(course)
        }
    }

    /// Raderna som text, till självtestet.
    var rowsForSelfTest: [String] {
        sections.flatMap { section in
            section.items.map { item -> String in
                switch item {
                case .all: return "Alla böcker \(counts.all)"
                case .reading: return "Läser nu \(counts.reading)"
                case .course(let id):
                    return "\(courses.first { $0.id == id }?.name ?? "?") \(counts.courses[id] ?? 0)"
                case .newCourse: return "Ny kurs"
                case .review: return "Repetera \(counts.review)"
                case .savedWords: return "Sparade ord \(counts.saved)"
                case .aboutDictionary: return "Om ordboken"
                }
            }
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
