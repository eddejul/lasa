import UIKit

/// Bakgrunden som PDF-sidorna visas med. Valet gäller alla böcker och sparas mellan gångerna.
enum ReaderTheme: String, CaseIterable {
    case white
    case sepia
    case dark

    private static let defaultsKey = "reader.theme"

    static var current: ReaderTheme {
        get {
            UserDefaults.standard.string(forKey: defaultsKey).flatMap(ReaderTheme.init(rawValue:)) ?? .white
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }

    var title: String {
        switch self {
        case .white: return "Vitt"
        case .sepia: return "Sepia"
        case .dark: return "Mörkt"
        }
    }

    var symbolName: String {
        switch self {
        case .white: return "sun.max"
        case .sepia: return "cup.and.saucer"
        case .dark: return "moon"
        }
    }

    /// Färgen som sidans vita papper får.
    var paperColor: UIColor {
        switch self {
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

            case .sepia:
                // Papperet blir sepia, svart text förblir svart.
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
