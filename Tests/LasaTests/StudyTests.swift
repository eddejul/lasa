import XCTest
@testable import Lasa

/// Våg 7 (Plugget): bokens sidnummer (K2), citaten (K3) och de nya stegen i trappan.
final class StudyTests: XCTestCase {

    // MARK: K2

    func testSuggestionFromFileName() {
        let one = BookPageNumbering.suggestion(fileName: "Lindqvist kap 3 (s63-80).pdf", pageCount: 18)
        XCTAssertEqual(one?.first, 63)
        XCTAssertEqual(one?.last, 80)
        XCTAssertEqual(one?.spread, false)
        let spread = BookPageNumbering.suggestion(fileName: "Lindqvist kap 15-19 (s281-305).pdf", pageCount: 13)
        XCTAssertEqual(spread?.first, 281)
        XCTAssertEqual(spread?.spread, true)
        XCTAssertNotNil(BookPageNumbering.suggestion(fileName: "Bok (s. 12–20).pdf", pageCount: 9))
        XCTAssertNil(BookPageNumbering.suggestion(fileName: "Lindqvist kap 15-19.pdf", pageCount: 10))
        XCTAssertNil(BookPageNumbering.suggestion(fileName: "Analys1-3.pdf", pageCount: 3))
        XCTAssertNil(BookPageNumbering.suggestion(fileName: "Bok (s80-63).pdf", pageCount: 3))
    }

    func testOffsetNumbers() {
        let numbering = BookPageNumbering.resolve(first: 0, spread: false, fileName: "Kap (s63-80).pdf",
                                                  pageCount: 18, hasPDFLabels: true)
        XCTAssertEqual(numbering.source, .offset(first: 63, spread: false))
        XCTAssertEqual(numbering.printed(for: 0, pdfLabel: "1"), "63")
        XCTAssertEqual(numbering.printed(for: 17, pdfLabel: nil), "80")
        XCTAssertEqual(numbering.index(forTyped: "70", pageCount: 18) { _ in nil }, 7)
        // Ett nummer utanför boken blir sidans plats i filen.
        XCTAssertEqual(numbering.index(forTyped: "5", pageCount: 18) { _ in nil }, 4)
        XCTAssertEqual(numbering.citationPage(for: 2, half: nil, pdfLabel: nil), "65")
    }

    func testSpreadNumbers() {
        let numbering = BookPageNumbering.resolve(first: 281, spread: true, fileName: "Kap.pdf", pageCount: 13,
                                                  hasPDFLabels: false)
        XCTAssertEqual(numbering.printed(for: 0, pdfLabel: nil), "281 och 282")
        XCTAssertEqual(numbering.printed(for: 2, pdfLabel: nil), "285 och 286")
        XCTAssertEqual(numbering.index(forTyped: "286", pageCount: 13) { _ in nil }, 2)
        XCTAssertEqual(numbering.index(forTyped: "285", pageCount: 13) { _ in nil }, 2)
        XCTAssertEqual(numbering.citationPage(for: 2, half: 1, pdfLabel: nil), "286")
        XCTAssertEqual(numbering.citationPage(for: 2, half: 0, pdfLabel: nil), "285")
        XCTAssertEqual(numbering.citationPage(for: 2, half: nil, pdfLabel: nil), "285 f.")
    }

    func testPDFLabelsAndFileNumbers() {
        let labels = BookPageNumbering.resolve(first: 0, spread: false, fileName: "Bok.pdf", pageCount: 5,
                                               hasPDFLabels: true)
        XCTAssertEqual(labels.source, .pdfLabels)
        XCTAssertEqual(labels.printed(for: 0, pdfLabel: "xii"), "xii")
        XCTAssertNil(labels.printed(for: 0, pdfLabel: "1"))
        XCTAssertEqual(labels.index(forTyped: "XII", pageCount: 5) { $0 == 3 ? "xii" : nil }, 3)
        // -1: PDF:ens egna nummer även när filnamnet har ett intervall.
        let off = BookPageNumbering.resolve(first: -1, spread: false, fileName: "Kap (s63-80).pdf", pageCount: 18,
                                            hasPDFLabels: false)
        XCTAssertEqual(off.source, .file)
        XCTAssertNil(off.printed(for: 4, pdfLabel: nil))
        XCTAssertEqual(off.citationPage(for: 4, half: nil, pdfLabel: nil), "5")
        XCTAssertFalse(off.usesBookNumbers)
    }

    // MARK: K3

    private let lindqvist = CitationSource(author: "Lindqvist, Anders", year: "2016",
                                           title: "Klassisk retorik för vår tid", publisher: "Studentlitteratur",
                                           place: "Lund")

