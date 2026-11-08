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
