import Foundation
import SQLite3

/// Säkerhetskopior i Filer (G1): Documents/Säkerhetskopia/<datum och tid>/ med markeringar och anteckningar
/// (`markeringar.sqlite`), sparade ord med repetitionen (`anvandarord.sqlite`) och läspositionerna
/// (`lasepositioner.json`, de ligger annars i UserDefaults). En kopia per dag, de sju senaste dagarna sparas.
/// I dag sparas alla kopior (högst tio, de äldsta automatiska tas först), och för tidigare dagar den nyaste
/// av varje slag: automatisk, egen (Spara en kopia nu) och före en återställning, så att en kopia Edvin gör
/// själv aldrig ersätter dagens automatiska (granskning 2, N1). Kopian före flytten till bokens id ligger i en
/// egen mapp, Före uppdateringen <datum tid>, som aldrig rensas.
///
/// Databaserna kopieras med SQLite:s backup, som ger en hel och riktig kopia även medan appen skriver.
/// Kopian görs med egna anslutningar i en egen kö, så att huvudtråden inte väntar.
enum Backup {

    static let keep = 7
    /// Högst så många kopior i dag (N1).
    static let todayLimit = 10

    /// Vem som gjorde kopian. Syns i namnet på mappen.
    enum Kind: Equatable, Hashable {
        /// Dagens kopia, som appen gör själv.
        case automatic
        /// Spara en kopia nu.
        case manual
        /// Kopian av läget före en återställning.
        case beforeRestore
    }

    struct Copy: Equatable {
        let url: URL
        let date: Date
        /// Kopian före en flytt av data (Före uppdateringen). Den rensas aldrig.
        var isBeforeUpdate = false
        var kind: Kind = .automatic
    }

    /// Slutet på mappens namn för kopior som inte är automatiska.
    private static let manualSuffix = " egen"
    private static let beforeRestoreSuffix = " före återställning"

