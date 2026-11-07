import Foundation

/// När appen går ut (G1). Med gratis Apple-ID gäller profilen som Sideloadly lägger in i sju dagar.
/// Utgångsdatumet läses ur `embedded.mobileprovision` i appaketet. I simulatorn finns ingen profil,
/// och då visas ingen varning.
enum AppExpiry {

    /// Hur långt i förväg varningen visas.
    static let warningWindow: TimeInterval = 2 * 86_400

    /// Självtestet: ett påhittat utgångsdatum, så att raden i biblioteket går att se i simulatorn.
    static var overrideDate: Date?

    /// Profilens utgångsdatum, eller nil om profilen saknas (simulatorn, eller en app från App Store).
    static let profileExpirationDate: Date? = {
        #if targetEnvironment(simulator)
        return nil
        #else
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return parse(data)
        #endif
    }()

    static var expirationDate: Date? {
        overrideDate ?? profileExpirationDate
    }

    /// Profilen är en signerad fil (CMS) med en vanlig plist i mitten. Plisten letas upp och läses.
    static func parse(_ data: Data) -> Date? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else {
            return nil
        }
        let plist = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let values = try? PropertyListSerialization.propertyList(from: plist, options: [], format: nil)
                as? [String: Any] else {
            return nil
        }
        return values["ExpirationDate"] as? Date
    }

    /// Appens namn som det syns på hemskärmen.
    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Appen"
    }

    /// Raden i biblioteket, eller nil när mer än två dagar är kvar.
    static func warning(now: Date = Date()) -> String? {
        guard let date = expirationDate else { return nil }
        return warning(expiring: date, now: now)
    }

    /// "Läsa går ut torsdag kl. 14, förnya i Sideloadly."
    static func warning(expiring date: Date, now: Date, calendar: Calendar = .current) -> String? {
        let remaining = date.timeIntervalSince(now)
        guard remaining < warningWindow else { return nil }
        guard remaining > 0 else {
            return "\(appName) har gått ut. Förnya den i Sideloadly."
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: date)).day ?? 0
        let day: String
        switch days {
        case 0: day = "i dag"
        case 1: day = "i morgon"
        default:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "sv_SE")
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "EEEE"
            day = formatter.string(from: date)
        }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let hour = parts.hour ?? 0
        let minute = parts.minute ?? 0
        let time = minute == 0 ? "\(hour)" : String(format: "%d.%02d", hour, minute)
        return "\(appName) går ut \(day) kl. \(time), förnya i Sideloadly."
    }
}
