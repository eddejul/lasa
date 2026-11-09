import Foundation

/// En fråga till ett ställe i boken (K6). Kommer ur en frågefil bredvid boken (`docs/FRAGOR.md`).
struct BookQuestion: Equatable {
    /// Frågans id i filen, eller ett id räknat ur frågans text när filen inte har något.
    let id: String
    /// Frågans nummer i filen, från 1. Står i pricken i marginalen.
    let number: Int
    let title: String
    let question: String
    /// Svaret, en rad per punkt. Tomt när filen inte har något svar.
    let answer: [String]
    /// Ett ordagrant citat ur boken där frågan hör hemma. Letas upp som en markering.
    let quote: String
    /// Hjälp att hitta stället: sidan i filen (PDF, från 1).
    let page: Int?
    /// Hjälp att hitta stället: kapitlet (EPUB och text), ett nummer från 1 eller en rubrik.
    let chapterNumber: Int?
    let chapterTitle: String?
    /// PDF utan text (fotad): var på sidan pricken står, 0 överst och 1 nederst.
    let y: Double?
}

/// Hur det gick på en fråga: Kan, Osäker eller Kan inte.
enum QuestionStatus: String, CaseIterable {
    case unknown = "kan_inte"
    case unsure = "osaker"
    case known = "kan"

    var title: String {
        switch self {
        case .known: return "Kan"
        case .unsure: return "Osäker"
        case .unknown: return "Kan inte"
        }
    }
}

/// Var en fråga står i boken: avsnittet (PDF-sidan eller kapitlet) och citatet i avsnittets text.
/// `length` 0 betyder att citatet inte hittades och att pricken står på `y` (en fotad sida).
struct QuestionPlace: Equatable {
    let section: Int
    let start: Int
    let length: Int
    let y: Double?
}

/// Frågefilen (K6): JSON bredvid boken, `Bok.pdf.fragor.json` eller `Bok.fragor.json`. Ren logik (G13).
enum BookQuestionFile {

    static let suffix = ".fragor.json"

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Granskning 5, L2: större frågefiler läses inte. En vanlig fil med hundra frågor är några tiotal kB.
    static let maxBytes = 2_000_000

    /// Läser och tolkar en frågefil. En fil över `maxBytes` läses inte alls, med ett tydligt besked. Kan köras
    /// utanför huvudtråden (ren logik och filen).
    static func read(_ url: URL) throws -> [BookQuestion] {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxBytes else {
            throw Failure(description: "Frågefilen är större än 2 MB och läses inte")
        }
        return try parse(Data(contentsOf: url))
    }

    /// Sant för en frågefil. Biblioteket visar dem aldrig som böcker.
    static func isQuestionFile(_ name: String) -> Bool {
        name.lowercased().hasSuffix(suffix)
    }

    /// Där frågefilen till en bok kan ligga, i den ordning de prövas: bredvid boken med hela filnamnet,
    /// bredvid boken med namnet utan ändelse, och samma två namn direkt i Böcker.
    static func candidates(forBookAt url: URL, booksDirectory: URL) -> [URL] {
        let name = url.lastPathComponent
        let stem = url.deletingPathExtension().lastPathComponent
        let folder = url.deletingLastPathComponent()
        var result = [folder.appendingPathComponent(name + suffix), folder.appendingPathComponent(stem + suffix)]
        if folder.standardizedFileURL.path != booksDirectory.standardizedFileURL.path {
            result += [booksDirectory.appendingPathComponent(name + suffix),
                       booksDirectory.appendingPathComponent(stem + suffix)]
        }
        return result
    }

