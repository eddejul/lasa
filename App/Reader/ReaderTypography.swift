import UIKit

/// Typsnitt och textstorlek för EPUB och textfiler. Gäller alla böcker och sparas mellan gångerna.
struct ReaderTypography: Equatable {

    enum Font: String, CaseIterable {
        case original
        case iowan
        case charter
        case georgia
        case palatino
        case avenir
        case system

        var title: String {
            switch self {
            case .original: return "Bokens eget"
            case .iowan: return "Iowan"
            case .charter: return "Charter"
            case .georgia: return "Georgia"
            case .palatino: return "Palatino"
            case .avenir: return "Avenir"
            case .system: return "San Francisco"
            }
        }

        /// Typsnittet i CSS, eller nil för bokens eget.
        var cssFamily: String? {
            switch self {
            case .original: return nil
            case .iowan: return "\"Iowan Old Style\", Georgia, serif"
            case .charter: return "Charter, Georgia, serif"
            case .georgia: return "Georgia, serif"
            case .palatino: return "Palatino, \"Palatino Linotype\", serif"
            case .avenir: return "\"Avenir Next\", Avenir, sans-serif"
            case .system: return "-apple-system, system-ui, sans-serif"
            }
        }

        /// Typsnittet som namnet visas med i listan.
        func previewFont(size: CGFloat) -> UIFont {
            let name: String?
            switch self {
            case .original, .system: name = nil
            case .iowan: name = "IowanOldStyle-Roman"
            case .charter: name = "Charter-Roman"
            case .georgia: name = "Georgia"
            case .palatino: name = "Palatino-Roman"
            case .avenir: name = "AvenirNext-Regular"
            }
            if let name = name, let font = UIFont(name: name, size: size) {
                return font
            }
            return .systemFont(ofSize: size)
        }
    }

    /// Storlekarna, som andel av bokens egen textstorlek.
    static let sizes: [Double] = [0.8, 0.9, 1.0, 1.1, 1.2, 1.35, 1.5, 1.7, 2.0]
    static let defaultSizeIndex = 2

    private static let fontKey = "reader.font"
    private static let sizeKey = "reader.size"

    var font: Font
    var sizeIndex: Int

    var scale: Double {
        Self.sizes[min(max(sizeIndex, 0), Self.sizes.count - 1)]
    }

    var canShrink: Bool {
        sizeIndex > 0
    }

    var canGrow: Bool {
        sizeIndex < Self.sizes.count - 1
    }

    /// Del av nyckeln för sparade sidantal.
    var key: String {
        "\(font.rawValue)-\(sizeIndex)"
    }

    static var current: ReaderTypography {
        get {
            let defaults = UserDefaults.standard
            let font = defaults.string(forKey: fontKey).flatMap(Font.init(rawValue:)) ?? .original
            let size = defaults.object(forKey: sizeKey) as? Int ?? defaultSizeIndex
            return ReaderTypography(font: font, sizeIndex: min(max(size, 0), sizes.count - 1))
        }
        set {
            UserDefaults.standard.set(newValue.font.rawValue, forKey: fontKey)
            UserDefaults.standard.set(newValue.sizeIndex, forKey: sizeKey)
        }
    }
}
