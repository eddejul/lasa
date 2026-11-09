import Foundation

/// En sparad AI-fråga (K6b), som JSON i `ai_questions.questions`. Fälten är kravets (id, typ, nar, fraga, svar,
/// oppen, plats, kalla, bok, position), plus var i boken platsen och källan står, till prickarna och Visa i boken.
struct AIStoredQuestion: Codable, Equatable {
    var id: String
    var typ: String
    var nar: String
    var fraga: String
    var svar: [String]
    var oppen: Bool
    var plats: String
    var kalla: String
    var bok: String
    /// Platsens slut i hela kapitlets text (UTF-16), bara för frågorna i texten.
    var position: Int?
    /// iPaden: avsnittet där platsen står (PDF-sidan från 0 eller kapitlet) och den träffade texten ordagrant.
    var avsnitt: Int?
    var ankare: String?
    /// iPaden: avsnittet där källan står och den träffade texten ordagrant.
    var kallaAvsnitt: Int?
    var kallaAnkare: String?
}

/// En rad i `ai_questions`: frågorna till en del av ett kapitel.
struct AIQuestionRecord: Equatable {
    let book: String
    let chapter: String
    let part: Int
    let chapterTitle: String
    let model: String
    let created: Double
    let summary: String
    let concepts: [String]
    let questions: [AIStoredQuestion]

    /// Kapitlets ordning i boken (kapitlet eller första sidan).
    var order: Int {
        AIQuestions.order(ofChapterKey: chapter)
    }
}

/// AI-frågorna i markeringar.sqlite (steg 13, följer med i säkerhetskopian, ingen synk). Bara från huvudtråden.
final class AIQuestionStore {

    static let shared = AIQuestionStore()

    /// Skickas när en boks frågor har sparats. `object` är bokens id.
    static let didChange = Notification.Name("AIQuestionStoreDidChange")

    private init() {}

    private static func decodeQuestions(_ text: String) -> [AIStoredQuestion] {
        guard let data = text.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([AIStoredQuestion].self, from: data)) ?? []
    }

    private static func decodeList(_ text: String) -> [String] {
        guard let data = text.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    static func encode<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// Bokens rader i läsordning (kapitlet, sedan delen).
    func records(book: String) -> [AIQuestionRecord] {
        var result: [AIQuestionRecord] = []
        AnnotationStore.shared.readBooks { db in
            try db.query("""
                SELECT chapter, part, chapter_title, model, created, summary, concepts, questions
                FROM ai_questions WHERE book = ?
                """, [book]) { row in
                result.append(AIQuestionRecord(book: book, chapter: row.string(0), part: row.int(1),
                                               chapterTitle: row.string(2), model: row.string(3),
                                               created: row.double(4), summary: row.string(5),
                                               concepts: Self.decodeList(row.string(6)),
                                               questions: Self.decodeQuestions(row.string(7))))
            }
        }
        return result.sorted { ($0.order, $0.part) < ($1.order, $1.part) }
    }

    /// Kapitlen (nycklarna) som redan har sparats för boken, också de utan frågor.
    func chapterKeys(book: String) -> Set<String> {
        var result = Set<String>()
        AnnotationStore.shared.readBooks { db in
            try db.query("SELECT DISTINCT chapter FROM ai_questions WHERE book = ?", [book]) { row in
                result.insert(row.string(0))
            }
        }
        return result
    }

    /// Böckerna som har AI-frågor, med när de senast fick frågor.
    func books() -> [(book: String, latest: Double)] {
        var result: [(book: String, latest: Double)] = []
        AnnotationStore.shared.readBooks { db in
            try db.query("SELECT book, MAX(created) FROM ai_questions GROUP BY book") { row in
                result.append((row.string(0), row.double(1)))
            }
        }
        return result
    }

    /// Sparar ett kapitels delar och tar bort kapitlets gamla rader i samma transaktion (Gör nya frågor).
    @discardableResult
    func replace(book: String, chapter: String, with records: [AIQuestionRecord]) -> Bool {
        let saved = AnnotationStore.shared.writeBooks("AI-frågorna") { db in
            try db.execute("DELETE FROM ai_questions WHERE book = ? AND chapter = ?", [book, chapter])
            for record in records {
                try db.execute("""
                    INSERT OR REPLACE INTO ai_questions (book, chapter, part, chapter_title, model, created, summary,
                        concepts, questions) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [book, chapter, record.part, record.chapterTitle, record.model, record.created,
                          record.summary, Self.encode(record.concepts), Self.encode(record.questions)])
            }
        }
        if saved {
            NotificationCenter.default.post(name: Self.didChange, object: book)
        }
        return saved
    }
}

/// Det skrivna svaret och Jämförs bedömning (K6b), i `question_answers` (steg 13).
extension QuestionStore {

    func myAnswer(question: String, book: String) -> (text: String, feedback: String) {
        var result = (text: "", feedback: "")
        AnnotationStore.shared.readBooks { db in
            try db.query("SELECT my_answer, feedback FROM question_answers WHERE book = ? AND question = ?",
                         [book, question]) { row in
                result = (row.string(0), row.string(1))
            }
        }
        return result
    }

    /// Sparar det skrivna svaret. En fråga som inte besvarats med Kan, Osäker eller Kan inte får en rad utan
    /// läge (`status` tom, `answered` 0), som inte räknas som besvarad.
    func setMyAnswer(_ text: String, question: String, book: String) {
        AnnotationStore.shared.writeBooks("ditt svar på frågan") { db in
            try db.execute("""
                INSERT INTO question_answers (book, question, status, answered, updated, my_answer)
                VALUES (?, ?, '', 0, ?, ?)
                ON CONFLICT(book, question) DO UPDATE SET my_answer = excluded.my_answer, updated = excluded.updated
                """, [book, question, Date().timeIntervalSince1970, text])
        }
    }

    /// Sparar Jämförs bedömning (JSON) tillsammans med svaret den gäller.
    func setFeedback(_ feedback: String, myAnswer: String, question: String, book: String) {
        AnnotationStore.shared.writeBooks("bedömningen av svaret") { db in
            try db.execute("""
                INSERT INTO question_answers (book, question, status, answered, updated, my_answer, feedback)
                VALUES (?, ?, '', 0, ?, ?, ?)
                ON CONFLICT(book, question) DO UPDATE SET my_answer = excluded.my_answer,
                    feedback = excluded.feedback, updated = excluded.updated
                """, [book, question, Date().timeIntervalSince1970, myAnswer, feedback])
        }
    }
}
