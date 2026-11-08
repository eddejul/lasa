import UIKit

/// En kort rad längst ner med Ångra (granskning 2, N7): ett tryck på bokmärkesbandet tar bort sidans bokmärke,
/// och raden ger en väg tillbaka i fem sekunder. Ligger ovanpå läsaren och rör inte sidans placering.
/// Samma rad visas när Sparat i ordkortet tar bort ett ord (D3-1), då i fönstret ovanpå kortet.
@MainActor
final class UndoBar: UIView {

    /// Raden som syns just nu, till självtestet.
    private(set) static weak var current: UndoBar?

    private let label = UILabel()
    private let button = UIButton(type: .system)
    private var onUndo: (() -> Void)?

    /// Visar raden i `host`. En rad som redan syns ersätts.
    @discardableResult
    static func show(_ text: String, in host: UIView, bottomInset: CGFloat = 96, undo: @escaping () -> Void) -> UndoBar {
        current?.removeFromSuperview()
        let bar = UndoBar(text: text, undo: undo)
        bar.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            bar.bottomAnchor.constraint(equalTo: host.safeAreaLayoutGuide.bottomAnchor, constant: -bottomInset),
            bar.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, constant: -32),
        ])
        current = bar
        bar.alpha = 0
        UIView.animate(withDuration: 0.2) { bar.alpha = 1 }
        UIAccessibility.post(notification: .announcement, argument: text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak bar] in
            bar?.hide()
        }
        return bar
    }

    private init(text: String, undo: @escaping () -> Void) {
        onUndo = undo
        super.init(frame: .zero)
        let palette = Theme.current
        backgroundColor = palette.surface
        layer.cornerRadius = 22
        layer.borderWidth = 1
        layer.borderColor = palette.rule.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = palette.isDark ? 0.4 : 0.15
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 2)
        label.text = text
        label.font = .systemFont(ofSize: 15)
        label.textColor = palette.ink
        button.setTitle("Ångra", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        button.tintColor = palette.accent
        button.addTarget(self, action: #selector(undoTapped), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [label, button])
        stack.spacing = 16
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    @objc private func undoTapped() {
        performUndo()
    }

    /// Ångra (också från självtestet).
    func performUndo() {
        let undo = onUndo
        onUndo = nil
        undo?()
        hide()
    }

    /// Tar bort raden utan att ångra, till exempel när det som togs bort redan har lagts tillbaka på annat sätt.
    func dismiss() {
        onUndo = nil
        hide()
    }

    private func hide() {
        guard superview != nil else { return }
        UIView.animate(withDuration: 0.2, animations: { self.alpha = 0 }, completion: { _ in
            self.removeFromSuperview()
        })
    }
}
