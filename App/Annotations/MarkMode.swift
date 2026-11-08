import UIKit

/// Markeringsläget i båda läsarna (G12 steg 3): gesterna (fingret som drar och trycket på en markering),
/// att vikningens, menyns och ordets gester stängs av medan läget är på, och raden nere med färgerna,
/// bläddringen och Klar (`HighlightModeBar`). Vad fingret markerar räknar läsaren ut, PDF med PDFKit och
/// EPUB i webbvyn. Ändras markeringsraden ska den ändras här och i `HighlightModeBar`, inte i läsarna.
@MainActor
final class MarkMode {

    /// Fingret som markerar. Tiden 0, så att den följer fingret direkt. Bara på i markeringsläget.
    let drag: UILongPressGestureRecognizer
    /// Ett tryck på en markering öppnar markeringens ruta (utanför markeringsläget).
    let tap: UITapGestureRecognizer

    /// Bläddra från raden, framåt (sant) eller bakåt.
    var onTurn: ((Bool) -> Void)?
    /// Klar på raden.
    var onDone: (() -> Void)?

    private(set) var isOn = false
    private(set) var bar: HighlightModeBar?
    private weak var host: UIView?

    /// Lägger gesterna i läsarens vy. Läsaren är mål och delegat för dem.
    init(host: UIView, target: Any, drag dragAction: Selector, tap tapAction: Selector,
         delegate: UIGestureRecognizerDelegate) {
        let drag = UILongPressGestureRecognizer(target: target, action: dragAction)
        drag.minimumPressDuration = 0
        drag.allowableMovement = .greatestFiniteMagnitude
        drag.delegate = delegate
        drag.isEnabled = false
        host.addGestureRecognizer(drag)

        let tap = UITapGestureRecognizer(target: target, action: tapAction)
        tap.delegate = delegate
        host.addGestureRecognizer(tap)

        self.host = host
        self.drag = drag
        self.tap = tap
    }

    /// Slår på eller av läget. `paused` är gesterna som är avstängda medan läget är på (vikningen, menyn,
    /// zoomen eller länkarna, och ordet). Falskt om läget redan var så, då har inget ändrats.
    func setOn(_ on: Bool, pausing paused: [UIGestureRecognizer]) -> Bool {
        guard on != isOn else { return false }
        isOn = on
        for recognizer in paused {
            recognizer.isEnabled = !on
        }
        drag.isEnabled = on
        return true
    }

    /// Raden nere med färgerna, bläddringen och Klar.
    func showBar() {
        guard bar == nil, let host = host else { return }
        let bar = HighlightModeBar(color: ReaderSettings.highlightColor)
        bar.onColor = { color in
            ReaderSettings.highlightColor = color
        }
        bar.onTurn = { [weak self] forward in
            self?.onTurn?(forward)
        }
        bar.onDone = { [weak self] in
            self?.onDone?()
        }
        ReaderMenus.installModeBar(bar, in: host)
        self.bar = bar
    }

    func removeBar() {
        bar?.removeFromSuperview()
        bar = nil
    }
}
