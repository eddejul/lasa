import UIKit

/// Ett omslag (B1): bokens egen bild, eller ett ritat omslag med titeln i New York för böcker utan bild
/// (text, Markdown, EPUB med SVG-omslag). Mjuk skugga och en smal rand till vänster som bokrygg, i kursens
/// färg när boken ligger i en kurs (B3).
final class CoverView: UIView {

    enum Content {
        case image(UIImage)
        /// Omslaget läses eller ritas i bakgrunden.
        case loading
        /// Ingen bild: ett ritat omslag.
        case drawn
    }

    private let clip = UIView()
    private let imageView = UIImageView()
    private let drawnTitle = UILabel()
    private let drawnRule = UIView()
    private let drawnFooter = UILabel()
    private let spine = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 2)
        clip.layer.cornerRadius = 4
        clip.clipsToBounds = true
        addSubview(clip)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        clip.addSubview(imageView)
        drawnTitle.numberOfLines = 5
        drawnTitle.textAlignment = .center
        drawnTitle.adjustsFontSizeToFitWidth = true
        drawnTitle.minimumScaleFactor = 0.6
        clip.addSubview(drawnTitle)
        clip.addSubview(drawnRule)
        drawnFooter.textAlignment = .center
        drawnFooter.numberOfLines = 1
        clip.addSubview(drawnFooter)
        clip.addSubview(spine)
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    func configure(_ content: Content, title: String, footer: String, stripe: UIColor?, palette: Palette) {
        let showsDrawn: Bool
        switch content {
        case .image(let image):
            imageView.image = image
            imageView.isHidden = false
            showsDrawn = false
            clip.backgroundColor = palette.surfaceSunk
        case .loading:
            imageView.image = nil
            imageView.isHidden = true
            showsDrawn = false
            clip.backgroundColor = palette.surfaceSunk
        case .drawn:
            imageView.image = nil
            imageView.isHidden = true
            showsDrawn = true
            clip.backgroundColor = palette.surface
        }
        drawnTitle.isHidden = !showsDrawn
        drawnRule.isHidden = !showsDrawn
        drawnFooter.isHidden = !showsDrawn
        drawnTitle.text = title
        drawnTitle.textColor = palette.ink
        drawnRule.backgroundColor = stripe ?? palette.accent
        drawnFooter.text = footer.uppercased()
        drawnFooter.textColor = palette.inkSoft
        spine.backgroundColor = stripe ?? (showsDrawn ? palette.accent : UIColor.black.withAlphaComponent(0.12))
        layer.shadowOpacity = palette.isDark ? 0.35 : 0.18
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        clip.frame = bounds
        imageView.frame = bounds
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 4).cgPath
        let width = bounds.width
        let side = max(width * 0.1, 8)
        let titleSize = max(min(width * 0.12, 22), 12)
        drawnTitle.font = Theme.serif(.title3, size: titleSize, weight: .regular)
        let titleWidth = width - side * 2
        let fitted = drawnTitle.sizeThatFits(CGSize(width: titleWidth, height: bounds.height * 0.5))
        let titleHeight = min(fitted.height, bounds.height * 0.5)
        drawnTitle.frame = CGRect(x: side, y: bounds.height * 0.3 - titleHeight / 2 + 8, width: titleWidth,
                                  height: titleHeight)
        drawnRule.frame = CGRect(x: (width - width * 0.22) / 2, y: drawnTitle.frame.maxY + 12,
                                 width: width * 0.22, height: 1.5)
        drawnFooter.font = .systemFont(ofSize: max(min(width * 0.055, 11), 8), weight: .medium)
        drawnFooter.frame = CGRect(x: side, y: bounds.height - side - 14, width: titleWidth, height: 14)
        spine.frame = CGRect(x: 0, y: 0, width: 3, height: bounds.height)
    }
}

/// En tunn stapel för hur långt man läst.
final class ProgressLine: UIView {

    private let fill = UIView()

