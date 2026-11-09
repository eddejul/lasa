import XCTest
@testable import Lasa

/// K6b: AI-frågornas logik mot det gemensamma facit `tools/simtest/ai-fragor/fixtur-1.json` (byggt av
/// referens.py). Samma fixtur prövas i Windows-appens node-test, så att båda apparna bygger samma fråga och
/// behåller samma frågor.
final class AIQuestionsTests: XCTestCase {

    private func fixture() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tools/simtest/ai-fragor/fixtur-1.json")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func sortedJSON(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func checked(_ fixture: [String: Any]) throws -> AIQuestions.CheckResult {
        let book = try XCTUnwrap(fixture["bok"] as? [String: Any])
        let chapter = try XCTUnwrap(fixture["kapitel"] as? [String: Any])
        let others = try XCTUnwrap(fixture["andraBocker"] as? [[String: Any]])
        let cap = try XCTUnwrap(fixture["tak"] as? [String: Int])
        let answer = try XCTUnwrap(fixture["svar"] as? [String: Any])
        return AIQuestions.check(answer: answer, text: try XCTUnwrap(chapter["text"] as? String),
                                 book: try XCTUnwrap(book["id"] as? String),
                                 chapter: try XCTUnwrap(chapter["nyckel"] as? String),
                                 part: try XCTUnwrap(chapter["del"] as? Int),
                                 otherTitles: others.compactMap { $0["titel"] as? String },
                                 cap: AIQuestions.Cap(before: cap["fore"] ?? 0, after: cap["efter"] ?? 0,
                                                      end: cap["slut"] ?? 0))
    }

    func testCountAndCapMatchTheFixture() throws {
        let fixture = try fixture()
        let chapter = try XCTUnwrap(fixture["kapitel"] as? [String: Any])
        let text = try XCTUnwrap(chapter["text"] as? String)
        let expected = try XCTUnwrap(fixture["antal"] as? [String: Int])
        let count = AIQuestions.count(characters: (text as NSString).length, last: false)
        XCTAssertEqual(count, AIQuestions.Count(after: expected["efter"] ?? -1, before: expected["fore"] ?? -1,
                                                connections: expected["kopplingar"] ?? -1, end: expected["slut"] ?? -1))
        let cap = try XCTUnwrap(fixture["tak"] as? [String: Int])
        XCTAssertEqual(AIQuestions.cap(for: count), AIQuestions.Cap(before: cap["fore"] ?? -1, after: cap["efter"] ?? -1,
                                                                    end: cap["slut"] ?? -1))
        // Pythons round avrundar till jämnt: 2,5 blir 2 och 3,5 blir 4.
        XCTAssertEqual(AIQuestions.count(characters: 8750, last: false).after, 2)
        XCTAssertEqual(AIQuestions.count(characters: 12250, last: false).after, 4)
        XCTAssertEqual(AIQuestions.count(characters: 100_000, last: true).after, 10)
        XCTAssertEqual(AIQuestions.count(characters: 100_000, last: true).end, 4)
        let later = AIQuestions.count(characters: 9000, part: 2, parts: 3, lastChapter: false)
        XCTAssertEqual(later.before, 0)
        XCTAssertEqual(later.end, 0)
        XCTAssertEqual(later.connections, 0)
    }

    func testPromptMatchesTheFixture() throws {
        let fixture = try fixture()
        let book = try XCTUnwrap(fixture["bok"] as? [String: Any])
        let chapter = try XCTUnwrap(fixture["kapitel"] as? [String: Any])
        let previous = try XCTUnwrap(fixture["tidigare"] as? [[String: Any]]).map {
            AIQuestions.PreviousChapter(title: $0["rubrik"] as? String ?? "", summary: $0["sammanfattning"] as? String ?? "")
        }
        let others = try XCTUnwrap(fixture["andraBocker"] as? [[String: Any]]).map {
            AIQuestions.OtherBook(title: $0["titel"] as? String ?? "", summary: $0["sammanfattning"] as? String ?? "",
                                  concepts: $0["begrepp"] as? [String] ?? [])
        }
        let expected = try XCTUnwrap(fixture["antal"] as? [String: Int])
        let count = AIQuestions.Count(after: expected["efter"] ?? 0, before: expected["fore"] ?? 0,
                                      connections: expected["kopplingar"] ?? 0, end: expected["slut"] ?? 0)
        let prompt = AIQuestions.prompt(
            book: AIQuestions.PromptBook(title: book["titel"] as? String ?? "", author: book["forfattare"] as? String ?? ""),
            chapter: AIQuestions.PromptChapter(title: chapter["rubrik"] as? String ?? "", part: chapter["del"] as? Int ?? 1,
                                               parts: chapter["delar"] as? Int ?? 1, text: chapter["text"] as? String ?? "",
                                               isLast: chapter["sista"] as? Bool ?? false),
            previous: previous, others: others, count: count)
        let wanted = try XCTUnwrap(fixture["prompt"] as? String)
        if prompt != wanted {
            let ours = prompt.components(separatedBy: "\n")
            let theirs = wanted.components(separatedBy: "\n")
            for (index, line) in theirs.enumerated() where index >= ours.count || ours[index] != line {
                XCTFail("Rad \(index + 1) skiljer sig:\nväntat: \(line)\nfick:   \(index < ours.count ? ours[index] : "(saknas)")")
                break
            }
        }
        XCTAssertEqual(prompt, wanted)
        // Utan tidigare kapitel och andra böcker, i en senare del av bokens sista kapitel.
        let alone = AIQuestions.prompt(book: AIQuestions.PromptBook(title: "B", author: ""),
                                       chapter: AIQuestions.PromptChapter(title: "K", part: 2, parts: 2, text: "x",
                                                                          isLast: true),
                                       previous: [], others: [],
                                       count: AIQuestions.count(characters: 9000, part: 2, parts: 2, lastChapter: true))
        XCTAssertTrue(alone.contains("Bok: B\nKapitel: K (del 2 av 2)\n\nTidigare kapitel i boken:\nInga.\n"))
        XCTAssertTrue(alone.contains("b) Inga frågor med \"nar\": \"fore\"."))
        XCTAssertTrue(alone.contains("Det här är bokens sista kapitel"))
    }

    func testSchemasMatchTheFixture() throws {
        let fixture = try fixture()
        XCTAssertEqual(try sortedJSON(AIQuestions.questionSchema), try sortedJSON(try XCTUnwrap(fixture["schemaFragor"])))
        XCTAssertEqual(try sortedJSON(AIQuestions.compareSchema), try sortedJSON(try XCTUnwrap(fixture["schemaJamfor"])))
    }

    func testCheckKeepsAndDropsAsTheFixture() throws {
        let fixture = try fixture()
        let result = try checked(fixture)
        let wanted = try XCTUnwrap(fixture["vantat"] as? [String: Any])
        let kept = try XCTUnwrap(wanted["behalls"] as? [[String: Any]])
        XCTAssertEqual(result.kept.map(\.number), kept.compactMap { $0["nr"] as? Int })
        for (ours, theirs) in zip(result.kept, kept) {
            XCTAssertEqual(ours.id, theirs["id"] as? String, "id för nr \(ours.number)")
            XCTAssertEqual(ours.type, theirs["typ"] as? String)
            XCTAssertEqual(ours.timing, theirs["nar"] as? String)
            XCTAssertEqual(ours.question, theirs["fraga"] as? String)
            XCTAssertEqual(ours.source, theirs["kalla"] as? String, "källan för nr \(ours.number)")
            XCTAssertEqual(ours.isOpen, theirs["oppen"] as? Bool)
            XCTAssertEqual(ours.position, theirs["position"] as? Int, "platsen för nr \(ours.number)")
            XCTAssertEqual(ours.id, AIQuestions.questionID(book: "11111111-2222-3333-4444-555555555555", chapter: "k3",
                                                           part: 1, timing: ours.timing, question: ours.question))
        }
        let dropped = try XCTUnwrap(wanted["slangs"] as? [[String: Any]])
        XCTAssertEqual(result.dropped.map(\.number), dropped.compactMap { $0["nr"] as? Int })
        XCTAssertEqual(result.dropped.map(\.reason), dropped.compactMap { $0["orsak"] as? String })
        XCTAssertEqual(result.dropped.map(\.question), dropped.compactMap { $0["fraga"] as? String })
        XCTAssertEqual(result.logLine(chapter: "k3"),
                       "AI-frågor k3: 6 av 13 behölls (plats 1, kalla 1, kopierad 1, avstand 1, bok 1, typ 1, svar 1)")
        // Platsen i texten pekar på slutet av träffen, som i referensen.
        let text = try XCTUnwrap((fixture["kapitel"] as? [String: Any])?["text"] as? String) as NSString
        if let first = result.kept.first(where: { $0.timing == "efter" }), let range = first.anchorRange {
            XCTAssertEqual(text.substring(with: range), "lättare att göra samma sak nästa gång")
        }
    }

    func testComparePromptsMatchTheFixture() throws {
        let fixture = try fixture()
        let result = try checked(fixture)
        let compares = try XCTUnwrap(fixture["jamfor"] as? [[String: Any]])
        XCTAssertEqual(compares.count, 2)
        for compare in compares {
            let number = try XCTUnwrap(compare["nr"] as? Int)
            let question = try XCTUnwrap(result.kept.first { $0.number == number })
            let prompt = AIQuestions.comparePrompt(
                AIQuestions.CompareQuestion(question: question.question, answer: question.answer, source: question.source,
                                            isOpen: question.isOpen),
                myAnswer: try XCTUnwrap(compare["mittSvar"] as? String))
            XCTAssertEqual(prompt, compare["prompt"] as? String, "Jämför för nr \(number)")
        }
    }

    func testLooseMatchAndFoldedSearch() {
        let text = "Han sa ”byta ut beteendet” och gick.\nKun-\nskap är makt." as NSString
        let loose = AIQuestions.find("sa \"byta ut beteendet\"", in: text)
        XCTAssertEqual(loose.map { text.substring(with: $0) }, "sa ”byta ut beteendet”")
        let folded = AIQuestions.find("KUNSKAP är", in: text)
        XCTAssertNotNil(folded)
        XCTAssertNil(AIQuestions.find("finns inte", in: text))
        XCTAssertNil(AIQuestions.find("x", in: text))
        XCTAssertEqual(AIQuestions.words("Två ord, 3 siffror: ett_två"), ["två", "ord", "3", "siffror", "ett", "två"])
    }

    func testLongChaptersSplitAtBlankLines() {
        let paragraph = String(repeating: "Ett ord till i stycket. ", count: 40)
        let text = Array(repeating: paragraph, count: 100).joined(separator: "\n\n") as NSString
        XCTAssertGreaterThan(text.length, AIQuestions.splitAbove)
        let parts = AIQuestions.parts(of: text)
        XCTAssertEqual(parts.count, Int((Double(text.length) / Double(AIQuestions.partLength)).rounded(.up)))
        XCTAssertEqual(parts.first?.location, 0)
        XCTAssertEqual(parts.last.map(NSMaxRange), text.length)
        for (left, right) in zip(parts, parts.dropFirst()) {
            XCTAssertEqual(NSMaxRange(left), right.location)
            // Delningen sker efter en tom rad.
            XCTAssertEqual(text.substring(with: NSRange(location: right.location - 2, length: 2)), "\n\n")
        }
        let short = "Kort kapitel." as NSString
        XCTAssertEqual(AIQuestions.parts(of: short), [NSRange(location: 0, length: short.length)])
    }

    func testChapterKeysAndOrder() {
        XCTAssertEqual(AIQuestions.chapterKey(chapter: 3), "k3")
        XCTAssertEqual(AIQuestions.chapterKey(firstPage: 11, lastPage: 20), "p11-20")
        XCTAssertEqual(AIQuestions.order(ofChapterKey: "k3"), 3)
        XCTAssertEqual(AIQuestions.order(ofChapterKey: "p11-20"), 11)
        XCTAssertEqual(AIQuestions.title(type: "annan_bok", book: "Atomvanor"), "Koppling till Atomvanor")
        XCTAssertEqual(AIQuestions.title(type: "svar_mening"), "Svår mening")
        XCTAssertEqual(AIQuestions.typeIDs.count, 21)
    }
}
