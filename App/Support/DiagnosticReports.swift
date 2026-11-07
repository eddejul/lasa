import Foundation
import MetricKit

/// Apples egna rapporter (MetricKit, G4): krascher, frysningar och en daglig sammanfattning av starttid,
/// minne och hängningar. iOS lämnar dem när de finns, oftast dagen efter. De sparas som JSON i
/// Documents/Diagnostik/MetricKit och följer med när loggen delas. Om iOS lämnar rapporter till en app
/// som installerats med gratis Apple-ID är inte känt, därför finns den egna loggen också.
final class DiagnosticReports: NSObject, MXMetricManagerSubscriber {

    static let shared = DiagnosticReports()

    static var directory: URL {
        AppLog.directory.appendingPathComponent("MetricKit", isDirectory: true)
    }

    /// Högst så här många rapporter sparas, de äldsta tas bort.
    private static let keep = 30

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        MXMetricManager.shared.add(self)
    }

    /// Rapporterna som finns, äldst först.
    static func files() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                                 options: [.skipsHiddenFiles])) ?? []
        return urls.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            save(payload.jsonRepresentation(), kind: "matvarden")
        }
        AppLog.shared.write("MetricKit: \(payloads.count) sammanfattningar sparade")
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            save(payload.jsonRepresentation(), kind: "diagnostik")
            let crashes = payload.crashDiagnostics?.count ?? 0
            let hangs = payload.hangDiagnostics?.count ?? 0
            AppLog.shared.write("MetricKit: rapport med \(crashes) krascher och \(hangs) frysningar sparad")
        }
    }

    private func save(_ data: Data, kind: String) {
        let manager = FileManager.default
        try? manager.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let suffix = String(UUID().uuidString.prefix(4))
        let name = "\(formatter.string(from: Date())) \(kind) \(suffix).json"
        try? data.write(to: Self.directory.appendingPathComponent(name))
        for old in Self.files().dropLast(Self.keep) {
            try? manager.removeItem(at: old)
        }
    }
}
