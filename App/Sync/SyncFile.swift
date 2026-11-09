import Foundation

// Synkfilerna (F1): en JSON-fil per enhet i mappen "Sensus synk" i den valda mappen i iCloud Drive.
// Formatet står i docs/SYNK.md och läses och skrivs på samma sätt av Windows-appen (windows/src/js/sync.js).
// Allt här är ren logik utan filer, så att det går att pröva i XCTest.

/// En läsposition i en synkfil. `bookID` är bokens kontrollsumma (SHA-256, gemener hex).
struct SyncPosition: Equatable {
    var bookID: String
    var title: String
    /// "pdf" eller "reflow" (EPUB och text).
    var kind: String
    var section: Int
    var progression: Double
    var updated: Double
}

struct SyncHighlight: Equatable {
    var id: String
    var bookID: String
    var section: Int
    var start: Int
    var length: Int
    var text: String
    var color: String
    var note: String
    var created: Double
    var updated: Double
    var deleted: Bool
}

struct SyncBookmark: Equatable {
    var id: String
    var bookID: String
    var section: Int
    var progression: Double
    var label: String
    var created: Double
    var updated: Double
    var deleted: Bool
}

/// Enheten som skrev filen.
struct SyncDevice: Equatable {
    var id: String
    var name: String
    var platform: String
}

/// Allt i en synkfil: enhetens hela bild av läspositioner, markeringar, bokmärken och sparade ord.
/// Borttaget finns kvar som rader med `deleted`. En rad som saknas betyder aldrig att något är borttaget.
struct SyncSnapshot: Equatable {
    var device: SyncDevice
    var written: Double
    /// Nyckel: bokens kontrollsumma.
    var positions: [String: SyncPosition] = [:]
    /// Nyckel: markeringens id med gemener.
    var highlights: [String: SyncHighlight] = [:]
    var bookmarks: [String: SyncBookmark] = [:]
    /// Nyckel: `SyncWord.key` (språk och grundform).
    var words: [String: SyncWord] = [:]
    /// Rader som inte gick att läsa och hoppades över.
    var skippedRows = 0

    var rowCount: Int {
        positions.count + highlights.count + bookmarks.count + words.count
    }

    var isEmpty: Bool {
        rowCount == 0
    }
}

enum SyncFile {

    /// Formatets version. Höjs bara när en äldre app inte längre kan läsa filen rätt. Nya fält i en rad
    /// höjer den inte: läsaren hoppar över fält den inte känner till.
    static let format = 1
    /// Undermappen i den valda mappen där enheternas filer ligger.
    static let folderName = "Sensus synk"
    static let fileExtension = "json"

    enum ReadError: Error, Equatable {
        case empty
        case notJSON
        case notSensus
        case newerFormat(Int)

        var text: String {
            switch self {
            case .empty: return "filen är tom"
            case .notJSON: return "filen går inte att läsa (trasig eller halvt hämtad)"
            case .notSensus: return "filen är inte en synkfil från Sensus"
            case .newerFormat(let version): return "filen har format \(version) från en nyare version av Sensus"
            }
        }
    }

    // MARK: Läsa

