import XCTest
@testable import Lasa

/// Automatiska tester av ren logik (G13). Körs i jobbet Simulatortest med `xcodebuild test-without-building`.
/// De rör inga riktiga databaser eller filer i appen.

/// Sökningens textjämförelse: små bokstäver, ett mellanslag mellan orden och avstavningar bort.
final class FoldedTextTests: XCTestCase {

    func testHyphenationAtLineBreakIsJoined() {
        XCTAssertEqual(FoldedText("Kun-\nskap" as NSString).text as String, "kunskap")
        XCTAssertEqual(FoldedText("Kun-\r\n  skap" as NSString).text as String, "kunskap")
    }

    func testHyphenBeforeCapitalIsKept() {
        // "Nord-\nAmerika" är inte en avstavning, eftersom nästa ord börjar med stor bokstav.
        XCTAssertEqual(FoldedText("Nord-\nAmerika" as NSString).text as String, "nord- amerika")
    }

    func testLowercaseKeepsSwedishLetters() {
        XCTAssertEqual(FoldedText("ÅSA ÄR ÖVER" as NSString).text as String, "åsa är över")
        // å, ä och ö skiljs från a och o.
        XCTAssertNotEqual(FoldedText("Åsa" as NSString).text as String, "asa")
    }

    func testWhitespaceCollapses() {
        XCTAssertEqual(FoldedText("en  \n\t två" as NSString).text as String, "en två")
    }

    func testSoftHyphenIsRemoved() {
        XCTAssertEqual(FoldedText("kun\u{00AD}skap" as NSString).text as String, "kunskap")
    }

    func testOriginalRangePointsBack() {
        let original = "Den som söker kun-\nskap måste läsa." as NSString
        let folded = FoldedText(original)
        let found = (folded.text as NSString).range(of: "kunskap")
        XCTAssertNotEqual(found.location, NSNotFound)
        let back = folded.originalRange(of: found)
        XCTAssertEqual(original.substring(with: back), "kun-\nskap")
    }

    func testQueryIsTrimmed() {
        XCTAssertEqual(FoldedText.query("  Kunskap "), "kunskap")
    }
}

/// Repetitionens schema i stil med Anki.
final class ReviewScheduleTests: XCTestCase {

    func testNewWord() {
        XCTAssertEqual(ReviewSchedule.next(.good, interval: 0, ease: 2.5, reps: 0).interval, 1)
        XCTAssertEqual(ReviewSchedule.next(.easy, interval: 0, ease: 2.5, reps: 0).interval, 4)
        XCTAssertEqual(ReviewSchedule.next(.again, interval: 0, ease: 2.5, reps: 0).interval, 10.0 / 1440.0,
                       accuracy: 0.000_001)
        XCTAssertFalse(ReviewSchedule.next(.again, interval: 0, ease: 2.5, reps: 0).lapse)
    }

    func testSecondReviewIsThreeDays() {
        XCTAssertEqual(ReviewSchedule.next(.good, interval: 1, ease: 2.5, reps: 1).interval, 3)
    }

    func testIntervalGrowsWithEase() {
        let next = ReviewSchedule.next(.good, interval: 3, ease: 2.5, reps: 2)
        XCTAssertEqual(next.interval, 7.5, accuracy: 0.000_1)
        XCTAssertEqual(next.reps, 3)
    }

    func testForgettingIsALapseAndLowersEase() {
        let next = ReviewSchedule.next(.again, interval: 10, ease: 2.5, reps: 4)
        XCTAssertTrue(next.lapse)
        XCTAssertEqual(next.reps, 0)
        XCTAssertEqual(next.ease, 2.3, accuracy: 0.000_1)
    }

    func testEaseNeverGoesBelowMinimum() {
        let next = ReviewSchedule.next(.again, interval: 1, ease: ReviewSchedule.minimumEase, reps: 2)
        XCTAssertEqual(next.ease, ReviewSchedule.minimumEase, accuracy: 0.000_1)
    }

    func testLabels() {
        XCTAssertEqual(ReviewSchedule.label(days: 10.0 / 1440.0), "10 min")
        XCTAssertEqual(ReviewSchedule.label(days: 1), "1 dag")
        XCTAssertEqual(ReviewSchedule.label(days: 3), "3 dagar")
        XCTAssertEqual(ReviewSchedule.label(days: 21), "3 veckor")
        XCTAssertEqual(ReviewSchedule.label(days: 120), "4 mån")
        XCTAssertEqual(ReviewSchedule.label(days: 400), "1 år")
    }
}

/// Synkens tider: den nyaste ändringen vinner, räknat i hela millisekunder.
final class SyncTimeTests: XCTestCase {

    func testSupabaseMicrosecondsAreRead() {
        let micro = SyncTime.seconds("2030-01-01T10:00:00.123456+00:00")
        let milli = SyncTime.seconds("2030-01-01T10:00:00.123Z")
        XCTAssertNotNil(micro)
        XCTAssertEqual(micro ?? 0, milli ?? -1, accuracy: 0.000_5)
    }