    func testInTextCitations() {
        XCTAssertEqual(Citation.quote("Retoriken bygger på det sanno-\nlika.", style: .harvard, source: lindqvist,
                                      page: "63"),
                       "”Retoriken bygger på det sannolika.” (Lindqvist 2016, s. 63)")
        XCTAssertEqual(Citation.inText(.apa, source: lindqvist, page: "63"), "(Lindqvist, 2016, s. 63)")
        XCTAssertEqual(Citation.inText(.harvard, source: lindqvist, page: nil), "(Lindqvist 2016)")
        var noYear = lindqvist
        noYear.year = ""
        XCTAssertEqual(Citation.inText(.harvard, source: noYear, page: "5"), "(Lindqvist u.å., s. 5)")
        let two = CitationSource(author: "Anders Lindqvist; Mika Hietanen", year: "2020", title: "T")
        XCTAssertEqual(Citation.inText(.harvard, source: two, page: nil), "(Lindqvist och Hietanen 2020)")
        XCTAssertEqual(Citation.inText(.apa, source: two, page: nil), "(Lindqvist & Hietanen, 2020)")
        let epub = CitationSource(author: "Anders Lindqvist, Mika Hietanen, Ola Ek", year: "2020", title: "T")
        XCTAssertEqual(Citation.inText(.harvard, source: epub, page: nil), "(Lindqvist m.fl. 2020)")
    }

    func testFootnoteAndReferences() {
        XCTAssertEqual(Citation.footnote(source: lindqvist, page: "63"),
                       "Anders Lindqvist, Klassisk retorik för vår tid (Lund: Studentlitteratur, 2016), s. 63.")
        XCTAssertEqual(Citation.quote("Text", style: .oxford, source: lindqvist, page: "63"),
                       "”Text”¹\n\n¹ Anders Lindqvist, Klassisk retorik för vår tid (Lund: Studentlitteratur, 2016), s. 63.")
        XCTAssertEqual(Citation.reference(.harvard, source: lindqvist),
                       "Lindqvist, A. (2016) Klassisk retorik för vår tid. Lund: Studentlitteratur.")
        XCTAssertEqual(Citation.reference(.apa, source: lindqvist),
                       "Lindqvist, A. (2016). Klassisk retorik för vår tid. Studentlitteratur.")
        XCTAssertEqual(Citation.names("Anders Lindqvist").first, Citation.Name(family: "Lindqvist", given: "Anders"))
        XCTAssertEqual(Citation.year(inFileName: "Lindqvist 2016 kap 3 (s63-80).pdf"), "2016")
        XCTAssertNil(Citation.year(inFileName: "Kap (s281-305).pdf"))
        XCTAssertEqual(Citation.year(fromDate: "2016-03-01"), "2016")
    }

    // MARK: Trappan

    /// Edvins data: en databas i den form main har i dag (steg 5) går genom de nya stegen utan att något
    /// försvinner, och de nya tabellerna går att skriva i.
    func testMainDatabaseGoesThroughTheNewSteps() throws {
        let db = try SQLiteDatabase(path: ":memory:", readOnly: false)
        try db.migrate(Array(AnnotationStore.migrations.prefix(5)))
        XCTAssertEqual(try db.userVersion(), 5)
        let record = BookRecord(id: "bok", sha256: "h", file: "RETA30/Kap (s63-80).pdf", title: "Kap", size: 5,
                                modified: 6, added: 7, missing: false)
        try BookRegistry.insert(record, into: db)
        try db.execute("UPDATE books SET custom_author = 'Lindqvist', progress = 0.25 WHERE id = 'bok'")
        try db.execute("""
            INSERT INTO highlights (id, book, section, start, length, text, color, note, created, updated, deleted, rects)
            VALUES ('m', 'bok', 1, 2, 3, 'text', 'green', 'not', 1, 2, 0, '[[1,2,3,4]]')
            """)
        try db.execute("INSERT INTO courses (id, name, color, folder, added, deleted) VALUES ('c', 'RETA30', '', 'RETA30', 1, 0)")
        try db.migrate(AnnotationStore.migrations)
        XCTAssertEqual(try db.userVersion(), AnnotationStore.migrations.count)
        var kept = ""
        try db.query("SELECT custom_author, progress FROM books") { kept = "\($0.string(0))|\($0.double(1))" }
        XCTAssertEqual(kept, "Lindqvist|0.25")
        var highlight = ""
        try db.query("SELECT note, rects FROM highlights") { highlight = "\($0.string(0))|\($0.string(1))" }
        XCTAssertEqual(highlight, "not|[[1,2,3,4]]")
        var courses = 0
        try db.query("SELECT COUNT(*) FROM courses") { courses = $0.int(0) }
        XCTAssertEqual(courses, 1)

        // Steg 6 (K2, K3).
        try db.execute("""
            INSERT INTO book_info (book, page_first, page_spread, author, year, title, publisher, place, updated)
            VALUES ('bok', 63, 0, 'Lindqvist, Anders', '2016', 'Klassisk retorik', 'Studentlitteratur', 'Lund', 1)
            """)
        var info = ""
        try db.query("SELECT page_first, year FROM book_info WHERE book = 'bok'") { info = "\($0.int(0))|\($0.string(1))" }
        XCTAssertEqual(info, "63|2016")
        // Trappan körd en gång till gör ingenting.
        let again = try db.migrate(AnnotationStore.migrations)
        XCTAssertEqual(again.from, again.to)
    }
}
