import UIKit

/// Säger till när något inte kunde sparas (G8). Felet skrivs alltid i loggen, och en ruta visas
/// högst en gång i minuten per sak, så att ett fel som upprepas inte stänger in användaren.
/// Kan anropas från vilken tråd som helst.
enum SaveProblems {

    private static let lock = NSLock()
    private static var lastShown: [String: Date] = [:]

    /// Antal fel sedan appen startade, till självtestet.
    private(set) static var count = 0

    /// `what` är det som inte kunde sparas, med stor bokstav: "Markeringarna", "Sparade ord".
    static func report(_ what: String, detail: String) {
        AppLog.shared.write("Kunde inte spara: \(what). \(detail)")
        lock.lock()
        count += 1
        let now = Date()
        let show = lastShown[what].map { now.timeIntervalSince($0) > 60 } ?? true
        if show {
            lastShown[what] = now
        }
        lock.unlock()
        guard show else { return }
        Task { @MainActor in
            present(title: "\(what) kunde inte sparas",
                    message: "Den senaste ändringen sparades inte. Försök igen. Fortsätter det, dela loggen under "
                        + "Inställningar, Diagnostik.")
        }
    }

    @MainActor
    private static func present(title: String, message: String) {
        guard !SelfTest.isActive else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first,
              var top = window.rootViewController else {
            return
        }
        while let presented = top.presentedViewController {
            top = presented
        }
        guard !(top is UIAlertController) else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        top.present(alert, animated: true)
    }
}
