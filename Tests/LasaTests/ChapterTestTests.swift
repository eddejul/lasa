import XCTest
@testable import Lasa

/// K7: självtestet ur markeringarna, ordet som plockas bort, alternativen, kapitelgränsen och steg 11.
final class ChapterTestTests: XCTestCase {

    private func highlight(_ id: String, _ text: String, section: Int = 1, start: Int = 0) -> Highlight {
        Highlight(id: id, book: "bok", section: section, start: start, length: (text as NSString).length, text: text,
                  color: .yellow, note: "", created: Date(), updated: Date())
    }

    func testKeywordPrefersConceptsThenLongWords() {
        let text = "Retoriken bygger på det sannolika, inte på det sanna."
        let ns = text as NSString
        let long = ChapterTestLogic.keyword(in: text, terms: [])
        XCTAssertEqual(long.map { ns.substring(with: $0) }, "Retoriken")
        let term = ChapterTestLogic.keyword(in: text, terms: ["sannolika"])
        XCTAssertEqual(term.map { ns.substring(with: $0) }, "sannolika")
        // Ett begrepp inne i ett annat ord räknas inte.
        let inside = ChapterTestLogic.keyword(in: "Sannolikheten avgör allt i talet här.", terms: ["sannolik"])
        XCTAssertEqual(inside.map { ("Sannolikheten avgör allt i talet här." as NSString).substring(with: $0) }, "Sannolikheten")
        XCTAssertNil(ChapterTestLogic.keyword(in: "Tre korta ord", terms: []))
        XCTAssertEqual(ChapterTestLogic.cloze(text, hiding: term!), "Retoriken bygger på det _____, inte på det sanna.")
    }

    func testDistractorsAreUniqueAndStable() {
        let pool = ["ethos", "Ethos", "pathos", "logos", "sannolika", "doxa", "kairos", "topos"]
        let wrong = ChapterTestLogic.distractors(for: "logos", pool: pool, seed: "m:1")
        XCTAssertEqual(wrong.count, 3)
        XCTAssertFalse(wrong.contains { $0.lowercased() == "logos" })
        XCTAssertEqual(Set(wrong.map { $0.lowercased() }).count, 3)
        XCTAssertEqual(wrong, ChapterTestLogic.distractors(for: "logos", pool: pool, seed: "m:1"))
        let options = ChapterTestLogic.shuffled(wrong + ["logos"], seed: "m:1")
        XCTAssertEqual(options, ChapterTestLogic.shuffled(wrong + ["logos"], seed: "m:1"))
        XCTAssertEqual(Set(options).count, 4)
    }

    func testCardsMixClozeChoiceAndQuestions() {
        let texts = ["Retoriken bygger på det sannolika och inte på det sanna.",
                     "Talaren måste känna sin publik innan talet börjar.",
                     "Kort.",
                     "Enthymemet är retorikens motsvarighet till syllogismen i logiken.",
                     "Kairos betyder det rätta ögonblicket för att säga något."]
        let highlights = texts.enumerated().map { highlight("h\($0.offset)", $0.element, start: $0.offset * 100) }
        let question = BookQuestion(id: "a", number: 1, title: "", question: "Vad är ethos?", answer: ["Karaktären"],
                                    quote: "x", page: nil, chapterNumber: nil, chapterTitle: nil, y: nil)
        let cards = ChapterTestLogic.cards(highlights: highlights, allHighlights: highlights, questions: [question],
                                           terms: ["ethos", "pathos", "logos"], book: "bok", source: "Kapitel 1")
        XCTAssertEqual(cards.count, 5)
        XCTAssertEqual(cards.map(\.kind), [.cloze, .choice, .cloze, .choice, .question])
        XCTAssertTrue(cards[0].prompt.contains(ChapterTestLogic.blank))
        XCTAssertEqual(cards[1].options.count, 4)
        XCTAssertTrue(cards[1].options.contains(cards[1].answer))
        XCTAssertEqual(cards[4].id, "q:bok:a")
        XCTAssertEqual(cards[4].questionID, "a")
        XCTAssertEqual(cards[0].id, "m:h0")
    }

    func testFinishedChapterOnlyForwardOverABoundary() {
        let starts = [0, 2, 5]
        XCTAssertEqual(ChapterTestLogic.finishedChapter(from: 1, to: 2, starts: starts), 0)
        XCTAssertEqual(ChapterTestLogic.finishedChapter(from: 4, to: 6, starts: starts), 1)
        XCTAssertNil(ChapterTestLogic.finishedChapter(from: 2, to: 3, starts: starts))
        XCTAssertNil(ChapterTestLogic.finishedChapter(from: 2, to: 1, starts: starts))
        XCTAssertNil(ChapterTestLogic.finishedChapter(from: 1, to: 2, starts: []))
    }

    /// Edvins data: en databas i formen före våg 8 (steg 9) går igenom stegen 10 och 11.
    func testStepElevenKeepsTheOldData() throws {
        let db = try SQLiteDatabase(path: ":memory:", readOnly: false)
        try db.migrate(Array(AnnotationStore.migrations.prefix(9)))
        try db.execute("""
            INSERT INTO page_notes (book, section, text, created, updated, deleted) VALUES ('bok', 3, 'Kvar', 1, 1, 0)
            """)
        try db.migrate(AnnotationStore.migrations)
        XCTAssertGreaterThanOrEqual(AnnotationStore.migrations.count, 11)
        var note = ""
        try db.query("SELECT text FROM page_notes") { note = $0.string(0) }
        XCTAssertEqual(note, "Kvar")
        try db.execute("""
            INSERT INTO study_cards (id, book, kind, due, interval, ease, reps, lapses, introduced, updated)
            VALUES ('m:x', 'bok', 'markering', 10, 1, 2.5, 1, 0, 5, 5)
            ON CONFLICT(id) DO UPDATE SET due = excluded.due
            """)
        var card = ""
        try db.query("SELECT kind, reps FROM study_cards WHERE id = 'm:x'") { card = "\($0.string(0))|\($0.int(1))" }
        XCTAssertEqual(card, "markering|1")
    }
}
