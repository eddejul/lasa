import UIKit

/// Färgerna i hela appen (U1, Papper och bläck). Varje bakgrund i läsaren har en palett med samma namn
/// på färgerna, så att biblioteket, menyraderna, rutorna och listorna följer bakgrunden man valt.
/// Värdena kommer ur designunderlaget (5-design.md, Färgtoken). Vitt har Pappers färger runt sidan.
struct Palette {
    /// Bakgrund bakom allt (biblioteket, listor).
    let canvas: UIColor
    /// Kort, rutor, celler, popovers och ark.
    let surface: UIColor
    /// Sökfält, chips och nedsänkta ytor.
    let surfaceSunk: UIColor
    /// Läsarens papper.
    let page: UIColor
    /// Huvudtext.
    let ink: UIColor
    /// Sekundär text.
    let inkSoft: UIColor
    /// Platshållare och avstängt. För svag för text man måste läsa.
    let inkFaint: UIColor
    /// Hårlinjer och ramar.
    let rule: UIColor
    /// Knappar, länkar och reglage.
    let accent: UIColor
    /// Bakgrund för valda chips och knappar.
    let accentSoft: UIColor
    /// Bokmärkesbandet.
    let ribbon: UIColor
    let success: UIColor
    let warning: UIColor
    let isDark: Bool

    var interfaceStyle: UIUserInterfaceStyle {
        isDark ? .dark : .light
    }
}

@MainActor
enum Theme {

    /// Skickas när temat har bytts, så att vyer som redan syns kan måla om sig.
    static let didChange = Notification.Name("ThemeDidChange")

    /// Paletten för bakgrunden som gäller nu (med Följ systemet inräknat).
    static var current: Palette {
        palette(for: ReaderTheme.effective)
    }

    static func palette(for theme: ReaderTheme) -> Palette {
        switch theme {
        case .paper, .white:
            return Palette(canvas: hex(0xF6F2EA), surface: hex(0xFFFDF8), surfaceSunk: hex(0xEEE8DD),
                           page: theme == .white ? .white : hex(0xFBF8F2),
                           ink: hex(0x1E1C19), inkSoft: hex(0x5F5950), inkFaint: hex(0x9A9387), rule: hex(0xE2DBCF),
                           accent: hex(0x2D5B84), accentSoft: hex(0xE3ECF4), ribbon: hex(0xB4432F),
                           success: hex(0x3E7B57), warning: hex(0xB7791F), isDark: false)
        case .sepia:
            return Palette(canvas: hex(0xEFE5D0), surface: hex(0xF8F0DF), surfaceSunk: hex(0xE6D9BF),
                           page: hex(0xF4ECD8),
                           ink: hex(0x3B2F23), inkSoft: hex(0x6E5D48), inkFaint: hex(0xA28F75), rule: hex(0xDCCDB0),
                           accent: hex(0x8A4B1F), accentSoft: hex(0xEEDCC6), ribbon: hex(0xA33E28),
                           success: hex(0x4F7A3C), warning: hex(0x9C6418), isDark: false)
        case .dark:
            return Palette(canvas: hex(0x141311), surface: hex(0x211F1C), surfaceSunk: hex(0x2B2925),
                           page: hex(0x1C1C1C),
                           ink: hex(0xE8E3DA), inkSoft: hex(0xABA497), inkFaint: hex(0x6F695F), rule: hex(0x37342F),
                           accent: hex(0x8DB4DC), accentSoft: hex(0x253446), ribbon: hex(0xD46A55),
                           success: hex(0x7DBF95), warning: hex(0xE0A94F), isDark: true)
        }
    }

    static func hex(_ value: UInt32) -> UIColor {
        UIColor(red: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1)
    }

    /// New York, systemets serif (iOS 13), till rubriker, boktitlar, ord och citat. Följer Dynamic Type
    /// när `style` anges. Faller tillbaka på systemfonten om serif saknas.
    static func serif(_ style: UIFont.TextStyle, size: CGFloat? = nil, weight: UIFont.Weight = .regular) -> UIFont {
        let base = UIFont.preferredFont(forTextStyle: style)
        let pointSize = size ?? base.pointSize
        let system = UIFont.systemFont(ofSize: pointSize, weight: weight)
        guard let descriptor = system.fontDescriptor.withDesign(.serif) else { return system }
        let font = UIFont(descriptor: descriptor, size: pointSize)
        return size == nil ? UIFontMetrics(forTextStyle: style).scaledFont(for: font) : font
    }

    // MARK: Hela appen

    /// Lägger temat på fönstren och på systemets standardvyer (tabeller, celler, menyrader) som skapas
    /// härefter, och skickar `didChange` så att vyer som redan syns målar om sig.
    static func apply() {
        let palette = current
        UITableView.appearance().backgroundColor = palette.canvas
        UITableView.appearance().separatorColor = palette.rule
        UITableViewCell.appearance().backgroundColor = palette.surface
        let navigation = navigationAppearance(palette)
        UINavigationBar.appearance().standardAppearance = navigation
        UINavigationBar.appearance().scrollEdgeAppearance = navigation
        UINavigationBar.appearance().compactAppearance = navigation
        UIToolbar.appearance().barTintColor = palette.canvas
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.tintColor = palette.accent
                window.overrideUserInterfaceStyle = palette.interfaceStyle
                window.backgroundColor = palette.canvas
            }
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Menyraden i biblioteket och listorna: canvas-bakgrund, bläck och stora rubriker i New York.
    static func navigationAppearance(_ palette: Palette) -> UINavigationBarAppearance {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = palette.canvas
        appearance.shadowColor = palette.rule
        appearance.titleTextAttributes = [.foregroundColor: palette.ink,
                                          .font: serif(.headline, size: 17, weight: .semibold)]
        appearance.largeTitleTextAttributes = [.foregroundColor: palette.ink,
                                               .font: serif(.largeTitle, size: 34, weight: .semibold)]
        return appearance
    }

    /// Menyraden i läsarna: ligger ovanpå sidan och har sidans papper som bakgrund, med en hårlinje under.
    static func readerAppearance(_ palette: Palette) -> UINavigationBarAppearance {
        // Samma slags bakgrund som förut (genomskinlig rad ovanpå sidan), så att sidans plats inte ändras,
        // men med sidans papper i stället för systemets glas.
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.backgroundEffect = nil
        appearance.backgroundColor = palette.page.withAlphaComponent(0.97)
        appearance.shadowColor = palette.rule
        appearance.titleTextAttributes = [.foregroundColor: palette.ink]
        return appearance
    }

    /// Målar om en navigeringsrad som redan finns.
    static func style(_ bar: UINavigationBar?) {
        guard let bar = bar else { return }
        let appearance = navigationAppearance(current)
        bar.standardAppearance = appearance
        bar.scrollEdgeAppearance = appearance
        bar.compactAppearance = appearance
        bar.tintColor = current.accent
    }

    /// En tabell som redan finns: bakgrund, linjer och de celler som syns.
    static func style(_ tableView: UITableView) {
        let palette = current
        tableView.backgroundColor = palette.canvas
        tableView.separatorColor = palette.rule
        for cell in tableView.visibleCells {
            cell.backgroundColor = palette.surface
        }
    }
}