    var progress: Double = 0 {
        didSet { setNeedsLayout() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 1.5
        clipsToBounds = true
        addSubview(fill)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    func setColors(track: UIColor, fill color: UIColor) {
        backgroundColor = track
        fill.backgroundColor = color
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let fraction = CGFloat(min(max(progress, 0), 1))
        fill.frame = CGRect(x: 0, y: 0, width: (bounds.width * fraction).rounded(), height: bounds.height)
    }
}

/// U10: ett tryck på ett omslag trycker ner det lite (97 procent). Med Minska rörelse tonas det i stället.
enum CoverPress {
    static func apply(_ pressed: Bool, to view: UIView) {
        let reduce = UIAccessibility.isReduceMotionEnabled
        UIView.animate(withDuration: pressed ? 0.12 : 0.22, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState],
                       animations: {
            if reduce {
                view.alpha = pressed ? 0.75 : 1
            } else {
                view.transform = pressed ? CGAffineTransform(scaleX: 0.97, y: 0.97) : .identity
            }
        })
    }
}

/// En bok i rutnätet (B1): omslag, titel, författare och en tunn stapel för hur långt man läst.
final class BookCell: UICollectionViewCell {

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            CoverPress.apply(isHighlighted, to: cover)
        }
    }

    static let id = "bok"

    let cover = CoverView()
    private let titleLabel = UILabel()
    private let authorLabel = UILabel()
    private let progressLine = ProgressLine()
    private let percentLabel = UILabel()

    /// Texten under omslaget: titel, författare och stapel.
    static let textHeight: CGFloat = 86

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(cover)
        titleLabel.numberOfLines = 2
        contentView.addSubview(titleLabel)
        contentView.addSubview(authorLabel)
        contentView.addSubview(progressLine)
        percentLabel.textAlignment = .right
        contentView.addSubview(percentLabel)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cover.transform = .identity
        cover.alpha = 1
    }

    func configure(_ item: ShelfItem, cover content: CoverView.Content, stripe: UIColor?, palette: Palette) {
        let footer = item.author.isEmpty ? item.book.kindLabel : item.author
        cover.configure(content, title: item.title, footer: footer, stripe: stripe, palette: palette)
        titleLabel.text = item.title
        titleLabel.font = Theme.serif(.subheadline, size: 15, weight: .medium)
        titleLabel.textColor = palette.ink
        authorLabel.text = item.author.isEmpty ? (item.book.folder ?? item.book.kindLabel) : item.author
        authorLabel.font = .systemFont(ofSize: 13)
        authorLabel.textColor = palette.inkSoft
        percentLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: item.finished ? .semibold : .regular)
        if item.finished {
            progressLine.isHidden = false
            progressLine.progress = 1
            progressLine.setColors(track: palette.rule, fill: palette.success)
            percentLabel.text = "Läst"
            percentLabel.textColor = palette.success
        } else if item.progress > 0 {
            progressLine.isHidden = false
            progressLine.progress = item.progress
            progressLine.setColors(track: palette.rule, fill: palette.accent)
            percentLabel.text = "\(max(Int((item.progress * 100).rounded(.down)), 1)) %"
            percentLabel.textColor = palette.inkSoft
        } else {
            progressLine.isHidden = true
            let fresh = item.isUnread && item.added > Date().timeIntervalSince1970 - 14 * 86_400
            percentLabel.text = fresh ? "Ny" : nil
            percentLabel.textColor = palette.accent
            percentLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        }
        accessibilityLabel = [item.title, item.author, item.finished ? "Läst"
                              : item.progress > 0 ? "\(Int((item.progress * 100).rounded())) procent läst" : nil]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = contentView.bounds.width
        let coverHeight = contentView.bounds.height - Self.textHeight
        cover.bounds = CGRect(x: 0, y: 0, width: width, height: max(coverHeight, 10))
        cover.center = CGPoint(x: width / 2, y: max(coverHeight, 10) / 2)
        var y = cover.frame.maxY + 8
        let titleHeight = min(titleLabel.sizeThatFits(CGSize(width: width, height: 60)).height, 40)
        titleLabel.frame = CGRect(x: 0, y: y, width: width, height: titleHeight)
        y = titleLabel.frame.maxY + 2
        authorLabel.frame = CGRect(x: 0, y: y, width: width, height: 17)
        let barY = contentView.bounds.height - 10
        percentLabel.frame = CGRect(x: width - 44, y: barY - 8, width: 44, height: 16)
        progressLine.frame = CGRect(x: 0, y: barY - 1.5, width: max(width - 52, 10), height: 3)
    }
}

