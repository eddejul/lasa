import XCTest
@testable import Lasa

/// V4: historiken bakom Tillbaka.
final class ReaderHistoryTests: XCTestCase {

    func testBackGoesToLatestPlace() {
        var history = ReaderHistory<Int>()
        history.push(4, label: "s. 5")
        history.push(40, label: "s. 41")
        XCTAssertEqual(history.pop()?.place, 40)
        XCTAssertEqual(history.pop()?.place, 4)
        XCTAssertNil(history.pop())
    }

    func testRecentShowsFiveNewestFirst() {
        var history = ReaderHistory<Int>()
        for page in 1...8 {
            history.push(page, label: "s. \(page)")
        }
        XCTAssertEqual(history.recent.map(\.place), [8, 7, 6, 5, 4])
    }

    func testSamePlaceTwiceIsSavedOnce() {
        var history = ReaderHistory<Int>()
        history.push(3, label: "s. 3")
        history.push(3, label: "s. 3")
        XCTAssertEqual(history.entries.count, 1)
    }

    func testPopFurtherBackForgetsNewer() {
        var history = ReaderHistory<Int>()
        history.push(1, label: "s. 1")
        history.push(2, label: "s. 2")
        history.push(3, label: "s. 3")
        XCTAssertEqual(history.pop(1)?.place, 2)
        XCTAssertEqual(history.entries.map(\.place), [1])
        XCTAssertNil(history.pop(5))
    }

    func testHistoryIsCapped() {
        var history = ReaderHistory<Int>()
        for page in 0..<50 {
            history.push(page, label: "s. \(page)")
        }
        XCTAssertEqual(history.entries.count, ReaderHistory<Int>.limit)
        XCTAssertEqual(history.entries.first?.place, 30)
    }
}

/// V1: sidor kvar, utan tid.
final class PageInfoTests: XCTestCase {

    func testPagesLeftAfterLastShownPage() {
        // Kapitlet är sidorna 10 till 19 (slutar före 20). På sidan 12 är 7 sidor kvar.
        XCTAssertEqual(PageInfo.pagesLeft(lastShown: 12, end: 20), 7)
        XCTAssertEqual(PageInfo.pagesLeft(lastShown: 19, end: 20), 0)
        XCTAssertEqual(PageInfo.pagesLeft(lastShown: 25, end: 20), 0)
    }

    func testTextWithoutTime() {
        XCTAssertEqual(PageInfo.text(left: 9, scope: .chapter), "9 sidor kvar i kapitlet")
        XCTAssertEqual(PageInfo.text(left: 1, scope: .book), "1 sida kvar i boken")
        XCTAssertEqual(PageInfo.text(left: 0, scope: .chapter), "Sista sidan i kapitlet")
        XCTAssertEqual(PageInfo.text(left: 270, scope: .book, estimated: true), "Cirka 270 sidor kvar i boken")
        XCTAssertFalse(PageInfo.text(left: 5, scope: .book).contains("min"))
    }

    func testBookWithoutChaptersShowsBook() {
        XCTAssertEqual(PageInfo.effectiveScope(hasChapters: false), .book)
    }
}

/// V6: Här var du visas efter mer än ett dygn, aldrig för en bok som inte öppnats.
final class ResumeCardTests: XCTestCase {

    func testShownAfterMoreThanADay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(ReaderResumeCard.shouldShow(lastRead: now.addingTimeInterval(-25 * 3600), now: now))
        XCTAssertFalse(ReaderResumeCard.shouldShow(lastRead: now.addingTimeInterval(-23 * 3600), now: now))
        XCTAssertFalse(ReaderResumeCard.shouldShow(lastRead: nil, now: now))
    }

    func testAgoInSwedish() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(ReaderResumeCard.ago(now.addingTimeInterval(-30 * 3600), now: now), "i går")
        XCTAssertEqual(ReaderResumeCard.ago(now.addingTimeInterval(-3 * 86_400), now: now), "för 3 dagar sedan")
        XCTAssertEqual(ReaderResumeCard.ago(now.addingTimeInterval(-21 * 86_400), now: now), "för 3 veckor sedan")
    }
}