    /// Början på namnet för kopior före en flytt av data. Mappar med det namnet rensas aldrig.
    static let beforeUpdatePrefix = "Före uppdateringen "

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
    /// Nycklarna i UserDefaults som hör till läspositionerna: under filnamnet (före G3) och under bokens id.
    private static let positionPrefixes = ["position.", "location.", "positionDate.",
                                           "bookPosition.", "bookLocation.", "bookPositionDate.",
                                           // P3: bokens ram för beskärningen.
                                           PageCropStore.prefix]

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
            let name = url.lastPathComponent
            let beforeUpdate = name.hasPrefix(beforeUpdatePrefix)
            let stamp = beforeUpdate ? String(name.dropFirst(beforeUpdatePrefix.count)) : name
            // "2026-11-08 101500 2" (en andra kopia samma sekund) läses på de första 17 tecknen.
            let date = folderFormatter.date(from: String(stamp.prefix(17)))
                ?? values?.contentModificationDate ?? .distantPast
            let kind: Kind = stamp.contains(beforeRestoreSuffix) ? .beforeRestore
                : stamp.contains(manualSuffix) ? .manual : .automatic
            return Copy(url: url, date: date, isBeforeUpdate: beforeUpdate, kind: kind)
        }
        .sorted { $0.date > $1.date }
    }

    /// De dagliga kopiorna, nyast först (utan kopiorna före en flytt).
    static func dailyCopies() -> [Copy] {
        copies().filter { !$0.isBeforeUpdate }
    }

    /// Gör en kopia om ingen har gjorts i dag. Körs i bakgrunden, `completion` på huvudtråden.
    static func makeDailyIfNeeded(completion: ((Copy?) -> Void)? = nil) {
        queue.async {
            let today = Calendar.current.startOfDay(for: Date())
            var made: Copy?
            if !dailyCopies().contains(where: { $0.date >= today }) {
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
            let result = Result { try makeNow(positions: positions, kind: .manual) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// G3: en kopia precis innan läspositioner och markeringar flyttas från filnamnet till bokens id.
    /// Den ligger i en egen mapp (Före uppdateringen <datum tid>) som aldrig rensas.
    /// Körs på huvudtråden och väntar tills kopian är klar. Falskt om den inte gick att spara.
    static func makeBeforeMigration() -> Bool {
        let positions = positionSnapshot()
        do {
            let copy = try queue.sync { try makeNow(positions: positions, prefix: beforeUpdatePrefix, prune: false) }
            AppLog.shared.write("Säkerhetskopia före flytten till bokens id: \(copy.url.lastPathComponent)")
            return true
        } catch {
            return false
        }
    }

    /// Körs i kön. `prune` falskt: inga kopior tas bort (före en återställning och en flytt).
    private static func makeNow(positions: [String: Any]? = nil, prefix: String = "", kind: Kind = .automatic,
                                prune shouldPrune: Bool = true) throws -> Copy {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let date = Date()
        let kindSuffix = kind == .manual ? manualSuffix : kind == .beforeRestore ? beforeRestoreSuffix : ""
        var name = prefix + folderFormatter.string(from: date) + kindSuffix
        var final = directory.appendingPathComponent(name, isDirectory: true)
        var suffix = 2
        while manager.fileExists(atPath: final.path) {
            name = prefix + folderFormatter.string(from: date) + kindSuffix + " \(suffix)"
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
        if shouldPrune {
            prune()
        }
        AppLog.shared.write("Säkerhetskopia sparad: \(name)")
        return Copy(url: final, date: date, isBeforeUpdate: !prefix.isEmpty, kind: kind)
    }

    /// Behåller den nyaste kopian för var och en av de sju senaste dagarna. Kopiorna före en flytt och
    /// `protecting` (kopian som just återställts) tas aldrig bort. Avbrutna kopior (.tmp) städas bort.
    private static func prune(protecting: URL? = nil) {
        let manager = FileManager.default
        for old in copiesToRemove(dailyCopies(), keep: keep, protecting: protecting) {
            try? manager.removeItem(at: old.url)
            AppLog.shared.write("Säkerhetskopia rensad: \(old.url.lastPathComponent)")
        }
        let leftovers = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in leftovers where url.pathExtension == "tmp" {
            try? manager.removeItem(at: url)
        }
    }

    /// Vilka kopior som ska bort (granskning 2, N1). I dag: inga, utom när det finns fler än `todayLimit`, och då
    /// de äldsta automatiska först. Tidigare dagar: den nyaste kopian av varje slag per dag sparas för de `keep`
    /// senaste dagarna (i dag räknas som en), resten tas bort. Aldrig `protecting` (kopian som just återställts)
    /// eller en kopia före en flytt. Ren logik, testad i XCTest.
    static func copiesToRemove(_ copies: [Copy], keep: Int, protecting: URL?, now: Date = Date(),
                               calendar: Calendar = .current) -> [Copy] {
        let today = calendar.startOfDay(for: now)
        func isProtected(_ copy: Copy) -> Bool {
            guard let protecting = protecting else { return false }
            return copy.url.standardizedFileURL == protecting.standardizedFileURL
        }
        let daily = copies.filter { !$0.isBeforeUpdate }
        var remove: [Copy] = []

        let todays = daily.filter { $0.date >= today }
        if todays.count > todayLimit {
            // Automatiska före egna, äldst först.
            let order = todays.filter { !isProtected($0) }.sorted { a, b in
                if (a.kind == .automatic) != (b.kind == .automatic) { return a.kind == .automatic }
                return a.date < b.date
            }
            remove += order.prefix(todays.count - todayLimit)
        }

        var days: [Date] = todays.isEmpty ? [] : [today]
        var keptKinds: [Date: Set<Kind>] = [:]
        for copy in daily.filter({ $0.date < today }).sorted(by: { $0.date > $1.date }) {
            let day = calendar.startOfDay(for: copy.date)
            if !days.contains(day), days.count < keep {
                days.append(day)
            }
            if days.contains(day), keptKinds[day]?.contains(copy.kind) != true {
                keptKinds[day, default: []].insert(copy.kind)
                continue
            }
            if !isProtected(copy) {
                remove.append(copy)
            }
        }
        return remove
    }

    // MARK: Återställ

    /// Ersätter markeringar, anteckningar, sparade ord och läspositioner med kopians.
    /// Först sparas en kopia av det som finns nu, så att återställningen går att ångra. Den kopian rensar
    /// ingenting, och rensningen efteråt rör aldrig kopian som återställts (granskningens fynd 1).
    /// Körs på huvudtråden, eftersom databaserna används där.
    static func restore(_ copy: Copy) throws {
        let annotations = copy.url.appendingPathComponent(annotationsName)
        let words = copy.url.appendingPathComponent(wordsName)
        let manager = FileManager.default
        guard manager.fileExists(atPath: annotations.path) || manager.fileExists(atPath: words.path) else {
            throw Failure.missing("Databaserna")
        }
        // Vänta ut en kopia som pågår.
        queue.sync {}
        let current = positionSnapshot()
        try queue.sync {
            _ = try makeNow(positions: current, kind: .beforeRestore, prune: false)
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
        queue.sync {
            prune(protecting: copy.url)
        }
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
        // Kopian blir en vanlig databas utan WAL, en enda fil i Filer.
        sqlite3_exec(to, "PRAGMA journal_mode = DELETE", nil, nil, nil)
    }

    private static func message(_ handle: OpaquePointer?) -> String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "okänt fel"
    }
}
