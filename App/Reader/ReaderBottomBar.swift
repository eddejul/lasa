import UIKit

/// Menyns nederkant i läsaren: ett reglage för att hoppa i boken och sidnumret.
/// Sidnumret är en knapp som öppnar Gå till sida.
final class ReaderBottomBar: UIView {

    let slider = UISlider()
    let pageButton = UIButton(type: .system)

    private let background = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))

    override init(frame: CGRect) {
        super.init(frame: frame)

        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.accessibilityLabel = "Plats i boken"
        background.contentView.addSubview(slider)

        pageButton.translatesAutoresizingMaskIntoConstraints = false
        pageButton.titleLabel?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        pageButton.accessibilityHint = "Öppnar Gå till sida"
        background.contentView.addSubview(pageButton)

        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),

            slider.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            slider.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 20),
            slider.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -20),

            pageButton.topAnchor.constraint(equalTo: slider.bottomAnchor, constant: 2),
            pageButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            pageButton.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -6)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    /// Temats färger (U1): sidans papper i stället för systemets glas, reglaget i accentfärgen.
    func apply(_ palette: Palette) {
        background.effect = nil
        background.backgroundColor = palette.page.withAlphaComponent(0.97)
        slider.minimumTrackTintColor = palette.accent
        slider.maximumTrackTintColor = palette.rule
        pageButton.tintColor = palette.inkSoft
    }
}