    static func decode(_ data: Data) -> Result<SyncSnapshot, ReadError> {
        guard !data.isEmpty else { return .failure(.empty) }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            return .failure(.notJSON)
        }
        guard let format = (root["format"] as? NSNumber)?.intValue, format >= 1,
              let device = root["device"] as? [String: Any],
              let deviceID = device["id"] as? String, !deviceID.isEmpty else {
            return .failure(.notSensus)
        }
        guard format <= Self.format else { return .failure(.newerFormat(format)) }
        var snapshot = SyncSnapshot(device: SyncDevice(id: deviceID, name: device["name"] as? String ?? "",
                                                       platform: device["platform"] as? String ?? ""),
                                    written: SyncTime.seconds(root["written_at"]) ?? 0)
        for row in rows(root["positions"], skipped: &snapshot.skippedRows) {
            guard let position = position(from: row) else {
                snapshot.skippedRows += 1
                continue
            }
            insert(position, into: &snapshot.positions, key: position.bookID, updated: \.updated)
        }
        for row in rows(root["highlights"], skipped: &snapshot.skippedRows) {
            guard let highlight = highlight(from: row) else {
                snapshot.skippedRows += 1
                continue
            }
            insert(highlight, into: &snapshot.highlights, key: highlight.id, updated: \.updated)
        }
        for row in rows(root["bookmarks"], skipped: &snapshot.skippedRows) {
            guard let bookmark = bookmark(from: row) else {
                snapshot.skippedRows += 1
                continue
            }
            insert(bookmark, into: &snapshot.bookmarks, key: bookmark.id, updated: \.updated)
        }
        for row in rows(root["saved_words"], skipped: &snapshot.skippedRows) {
            guard let word = word(from: row) else {
                snapshot.skippedRows += 1
                continue
            }
            snapshot.words[word.key] = SyncMerge.mergeWord(snapshot.words[word.key], word)
        }
        return .success(snapshot)
    }

    /// Raderna i en lista. Något annat än en lista räknas som en överhoppad rad, saknas listan är den tom.
    private static func rows(_ value: Any?, skipped: inout Int) -> [[String: Any]] {
        guard let value = value, !(value is NSNull) else { return [] }
        guard let list = value as? [Any] else {
            skipped += 1
            return []
        }
        var result: [[String: Any]] = []
        for item in list {
            if let row = item as? [String: Any] {
                result.append(row)
            } else {
                skipped += 1
            }
        }
        return result
    }

    /// Samma nyckel två gånger i en fil: den nyaste gäller.
    private static func insert<T>(_ value: T, into map: inout [String: T], key: String, updated: KeyPath<T, Double>) {
        if let existing = map[key], !SyncTime.newer(value[keyPath: updated], than: existing[keyPath: updated]) {
            return
        }
        map[key] = value
    }

    static func position(from row: [String: Any]) -> SyncPosition? {
        guard let book = (row["book_id"] as? String)?.lowercased(), !book.isEmpty,
              let kind = row["kind"] as? String, kind == "pdf" || kind == "reflow",
              let updated = SyncTime.seconds(row["updated_at"]),
              let section = int(row["section"]), section >= 0 else { return nil }
        let progression = rounded(min(max(double(row["progression"]) ?? 0, 0), 1))
        return SyncPosition(bookID: book, title: row["title"] as? String ?? "", kind: kind, section: section,
                            progression: progression, updated: updated)
    }

    static func highlight(from row: [String: Any]) -> SyncHighlight? {
        guard let id = (row["id"] as? String)?.lowercased(), !id.isEmpty,
              let book = (row["book_id"] as? String)?.lowercased(), !book.isEmpty,
              let updated = SyncTime.seconds(row["updated_at"]),
              let section = int(row["section"]), section >= 0,
              let start = int(row["start"]), start >= 0,
              let length = int(row["length"]), length >= 0 else { return nil }
        return SyncHighlight(id: id, bookID: book, section: section, start: start, length: length,
                             text: row["text"] as? String ?? "", color: row["color"] as? String ?? "yellow",
                             note: row["note"] as? String ?? "", created: SyncTime.seconds(row["created_at"]) ?? updated,
                             updated: updated, deleted: bool(row["deleted"]))
    }

    static func bookmark(from row: [String: Any]) -> SyncBookmark? {
        guard let id = (row["id"] as? String)?.lowercased(), !id.isEmpty,
              let book = (row["book_id"] as? String)?.lowercased(), !book.isEmpty,
              let updated = SyncTime.seconds(row["updated_at"]),
              let section = int(row["section"]), section >= 0 else { return nil }
        return SyncBookmark(id: id, bookID: book, section: section,
                            progression: rounded(min(max(double(row["progression"]) ?? 0, 0), 1)),
                            label: row["label"] as? String ?? "", created: SyncTime.seconds(row["created_at"]) ?? updated,
                            updated: updated, deleted: bool(row["deleted"]))
    }

    static func word(from row: [String: Any]) -> SyncWord? {
        guard let lemma = row["lemma"] as? String, !lemma.isEmpty,
              let language = row["language"] as? String, language == "sv" || language == "en",
              let updated = SyncTime.seconds(row["updated_at"]) else { return nil }
        var word = SyncWord(lemma: lemma, language: language)
        word.word = row["word"] as? String ?? lemma
        word.sentence = row["sentence"] as? String ?? ""
        word.book = row["book"] as? String ?? ""
        word.page = int(row["page"]) ?? 0
        word.lookups = max(int(row["lookups"]) ?? 1, 1)
        word.created = SyncTime.seconds(row["created_at"]) ?? updated
        word.updated = updated
        word.deleted = bool(row["deleted"])
        if !word.deleted, let reviewUpdated = SyncTime.seconds(row["review_updated_at"]), let due = double(row["due"]) {
            word.due = due
            word.interval = double(row["interval"]) ?? 0
            word.ease = double(row["ease"]) ?? 2.5
            word.reps = int(row["reps"]) ?? 0
            word.lapses = int(row["lapses"]) ?? 0
            word.reviewUpdated = reviewUpdated
        }
        return word
    }

    // MARK: Skriva

    static func encode(_ snapshot: SyncSnapshot) throws -> Data {
        let root: [String: Any] = [
            "format": format,
            "app": "Sensus",
            "device": ["id": snapshot.device.id, "name": snapshot.device.name, "platform": snapshot.device.platform],
            "written_at": SyncTime.string(snapshot.written),
            "positions": snapshot.positions.keys.sorted().compactMap { key -> [String: Any]? in
                snapshot.positions[key].map { row($0) }
            },
            "highlights": snapshot.highlights.keys.sorted().compactMap { key -> [String: Any]? in
                snapshot.highlights[key].map { row($0) }
            },
            "bookmarks": snapshot.bookmarks.keys.sorted().compactMap { key -> [String: Any]? in
                snapshot.bookmarks[key].map { row($0) }
            },
            "saved_words": snapshot.words.keys.sorted().compactMap { key -> [String: Any]? in
                snapshot.words[key].map { row($0) }
            },
        ]
        var options: JSONSerialization.WritingOptions = [.sortedKeys]
        if #available(iOS 13.0, *) {
            options.insert(.withoutEscapingSlashes)
        }
        return try JSONSerialization.data(withJSONObject: root, options: options)
    }

    static func row(_ position: SyncPosition) -> [String: Any] {
        ["book_id": position.bookID, "title": position.title, "kind": position.kind, "section": position.section,
         "progression": rounded(position.progression), "updated_at": SyncTime.string(position.updated)]
    }

    static func row(_ highlight: SyncHighlight) -> [String: Any] {
        ["id": highlight.id, "book_id": highlight.bookID, "section": highlight.section, "start": highlight.start,
         "length": highlight.length, "text": highlight.text, "color": highlight.color, "note": highlight.note,
         "created_at": SyncTime.string(highlight.created), "updated_at": SyncTime.string(highlight.updated),
         "deleted": highlight.deleted]
    }

    static func row(_ bookmark: SyncBookmark) -> [String: Any] {
        ["id": bookmark.id, "book_id": bookmark.bookID, "section": bookmark.section,
         "progression": rounded(bookmark.progression), "label": bookmark.label,
         "created_at": SyncTime.string(bookmark.created), "updated_at": SyncTime.string(bookmark.updated),
         "deleted": bookmark.deleted]
    }

    static func row(_ word: SyncWord) -> [String: Any] {
        let review = !word.deleted && word.reviewUpdated != nil && word.due != nil
        return [
            "lemma": word.lemma, "language": word.language, "word": word.word, "sentence": word.sentence,
            "book": word.book, "page": word.page, "lookups": word.lookups,
            "created_at": SyncTime.string(word.created), "updated_at": SyncTime.string(word.updated),
            "deleted": word.deleted,
            "due": review ? (word.due ?? 0) as Any : NSNull() as Any,
            "interval": review ? (word.interval ?? 0) as Any : NSNull() as Any,
            "ease": review ? (word.ease ?? 2.5) as Any : NSNull() as Any,
            "reps": review ? (word.reps ?? 0) as Any : NSNull() as Any,
            "lapses": review ? (word.lapses ?? 0) as Any : NSNull() as Any,
            "review_updated_at": review ? SyncTime.string(word.reviewUpdated ?? 0) as Any : NSNull() as Any,
        ]
    }

    /// Andelar med sex decimaler, så att samma värde alltid skrivs likadant.
    static func rounded(_ value: Double) -> Double {
        (value * 1_000_000).rounded() / 1_000_000
    }

    // MARK: Tolkning

    static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            let double = number.doubleValue
            guard double.isFinite, abs(double) < 1e12 else { return nil }
            return Int(double)
        }
        if let text = value as? String {
            return Int(text)
        }
        return nil
    }

    static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            let double = number.doubleValue
            return double.isFinite ? double : nil
        }
        if let text = value as? String {
            return Double(text)
        }
        return nil
    }

    static func bool(_ value: Any?) -> Bool {
        if let flag = value as? Bool {
            return flag
        }
        return (value as? NSNumber)?.intValue == 1
    }
}

