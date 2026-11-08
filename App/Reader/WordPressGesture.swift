import UIKit

/// Hållgesten för ordboken i båda läsarna (G12 steg 2): gesten, att vikningens och menyns tryck avbryts när
/// ett ord hålls, och bubblan ovanför fingret (`WordBubble`). Själva ordet tas fram av läsaren: med PDFKit
/// direkt i PDF, och i kapitlets dolda webbvy i EPUB och text, där svaret kommer med en fördröjning.
@MainActor
enum WordPressGesture {

    /// Hur länge fingret ska ligga still på ett ord innan det slås upp.
    nonisolated static let duration: TimeInterval = 0.35

    /// Hur långt från fingret ett ord får ligga och ändå väljas, i punkter.
    nonisolated static let fingerTolerance: CGFloat = 22

    /// Gesten som följer fingret när det hålls på ett ord.
    static func makeRecognizer(target: Any, action: Selector,
                               delegate: UIGestureRecognizerDelegate?) -> UILongPressGestureRecognizer {
        let press = UILongPressGestureRecognizer(target: target, action: action)
        press.minimumPressDuration = duration
        press.delegate = delegate
        return press
    }

    /// Avbryter tryck som redan har börjat (vikningen, menyn, zoomen eller länkarna), så att de inte också
    /// slår till när fingret lyfts.
    static func cancel(_ recognizers: [UIGestureRecognizer]) {
        for recognizer in recognizers where recognizer.isEnabled {
            recognizer.isEnabled = false
            recognizer.isEnabled = true
        }
    }
}

/// Fingret skymmer ordet, så ordet visas också i en bubbla ovanför fingret medan man håller.
@MainActor
final class WordBubble {

    private weak var host: UIView?
    private weak var label: PaddedLabel?

    /// `host` är läsarens vy, som bubblan läggs i.
    init(host: UIView) {
        self.host = host
    }

    /// Ordet i bubblan, eller nil när ingen bubbla syns.
    var text: String? {
        label?.text
    }

    func show(_ word: String, at point: CGPoint) {
        guard let host = host else { return }
        let bubble: PaddedLabel
        if let existing = label {
            bubble = existing
        } else {
            bubble = PaddedLabel()
            bubble.insets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
            bubble.font = .preferredFont(forTextStyle: .headline)
            bubble.textColor = .white
            bubble.backgroundColor = UIColor(white: 0.12, alpha: 0.9)
            bubble.layer.cornerRadius = 10
            bubble.layer.masksToBounds = true
            bubble.isUserInteractionEnabled = false
            host.addSubview(bubble)
            label = bubble
        }
        bubble.text = word
        bubble.sizeToFit()
        move(to: point)
    }

    /// Flyttar bubblan till fingret, i läsarens vy. Under fingret om den inte får plats ovanför.
    func move(to point: CGPoint) {
        guard let bubble = label, let host = host else { return }
        let size = bubble.bounds.size
        let margin: CGFloat = 8
        var center = CGPoint(x: point.x, y: point.y - 64)
        if center.y - size.height / 2 < host.safeAreaInsets.top + margin {
            center.y = point.y + 64
        }
        center.x = min(max(center.x, size.width / 2 + margin), host.bounds.width - size.width / 2 - margin)
        bubble.center = center
    }

    func hide() {
        label?.removeFromSuperview()
        label = nil
    }
}
