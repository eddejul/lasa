import XCTest
@testable import Lasa

/// D3-1: Sparat i ordkortet tar bort ordet och dess repetition, och Ångra lägger tillbaka samma rad och samma
/// repetition. Provas i en egen databasfil, så att appens sparade ord inte rörs.
final class UserWordsUndoTests: XCTestCase {

    private var url: URL!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory.appendingPathComponent("ord-\(UUID().uuidString).sqlite")
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
        super.tearDown()
    }

    /// Ett sparat ord med bok, vald betydelse och en repetition.
    private func savedWithReview(_ words: UserWords) -> SavedWordRecord? {
        words.save(word: "övar", lemma: "öva", language: .swedish, sentence: "Hon övar varje dag.", book: "Kursboken",
                   pageIndex: 4, bookID: "bok-1")
        words.save(word: "övade", lemma: "öva", language: .swedish, sentence: "Hon övade i går.", book: "Kursboken",
                   pageIndex: 6, bookID: "bok-1")
        words.setSense(lemma: "öva", language: .swedish, senseID: "s2")
        guard let saved = words.savedWords().first(where: { $0.lemma == "öva" }) else { return nil }
        let card = ReviewCard(word: saved, interval: 0, ease: 2.5, reps: 0, lapses: 0, isNew: true)
        words.record(.good, for: card, now: Date(timeIntervalSince1970: 1_800_000_000))
        return words.savedWordRecord(lemma: "öva", language: .swedish)
    }

    func testUndoPutsBackTheSameRowAndReview() throws {
        let words = UserWords(fileURL: url)
        let before = try XCTUnwrap(savedWithReview(words))
        XCTAssertEqual(before.lookups, 2)
        XCTAssertEqual(before.bookID, "bok-1")
        XCTAssertEqual(before.senseID, "s2")
        XCTAssertEqual(before.review?.reps, 1)

        let removed = try XCTUnwrap(words.delete(lemma: "öva", language: .swedish))
        XCTAssertEqual(removed, before)
        XCTAssertFalse(words.isSaved(lemma: "öva", language: .swedish))
        XCTAssertNil(words.savedWordRecord(lemma: "öva", language: .swedish))
        let deletedAt = try XCTUnwrap(words.deletionTime(lemma: "öva", language: .swedish))
        XCTAssertTrue(words.wordsForSync().contains { $0.lemma == "öva" && $0.deleted })

        XCTAssertTrue(words.restoreDeleted(removed))
        let after = try XCTUnwrap(words.savedWordRecord(lemma: "öva", language: .swedish))
        // Allt är som före utom ordets ändringstid, som är nyare än borttagningen.
        var expected = before
        expected.updated = after.updated
        XCTAssertEqual(after, expected)
        XCTAssertEqual(after.review, before.review)
        XCTAssertTrue(SyncTime.newer(after.updated, than: deletedAt))
        XCTAssertNil(words.deletionTime(lemma: "öva", language: .swedish))
        XCTAssertEqual(words.savedWords().count, 1)

        // Synken skickar ordet som levande, med repetitionen.
        let synced = try XCTUnwrap(words.wordsForSync().first { $0.lemma == "öva" })
        XCTAssertFalse(synced.deleted)
        XCTAssertEqual(synced.reps, 1)
        XCTAssertEqual(synced.due, before.review?.due)
    }

    func testUndoReplacesAWordSavedAgainMeanwhile() throws {
        // Ordet sparas igen innan Ångra (ett nytt uppslag): utan repetition, utan bok-id, ett uppslag.
        let words = UserWords(fileURL: url)
        let before = try XCTUnwrap(savedWithReview(words))
        let removed = try XCTUnwrap(words.delete(lemma: "öva", language: .swedish))
        words.save(word: "övar", lemma: "öva", language: .swedish, sentence: "En annan mening.", book: "Kursboken",
                   pageIndex: 9)
        let fresh = try XCTUnwrap(words.savedWordRecord(lemma: "öva", language: .swedish))
        XCTAssertNil(fresh.review)
        XCTAssertEqual(fresh.bookID, "")

        XCTAssertTrue(words.restoreDeleted(removed))
        let after = try XCTUnwrap(words.savedWordRecord(lemma: "öva", language: .swedish))
        var expected = before
        expected.updated = after.updated
        XCTAssertEqual(after, expected)
        XCTAssertEqual(words.savedWords().count, 1)
    }

    func testUndoGivesANewIdWhenAnotherWordTookIt() throws {
        let words = UserWords(fileURL: url)
        let before = try XCTUnwrap(savedWithReview(words))
        let removed = try XCTUnwrap(words.delete(lemma: "öva", language: .swedish))
        // Ett annat ord sparas under tiden och tar nästa lediga nummer, som är det borttagna ordets.
        words.save(word: "kunskap", lemma: "kunskap", language: .swedish, sentence: "Kunskap.", book: "Kursboken",
                   pageIndex: 1)
        let other = try XCTUnwrap(words.savedWordRecord(lemma: "kunskap", language: .swedish))
        XCTAssertEqual(other.id, before.id)

        XCTAssertTrue(words.restoreDeleted(removed))
        let after = try XCTUnwrap(words.savedWordRecord(lemma: "öva", language: .swedish))
        XCTAssertNotEqual(after.id, other.id)
        var expected = before
        expected.id = after.id
        expected.updated = after.updated
        XCTAssertEqual(after, expected)
        XCTAssertEqual(words.savedWordRecord(lemma: "kunskap", language: .swedish), other)
    }

    func testDeletingAWordThatIsNotSavedGivesNothingToUndo() {
        let words = UserWords(fileURL: url)
        XCTAssertNil(words.delete(lemma: "finns", language: .swedish))
    }

    func testUndoOfAWordWithoutReviewLeavesNoReview() throws {
        let words = UserWords(fileURL: url)
        words.save(word: "retorik", lemma: "retorik", language: .swedish, sentence: "Retorik.", book: "Kursboken",
                   pageIndex: 2, bookID: "bok-2")
        let before = try XCTUnwrap(words.savedWordRecord(lemma: "retorik", language: .swedish))
        XCTAssertNil(before.review)
        let removed = try XCTUnwrap(words.delete(lemma: "retorik", language: .swedish))
        XCTAssertTrue(words.restoreDeleted(removed))
        let after = try XCTUnwrap(words.savedWordRecord(lemma: "retorik", language: .swedish))
        XCTAssertNil(after.review)
        XCTAssertEqual(after.bookID, "bok-2")
        XCTAssertEqual(after.id, before.id)
    }
}