/// Sammanslagningen (F1): den nyaste ändringen vinner, rad för rad, räknat i hela millisekunder. För ett
/// sparat ord jämförs ordet och repetitionen var för sig. Vid lika tid vinner det som redan fanns (den lokala
/// bilden läggs först), så att en annan enhets fil aldrig skriver över något lokalt som är lika nytt eller nyare.
enum SyncMerge {

    /// Slår ihop bilderna. Den första i listan vinner vid lika tid. Ingenting tas bort för att det saknas
    /// i en fil: en rad finns med i resultatet om den finns i någon av bilderna.
    static func merge(_ snapshots: [SyncSnapshot], device: SyncDevice, written: Double) -> SyncSnapshot {
        var result = SyncSnapshot(device: device, written: written)
        for snapshot in snapshots {
            for (key, position) in snapshot.positions {
                result.positions[key] = newest(result.positions[key], position, \.updated)
            }
            for (key, highlight) in snapshot.highlights {
                result.highlights[key] = newest(result.highlights[key], highlight, \.updated)
            }
            for (key, bookmark) in snapshot.bookmarks {
                result.bookmarks[key] = newest(result.bookmarks[key], bookmark, \.updated)
            }
            for (key, word) in snapshot.words {
                result.words[key] = mergeWord(result.words[key], word)
            }
        }
        return result
    }

