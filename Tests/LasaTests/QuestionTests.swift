import XCTest
@testable import Lasa

/// K6: frågefilen, var den ligger, prickarnas placering och steg 10 i trappan.
final class QuestionTests: XCTestCase {

    func testParsesTheDocumentedFormat() throws {
        let json = """
        {"sensus": "frågor", "version": 1, "fragor": [
          {"id": "a", "sida": 2, "citat": "Den som söker", "titel": "Rubrik", "fraga": "Vad?", "svar": ["Ett", "Två"]},
          {"sida": "3", "y": 1.4, "fraga": "Fotad sida", "svar": "Ett svar"},
          {"citat": "Bara citat", "kapitel": "Kapitel 3", "fraga": "Kapitel som rubrik"},
          {"citat": "Kapitel som nummer", "kapitel": 4, "fraga": "Fyra"},
          {"fraga": "Utan citat och sida hoppas över"},
          {"citat": "Utan fråga hoppas över"},
          {"id": "a", "citat": "Samma id", "fraga": "Kopia"}
        ]}
        """
        let questions = try BookQuestionFile.parse(Data(json.utf8))
        XCTAssertEqual(questions.count, 5)
        XCTAssertEqual(questions.map(\.number), [1, 2, 3, 4, 5])
        XCTAssertEqual(questions[0].answer, ["Ett", "Två"])
        XCTAssertEqual(questions[0].page, 2)
        XCTAssertEqual(questions[1].page, 3)
        XCTAssertEqual(questions[1].y, 1)
        XCTAssertEqual(questions[1].answer, ["Ett svar"])
        XCTAssertEqual(questions[2].chapterTitle, "Kapitel 3")
        XCTAssertNil(questions[2].chapterNumber)
        XCTAssertEqual(questions[3].chapterNumber, 4)
        XCTAssertNil(questions[3].chapterTitle)
        XCTAssertEqual(questions[4].id, "a-5")
        // Utan id: samma id varje gång.
        let again = try BookQuestionFile.parse(Data(json.utf8))
        XCTAssertEqual(questions[1].id, again[1].id)
        XCTAssertTrue(questions[1].id.hasPrefix("f"))
        // En lista direkt går också, liksom engelska namn.
        let list = try BookQuestionFile.parse(Data(#"[{"question": "Q", "quote": "q", "answer": "A"}]"#.utf8))
        XCTAssertEqual(list.first?.question, "Q")
        XCTAssertThrowsError(try BookQuestionFile.parse(Data("inte json".utf8)))
        XCTAssertThrowsError(try BookQuestionFile.parse(Data(#"{"annat": []}"#.utf8)))
    }

    /// Granskning 5, L2 och L5: ett jättetal som sida kraschar inte, och en fil över 2 MB läses inte.
    func testHugePageAndHugeFile() throws {
        let json = #"[{"sida": "-9223372036854775808", "fraga": "A"}, {"sida": 9223372036854775807, "fraga": "B"}]"#
        let questions = try BookQuestionFile.parse(Data(json.utf8))
        XCTAssertEqual(questions.map(\.page), [1, 100_000])
        XCTAssertEqual(BookQuestionFile.hint(for: questions[0], chapterTitles: [], sectionCount: 10), 0)
        XCTAssertEqual(BookQuestionFile.hint(for: questions[1], chapterTitles: [], sectionCount: 10), 9)

        let folder = FileManager.default.temporaryDirectory
        let small = folder.appendingPathComponent("liten-\(UUID().uuidString).fragor.json")
        let big = folder.appendingPathComponent("stor-\(UUID().uuidString).fragor.json")
        defer {
            try? FileManager.default.removeItem(at: small)
            try? FileManager.default.removeItem(at: big)
        }
        try Data(json.utf8).write(to: small)
        XCTAssertEqual(try BookQuestionFile.read(small).count, 2)
        var data = Data(#"[{"sida": 1, "fraga": "A", "svar": ""#.utf8)
        data.append(Data(repeating: UInt8(ascii: "x"), count: BookQuestionFile.maxBytes))
        data.append(Data(#""}]"#.utf8))
        try data.write(to: big)
        XCTAssertThrowsError(try BookQuestionFile.read(big))
    }

    func testFileNamesAndPlaces() {
        XCTAssertTrue(BookQuestionFile.isQuestionFile("Bok.pdf.fragor.json"))
        XCTAssertTrue(BookQuestionFile.isQuestionFile("Bok.FRAGOR.JSON"))
        XCTAssertFalse(BookQuestionFile.isQuestionFile("Bok.json"))
        XCTAssertFalse(BookQuestionFile.isQuestionFile("Bok.pdf"))
        let books = URL(fileURLWithPath: "/D/Böcker", isDirectory: true)
        let inCourse = BookQuestionFile.candidates(forBookAt: URL(fileURLWithPath: "/D/Böcker/RETA30/Bok.pdf"),
                                                   booksDirectory: books).map(\.path)
        XCTAssertEqual(inCourse, ["/D/Böcker/RETA30/Bok.pdf.fragor.json", "/D/Böcker/RETA30/Bok.fragor.json",
                                  "/D/Böcker/Bok.pdf.fragor.json", "/D/Böcker/Bok.fragor.json"])
        let top = BookQuestionFile.candidates(forBookAt: URL(fileURLWithPath: "/D/Böcker/Bok.epub"),
                                              booksDirectory: books).map(\.path)
        XCTAssertEqual(top, ["/D/Böcker/Bok.epub.fragor.json", "/D/Böcker/Bok.fragor.json"])
    }

    func testHints() {
        let pdf = BookQuestion(id: "a", number: 1, title: "", question: "?", answer: [], quote: "x", page: 40,
                               chapterNumber: nil, chapterTitle: nil, y: nil)
        XCTAssertEqual(BookQuestionFile.hint(for: pdf, chapterTitles: [], sectionCount: 12), 11)
        let titles = ["Omslag", "Kapitel 1: Början", "Kapitel 3: Fotnoter"]
        let byTitle = BookQuestion(id: "b", number: 2, title: "", question: "?", answer: [], quote: "x", page: nil,
                                   chapterNumber: nil, chapterTitle: "kapitel 3", y: nil)
        XCTAssertEqual(BookQuestionFile.hint(for: byTitle, chapterTitles: titles, sectionCount: 3), 2)
        let byNumber = BookQuestion(id: "c", number: 3, title: "", question: "?", answer: [], quote: "x", page: nil,
                                    chapterNumber: 2, chapterTitle: nil, y: nil)
        XCTAssertEqual(BookQuestionFile.hint(for: byNumber, chapterTitles: titles, sectionCount: 3), 1)
        let none = BookQuestion(id: "d", number: 4, title: "", question: "?", answer: [], quote: "x", page: nil,
                                chapterNumber: 9, chapterTitle: nil, y: nil)
        XCTAssertNil(BookQuestionFile.hint(for: none, chapterTitles: titles, sectionCount: 3))
    }

    func testDotsStayInTheMarginAndApart() {
        // Bred marginal: pricken står i marginalen, till höger om sidan eller till vänster på vänstersidan.
        let wide = QuestionDotLayout.centerX(contentMinX: 80, contentMaxX: 600, width: 680, outerIsLeft: false)
        XCTAssertGreaterThan(wide.x - wide.size / 2, 600)
        XCTAssertEqual(wide.size, QuestionDotLayout.size)
        let left = QuestionDotLayout.centerX(contentMinX: 80, contentMaxX: 600, width: 680, outerIsLeft: true)
        XCTAssertLessThan(left.x + left.size / 2, 80)
        // Smal marginal (12 punkter): en mindre prick vid bladets kant, inom bladet.
        let narrow = QuestionDotLayout.centerX(contentMinX: 12, contentMaxX: 756, width: 768, outerIsLeft: false)
        XCTAssertEqual(narrow.size, QuestionDotLayout.smallSize)
        XCTAssertLessThanOrEqual(narrow.x + narrow.size / 2, 768)
        // Tre frågor på samma rad sprids ut, och ingen hamnar utanför sidan.
        let ys = QuestionDotLayout.spread([100, 101, 99, 990], gap: 26, top: 20, bottom: 1000)
        let sorted = ys.sorted()
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, 26 - 0.001)
        }
        XCTAssertEqual(ys[3], 990)
        let crowded = QuestionDotLayout.spread([995, 996, 997], gap: 26, top: 20, bottom: 1000)
        XCTAssertLessThanOrEqual(crowded.max() ?? 0, 1000)
        XCTAssertGreaterThanOrEqual(crowded.min() ?? 0, 20)
    }

    /// Edvins data: en databas i formen före våg 8 (steg 9) går igenom steg 10 utan att något försvinner.
    func testStepTenKeepsTheOldData() throws {
        let db = try SQLiteDatabase(path: ":memory:", readOnly: false)
        try db.migrate(Array(AnnotationStore.migrations.prefix(9)))
        XCTAssertEqual(try db.userVersion(), 9)
        try db.execute("""
            INSERT INTO highlights (id, book, section, start, length, text, color, note, created, updated, deleted, rects)
            VALUES ('m', 'bok', 1, 2, 3, 'text', 'green', 'not', 1, 2, 0, '')
            """)
        try db.execute("""
            INSERT INTO concepts (id, book, term, definition, highlight, created, updated, deleted)
            VALUES ('k', 'bok', 'ethos', 'Talarens karaktär', 'm', 1, 1, 0)
            """)
        try db.migrate(AnnotationStore.migrations)
        XCTAssertEqual(try db.userVersion(), AnnotationStore.migrations.count)
        var kept = ""
        try db.query("SELECT h.note, c.term FROM highlights h, concepts c") { kept = "\($0.string(0))|\($0.string(1))" }
        XCTAssertEqual(kept, "not|ethos")
        for status in ["kan_inte", "kan"] {
            try db.execute("""
                INSERT INTO question_answers (book, question, status, answered, updated) VALUES ('bok', 'a', ?, 1, 1)
                ON CONFLICT(book, question) DO UPDATE SET status = excluded.status, answered = answered + 1
                """, [status])
        }
        var answer = ""
        try db.query("SELECT status, answered FROM question_answers") { answer = "\($0.string(0))|\($0.int(1))" }
        XCTAssertEqual(answer, "kan|2")
        let again = try db.migrate(AnnotationStore.migrations)
        XCTAssertEqual(again.from, again.to)
    }
}
