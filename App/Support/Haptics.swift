import UIKit

/// Mikrovibrationer.
/// Fungerar på iPhone. iPad saknar vibrationsmotor och ignorerar anropen, det är förväntat.
@MainActor
final class Haptics {

    static let shared = Haptics()

    private let pageTurn = UIImpactFeedbackGenerator(style: .light)
    private let selection = UISelectionFeedbackGenerator()

    private init() {}

    /// Anropas när en sida börjar vikas, så att vibrationen kommer utan fördröjning.
    func prepareForPageTurn() {
        pageTurn.prepare()
    }

    func pageTurned() {
        pageTurn.impactOccurred(intensity: 0.55)
    }

    /// Används av ordfunktionen i fas 2.
    func wordTapped() {
        selection.selectionChanged()
    }
}
