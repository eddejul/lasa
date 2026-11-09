import XCTest
@testable import Lasa

/// Våg 8b: texten runt markeringen (A1), anteckningen, svarets tolkning, Googles fel och nyckeln ur urklipp (U7).
final class AITests: XCTestCase {

    private func highlight(_ text: String, start: Int = 0, note: String = "") -> Highlight {
        Highlight(id: "h", book: "b", section: 0, start: start, length: (text as NSString).length, text: text,
                  color: .yellow, note: note, created: Date(), updated: Date())
    }

    // MARK: Texten runt markeringen

    func testParagraphsFromHTML() {
        let html = "<html><head><title>T</title><style>p{}</style></head><body><h1>Rubrik</h1>"
            + "<p>Ett &amp; två.</p>\n<p>Med <em>kursiv\n text</em> och&nbsp;mer h&#228;r.</p><br/><p>Sist.</p>"
            + "<script>var x = 1;</script></body></html>"
        XCTAssertEqual(PassageText.paragraphs(html: html),
                       ["Rubrik", "Ett & två.", "Med kursiv text och mer här.", "Sist."])
    }

    func testParagraphAroundHighlight() {
        let paragraphs = ["Första stycket.", "Andra stycket med markerad text i mitten.", "Tredje."]
        let passage = PassageText.paragraphPassage(highlight("markerad text"), paragraphs: paragraphs)
        XCTAssertEqual(passage.context, "Andra stycket med markerad text i mitten.")
        XCTAssertEqual(passage.marked, "markerad text")
        // Över två stycken: båda tas med.
        let across = PassageText.paragraphPassage(highlight("i mitten. Tredje"), paragraphs: paragraphs)
        XCTAssertTrue(across.context.hasSuffix("Tredje."))
        // Hittas den inte skickas bara markeringen.
        let missing = PassageText.paragraphPassage(highlight("finns inte"), paragraphs: paragraphs)
        XCTAssertEqual(missing.context, "finns inte")
    }

    func testSentencesAroundHighlightInPDF() {
        let text = "Ett är först. Två kommer sedan. Tre är mitt. Fyra har ordet här. Fem följer. "
            + "Sex är näst sist. Sju är sist."
        let expected = "Två kommer sedan. Tre är mitt. Fyra har ordet här. Fem följer. Sex är näst sist."
        let start = (text as NSString).range(of: "ordet").location
        let passage = PassageText.sentencePassage(highlight("ordet", start: start), in: text)
        XCTAssertEqual(passage.context, expected)
        // Fel plats: markeringen letas upp i texten.
        let moved = PassageText.sentencePassage(highlight("ordet", start: 0), in: text)
        XCTAssertEqual(moved.context, expected)
    }

    func testNeverMoreThanMaxLength() {
        let long = String(repeating: "Ett mycket långt stycke utan någon riktig poäng alls. ", count: 400)
        let start = (long as NSString).length / 2
        let marked = (long as NSString).substring(with: NSRange(location: start, length: 12))
        let passage = PassageText.sentencePassage(highlight(marked, start: start), in: long)
        XCTAssertLessThanOrEqual(passage.context.count, PassageText.maxLength)
        let paragraph = PassageText.paragraphPassage(highlight("långt stycke utan"), paragraphs: [long])
        XCTAssertLessThanOrEqual(paragraph.context.count, PassageText.maxLength)
        XCTAssertTrue(paragraph.context.contains("långt stycke utan"))
    }

    func testHyphenationAndSpacesAreJoined() {
        XCTAssertEqual(PassageText.collapse("kun-\nskap  och\u{00AD}så\n\nmer "), "kunskap ochså mer")
    }

    // MARK: Svaret och anteckningen

    private let answer: [String: Any] = [
        "core": " Kärnan. ",
        "concepts": [["term": "term", "definition": "Definition."], ["term": "", "definition": "Tom term."]],
        "example": "Ett exempel.",
        "question": "En fråga?",
        "answer": "Ett svar.",
    ]

    func testExplanationParsing() throws {
        let explanation = try XCTUnwrap(PassageExplain.Explanation(json: answer))
        XCTAssertEqual(explanation.core, "Kärnan.")
        XCTAssertEqual(explanation.concepts.count, 1)
        XCTAssertNil(PassageExplain.Explanation(json: ["core": "  "]))
    }

