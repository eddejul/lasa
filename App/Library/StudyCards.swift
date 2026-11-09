import UIKit

/// Ett studiekort i biblioteket (avsnittet `study`): Repetera (U6) och Dagens markeringar (K7). Bara antal,
/// aldrig någon tid (Edvins beslut).
enum StudyItem: Equatable {
    /// Orden som väntar i repetitionen, samma antal som Repetera i sidopanelen.
    case review(count: Int)
    /// Markeringarna som väntar i dagens repetition av markeringar.
    case highlights(count: Int)

    var title: String {
        switch self {
        case .review: return "Repetera"
        case .highlights: return "Dagens markeringar"
        }
    }

    var text: String {
        switch self {
        case .review(let count):
            return ReviewLogic.cardText(count)
        case .highlights(let count):
            if count == 0 {
                return "Inga markeringar väntar just nu"
            }
            return count == 1 ? "1 markering att repetera" : "\(count) markeringar att repetera"
        }
    }

    var count: Int {
        switch self {
        case .review(let count), .highlights(let count): return count
        }
    }

    var symbol: String {
        switch self {
        case .review: return "rectangle.stack"
        case .highlights: return "highlighter"
        }
    }
}

/// U6: raden med studiekort i biblioteket. Korten ligger sida vid sida på iPad och under varandra på smal
/// bredd. Ett tryck på ett kort ger `onOpen` med kortet.
final class StudyCardsCell: UICollectionViewCell {

    static let id = "studie"
    static let cardHeight: CGFloat = 88
    static let spacing: CGFloat = 12

    /// Korten sida vid sida från 560 punkters bredd, högst tre i en rad.
    static func columns(width: CGFloat, count: Int) -> Int {
        width < 560 ? 1 : max(1, min(count, 3))
    }

    /// Radens höjd för `count` kort i bredden `width` (utan marginalerna).
    static func height(count: Int, width: CGFloat) -> CGFloat {
        guard count > 0 else { return 1 }
        let columns = columns(width: width, count: count)
        let rows = (count + columns - 1) / columns
        return CGFloat(rows) * cardHeight + CGFloat(rows - 1) * spacing
    }

    var onOpen: ((StudyItem) -> Void)?
    private(set) var items: [StudyItem] = []
    private var cards: [StudyCardView] = []

    func configure(items: [StudyItem], palette: Palette) {
        self.items = items
        while cards.count < items.count {
            let card = StudyCardView()
            card.addTarget(self, action: #selector(cardTapped(_:)), for: .touchUpInside)
            contentView.addSubview(card)
            cards.append(card)
        }
        for (index, card) in cards.enumerated() {
            card.isHidden = index >= items.count
            if index < items.count {
                card.tag = index
                card.configure(items[index], palette: palette)
            }
        }
        setNeedsLayout()
    }

    @objc private func cardTapped(_ card: StudyCardView) {
        guard card.tag < items.count else { return }
        onOpen?(items[card.tag])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = contentView.bounds.width
        let columns = Self.columns(width: width, count: items.count)
        let cardWidth = ((width - Self.spacing * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down)
        for (index, card) in cards.enumerated() where index < items.count {
            let column = index % columns
            let row = index / columns
            card.frame = CGRect(x: CGFloat(column) * (cardWidth + Self.spacing),
                                y: CGFloat(row) * (Self.cardHeight + Self.spacing),
                                width: cardWidth, height: Self.cardHeight)
        }
    }
}

/// Ett kort: symbolen i en rund ruta, titeln i New York, antalet under och en pil till höger.
final class StudyCardView: UIControl {

    private let iconBackground = UIView()
    private let icon = UIImageView()
    private let titleLabel = UILabel()
    private let textLabel = UILabel()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 14
        layer.borderWidth = 1
        iconBackground.layer.cornerRadius = 22
        iconBackground.isUserInteractionEnabled = false
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 19, weight: .medium)
        chevron.contentMode = .scaleAspectFit
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        titleLabel.numberOfLines = 1
        textLabel.numberOfLines = 1
        textLabel.adjustsFontSizeToFitWidth = true
        textLabel.minimumScaleFactor = 0.8
        for view in [iconBackground, icon, titleLabel, textLabel, chevron] as [UIView] {
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            UIView.animate(withDuration: 0.15) {
                self.alpha = self.isHighlighted ? 0.6 : 1
            }
        }
    }

    func configure(_ item: StudyItem, palette: Palette) {
        backgroundColor = palette.surface
        layer.borderColor = palette.rule.cgColor
        iconBackground.backgroundColor = palette.accentSoft
        icon.image = UIImage(systemName: item.symbol)
        icon.tintColor = palette.accent
        chevron.tintColor = palette.inkFaint
        titleLabel.text = item.title
        titleLabel.font = Theme.serif(.headline, size: 18, weight: .semibold)
        titleLabel.textColor = palette.ink
        textLabel.text = item.text
        textLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        textLabel.textColor = item.count > 0 ? palette.ink : palette.inkSoft
        accessibilityLabel = item.title
        accessibilityValue = item.text
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = bounds.height
        iconBackground.frame = CGRect(x: 16, y: (height - 44) / 2, width: 44, height: 44)
        icon.frame = iconBackground.frame.insetBy(dx: 11, dy: 11)
        chevron.frame = CGRect(x: bounds.width - 16 - 12, y: (height - 16) / 2, width: 12, height: 16)
        let x = iconBackground.frame.maxX + 14
        let width = max(chevron.frame.minX - 10 - x, 20)
        titleLabel.frame = CGRect(x: x, y: height / 2 - 23, width: width, height: 24)
        textLabel.frame = CGRect(x: x, y: height / 2 + 3, width: width, height: 20)
    }
}
