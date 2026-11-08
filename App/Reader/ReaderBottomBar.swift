import UIKit

/// Menyns nederkant i läsaren: tidslinjen (V2) för att hoppa i boken och under det en rad med sidan till vänster,
/// kapitlets namn i mitten (V2) och sidor kvar till höger (V1). Sidan är en knapp som öppnar Gå till sida
/// (PDF) eller Innehåll (EPUB), och sidor kvar växlar mellan kapitlet och boken när man trycker.
final class ReaderBottomBar: UIView {

    /// V2: tidslinjen (heter slider sedan reglagets tid, läsarna använder den som ett reglage).
    let slider = ReaderTimeline()
    let pageButton = UIButton(type: .system)
    /// V2: kapitlets namn under linjen.
    let chapterLabel = UILabel()
    /// V1: sidor kvar i kapitlet eller i boken. Ett tryck växlar.
    let infoButton = UIButton(type: .system)

    private let background = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))

    override init(frame: CGRect) {
        super.init(frame: frame)

        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.accessibilityLabel = "Plats i boken"
        // Ovanpå bakgrunden, inte i den, så att bubblan över fingret kan sticka upp över sidan.
        addSubview(slider)

        pageButton.translatesAutoresizingMaskIntoConstraints = false
        pageButton.titleLabel?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        pageButton.titleLabel?.lineBreakMode = .byTruncatingTail
        pageButton.accessibilityHint = "Öppnar Gå till sida"
        pageButton.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        addSubview(pageButton)

        chapterLabel.translatesAutoresizingMaskIntoConstraints = false
        chapterLabel.font = .systemFont(ofSize: 13, weight: .medium)
        chapterLabel.textAlignment = .center
        chapterLabel.lineBreakMode = .byTruncatingTail
        chapterLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chapterLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(chapterLabel)

        infoButton.translatesAutoresizingMaskIntoConstraints = false
        infoButton.titleLabel?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        infoButton.titleLabel?.lineBreakMode = .byTruncatingTail
        infoButton.accessibilityHint = "Växlar mellan sidor kvar i kapitlet och i boken"
        infoButton.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        addSubview(infoButton)

        let centered = chapterLabel.centerXAnchor.constraint(equalTo: centerXAnchor)
        centered.priority = .defaultHigh
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),

            slider.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            slider.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 20),
            slider.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -20),

            pageButton.topAnchor.constraint(equalTo: slider.bottomAnchor, constant: 2),
            pageButton.leadingAnchor.constraint(equalTo: slider.leadingAnchor),
            pageButton.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -6),

            infoButton.centerYAnchor.constraint(equalTo: pageButton.centerYAnchor),
            infoButton.trailingAnchor.constraint(equalTo: slider.trailingAnchor),
            infoButton.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.4),

            chapterLabel.centerYAnchor.constraint(equalTo: pageButton.centerYAnchor),
            centered,
            chapterLabel.leadingAnchor.constraint(greaterThanOrEqualTo: pageButton.trailingAnchor, constant: 12),
            chapterLabel.trailingAnchor.constraint(lessThanOrEqualTo: infoButton.leadingAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    /// Temats färger (U1): sidans papper i stället för systemets glas, reglaget i accentfärgen.
    func apply(_ palette: Palette) {
        background.effect = nil
        background.backgroundColor = palette.page.withAlphaComponent(0.97)
        slider.apply(palette)
        pageButton.tintColor = palette.inkSoft
        chapterLabel.textColor = palette.ink
        infoButton.tintColor = palette.accent
    }
}
