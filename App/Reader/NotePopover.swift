import UIKit

/// V5: en fotnot eller referens i en liten ruta vid siffran, i stället för att boken hoppar till noten.
/// Knappen Gå till noten hoppar som förut (med Tillbaka, V4). Samma ruta i båda läsarna (G12).
final class NotePopoverViewController: UIViewController, UIPopoverPresentationControllerDelegate {

    static let width: CGFloat = 360
    static let maxHeight: CGFloat = 340

    private let heading: String
    private let text: String
    private let onGo: () -> Void
    private let stack = UIStackView()

    /// Notens text, till självtestet.
    var noteText: String {
        text
    }

    init(heading: String, text: String, onGo: @escaping () -> Void) {
        self.heading = heading
        self.text = text
        self.onGo = onGo
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    /// Visar rutan vid siffran. På iPhone också som en liten ruta, inte som ett ark.
    static func present(from host: UIViewController, sourceView: UIView, sourceRect: CGRect, heading: String,
                        text: String, onGo: @escaping () -> Void) {
        let controller = NotePopoverViewController(heading: heading, text: text, onGo: onGo)
        controller.modalPresentationStyle = .popover
        if let popover = controller.popoverPresentationController {
            popover.sourceView = sourceView
            popover.sourceRect = sourceRect
            popover.permittedArrowDirections = [.up, .down]
            popover.backgroundColor = Theme.current.surface
            popover.delegate = controller
        }
        host.present(controller, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let palette = Theme.current
        view.backgroundColor = palette.surface

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = false
        view.addSubview(scroll)

        stack.axis = .vertical
        stack.spacing = 10
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        let headingLabel = UILabel()
        headingLabel.text = heading
        headingLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        headingLabel.textColor = palette.inkFaint
        stack.addArrangedSubview(headingLabel)

        let body = UILabel()
        body.text = text
        body.numberOfLines = 0
        body.font = Theme.serif(.body, size: 16, weight: .regular)
        body.textColor = palette.ink
        stack.addArrangedSubview(body)

        let button = UIButton(type: .system)
        button.setTitle("Gå till noten", for: .normal)
        button.setImage(UIImage(systemName: "arrow.down.doc"), for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        button.tintColor = palette.accent
        button.contentHorizontalAlignment = .leading
        button.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: -6)
        button.addTarget(self, action: #selector(goTapped), for: .touchUpInside)
        stack.addArrangedSubview(button)

        let margin: CGFloat = 16
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: margin),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -margin),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: margin),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -margin),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -2 * margin),
        ])

        let fitting = stack.systemLayoutSizeFitting(CGSize(width: Self.width - 2 * margin, height: 0),
                                                    withHorizontalFittingPriority: .required,
                                                    verticalFittingPriority: .fittingSizeLevel)
        preferredContentSize = CGSize(width: Self.width, height: min(fitting.height + 2 * margin, Self.maxHeight))
    }

    @objc private func goTapped() {
        let go = onGo
        dismiss(animated: true) {
            go()
        }
    }

    func adaptivePresentationStyle(for controller: UIPresentationController,
                                   traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        .none
    }
}

/// V5: notens text i en EPUB, ur kapitelfilen på disken (ingen webbvy behövs). Körs i bakgrunden.
enum NoteFinder {

    /// Texten i elementet med id (eller name) `fragment`. Är elementet bara ett ankare eller en siffra tas
    /// stycket runt det. Nil när filen inte går att läsa som XHTML eller noten inte hittas, och läsaren hoppar då
    /// till noten som förut.
    static func text(in url: URL, fragment: String) -> String? {
        guard !fragment.isEmpty, let root = XMLTree.parse(contentsOf: url),
              let path = path(to: fragment, from: root) else { return nil }
        let inline: Set<String> = ["a", "span", "sup", "sub", "em", "i", "b", "strong", "small"]
        var level = path.count - 1
        var text = path[level].text
        while level > 0, inline.contains(path[level].name) || text.count < 4 {
            level -= 1
            let name = path[level].name
            if name == "body" || name == "html" {
                return nil
            }
            text = path[level].text
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > 1200 ? String(trimmed.prefix(1200)) + " …" : trimmed
    }

    /// Vägen från roten till elementet med id eller name `fragment`, roten först.
    private static func path(to fragment: String, from root: XMLNode) -> [XMLNode]? {
        if root["id"] == fragment || (root.name == "a" && root["name"] == fragment) {
            return [root]
        }
        for child in root.children where child.name != "#text" {
            if let rest = path(to: fragment, from: child) {
                return [root] + rest
            }
        }
        return nil
    }
}
