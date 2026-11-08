import UIKit

/// V6: Här var du. När en bok öppnas efter mer än ett dygn ligger ett litet kort över sidan med kapitlets rubrik
/// och dina tre senaste markeringar, så att du hämtar fram det du läste förra gången innan du läser vidare.
/// Ett tryck var som helst stänger kortet. Edvins beslut 8 november 2026: ingen fråga och ingen knapp
/// Fråga mig först, bara kortet. Samma kort i båda läsarna (G12).
final class ReaderResumeCard: UIView {

    /// Ett dygn: kortet visas när boken senast lästes för längre sedan än så.
    static let interval: TimeInterval = 24 * 60 * 60

    /// Om kortet ska visas, när boken senast lästes vid `lastRead` (nil för en bok som aldrig öppnats).
    static func shouldShow(lastRead: Date?, now: Date = Date()) -> Bool {
        guard let lastRead = lastRead else { return false }
        return now.timeIntervalSince(lastRead) > interval
    }

    /// "i går", "för 3 dagar sedan", "för 2 veckor sedan".
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let days = Int(now.timeIntervalSince(date) / interval)
        switch days {
        case ..<2: return "i går"
        case 2..<14: return "för \(days) dagar sedan"
        case 14..<60: return "för \(days / 7) veckor sedan"
        default: return "för \(days / 30) månader sedan"
        }
    }

    private let card = UIView()
    private let stack = UIStackView()
    var onClose: (() -> Void)?

    /// Texterna på kortet, till självtestet.
    private(set) var summary = ""

    init(chapter: String, lastRead: Date?, highlights: [Highlight]) {
        super.init(frame: .zero)
        let palette = Theme.current
        backgroundColor = palette.ink.withAlphaComponent(0.06)

        card.backgroundColor = palette.surface
        card.layer.cornerRadius = 18
        card.layer.borderWidth = 1 / UIScreen.main.scale
        card.layer.borderColor = palette.rule.cgColor
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.18
        card.layer.shadowRadius = 18
        card.layer.shadowOffset = CGSize(width: 0, height: 6)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        var heading = "Här var du"
        if let lastRead = lastRead {
            heading += ", \(Self.ago(lastRead))"
        }
        stack.addArrangedSubview(label(heading, font: .systemFont(ofSize: 12, weight: .semibold), color: palette.inkFaint))
        let title = label(chapter, font: Theme.serif(.title3, size: 22, weight: .semibold), color: palette.ink)
        title.numberOfLines = 2
        stack.addArrangedSubview(title)
        stack.setCustomSpacing(16, after: title)

        var lines = [heading, chapter]
        if highlights.isEmpty {
            stack.addArrangedSubview(label("Inga markeringar i boken än.", font: .systemFont(ofSize: 14), color: palette.inkSoft))
        } else {
            stack.addArrangedSubview(label(highlights.count == 1 ? "Din senaste markering" : "Dina senaste markeringar",
                                           font: .systemFont(ofSize: 12, weight: .semibold), color: palette.inkFaint))
            for highlight in highlights.prefix(3) {
                stack.addArrangedSubview(row(for: highlight, palette: palette))
                lines.append(highlight.text)
            }
        }
        let hint = label("Tryck för att läsa vidare", font: .systemFont(ofSize: 12, weight: .medium), color: palette.inkFaint)
        hint.textAlignment = .center
        stack.addArrangedSubview(hint)
        stack.setCustomSpacing(18, before: hint)
        summary = lines.joined(separator: " | ")

        let width = card.widthAnchor.constraint(equalTo: widthAnchor, constant: -48)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
            width,
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
        ])

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(close)))
        isAccessibilityElement = true
        accessibilityLabel = lines.joined(separator: ". ")
        accessibilityHint = "Stänger kortet"
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    /// Lägger kortet över hela läsarens vy och tonar in det.
    func show(in view: UIView) {
        frame = view.bounds
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        alpha = 0
        view.addSubview(self)
        UIView.animate(withDuration: 0.25) { self.alpha = 1 }
    }

    @objc func close() {
        UIView.animate(withDuration: 0.2, animations: { self.alpha = 0 }) { _ in
            self.removeFromSuperview()
        }
        onClose?()
    }

    override func accessibilityActivate() -> Bool {
        close()
        return true
    }

    private func label(_ text: String, font: UIFont, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = font
        label.textColor = color
        label.numberOfLines = 0
        return label
    }

    /// En markering: en prick i markeringens färg och texten i kursiv New York, högst tre rader.
    private func row(for highlight: Highlight, palette: Palette) -> UIView {
        let dot = UIView()
        dot.backgroundColor = highlight.color.solid
        dot.layer.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        let text = UILabel()
        text.text = highlight.text.trimmingCharacters(in: .whitespacesAndNewlines)
        text.numberOfLines = 3
        text.lineBreakMode = .byTruncatingTail
        let base = Theme.serif(.body, size: 15, weight: .regular)
        text.font = base.fontDescriptor.withSymbolicTraits(.traitItalic).map { UIFont(descriptor: $0, size: 15) } ?? base
        text.textColor = palette.ink
        text.translatesAutoresizingMaskIntoConstraints = false
        let container = UIView()
        container.addSubview(dot)
        container.addSubview(text)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            dot.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            dot.topAnchor.constraint(equalTo: text.topAnchor, constant: 6),
            text.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            text.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            text.topAnchor.constraint(equalTo: container.topAnchor),
            text.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }
}
