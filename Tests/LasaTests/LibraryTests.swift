import UIKit
import XCTest
@testable import Lasa

/// B1 och B2: bibliotekets sortering, filter, Fortsätt läsa och raden med sidor kvar, titlar ur filer,
/// och att databasen från våg 3 går genom trappan utan att något försvinner.
final class LibraryLogicTests: XCTestCase {

    private func item(_ path: String, title: String, progress: Double = 0, finished: Bool = false,
                      added: Double = 0, lastRead: Double = 0, page: Int = 0, pages: Int = 0,
                      chapterLeft: Int = -1) -> ShelfItem {
        let url = URL(fileURLWithPath: "/tmp/Böcker/" + path)
        var record = BookRecord(id: path, sha256: "", file: path, title: (path as NSString).deletingPathExtension,
                                size: 1, modified: 1, added: added, missing: false)
        record.bookTitle = title
        record.progress = progress
        record.finished = finished
        record.page = page
        record.pages = pages
        record.chapterLeft = chapterLeft
        return ShelfItem(book: Book(url: url, id: path, path: path), record: record, lastRead: lastRead)
    }

    private lazy var sample: [ShelfItem] = [
        item("a.pdf", title: "Retorikens grunder", progress: 0.28, added: 10, lastRead: 500, page: 87, pages: 312),
        item("b.epub", title: "Classical Rhetoric", progress: 0.09, added: 30, lastRead: 900),
        item("c.pdf", title: "Att analysera argument", added: 40),
        item("d.md", title: "Anteckningar", progress: 1, finished: true, added: 20, lastRead: 100),
        item("e.pdf", title: "Ord och läsning", added: 50),
    ]

    func testSortRecentPutsLastReadFirstThenNewestAdded() {
        let order = LibraryLogic.sort(sample, by: .recent).map(\.book.path)
        XCTAssertEqual(order, ["b.epub", "a.pdf", "d.md", "e.pdf", "c.pdf"])
    }

    func testSortTitleAndAdded() {
        XCTAssertEqual(LibraryLogic.sort(sample, by: .title).map(\.title),
                       ["Anteckningar", "Att analysera argument", "Classical Rhetoric", "Ord och läsning",
                        "Retorikens grunder"])
        XCTAssertEqual(LibraryLogic.sort(sample, by: .added).map(\.book.path), ["e.pdf", "c.pdf", "b.epub", "d.md", "a.pdf"])
    }

    func testFilters() {
        XCTAssertEqual(Set(LibraryLogic.filter(sample, .reading).map(\.book.path)), ["a.pdf", "b.epub"])
        XCTAssertEqual(Set(LibraryLogic.filter(sample, .unread).map(\.book.path)), ["c.pdf", "e.pdf"])
        XCTAssertEqual(LibraryLogic.filter(sample, .finished).map(\.book.path), ["d.md"])
        XCTAssertEqual(LibraryLogic.filter(sample, .all).count, 5)
    }

    func testContinueReadingSkipsFinishedBooks() {
        XCTAssertEqual(LibraryLogic.continueReading(sample)?.book.path, "b.epub")
        let onlyFinished = [item("d.md", title: "Klar", progress: 1, finished: true, lastRead: 999)]
        XCTAssertNil(LibraryLogic.continueReading(onlyFinished))
    }

    func testStatusLineHasPagesLeftAndNoTime() {
        XCTAssertEqual(LibraryLogic.statusLine(sample[0]), "Sida 87 av 312, 225 sidor kvar")
        XCTAssertEqual(LibraryLogic.statusLine(item("x.epub", title: "X", progress: 0.4, chapterLeft: 4)),
                       "40 %, 4 sidor kvar i kapitlet")
        XCTAssertEqual(LibraryLogic.statusLine(item("y.epub", title: "Y", progress: 0.5)), "50 % läst")
        XCTAssertEqual(LibraryLogic.statusLine(item("z.pdf", title: "Z", progress: 1, page: 10, pages: 10)),
                       "Sida 10 av 10, sista sidan")
        for line in [sample[0], sample[1]].map(LibraryLogic.statusLine) {
            XCTAssertFalse(line.contains("min"), "ingen tid kvar: \(line)")
        }
    }

    func testSearchIgnoresCaseAndAccents() {
        XCTAssertEqual(LibraryLogic.search(sample, "lasning").map(\.book.path), ["e.pdf"])
        XCTAssertEqual(LibraryLogic.search(sample, "RETORIK grund").map(\.book.path), ["a.pdf"])
        XCTAssertEqual(LibraryLogic.search(sample, "").count, 5)
    }

    func testColumns() {
        XCTAssertEqual(LibraryLogic.columns(width: 390, landscape: false), 2)
        XCTAssertEqual(LibraryLogic.columns(width: 768, landscape: false), 3)
        XCTAssertEqual(LibraryLogic.columns(width: 764, landscape: true), 4)
        XCTAssertEqual(LibraryLogic.columns(width: 1024, landscape: true), 5)
    }

    func testTitles() {
        XCTAssertEqual(BookRecord.cleanedTitle("Retorikens_grunder  kap_3"), "Retorikens grunder kap 3")
        XCTAssertEqual(BookFileReader.usableTitle("Microsoft Word - Kompendium.docx"), "")
        XCTAssertEqual(BookFileReader.usableTitle("Microsoft Word - Topik och kria"), "Topik och kria")
        XCTAssertEqual(BookFileReader.usableTitle("untitled"), "")
        XCTAssertEqual(BookFileReader.usableTitle("  Retorikens   grunder "), "Retorikens grunder")
        var record = BookRecord(id: "a", sha256: "", file: "Bok_1.pdf", title: "Bok_1", size: 1, modified: 1, added: 0,
                                missing: false)
        XCTAssertEqual(record.displayTitle, "Bok 1")
        record.bookTitle = "Riktig titel"
        XCTAssertEqual(record.displayTitle, "Riktig titel")
        record.customTitle = "Egen"
        XCTAssertEqual(record.displayTitle, "Egen")
    }