    /// `incoming` om den är nyare än `existing`, annars `existing`.
    static func newest<T>(_ existing: T?, _ incoming: T, _ updated: KeyPath<T, Double>) -> T {
        guard let existing = existing else { return incoming }
        return SyncTime.newer(incoming[keyPath: updated], than: existing[keyPath: updated]) ? incoming : existing
    }

    /// Ett sparat ord ur två bilder: ordet från den med nyast `updated`, repetitionen från den med nyast
    /// `reviewUpdated`. Ett borttaget ord har ingen repetition. Vid lika tid vinner `existing`.
    static func mergeWord(_ existing: SyncWord?, _ incoming: SyncWord) -> SyncWord {
        guard let existing = existing else {
            var word = incoming
            if word.deleted {
                clearReview(&word)
            }
            return word
        }
        let wordFromIncoming = SyncTime.newer(incoming.updated, than: existing.updated)
        let reviewFromIncoming = SyncTime.newer(incoming.reviewUpdated, than: existing.reviewUpdated)
        let reviewFromExisting = !reviewFromIncoming && SyncTime.newer(existing.reviewUpdated, than: incoming.reviewUpdated)
        var merged = wordFromIncoming ? incoming : existing
        let source = reviewFromIncoming ? incoming : (reviewFromExisting ? existing : merged)
        if merged.deleted {
            clearReview(&merged)
        } else {
            merged.due = source.due
            merged.interval = source.interval
            merged.ease = source.ease
            merged.reps = source.reps
            merged.lapses = source.lapses
            merged.reviewUpdated = source.reviewUpdated
        }
        return merged
    }

