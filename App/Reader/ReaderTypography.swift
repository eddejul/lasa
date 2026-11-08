import UIKit

/// Typsnitt, textstorlek, marginal, radavstånd och justering för EPUB och textfiler (U2). Gäller alla
/// böcker och sparas mellan gångerna. Allt som ändrar hur texten bryts ingår i `key`, så att de sparade
/// sidantalen bara används med samma utseende.
struct ReaderTypography: Equatable {

    enum Font: String, CaseIterable {
        case original
        case newYork
        case iowan
        case charter
        case georgia
        case palatino
        case avenir
        case system

        var title: String {
            switch self {
            case .original: return "Bokens eget"
            case .newYork: return "New York"
            case .iowan: return "Iowan"
            case .charter: return "Charter"
            case .georgia: return "Georgia"
            case .palatino: return "Palatino"
            case .avenir: return "Avenir"
            case .system: return "San Francisco"
            }
        }

        /// Namnet på knappen i utseenderutan.
        var shortTitle: String {
            self == .original ? "Bokens" : title
        }

        /// Typsnittet i CSS, eller nil för bokens eget.
        var cssFamily: String? {
            switch self {
            case .original: return nil
            case .newYork: return "ui-serif, \"New York\", Georgia, serif"
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
            case .newYork:
                let system = UIFont.systemFont(ofSize: size)
                return system.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: size) } ?? system
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

    /// Marginalen, och med den hur lång raden får bli: Smal ungefär 75 tecken, Normal 66, Bred 58.
    enum Margin: String, CaseIterable {
        case narrow
        case normal
        case wide

        var title: String {
            switch self {
            case .narrow: return "Smal"
            case .normal: return "Normal"
            case .wide: return "Bred"
            }
        }

        /// Gånger läsarens vanliga sidmarginal.
        var factor: CGFloat {
            switch self {
            case .narrow: return 0.7
            case .normal: return 1.0
            case .wide: return 1.4
            }
        }

        /// Längsta raden i em. Ett tecken är i snitt ungefär 0,44 em i serifftypsnitt (mätt i simulatorn:
        /// 34 em gav 76 tecken i Georgia), så 29,5 em ger ungefär 66 tecken.
        var measure: Double {
            switch self {
            case .narrow: return 33.5
            case .normal: return 29.5
            case .wide: return 26
            }
        }
    }

    enum LineSpacing: String, CaseIterable {
        case tight
        case normal
        case airy

        var title: String {
            switch self {
            case .tight: return "Tätt"
            case .normal: return "Normalt"
            case .airy: return "Luftigt"
            }
        }

        var lineHeight: Double {
            switch self {
            case .tight: return 1.3
            case .normal: return 1.5
            case .airy: return 1.75
            }
        }
    }

    /// Storlekarna, som andel av bokens egen textstorlek.
    static let sizes: [Double] = [0.8, 0.9, 1.0, 1.1, 1.2, 1.35, 1.5, 1.7, 2.0]
    static let defaultSizeIndex = 2

    private static let fontKey = "reader.font"
    private static let sizeKey = "reader.size"
    private static let marginKey = "reader.margin"
    private static let spacingKey = "reader.lineSpacing"
    private static let justifyKey = "reader.justify"

    var font: Font
    var sizeIndex: Int
    var margin: Margin = .normal
    var lineSpacing: LineSpacing = .normal
    /// Justerade stycken, avstavade på bokens språk.
    var justify = true

    /// Det som Återställ ger.
    static let standard = ReaderTypography(font: .original, sizeIndex: defaultSizeIndex)

    var scale: Double {
        Self.sizes[min(max(sizeIndex, 0), Self.sizes.count - 1)]
    }

    var canShrink: Bool {
        sizeIndex > 0
    }

    var canGrow: Bool {
        sizeIndex < Self.sizes.count - 1
    }

    /// Del av nyckeln för sparade sidantal. Marginal, radavstånd och justering ändrar hur texten bryts.
    var key: String {
        "\(font.rawValue)-\(sizeIndex)-\(margin.rawValue)-\(lineSpacing.rawValue)-\(justify ? "j" : "v")"
    }

    static var current: ReaderTypography {
        get {
            let defaults = UserDefaults.standard
            let font = defaults.string(forKey: fontKey).flatMap(Font.init(rawValue:)) ?? .original
            let size = defaults.object(forKey: sizeKey) as? Int ?? defaultSizeIndex
            var value = ReaderTypography(font: font, sizeIndex: min(max(size, 0), sizes.count - 1))
            value.margin = defaults.string(forKey: marginKey).flatMap(Margin.init(rawValue:)) ?? .normal
            value.lineSpacing = defaults.string(forKey: spacingKey).flatMap(LineSpacing.init(rawValue:)) ?? .normal
            value.justify = defaults.object(forKey: justifyKey) as? Bool ?? true
            return value
        }
        set {
            UserDefaults.standard.set(newValue.font.rawValue, forKey: fontKey)
            UserDefaults.standard.set(newValue.sizeIndex, forKey: sizeKey)
            UserDefaults.standard.set(newValue.margin.rawValue, forKey: marginKey)
            UserDefaults.standard.set(newValue.lineSpacing.rawValue, forKey: spacingKey)
            UserDefaults.standard.set(newValue.justify, forKey: justifyKey)
        }
    }
}