    func testEPUBPaths() {
        XCTAssertEqual(BookFileReader.resolve("bilder/omslag.jpg", base: "OEBPS"), "OEBPS/bilder/omslag.jpg")
        XCTAssertEqual(BookFileReader.resolve("../Images/cover%20big.jpg", base: "OEBPS/Text"), "OEBPS/Images/cover big.jpg")
        XCTAssertEqual(BookFileReader.resolve("cover.png", base: ""), "cover.png")
    }

    // MARK: Kurser (B3)

    func testFolderCourses() {
        XCTAssertEqual(CourseLogic.topFolder(of: "RETA30/Kap 1/Bok.pdf"), "RETA30")
        XCTAssertNil(CourseLogic.topFolder(of: "Bok.pdf"))
        let deleted = Course(id: "d", name: "Gammal", color: "", folder: "Gammal", added: 0, deleted: true)
        let existing = Course(id: "r", name: "Retorik", color: "", folder: "RETA30", added: 0)
        let names = CourseLogic.newFolderCourses(paths: ["RETA30/a.pdf", "HP/b.pdf", "HP/c.pdf", "Gammal/x.pdf", "d.pdf"],
                                                 existing: [deleted, existing])
        // RETA30 har en kurs, Gammal togs bort och skapas inte igen.
        XCTAssertEqual(names, ["HP"])
    }

    func testCourseMembership() {
        let folder = Course(id: "f", name: "RETA30", color: "", folder: "RETA30", added: 0)
        let own = Course(id: "o", name: "Tenta", color: "green", folder: "", added: 0)
        let gone = Course(id: "g", name: "Borta", color: "", folder: "", added: 0, deleted: true)
        let courses = [folder, own, gone]
        let explicit: [String: Set<String>] = ["b1": ["o", "g"], "b2": ["o"]]
        XCTAssertEqual(CourseLogic.courses(forPath: "RETA30/Bok.pdf", bookID: "b1", courses: courses, explicit: explicit),
                       ["f", "o"])
        XCTAssertEqual(CourseLogic.courses(forPath: "Annan.pdf", bookID: "b2", courses: courses, explicit: explicit), ["o"])
        XCTAssertEqual(CourseLogic.courses(forPath: "Annan.pdf", bookID: "b3", courses: courses, explicit: explicit), [])
        XCTAssertEqual(own.tint, HighlightColor.green.solid)
    }

    func testCourseTablesInTheStair() throws {
        let db = try SQLiteDatabase(path: ":memory:", readOnly: false)
        try db.migrate(Array(AnnotationStore.migrations.prefix(4)))
        try db.migrate(AnnotationStore.migrations)
        try db.execute("INSERT INTO courses (id, name, color, folder, added, deleted) VALUES ('c', 'RETA30', '', '', 1, 0)")
        try db.execute("INSERT OR IGNORE INTO course_books (course, book, added) VALUES ('c', 'b', 1)")
        try db.execute("INSERT OR IGNORE INTO course_books (course, book, added) VALUES ('c', 'b', 2)")
        var count = 0
        try db.query("SELECT COUNT(*) FROM course_books") { count = $0.int(0) }
        XCTAssertEqual(count, 1)
    }

    /// Edvins data: en databas i den form våg 3 lämnade går genom trappan utan att något försvinner, och en rad
    /// som sparas om behåller titel och omslag.
    func testWave3DatabaseKeepsEverything() throws {
        let db = try SQLiteDatabase(path: ":memory:", readOnly: false)
        try db.migrate(Array(AnnotationStore.migrations.prefix(3)))
        XCTAssertEqual(try db.userVersion(), 3)
        let record = BookRecord(id: "bok", sha256: "h", file: "RETA30/Bok.pdf", title: "Bok", size: 5, modified: 6,
                                added: 7, missing: false)
        try BookRegistry.insert(record, into: db)
        try db.execute("""
            INSERT INTO highlights (id, book, section, start, length, text, color, note, created, updated, deleted, rects)
            VALUES ('m', 'bok', 1, 2, 3, 'text', 'green', 'not', 1, 2, 0, '[[1,2,3,4]]')
            """)
        try db.migrate(AnnotationStore.migrations)
        XCTAssertEqual(try db.userVersion(), AnnotationStore.migrations.count)
        var highlight = ""
        try db.query("SELECT book, note, rects FROM highlights") { highlight = "\($0.string(0))|\($0.string(1))|\($0.string(2))" }
        XCTAssertEqual(highlight, "bok|not|[[1,2,3,4]]")
        var defaults = ""
        try db.query("SELECT file, sha256, book_title, cover_page, progress, chapter_left FROM books") { row in
            defaults = "\(row.string(0))|\(row.string(1))|\(row.string(2))|\(row.int(3))|\(row.double(4))|\(row.int(5))"
        }
        XCTAssertEqual(defaults, "RETA30/Bok.pdf|h||-1|0.0|-1")

        try db.execute("UPDATE books SET book_title = 'Riktig', cover = 'c.jpg', progress = 0.5 WHERE id = 'bok'")
        var moved = record
        moved.file = "Bok.pdf"
        try BookRegistry.insert(moved, into: db)
        var kept = ""
        try db.query("SELECT file, book_title, cover, progress FROM books") { row in
            kept = "\(row.string(0))|\(row.string(1))|\(row.string(2))|\(row.double(3))"
        }
        XCTAssertEqual(kept, "Bok.pdf|Riktig|c.jpg|0.5")
    }
}
