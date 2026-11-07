import Foundation
import SQLite3

/// Säkerhetskopior i Filer (G1): Documents/Säkerhetskopia/<datum och tid>/ med markeringar och anteckningar
/// (`markeringar.sqlite`), sparade ord med repetitionen (`anvandarord.sqlite`) och läspositionerna
/// (`lasepositioner.json`, de ligger annars i UserDefaults). En kopia per dag, de sju senaste sparas.
///
/// Databaserna kopieras med SQLite:s backup, som ger en hel och riktig kopia även medan appen skriver.
/// Kopian görs med egna anslutningar i en egen kö, så att huvudtråden inte väntar.
enum Backup {

    static let keep = 7

    struct Copy {
        let url: URL
        let date: Date
    }

    enum Failure: LocalizedError {
        case missing(String)
        case sqlite(String)

        var errorDescription: String? {
            switch self {
            case .missing(let name): return "\(name) finns inte i kopian."
            case .sqlite(let message): return "Databasen kunde inte kopieras: \(message)"
            }
        }
    }

    private static let queue = DispatchQueue(label: "se.edvin.lasa.backup", qos: .utility)
    private static let annotationsName = "markeringar.sqlite"
    private static let wordsName = "anvandarord.sqlite"
    private static let positionsName = "lasepositioner.json"
    /// Nycklarna i UserDefaults som hör till läspositionerna.
    private static let positionPrefixes = ["position.", "location.", "positionDate."]

    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Säkerhetskopia", isDirectory: true)
    }

    private static let folderFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return formatter
    }()

    // MARK: Kopiorna

    /// Kopiorna, nyast först.
    static func copies() -> [Copy] {
        let manager = FileManager.default
        let urls = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey,
                                                                                               .contentModificationDateKey],
                                                     options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url -> Copy? in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values?.isDirectory == true, url.pathExtension != "tmp",
                  manager.fileExists(atPath: url.appendingPathComponent(annotationsName).path)
                    || manager.fileExists(atPath: url.appendingPathComponent(wordsName).path) else {
                return nil
            }
            let date = folderFormatter.date(from: url.lastPathComponent) ?? values?.contentModificationDate ?? .distantPast
            return Copy(url: url, date: date)
        }
        .sorted { $0.date > $1.date }
    }

    /// Gör en kopia om ingen har gjorts i dag. Körs i bakgrunden, `completion` på huvudtråden.
    static func makeDailyIfNeeded(completion: ((Copy?) -> Void)? = nil) {
        queue.async {
            let today = Calendar.current.startOfDay(for: Date())
            var made: Copy?
            if !copies().contains(where: { $0.date >= today }) {
                made = try? makeNow()
            }
            if let completion = completion {
                DispatchQueue.main.async { completion(made) }
            }
        }
    }

    /// Gör en kopia nu, oavsett om det redan finns en i dag. Körs i bakgrunden, `completion` på huvudtråden.
    static func make(completion: @escaping (Result<Copy, Error>) -> Void) {
        let positions = positionSnapshot()
        queue.async {
            let result = Result { try makeNow(positions: positions) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Körs i kön.
    private static func makeNow(positions: [String: Any]? = nil) throws -> Copy {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let date = Date()
        var name = folderFormatter.string(from: date)
        var final = directory.appendingPathComponent(name, isDirectory: true)
        var suffix = 2
        while manager.fileExists(atPath: final.path) {
            name = folderFormatter.string(from: date) + " \(suffix)"
            final = directory.appendingPathComponent(name, isDirectory: true)
            suffix += 1
        }
        // Först i en tillfällig mapp, så att en avbruten kopia aldrig ser hel ut.
        let temporary = directory.appendingPathComponent(name + ".tmp", isDirectory: true)
        try? manager.removeItem(at: temporary)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
        do {
            for (source, file) in [(AnnotationStore.fileURL, annotationsName), (UserWords.fileURL, wordsName)]
            where manager.fileExists(atPath: source.path) {
                try copyDatabase(from: source, to: temporary.appendingPathComponent(file))
            }
            let snapshot = positions ?? positionSnapshot()
            let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: temporary.appendingPathComponent(positionsName))
            try manager.moveItem(at: temporary, to: final)
        } catch {
            try? manager.removeItem(at: temporary)
            AppLog.shared.write("Säkerhetskopian misslyckades: \(error.localizedDescription)")
            throw error
        }
        prune()
        AppLog.shared.write("Säkerhetskopia sparad: \(name)")
        return Copy(url: final, date: date)
    }

    /// Behåller de sju senaste.
    private static func prune() {
        for old in copies().dropFirst(keep) {
            try? FileManager.default.removeItem(at: old.url)
        }
    }

    // MARK: Återställ

    /// Ersätter markeringar, anteckningar, sparade ord och läspositioner med kopians.
    /// Först sparas en kopia av det som finns nu, så att återställningen går att ångra.
    /// Körs på huvudtråden, eftersom databaserna används där.
    static func restore(_ copy: Copy) throws {
        // Vänta ut en kopia som pågår.
        queue.sync {}
        let current = positionSnapshot()
        try queue.sync {
            _ = try makeNow(positions: current)
        }
        let annotations = copy.url.appendingPathComponent(annotationsName)
        let words = copy.url.appendingPathComponent(wordsName)
        let manager = FileManager.default
        guard manager.fileExists(atPath: annotations.path) || manager.fileExists(atPath: words.path) else {
            throw Failure.missing("Databaserna")
        }
        if manager.fileExists(atPath: annotations.path) {
            try AnnotationStore.shared.restore(from: annotations)
        }
        if manager.fileExists(atPath: words.path) {
            try UserWords.shared.restore(from: words)
        }
        let positions = copy.url.appendingPathComponent(positionsName)
        if let data = try? Data(contentsOf: positions),
           let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            restorePositions(values)
        }
        AppLog.shared.write("Återställt från säkerhetskopian \(copy.url.lastPathComponent)")
    }

    // MARK: Läspositionerna

    static func positionSnapshot() -> [String: Any] {
        UserDefaults.standard.dictionaryRepresentation().filter { key, value in
            positionPrefixes.contains { key.hasPrefix($0) } && (value is String || value is NSNumber)
        }
    }

    private static func restorePositions(_ values: [String: Any]) {
        let defaults = UserDefaults.standard
        for key in positionSnapshot().keys {
            defaults.removeObject(forKey: key)
        }
        for (key, value) in values where positionPrefixes.contains(where: { key.hasPrefix($0) }) {
            defaults.set(value, forKey: key)
        }
    }

    // MARK: SQLite

    /// Kopierar en hel databas med SQLite:s backup, i egna anslutningar.
    static func copyDatabase(from source: URL, to destination: URL) throws {
        var from: OpaquePointer?
        var to: OpaquePointer?
        defer {
            sqlite3_close(from)
            sqlite3_close(to)
        }
        guard sqlite3_open_v2(source.path, &from, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw Failure.sqlite(message(from))
        }
        try? FileManager.default.removeItem(at: destination)
        guard sqlite3_open_v2(destination.path, &to, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw Failure.sqlite(message(to))
        }
        try SQLiteDatabase.backup(from: from, to: to)
    }

    private static func message(_ handle: OpaquePointer?) -> String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "okänt fel"
    }
}