    func testTimesWithoutFractionAndShortFraction() {
        let whole = SyncTime.seconds("2030-01-01T10:00:00+00:00")
        let half = SyncTime.seconds("2030-01-01T10:00:00.5+00:00")
        XCTAssertNotNil(whole)
        XCTAssertEqual((half ?? 0) - (whole ?? 0), 0.5, accuracy: 0.000_5)
        XCTAssertNil(SyncTime.seconds(""))
        XCTAssertNil(SyncTime.seconds(nil))
    }

    func testNewerCountsWholeMilliseconds() {
        XCTAssertFalse(SyncTime.newer(1.000_4, than: 1.0))
        XCTAssertTrue(SyncTime.newer(1.002, than: 1.0))
        XCTAssertFalse(SyncTime.newer(1.0, than: 1.002))
        XCTAssertTrue(SyncTime.newer(1.0, than: nil))
        XCTAssertFalse(SyncTime.newer(nil, than: 1.0))
        XCTAssertFalse(SyncTime.newer(nil, than: nil))
    }

    func testRoundTrip() {
        // En halv sekund går att skriva exakt, så att avrundningen inte spelar in.
        let value = 1_900_000_000.5
        XCTAssertEqual(SyncTime.seconds(SyncTime.string(value)) ?? 0, value, accuracy: 0.000_5)
    }
}

/// Databasernas trappa och transaktioner (G8), i en databas i minnet.
final class SQLiteDatabaseTests: XCTestCase {

    private struct Stop: Error {}

    func testMigrationRunsOnlyNewSteps() throws {
        let db = try SQLiteDatabase(path: ":memory:", readOnly: false)
        XCTAssertEqual(try db.userVersion(), 0)
        let first = try db.migrate(["CREATE TABLE t (a INTEGER);"])
        XCTAssertEqual(first.from, 0)
        XCTAssertEqual(first.to, 1)
        let second = try db.migrate(["CREATE TABLE t (a INTEGER);", "ALTER TABLE t ADD COLUMN b TEXT NOT NULL DEFAULT '';"])
        XCTAssertEqual(second.from, 1)
        XCTAssertEqual(second.to, 2)
        let again = try db.migrate(["CREATE TABLE t (a INTEGER);", "ALTER TABLE t ADD COLUMN b TEXT NOT NULL DEFAULT '';"])
        XCTAssertEqual(again.from, 2)
        XCTAssertEqual(again.to, 2)
        try db.execute("INSERT INTO t (a, b) VALUES (1, 'ett')")
    }

    func testFailedStepLeavesVersion() throws {
        let db = try SQLiteDatabase(path: ":memory:", readOnly: false)
        XCTAssertThrowsError(try db.migrate(["CREATE TABLE t (a INTEGER);", "THIS IS NOT SQL;"]))
        XCTAssertEqual(try db.userVersion(), 1)
    }

    func testRollbackOnError() throws {
        let db = try SQLiteDatabase(path: ":memory:", readOnly: false)
        try db.executeScript("CREATE TABLE t (a INTEGER);")
        XCTAssertThrowsError(try db.transaction { () throws -> Void in
            try db.execute("INSERT INTO t (a) VALUES (1)")
            throw Stop()
        })
        var count = -1
        try db.query("SELECT COUNT(*) FROM t") { row in count = row.int(0) }
        XCTAssertEqual(count, 0)
        try db.transaction { () throws -> Void in
            try db.execute("INSERT INTO t (a) VALUES (2)")
            // En transaktion inuti en annan blir en del av den yttre.
            try db.transaction { () throws -> Void in
                try db.execute("INSERT INTO t (a) VALUES (3)")
            }
        }
        try db.query("SELECT COUNT(*) FROM t") { row in count = row.int(0) }
        XCTAssertEqual(count, 2)
    }
}

/// Varningen innan appen går ut (G1).
final class AppExpiryTests: XCTestCase {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Stockholm") ?? .current
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        // November 2026: måndag den 9, onsdag den 11, torsdag den 12.
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute)) ?? Date()
    }

    func testNoWarningThreeDaysBefore() {
        XCTAssertNil(AppExpiry.warning(expiring: date(12, 14), now: date(9, 10), calendar: calendar))
    }

    func testWarningNamesTheDay() {
        let name = AppExpiry.appName
        XCTAssertEqual(AppExpiry.warning(expiring: date(12, 14), now: date(10, 15), calendar: calendar),
                       "\(name) går ut torsdag kl. 14, förnya i Sideloadly.")
        XCTAssertEqual(AppExpiry.warning(expiring: date(12, 14, 30), now: date(11, 9), calendar: calendar),
                       "\(name) går ut i morgon kl. 14.30, förnya i Sideloadly.")
        XCTAssertEqual(AppExpiry.warning(expiring: date(12, 14), now: date(12, 8), calendar: calendar),
                       "\(name) går ut i dag kl. 14, förnya i Sideloadly.")
    }

    func testProfileIsParsedFromSignedFile() throws {
        let expiry = Date(timeIntervalSince1970: 1_900_000_000)
        var data = Data([0x30, 0x82, 0x0A, 0x00]) + Data("signerat".utf8)
        data.append(try PropertyListSerialization.data(fromPropertyList: ["ExpirationDate": expiry, "Name": "Test"],
                                                        format: .xml, options: 0))
        data.append(Data([0x00, 0xA0, 0x82, 0x01]))
        XCTAssertEqual(AppExpiry.parse(data), expiry)
        XCTAssertNil(AppExpiry.parse(Data("ingen plist".utf8)))
    }
}

