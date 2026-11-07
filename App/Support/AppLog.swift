import Foundation
import UIKit

/// En logg i Filer (Documents/Diagnostik/logg.txt), så att det som händer på iPaden går att se i efterhand:
/// starter, tider, sidor som inte kunde ritas, minnesvarningar, fel som inte kunde sparas och synkens fel.
/// Kan anropas från vilken tråd som helst. Raderna skrivs i en egen kö. Högst cirka 1 MB, sedan flyttas
/// loggen till logg-förra.txt och en ny börjar.
final class AppLog {

    static let shared = AppLog()

    static let maxBytes = 1_000_000

    private let queue = DispatchQueue(label: "se.edvin.lasa.logg", qos: .utility)
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "sv_SE")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Diagnostik", isDirectory: true)
    }

    static var fileURL: URL {
        directory.appendingPathComponent("logg.txt")
    }

    static var previousURL: URL {
        directory.appendingPathComponent("logg-förra.txt")
    }

    private init() {}

    /// Lägger till en rad med tid först.
    func write(_ text: String) {
        let now = Date()
        queue.async { [formatter] in
            let line = formatter.string(from: now) + "  " + text + "\n"
            AppLog.append(line)
        }
    }

    /// Väntar tills alla rader är skrivna, till exempel innan loggen delas.
    func flush() {
        queue.sync {}
    }

    /// Filerna att dela: den förra loggen om den finns, och den nuvarande.
    var shareableFiles: [URL] {
        flush()
        return [AppLog.previousURL, AppLog.fileURL].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func append(_ line: String) {
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL
        if let size = (try? manager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue,
           size > maxBytes {
            try? manager.removeItem(at: previousURL)
            try? manager.moveItem(at: url, to: previousURL)
        }
        let data = Data(line.utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: url)
        }
    }

    /// Första raden vid varje start: version, enhet, iOS, minne och ledigt utrymme.
    @MainActor
    func writeLaunch() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let device = UIDevice.current
        let ram = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        var free = "okänt"
        if let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let bytes = values.volumeAvailableCapacityForImportantUsage {
            free = String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
        }
        write("Start: version \(version) (\(build)), \(device.model), \(device.systemName) \(device.systemVersion), "
              + String(format: "%.1f GB RAM", ram) + ", ledigt \(free), appen använder "
              + String(format: "%.0f MB", MemoryUsage.megabytes))
    }
}