    /// Frågefilen till en bok, om den finns.
    static func url(for book: Book, booksDirectory: URL = LibraryStore.shared.booksDirectory) -> URL? {
        candidates(forBookAt: book.url, booksDirectory: booksDirectory).first {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    /// Där en ny frågefil läggs när den väljs i Filer: bredvid boken, med bokens hela filnamn.
    static func target(for book: Book) -> URL {
        book.url.deletingLastPathComponent().appendingPathComponent(book.url.lastPathComponent + suffix)
    }

    /// Läser frågorna. Godtar en lista direkt eller ett objekt med listan under `fragor` (eller `questions`).
    /// En fråga måste ha en fråga och ett citat eller en sida, annars hoppas den över.
    static func parse(_ data: Data) throws -> [BookQuestion] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw Failure(description: "Filen är inte giltig JSON")
        }
        let list: [Any]
        if let array = object as? [Any] {
            list = array
        } else if let dictionary = object as? [String: Any],
                  let array = (dictionary["fragor"] ?? dictionary["frågor"] ?? dictionary["questions"]) as? [Any] {
            list = array
        } else {
            throw Failure(description: "Filen saknar listan fragor")
        }
        var result: [BookQuestion] = []
        var used = Set<String>()
        for item in list {
            guard let entry = item as? [String: Any] else { continue }
            let question = text(entry["fraga"] ?? entry["fråga"] ?? entry["question"])
            let quote = text(entry["citat"] ?? entry["quote"])
            // Granskning 5, L5: sidan hålls inom 1 till 100 000, så att ett jättetal inte kan spilla över.
            let page = integer(entry["sida"] ?? entry["page"]).map { min(max($0, 1), 100_000) }
            guard !question.isEmpty, !quote.isEmpty || page != nil else { continue }
            let number = result.count + 1
            var id = text(entry["id"])
            if id.isEmpty {
                id = "f" + String(stableHash(question + "|" + quote), radix: 36)
            }
            // Samma id två gånger (en kopierad fråga): den andra får numret efter sig.
            if used.contains(id) {
                id += "-\(number)"
            }
            used.insert(id)
            let chapter = entry["kapitel"] ?? entry["chapter"]
            let y = (entry["y"] as? NSNumber)?.doubleValue
            result.append(BookQuestion(id: id, number: number,
                                       title: text(entry["titel"] ?? entry["title"]),
                                       question: question,
                                       answer: lines(entry["svar"] ?? entry["answer"]),
                                       quote: quote,
                                       page: page,
                                       chapterNumber: integer(chapter),
                                       chapterTitle: chapter is String && integer(chapter) == nil ? text(chapter) : nil,
                                       y: y.map { min(max($0, 0), 1) }))
        }
        return result
    }

    /// Avsnittet att börja leta i: filens sida (PDF) eller kapitlet, ur numret eller rubriken.
    /// `chapterTitles` är kapitlens rubriker i läsordning (EPUB och text), tomt för PDF.
    static func hint(for question: BookQuestion, chapterTitles: [String], sectionCount: Int) -> Int? {
        if chapterTitles.isEmpty {
            guard let page = question.page else { return nil }
            return min(max(page, 1) - 1, max(sectionCount - 1, 0))
        }
        if let number = question.chapterNumber, number >= 1, number <= chapterTitles.count {
            return number - 1
        }
        if let title = question.chapterTitle.map(FoldedText.query), !title.isEmpty {
            if let exact = chapterTitles.firstIndex(where: { FoldedText.query($0) == title }) {
                return exact
            }
            return chapterTitles.firstIndex { FoldedText.query($0).hasPrefix(title) || FoldedText.query($0).contains(title) }
        }
        return nil
    }

    private static func text(_ value: Any?) -> String {
        if let string = value as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return ""
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func lines(_ value: Any?) -> [String] {
        if let list = value as? [Any] {
            return list.map { text($0) }.filter { !$0.isEmpty }
        }
        let single = text(value)
        return single.isEmpty ? [] : [single]
    }

    /// FNV-1a, samma svar varje gång (Swifts `hashValue` byts vid varje start).
    static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}

/// K6: frågorna i marginalen av eller på. Gäller alla böcker, avstängt från början (Edvin: en toggle).
enum QuestionsSetting {

    static let didChange = Notification.Name("QuestionsSettingDidChange")
    private static let key = "reader.questions"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }
}

/// Hur det gick på frågorna: tabellen `question_answers` i markeringar.sqlite (steg 10 i trappan, följer
/// med i säkerhetskopian). En rad per bok och fråga med det senaste svaret. Bara från huvudtråden.
final class QuestionStore {

    static let shared = QuestionStore()

    /// Skickas när ett svar har sparats. `object` är bokens nyckel.
    static let didChange = Notification.Name("QuestionStoreDidChange")

    private init() {}

    func statuses(book: String) -> [String: QuestionStatus] {
        var result: [String: QuestionStatus] = [:]
        AnnotationStore.shared.readBooks { db in
            try db.query("SELECT question, status FROM question_answers WHERE book = ?", [book]) { row in
                if let status = QuestionStatus(rawValue: row.string(1)) {
                    result[row.string(0)] = status
                }
            }
        }
        return result
    }

    func setStatus(_ status: QuestionStatus, question: String, book: String) {
        AnnotationStore.shared.writeBooks("svaret på frågan") { db in
            try db.execute("""
                INSERT INTO question_answers (book, question, status, answered, updated) VALUES (?, ?, ?, 1, ?)
                ON CONFLICT(book, question) DO UPDATE SET status = excluded.status, answered = answered + 1,
                    updated = excluded.updated
                """, [book, question, status.rawValue, Date().timeIntervalSince1970])
        }
        NotificationCenter.default.post(name: Self.didChange, object: book)
    }
}