/// Fortsätt läsa (B2): boken man läste senast, med kapitel, sida och sidor kvar. Ingen tid kvar.
final class ContinueCell: UICollectionViewCell {

    static let id = "fortsatt"

    let cover = CoverView()
    private let card = UIView()
    private let eyebrow = UILabel()
    private let titleLabel = UILabel()
    private let authorLabel = UILabel()
    private let chapterLabel = UILabel()
    private let progressLine = ProgressLine()
    private let statusLabel = UILabel()
    let button = UIButton(type: .system)
    var onContinue: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        card.layer.cornerRadius = 14
        card.layer.borderWidth = 1
        contentView.addSubview(card)
        card.addSubview(cover)
        eyebrow.text = "FORTSÄTT LÄSA"
        for label in [eyebrow, titleLabel, authorLabel, chapterLabel, statusLabel] {
            card.addSubview(label)
        }
        titleLabel.numberOfLines = 2
        card.addSubview(progressLine)
        button.setTitle("Fortsätt", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        button.layer.cornerRadius = 20
        button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
        button.addTarget(self, action: #selector(continueTapped), for: .touchUpInside)
        card.addSubview(button)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    @objc private func continueTapped() {
        onContinue?()
    }

    func configure(_ item: ShelfItem, cover content: CoverView.Content, stripe: UIColor?, palette: Palette) {
        card.backgroundColor = palette.surface
        card.layer.borderColor = palette.rule.cgColor
        cover.configure(content, title: item.title, footer: item.author.isEmpty ? item.book.kindLabel : item.author,
                        stripe: stripe, palette: palette)
        eyebrow.font = .systemFont(ofSize: 12, weight: .semibold)
        eyebrow.textColor = palette.inkSoft
        eyebrow.attributedText = NSAttributedString(string: "FORTSÄTT LÄSA", attributes: [.kern: 1.0])
        titleLabel.text = item.title
        titleLabel.font = Theme.serif(.title2, size: 22, weight: .semibold)
        titleLabel.textColor = palette.ink
        authorLabel.text = [item.author, item.book.folder ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
        authorLabel.font = .systemFont(ofSize: 15)
        authorLabel.textColor = palette.inkSoft
        chapterLabel.text = item.chapter
        chapterLabel.font = .systemFont(ofSize: 15)
        chapterLabel.textColor = palette.ink
        progressLine.progress = item.progress
        progressLine.setColors(track: palette.rule, fill: palette.accent)
        statusLabel.text = LibraryLogic.statusLine(item)
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        statusLabel.textColor = palette.inkSoft
        button.backgroundColor = palette.accent
        button.setTitleColor(palette.surface, for: .normal)
        button.accessibilityLabel = "Fortsätt läsa \(item.title)"
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        card.frame = contentView.bounds
        let inset: CGFloat = 16
        let coverHeight = card.bounds.height - inset * 2
        let coverWidth = (coverHeight / 1.5).rounded()
        cover.frame = CGRect(x: inset, y: inset, width: coverWidth, height: coverHeight)
        let x = cover.frame.maxX + 20
        let width = max(card.bounds.width - x - inset, 40)
        var y: CGFloat = inset + 2
        eyebrow.frame = CGRect(x: x, y: y, width: width, height: 16)
        y = eyebrow.frame.maxY + 6
        let titleHeight = min(titleLabel.sizeThatFits(CGSize(width: width, height: 80)).height, 56)
        titleLabel.frame = CGRect(x: x, y: y, width: width, height: titleHeight)
        y = titleLabel.frame.maxY + 2
        authorLabel.frame = CGRect(x: x, y: y, width: width, height: authorLabel.text?.isEmpty == false ? 19 : 0)
        y = authorLabel.frame.maxY + (chapterLabel.text?.isEmpty == false ? 6 : 0)
        chapterLabel.frame = CGRect(x: x, y: y, width: width, height: chapterLabel.text?.isEmpty == false ? 19 : 0)
        let buttonHeight: CGFloat = 40
        let buttonWidth = button.sizeThatFits(CGSize(width: width, height: buttonHeight)).width + 8
        button.frame = CGRect(x: x, y: card.bounds.height - inset - buttonHeight, width: min(buttonWidth, width),
                              height: buttonHeight)
        statusLabel.frame = CGRect(x: x, y: button.frame.minY - 26, width: width, height: 17)
        progressLine.frame = CGRect(x: x, y: statusLabel.frame.minY - 9, width: min(width, 320), height: 3)
    }
}

/// Kortet Gör mer med Sensus (B5) efter första starten: Förklaring med AI, med Ställ in och Senare.
/// Synken finns inte med, den byggs om till iCloud Drive.
final class MoreCell: UICollectionViewCell {

    static let id = "mer"

    private let titleLabel = UILabel()
    private let icon = UIImageView(image: UIImage(systemName: "sparkles"))
    private let rowTitle = UILabel()
    private let rowText = UILabel()
    private let setUpButton = UIButton(type: .system)
    private let laterButton = UIButton(type: .system)
    var onSetUp: (() -> Void)?
    var onLater: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 14
        contentView.layer.borderWidth = 1
        titleLabel.text = "Gör mer med Sensus"
        rowTitle.text = "Förklaring med AI"
        rowText.text = "Ordkortet kan förklara vad ordet betyder just i meningen, med Googles Gemini. "
            + "Det kräver en gratis nyckel, och meningen skickas då till Google."
        rowText.numberOfLines = 0
        setUpButton.setTitle("Ställ in", for: .normal)
        setUpButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        setUpButton.layer.cornerRadius = 18
        setUpButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        setUpButton.addTarget(self, action: #selector(setUpTapped), for: .touchUpInside)
        laterButton.setTitle("Senare", for: .normal)
        laterButton.titleLabel?.font = .systemFont(ofSize: 15)
        laterButton.addTarget(self, action: #selector(laterTapped), for: .touchUpInside)
        for view in [titleLabel, icon, rowTitle, rowText, setUpButton, laterButton] as [UIView] {
            contentView.addSubview(view)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    @objc private func setUpTapped() {
        onSetUp?()
    }

    @objc private func laterTapped() {
        onLater?()
    }

    func configure(palette: Palette) {
        contentView.backgroundColor = palette.surface
        contentView.layer.borderColor = palette.rule.cgColor
        titleLabel.font = Theme.serif(.headline, size: 18, weight: .semibold)
        titleLabel.textColor = palette.ink
        titleLabel.accessibilityTraits = .header
        icon.tintColor = palette.accent
        icon.contentMode = .scaleAspectFit
        rowTitle.font = .systemFont(ofSize: 16, weight: .semibold)
        rowTitle.textColor = palette.ink
        rowText.font = .systemFont(ofSize: 14)
        rowText.textColor = palette.inkSoft
        setUpButton.backgroundColor = palette.accent
        setUpButton.setTitleColor(palette.surface, for: .normal)
        laterButton.tintColor = palette.accent
        setNeedsLayout()
    }

    static let height: CGFloat = 156

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = contentView.bounds.width
        titleLabel.frame = CGRect(x: 16, y: 14, width: width - 32, height: 24)
        icon.frame = CGRect(x: 16, y: 52, width: 24, height: 24)
        let x: CGFloat = 52
        let buttonsWidth: CGFloat = width < 520 ? 0 : 200
        let textWidth = width - x - 16 - buttonsWidth
        rowTitle.frame = CGRect(x: x, y: 52, width: textWidth, height: 22)
        let textHeight = min(rowText.sizeThatFits(CGSize(width: textWidth, height: 80)).height, 60)
        rowText.frame = CGRect(x: x, y: 76, width: textWidth, height: textHeight)
        let setUpWidth = setUpButton.sizeThatFits(CGSize(width: 160, height: 36)).width + 4
        if buttonsWidth > 0 {
            setUpButton.frame = CGRect(x: width - 16 - setUpWidth, y: 58, width: setUpWidth, height: 36)
            laterButton.frame = CGRect(x: setUpButton.frame.minX - 84, y: 58, width: 76, height: 36)
        } else {
            setUpButton.frame = CGRect(x: x, y: contentView.bounds.height - 48, width: setUpWidth, height: 36)
            laterButton.frame = CGRect(x: setUpButton.frame.maxX + 8, y: contentView.bounds.height - 48, width: 76,
                                       height: 36)
        }
    }
}

/// Det tomma biblioteket (B5): tre vägar in, Välj filer, Öppna från Filer och Prova exempelboken.
final class EmptyLibraryView: UIView {

    var onChoose: (() -> Void)?
    var onFiles: (() -> Void)?
    var onSample: (() -> Void)?

    init(palette: Palette) {
        super.init(frame: .zero)
        let title = UILabel()
        title.text = "Inga böcker än"
        title.font = Theme.serif(.title2, size: 26, weight: .semibold)
        title.textColor = palette.ink
        title.textAlignment = .center
        let text = UILabel()
        text.text = "Lägg in en PDF, en EPUB eller en textfil. Böcker i en mapp blir en kurs av sig själva."
        text.font = .preferredFont(forTextStyle: .body)
        text.textColor = palette.inkSoft
        text.textAlignment = .center
        text.numberOfLines = 0
        let buttons = [
            Self.button("Välj filer", symbol: "plus", filled: true, palette: palette, action: #selector(choose)),
            Self.button("Öppna från Filer", symbol: "folder", filled: false, palette: palette, action: #selector(files)),
            Self.button("Prova exempelboken", symbol: "book", filled: false, palette: palette, action: #selector(sample)),
        ]
        let stack = UIStackView(arrangedSubviews: [title, text] + buttons)
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14
        stack.setCustomSpacing(28, after: text)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        var constraints = [
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            text.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ]
        for button in buttons {
            constraints.append(button.widthAnchor.constraint(equalToConstant: 260))
            constraints.append(button.heightAnchor.constraint(equalToConstant: 48))
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    private static func button(_ title: String, symbol: String, filled: Bool, palette: Palette,
                               action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle("  " + title, for: .normal)
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        button.layer.cornerRadius = 24
        if filled {
            button.backgroundColor = palette.accent
            button.tintColor = palette.surface
            button.setTitleColor(palette.surface, for: .normal)
        } else {
            button.backgroundColor = palette.surface
            button.layer.borderWidth = 1
            button.layer.borderColor = palette.rule.cgColor
            button.tintColor = palette.accent
            button.setTitleColor(palette.accent, for: .normal)
        }
        button.addTarget(nil, action: action, for: .touchUpInside)
        return button
    }

    @objc private func choose() {
        onChoose?()
    }

    @objc private func files() {
        onFiles?()
    }

    @objc private func sample() {
        onSample?()
    }
}

/// En rad med text och förlopp: utgångsvarningen (G1) och Lägger till Bok.pdf (G10, G3).
final class MessageCell: UICollectionViewCell {

    static let id = "meddelande"

    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .vertical
        stack.spacing = 8
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        contentView.layer.cornerRadius = 12
        contentView.clipsToBounds = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    /// `lines`: texten och förloppet (nil: ingen stapel).
    func configure(lines: [(text: String, progress: Double?)], background: UIColor, palette: Palette) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        contentView.backgroundColor = background
        for line in lines {
            let label = UILabel()
            label.text = line.text
            label.numberOfLines = 0
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.textColor = palette.ink
            stack.addArrangedSubview(label)
            if let progress = line.progress {
                let bar = UIProgressView(progressViewStyle: .default)
                bar.progress = Float(progress)
                bar.progressTintColor = palette.accent
                bar.trackTintColor = palette.rule
                stack.addArrangedSubview(bar)
            }
        }
    }
}

/// Raden över rutnätet: rubriken, filtret och Sortera (B2).
final class BooksHeaderView: UICollectionReusableView {

    static let id = "rubrik"

    private let titleLabel = UILabel()
    let filterControl = UISegmentedControl(items: LibraryFilter.allCases.map(\.title))
    let sortButton = UIButton(type: .system)
    var onFilter: ((LibraryFilter) -> Void)?
    var onSort: ((LibrarySort) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(titleLabel)
        filterControl.addTarget(self, action: #selector(filterChanged), for: .valueChanged)
        addSubview(filterControl)
        sortButton.showsMenuAsPrimaryAction = true
        sortButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        addSubview(sortButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    @objc private func filterChanged() {
        let index = filterControl.selectedSegmentIndex
        guard index >= 0, index < LibraryFilter.allCases.count else { return }
        onFilter?(LibraryFilter.allCases[index])
    }

    func configure(title: String, filter: LibraryFilter, sort: LibrarySort, palette: Palette) {
        titleLabel.text = title
        titleLabel.font = Theme.serif(.title2, size: 22, weight: .semibold)
        titleLabel.textColor = palette.ink
        titleLabel.accessibilityTraits = .header
        filterControl.selectedSegmentIndex = LibraryFilter.allCases.firstIndex(of: filter) ?? 0
        filterControl.selectedSegmentTintColor = palette.surface
        filterControl.backgroundColor = palette.surfaceSunk
        filterControl.setTitleTextAttributes([.foregroundColor: palette.inkSoft], for: .normal)
        filterControl.setTitleTextAttributes([.foregroundColor: palette.ink], for: .selected)
        sortButton.setTitle(" \(sort.title)", for: .normal)
        sortButton.setImage(UIImage(systemName: "arrow.up.arrow.down"), for: .normal)
        sortButton.tintColor = palette.accent
        sortButton.accessibilityLabel = "Sortera, \(sort.title)"
        let actions = LibrarySort.allCases.map { option in
            UIAction(title: option.title, state: option == sort ? .on : .off) { [weak self] _ in
                self?.onSort?(option)
            }
        }
        sortButton.menu = UIMenu(title: "Sortera", options: .singleSelection, children: actions)
        setNeedsLayout()
    }

    /// Smal (iPhone): filtret på en egen rad under rubriken.
    static func height(compact: Bool) -> CGFloat {
        compact ? 92 : 56
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let sortWidth = min(sortButton.sizeThatFits(CGSize(width: 200, height: 32)).width + 8, 170)
        if width < 560 {
            titleLabel.frame = CGRect(x: 0, y: 8, width: width - sortWidth - 8, height: 30)
            sortButton.frame = CGRect(x: width - sortWidth, y: 8, width: sortWidth, height: 32)
            filterControl.frame = CGRect(x: 0, y: 50, width: width, height: 32)
        } else {
            let titleWidth = min(titleLabel.sizeThatFits(CGSize(width: 300, height: 30)).width, 260)
            titleLabel.frame = CGRect(x: 0, y: 12, width: titleWidth, height: 30)
            sortButton.frame = CGRect(x: width - sortWidth, y: 11, width: sortWidth, height: 32)
            let filterX = titleLabel.frame.maxX + 20
            let filterWidth = min(max(width - filterX - sortWidth - 16, 200), 380)
            filterControl.frame = CGRect(x: filterX, y: 11, width: filterWidth, height: 32)
        }
    }
}