    func testNoteKeepsOwnTextFirstAndIsNotRepeated() throws {
        let explanation = try XCTUnwrap(PassageExplain.Explanation(json: answer))
        let empty = try XCTUnwrap(PassageExplain.note(adding: explanation, to: ""))
        XCTAssertTrue(empty.hasPrefix(PassageExplain.noteHeading))
        let own = try XCTUnwrap(PassageExplain.note(adding: explanation, to: "Min anteckning."))
        XCTAssertTrue(own.hasPrefix("Min anteckning.\n\n" + PassageExplain.noteHeading))
        XCTAssertTrue(own.contains("Kontrollfråga: En fråga?\nSvar: Ett svar."))
        XCTAssertNil(PassageExplain.note(adding: explanation, to: own))
    }

    // MARK: Googles fel

    private func errorData(_ code: Int, _ message: String, details: [[String: Any]] = []) -> Data {
        try! JSONSerialization.data(withJSONObject: ["error": ["code": code, "message": message, "details": details]])
    }

    func testFailures() {
        let model = "gemini-3.5-flash-lite"
        XCTAssertEqual(AIClient.failure(status: 400, data: errorData(400, "API key not valid. Please pass a valid API key."),
                                        model: model), .badKey)
        XCTAssertEqual(AIClient.failure(status: 403, data: nil, model: model), .badKey)
        XCTAssertEqual(AIClient.failure(status: 404, data: nil, model: model), .unknownModel(model))
        let day = errorData(429, "You exceeded your current quota", details: [
            ["@type": "type.googleapis.com/google.rpc.QuotaFailure",
             "violations": [["quotaId": "GenerateRequestsPerDayPerProjectPerModel-FreeTier"]]],
            ["@type": "type.googleapis.com/google.rpc.RetryInfo", "retryDelay": "40s"],
        ])
        XCTAssertEqual(AIClient.failure(status: 429, data: day, model: model), .quotaToday)
        let minute = errorData(429, "You exceeded your current quota", details: [
            ["@type": "type.googleapis.com/google.rpc.QuotaFailure",
             "violations": [["quotaId": "GenerateRequestsPerMinutePerProjectPerModel-FreeTier"]]],
            ["@type": "type.googleapis.com/google.rpc.RetryInfo", "retryDelay": "29.6s"],
        ])
        XCTAssertEqual(AIClient.failure(status: 429, data: minute, model: model), .quotaPerMinute(seconds: 30))
        XCTAssertEqual(AIClient.failure(status: 429, data: nil, model: model), .quotaPerMinute(seconds: nil))
        XCTAssertTrue(AIClient.Failure.quotaToday.errorDescription?.contains("svensk tid") == true)
    }

    func testCacheKeyDependsOnModelAndPrompt() {
        let schema: [String: Any] = ["type": "object"]
        let a = AIClient.cacheKey(kind: "stycke-1", model: "m1", prompt: "p", schema: schema)
        XCTAssertEqual(a, AIClient.cacheKey(kind: "stycke-1", model: "m1", prompt: "p", schema: schema))
        XCTAssertNotEqual(a, AIClient.cacheKey(kind: "stycke-1", model: "m2", prompt: "p", schema: schema))
        XCTAssertNotEqual(a, AIClient.cacheKey(kind: "stycke-1", model: "m1", prompt: "q", schema: schema))
        XCTAssertEqual(a.count, 64)
    }

    // MARK: Nyckeln ur urklipp (U7)

    func testKeyCandidate() {
        XCTAssertEqual(AIKeyGuideViewController.keyCandidate("  AIzaSyA1234567890abcdefghijklmnopqrs \n"),
                       "AIzaSyA1234567890abcdefghijklmnopqrs")
        XCTAssertNil(AIKeyGuideViewController.keyCandidate(""))
        XCTAssertNil(AIKeyGuideViewController.keyCandidate("en mening med flera ord i urklippet"))
        XCTAssertNil(AIKeyGuideViewController.keyCandidate("kort"))
    }
}