/// Ordkortet (U4) och den valda betydelsen (O7).
final class WordCardTests: XCTestCase {

    private func sense(_ id: String, _ definition: String?, _ synonyms: [String]) -> WordSense {
        WordSense(id: id, definition: definition,
                  synonyms: synonyms.map { Synonym(word: $0, score: 4, frequency: 4) })
    }

    private var entries: [WordEntry] {
        [WordEntry(lemma: "lätt", pos: "av", posName: "adjektiv",
                   senses: [sense("lätt..1", "som väger lite", ["lättviktig"]),
                            sense("lätt..2", nil, ["enkel", "okomplicerad", "simpel", "busenkel", "elementär"])],
                   translations: [], translationVia: nil),
         WordEntry(lemma: "lätt", pos: "ab", posName: "adverb",
                   senses: [sense("lätt..3", "utan svårighet", [])],
                   translations: [], translationVia: nil)]
    }

    func testChosenSenseIsFoundInAnyEntry() {
        XCTAssertEqual(WordText.sense(withID: "lätt..2", in: entries)?.sense.id, "lätt..2")
        XCTAssertEqual(WordText.sense(withID: "lätt..3", in: entries)?.entry.pos, "ab")
    }

    func testNoChoiceGivesNil() {
        XCTAssertNil(WordText.sense(withID: "", in: entries))
        XCTAssertNil(WordText.sense(withID: "finns..9", in: entries))
    }

    func testGlossIsDefinitionOrFourSynonyms() {
        XCTAssertEqual(WordText.gloss(entries[0].senses[0]), "som väger lite")
        XCTAssertEqual(WordText.gloss(entries[0].senses[1]), "enkel, okomplicerad, simpel, busenkel")
    }

    func testSourceLine() {
        XCTAssertEqual(WordText.source(book: "Retorikens grunder", pageIndex: 87), "Retorikens grunder, s. 88")
        XCTAssertEqual(WordText.source(book: "Bok", pageIndex: nil), "Bok")
        XCTAssertNil(WordText.source(book: nil, pageIndex: 3))
        XCTAssertNil(WordText.source(book: "", pageIndex: 3))
    }
}

/// Dina ord i texten (O4): matchningen av sparade ord i en text.
final class SavedWordMatcherTests: XCTestCase {

    func testFormsAreMatchedWithPositions() {
        let forms = ["kunskap": "w:sv|kunskap", "kunskapen": "k:sv|kunskap"]
        let found = SavedWordMatcher.matches(in: "Kunskap är makt. Kunskapen växer.", forms: forms)
        XCTAssertEqual(found.map { $0.range }, [NSRange(location: 0, length: 7), NSRange(location: 17, length: 9)])
        XCTAssertEqual(found.map { $0.value }, ["w:sv|kunskap", "k:sv|kunskap"])
    }

    func testPartOfLongerWordIsNotMatched() {
        XCTAssertTrue(SavedWordMatcher.matches(in: "kunskapsteori", forms: ["kunskap": "w:sv|kunskap"]).isEmpty)
        XCTAssertTrue(SavedWordMatcher.matches(in: "", forms: ["kunskap": "w:sv|kunskap"]).isEmpty)
    }

    func testCurlyApostropheMatchesStraight() {
        let found = SavedWordMatcher.matches(in: "We don’t know.", forms: ["don't": "w:en|do"])
        XCTAssertEqual(found.first?.range, NSRange(location: 3, length: 5))
    }

    func testEnglishRegularForms() {
        XCTAssertTrue(SavedWordMatcher.englishForms(of: "stop").isSuperset(of: ["stops", "stopped", "stopping"]))
        XCTAssertTrue(SavedWordMatcher.englishForms(of: "study").isSuperset(of: ["studies", "studied", "studying"]))
        XCTAssertTrue(SavedWordMatcher.englishForms(of: "make").isSuperset(of: ["makes", "making"]))
        XCTAssertTrue(SavedWordMatcher.englishForms(of: "box").contains("boxes"))
    }

    func testIDGivesLanguageAndLemma() {
        XCTAssertEqual(SavedWordMarks.word(fromID: "ord:sv|lätt")?.lemma, "lätt")
        XCTAssertEqual(SavedWordMarks.word(fromID: "ord:en|run up")?.language, .english)
        XCTAssertNil(SavedWordMarks.word(fromID: "ord:xx|lätt"))
        XCTAssertTrue(SavedWordMarks.isWordID("ord:sv|lätt"))
        XCTAssertFalse(SavedWordMarks.isWordID("6f1c2d3e-0000"))
    }
}
