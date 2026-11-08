import UIKit

/// Bakgrunden i läsaren, och sedan U1 i hela appen (`Theme`). Valet gäller alla böcker och sparas.
/// Papper (varmvitt) är förvalt. Vitt finns kvar för PDF:er som har eget papper.
enum ReaderTheme: String, CaseIterable {
    case paper
    case white
    case sepia
    case dark

    private static let defaultsKey = "reader.theme"
    private static let followKey = "reader.theme.followSystem"

    /// Bakgrunden som valts. Papper om inget valts (U1).
    static var current: ReaderTheme {
        get {
            UserDefaults.standard.string(forKey: defaultsKey).flatMap(ReaderTheme.init(rawValue:)) ?? .paper
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }

    /// Följ systemet: Mörkt när iPaden är i mörkt läge, annars den valda bakgrunden.
    static var followsSystem: Bool {
        get { UserDefaults.standard.bool(forKey: followKey) }
        set { UserDefaults.standard.set(newValue, forKey: followKey) }
    }

    /// Om systemet är i mörkt läge. Sätts av SceneDelegate ur fönsterscenens egenskaper.
    static var systemIsDark = false

    /// Bakgrunden som gäller nu.
    static var effective: ReaderTheme {
        followsSystem && systemIsDark ? .dark : current
    }

    var title: String {
        switch self {
        case .paper: return "Papper"
        case .white: return "Vitt"
        case .sepia: return "Sepia"
        case .dark: return "Mörkt"
        }
    }

    var symbolName: String {
        switch self {
        case .paper: return "doc.plaintext"
        case .white: return "sun.max"
        case .sepia: return "cup.and.saucer"
        case .dark: return "moon"
        }
    }

    /// Färgen som sidans vita papper får.
    var paperColor: UIColor {
        switch self {
        case .paper: return UIColor(red: 0xFB / 255, green: 0xF8 / 255, blue: 0xF2 / 255, alpha: 1)
        case .white: return .white
        case .sepia: return UIColor(red: 0.957, green: 0.925, blue: 0.847, alpha: 1)
        case .dark: return UIColor(white: 0.11, alpha: 1)
        }
    }

    var isDark: Bool {
        self == .dark
    }
}

/// Lägger temat på en färdigritad sida. Anropas på renderingskön, aldrig på huvudtråden.
enum PageImageStyler {

    static func apply(_ theme: ReaderTheme, to image: UIImage) -> UIImage {
        guard theme != .white, image.size.width > 0, image.size.height > 0 else { return image }

        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        format.preferredRange = .standard
        let rect = CGRect(origin: .zero, size: image.size)

        return UIGraphicsImageRenderer(size: image.size, format: format).image { context in
            let cg = context.cgContext
            switch theme {
            case .white:
                image.draw(in: rect)

            case .paper, .sepia:
                // Papperet blir varmvitt eller sepia, svart text förblir svart.
                cg.setFillColor(theme.paperColor.cgColor)
                cg.fill(rect)
                image.draw(in: rect, blendMode: .multiply, alpha: 1)

            case .dark:
                // Sidan på vitt papper först, så att genomskinliga sidor också får mörkt papper.
                cg.setFillColor(UIColor.white.cgColor)
                cg.fill(rect)
                image.draw(in: rect)
                // Vänd ljusheten men behåll färgtonen, så att diagram och bilder inte blir negativ.
                cg.setBlendMode(.difference)
                cg.fill(rect)
                image.draw(in: rect, blendMode: .hue, alpha: 1)

                // Mjukare kontrast: papperet blir mörkgrått (0,125 gånger 0,88 ger 0,11), texten ljusgrå.
                cg.setBlendMode(.lighten)
                cg.setFillColor(UIColor(white: 0.125, alpha: 1).cgColor)
                cg.fill(rect)
                cg.setBlendMode(.multiply)
                cg.setFillColor(UIColor(white: 0.88, alpha: 1).cgColor)
                cg.fill(rect)
            }
        }
    }
}