    private static func clearReview(_ word: inout SyncWord) {
        word.due = nil
        word.interval = nil
        word.ease = nil
        word.reps = nil
        word.lapses = nil
        word.reviewUpdated = nil
    }

    /// Det som ska sparas på enheten: rader i den sammanslagna bilden som är nyare än enhetens egna.
    struct Changes: Equatable {
        var positions: [SyncPosition] = []
        var highlights: [SyncHighlight] = []
        var bookmarks: [SyncBookmark] = []
        var words: [SyncWord] = []

        var count: Int {
            positions.count + highlights.count + bookmarks.count + words.count
        }
    }

    static func changes(local: SyncSnapshot, merged: SyncSnapshot) -> Changes {
        var changes = Changes()
        for key in merged.positions.keys.sorted() {
            guard let position = merged.positions[key] else { continue }
            if SyncTime.newer(position.updated, than: local.positions[key]?.updated) {
                changes.positions.append(position)
            }
        }
        for key in merged.highlights.keys.sorted() {
            guard let highlight = merged.highlights[key] else { continue }
            if SyncTime.newer(highlight.updated, than: local.highlights[key]?.updated) {
                changes.highlights.append(highlight)
            }
        }
        for key in merged.bookmarks.keys.sorted() {
            guard let bookmark = merged.bookmarks[key] else { continue }
            if SyncTime.newer(bookmark.updated, than: local.bookmarks[key]?.updated) {
                changes.bookmarks.append(bookmark)
            }
        }
        for key in merged.words.keys.sorted() {
            guard let word = merged.words[key] else { continue }
            let mine = local.words[key]
            let wordNewer = SyncTime.newer(word.updated, than: mine?.updated)
            let reviewNewer = !word.deleted && SyncTime.newer(word.reviewUpdated, than: mine?.reviewUpdated)
            if wordNewer || reviewNewer {
                changes.words.append(word)
            }
        }
        return changes
    }

    /// Hur många rader som är nya eller ändrade jämfört med förra versionen av filen. Raderna jämförs som de
    /// skrivs i filen, så att en tid som lästs tillbaka ur filen (i hela millisekunder) räknas som samma.
    static func changedRows(from old: SyncSnapshot?, to new: SyncSnapshot) -> Int {
        guard let old = old else { return new.rowCount }
        func differs(_ a: [String: Any], _ b: [String: Any]?) -> Bool {
            guard let b = b else { return true }
            return !NSDictionary(dictionary: a).isEqual(to: b)
        }
        var count = 0
        count += new.positions.filter { differs(SyncFile.row($0.value), old.positions[$0.key].map { SyncFile.row($0) }) }.count
        count += new.highlights.filter { differs(SyncFile.row($0.value), old.highlights[$0.key].map { SyncFile.row($0) }) }
            .count
        count += new.bookmarks.filter { differs(SyncFile.row($0.value), old.bookmarks[$0.key].map { SyncFile.row($0) }) }
            .count
        count += new.words.filter { differs(SyncFile.row($0.value), old.words[$0.key].map { SyncFile.row($0) }) }.count
        return count
    }
}
