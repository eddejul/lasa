import XCTest
@testable import Lasa

/// A2: förklara kapitlet med egna ord. Jämförelsen utan AI, Geminis punkter som måste peka på egna markeringar,
/// frågan som aldrig innehåller kapitlets text, och steg 12 i trappan.
final class ChapterExplainTests: XCTestCase {

    private func mark(_ id: String, _ text: String, section: Int = 0, start: Int = 0) -> Highlight {
        Highlight(id: id, book: "bok", section: section, start: start, length: (text as NSString).length, text: text,
                  color: .yellow, note: "", created: Date(), updated: Date())
    }

    private func concept(_ term: String, highlight: String) -> Concept {
        Concept(id: "c-" + term, book: "bok", term: term, definition: "", highlight: highlight, created: Date(),
                updated: Date())
    }

    func testMentionsCountsInflectionsAndCompounds() {
        let words = ChapterExplainLogic.words("Kunskapen kräver en metod, och Ethosargument väger tungt i genus deliberativum.")
        XCTAssertTrue(ChapterExplainLogic.mentions("kunskap", words: words))
        XCTAssertTrue(ChapterExplainLogic.mentions("metoden", words: words))
        XCTAssertTrue(ChapterExplainLogic.mentions("ethos", words: words))
        XCTAssertTrue(ChapterExplainLogic.mentions("Genus deliberativum", words: words))
        XCTAssertFalse(ChapterExplainLogic.mentions("kairos", words: words))
        XCTAssertFalse(ChapterExplainLogic.mentions("genus iudiciale", words: words))
        XCTAssertFalse(ChapterExplainLogic.mentions("", words: words))
        // Korta ord måste stå exakt.
        XCTAssertFalse(ChapterExplainLogic.mentions("en", words: ChapterExplainLogic.words("enkel")))
    }

    func testMaterialTakesConceptsFirstAndKeywordsOnce() {
        let marks = [
            mark("h2", "Talaren måste anpassa argumenten efter publiken och situationen.", start: 50),
            mark("h1", "Retoriken vilar på tre bevismedel som talaren kan använda.", start: 0),
            mark("h3", "Kairos betyder det rätta ögonblicket att säga något.", start: 90),
        ]
        let material = ChapterExplainLogic.material(book: "bok", bookTitle: "Retorik", section: 0, chapter: "Kapitel 1",
                                                    highlights: marks,
                                                    concepts: [concept("kairos", highlight: "h3"),
                                                               concept("logos", highlight: "annan")])
        XCTAssertEqual(material.marks.map(\.ref), ["M1", "M2", "M3"])
        XCTAssertEqual(material.marks.map(\.id), ["h1", "h2", "h3"])
        XCTAssertEqual(material.items.map(\.term), ["kairos", "bevismedel", "situationen"])
        XCTAssertEqual(material.items.first?.kind, .concept)
        XCTAssertEqual(material.items.first?.highlight, "h3")
        let coverage = ChapterExplainLogic.coverage(material.items,
                                                    explanation: "Det handlar om bevismedel och om situationen.")
        XCTAssertEqual(coverage.covered.map(\.term), ["bevismedel", "situationen"])
        XCTAssertEqual(coverage.missing.map(\.term), ["kairos"])
    }

    func testFeedbackOnlyKeepsPointsOnOwnMarks() {
        let marks = [ChapterExplainMaterial.Mark(ref: "M1", id: "h1", text: "Första"),
                     ChapterExplainMaterial.Mark(ref: "M2", id: "h2", text: "Andra")]
        let json: [String: Any] = [
            "correct": [["text": "Stämmer.", "mark": "M1"], ["text": "Med hakparentes.", "mark": "[m2]"]],
            "missing": [["text": "Finns inte.", "mark": "M9"], ["text": "", "mark": "M1"]],
            "wrong": [["text": "Utan id."]],
        ]
        let feedback = ChapterFeedback(json: json, marks: marks)
        XCTAssertEqual(feedback.points.map(\.highlight), ["h1", "h2"])
        XCTAssertEqual(feedback.points.map(\.quote), ["Första", "Andra"])
        XCTAssertEqual(feedback.dropped, 3)
        let stored = ChapterFeedback.decode(ChapterFeedback.encode(feedback.points))
        XCTAssertEqual(stored, feedback.points)
        XCTAssertEqual(ChapterFeedback.encode([]), "")
        XCTAssertEqual(ChapterFeedback.decode(""), [])
    }

    func testPromptHasMarksAndExplanationButNoChapterText() {
        let material = ChapterExplainMaterial(book: "bok", bookTitle: "Klassisk retorik", section: 3, chapter: "Kapitel 3",
                                              marks: [.init(ref: "M1", id: "h1", text: "Ethos är talarens karaktär.")],
                                              items: [])
        let prompt = ChapterExplainLogic.prompt(material: material, explanation: "  Kapitlet handlar om ethos.  ")
        XCTAssertTrue(prompt.contains("Bok: Klassisk retorik"))
        XCTAssertTrue(prompt.contains("Kapitel: Kapitel 3"))
        XCTAssertTrue(prompt.contains("[M1] \"Ethos är talarens karaktär.\""))
        XCTAssertTrue(prompt.contains("\"\"\"\nKapitlet handlar om ethos.\n\"\"\""))
        let schema = ChapterExplainLogic.schema(refs: ["M1"])
        let properties = schema["properties"] as? [String: Any]
        let list = properties?["missing"] as? [String: Any]
        let point = (list?["items"] as? [String: Any])?["properties"] as? [String: Any]
        XCTAssertEqual((point?["mark"] as? [String: Any])?["enum"] as? [String], ["M1"])
    }

    /// Edvins data: en databas i formen före A2 (steg 11) går igenom steg 12, och förklaringen sparas.
    func testStepTwelveKeepsTheOldData() throws {
        let db = try SQLiteDatabase(path: ":memory:", readOnly: false)
        try db.migrate(Array(AnnotationStore.migrations.prefix(11)))
        try db.execute("""
            INSERT INTO study_cards (id, book, kind, due, interval, ease, reps, lapses, introduced, updated)
            VALUES ('m:x', 'bok', 'markering', 10, 1, 2.5, 1, 0, 5, 5)
            """)
        try db.execute("""
            INSERT INTO concepts (id, book, term, definition, highlight, created, updated, deleted)
            VALUES ('c1', 'bok', 'ethos', '', 'h1', 1, 1, 0)
            """)
        try db.migrate(AnnotationStore.migrations)
        XCTAssertGreaterThanOrEqual(AnnotationStore.migrations.count, 12)
        XCTAssertEqual(try db.userVersion(), AnnotationStore.migrations.count)
        var card = ""
        try db.query("SELECT kind, reps FROM study_cards WHERE id = 'm:x'") { card = "\($0.string(0))|\($0.int(1))" }
        XCTAssertEqual(card, "markering|1")
        var term = ""
        try db.query("SELECT term FROM concepts WHERE id = 'c1'") { term = $0.string(0) }
        XCTAssertEqual(term, "ethos")
        try db.execute("""
            INSERT INTO chapter_explanations (id, book, section, chapter, text, covered, missing, feedback, model,
                created, updated, deleted)
            VALUES ('e1', 'bok', 3, 'Kapitel 3', 'Min förklaring', 'b:ethos', 'n:logos', '', '', 1, 1, 0)
            """)
        var row = ""
        try db.query("SELECT text, covered, missing FROM chapter_explanations WHERE book = 'bok' AND deleted = 0") {
            row = "\($0.string(0))|\($0.string(1))|\($0.string(2))"
        }
        XCTAssertEqual(row, "Min förklaring|b:ethos|n:logos")
    }

    func testStoredWordCodesKeepTheirKind() {
        let items = [ChapterExplainItem(term: "ethos", kind: .concept, highlight: "h1"),
                     ChapterExplainItem(term: "bevismedel", kind: .keyword, highlight: "h2")]
        let codes = ChapterExplanation.codes(items)
        XCTAssertEqual(codes, ["b:ethos", "n:bevismedel"])
        XCTAssertEqual(codes.map { ChapterExplanation.item(code: $0).kind }, [.concept, .keyword])
        XCTAssertEqual(codes.map { ChapterExplanation.item(code: $0).term }, ["ethos", "bevismedel"])
    }
}
