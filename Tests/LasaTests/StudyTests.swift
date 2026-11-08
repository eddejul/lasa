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
        // D4-2: jämn sida till vänster, så ett kapitel som börjar på s. 281 har 280 och 281 på första bilden.
        XCTAssertEqual(numbering.printed(for: 0, pdfLabel: nil), "280 och 281")
        XCTAssertEqual(numbering.printed(for: 2, pdfLabel: nil), "284 och 285")
        XCTAssertEqual(numbering.index(forTyped: "281", pageCount: 13) { _ in nil }, 0)
        XCTAssertEqual(numbering.index(forTyped: "286", pageCount: 13) { _ in nil }, 3)
        XCTAssertEqual(numbering.index(forTyped: "285", pageCount: 13) { _ in nil }, 2)
        XCTAssertEqual(numbering.citationPage(for: 2, half: 1, pdfLabel: nil), "285")
        XCTAssertEqual(numbering.citationPage(for: 2, half: 0, pdfLabel: nil), "284")
        XCTAssertEqual(numbering.citationPage(for: 2, half: nil, pdfLabel: nil), "284 f.")
        let even = BookPageNumbering(source: .offset(first: 62, spread: true))
        XCTAssertEqual(even.printed(for: 0, pdfLabel: nil), "62 och 63")
        XCTAssertNil(BookPageNumbering(source: .offset(first: 1, spread: true)).printed(for: 0, pdfLabel: nil))
    }

    func testPDFLabelsAndFileNumbers() {
        let labels = BookPageNumbering.resolve(first: 0, spread: false, fileName: "Bok.pdf", pageCount: 5,
                                               hasPDFLabels: true)
        XCTAssertEqual(labels.source, .pdfLabels)
        XCTAssertEqual(labels.printed(for: 0, pdfLabel: "xii"), "xii")
        XCTAssertNil(labels.printed(for: 0, pdfLabel: "1"))
        XCTAssertEqual(labels.index(forTyped: "XII", pageCount: 5) { $0 == 3 ? "xii" : nil }, 3)
        // -1: läsaren har sagt att filens nummer är bokens, även när filnamnet har ett intervall.
        let off = BookPageNumbering.resolve(first: -1, spread: false, fileName: "Kap (s63-80).pdf", pageCount: 18,
                                            hasPDFLabels: true)
        XCTAssertEqual(off.source, .fileConfirmed)
        XCTAssertNil(off.printed(for: 4, pdfLabel: "v"))
        XCTAssertEqual(off.citationPage(for: 4, half: nil, pdfLabel: nil), "5")
        XCTAssertFalse(off.usesBookNumbers)
        // -2: PDF:ens sidetiketter.
        XCTAssertEqual(BookPageNumbering.resolve(first: -2, spread: false, fileName: "Kap (s63-80).pdf", pageCount: 18,
                                                 hasPDFLabels: true).source, .pdfLabels)
    }

    /// D4-1: utan intervall i filnamnet, utan sidetiketter och utan inställning får citatet ingen sida.
    func testUnsetBookNumbersGiveNoCitationPage() {
        let hietanen = BookPageNumbering.resolve(first: 0, spread: false,
                                                 fileName: "HIETANEN 2015 Topikernas teori och praktik.pdf",
                                                 pageCount: 25, hasPDFLabels: false)
        XCTAssertEqual(hietanen.source, .file)
        XCTAssertNil(hietanen.citationPage(for: 22, half: nil, pdfLabel: nil))
        XCTAssertNil(hietanen.printed(for: 22, pdfLabel: nil))
        XCTAssertEqual(Citation.inText(.harvard, source: CitationSource(author: "Hietanen, Mika", year: "2015", title: "T"),
                                       page: hietanen.citationPage(for: 22, half: nil, pdfLabel: nil)),
                       "(Hietanen 2015)")
        // Förslaget ur sidornas text: tryckta nummer i sidhuvud eller sidfot, bara som förslag.
        XCTAssertEqual(PrintedPageNumbers.candidates(in: "Topikernas teori\nText på sidan.\nMer text.\n136"), [136])
        XCTAssertEqual(PrintedPageNumbers.candidates(in: "134 MIKA HIETANEN\nText.\nSlut."), [134])
        XCTAssertEqual(PrintedPageNumbers.candidates(in: "Bara text utan tal\nfyra 2 rader"), [])
        let pages = (20..<25).map { (index: $0, numbers: [$0 + 112, 7]) } + [(index: 3, numbers: [])]
        let found = PrintedPageNumbers.firstPage(pages)
        XCTAssertEqual(found?.first, 112)
        XCTAssertEqual(found?.votes, 5)
        XCTAssertNil(PrintedPageNumbers.firstPage([(index: 0, numbers: [5]), (index: 1, numbers: [9])]))
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

    // MARK: K1

    private func entry(_ id: String, color: HighlightColor, note: String = "", chapter: String,
                       book: String = "b") -> NotebookEntry {
        let highlight = Highlight(id: id, book: book, section: 0, start: 0, length: 4, text: "Text \(id) om ethos",
                                  color: color, note: note, created: Date(), updated: Date())
        return NotebookEntry(highlight: highlight, bookID: book, bookTitle: "Bok \(book)", chapter: chapter, page: "63")
    }

    func testNotebookFiltersAndGroups() {
        let entries = [entry("1", color: .yellow, chapter: "Kap 1"), entry("2", color: .blue, note: "Begrepp", chapter: "Kap 1"),
                       entry("3", color: .yellow, chapter: "Kap 2"), entry("4", color: .pink, chapter: "", book: "c")]
        var filter = NotebookLogic.Filter()
        XCTAssertEqual(NotebookLogic.filter(entries, filter).count, 4)
        filter.colors = [.yellow]
        XCTAssertEqual(NotebookLogic.filter(entries, filter).map(\.highlight.id), ["1", "3"])
        filter.colors = []
        filter.notesOnly = true
        XCTAssertEqual(NotebookLogic.filter(entries, filter).map(\.highlight.id), ["2"])
        filter.notesOnly = false
        filter.query = "BEGREPP"
        XCTAssertEqual(NotebookLogic.filter(entries, filter).map(\.highlight.id), ["2"])
        filter.query = ""
        filter.books = ["c"]
        XCTAssertEqual(NotebookLogic.filter(entries, filter).map(\.highlight.id), ["4"])
        let groups = NotebookLogic.groups(Array(entries.prefix(3)), allBooks: false)
        XCTAssertEqual(groups.map(\.title), ["Kap 1", "Kap 2"])
        XCTAssertEqual(NotebookLogic.groups(entries, allBooks: true).map(\.title), ["Bok b: Kap 1", "Bok b: Kap 2", "Bok c"])
    }

    // MARK: K10

    func testReadingWeekStartsOnMondayAndCountsDays() {
        var calendar = ReadingWeek.calendar
        calendar.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        // Söndag 8 november 2026 kl. 23.30 i svensk tid.
        let sunday = DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: 2026, month: 11, day: 8,
                                    hour: 23, minute: 30).date!
        XCTAssertEqual(ReadingWeek.dayKey(sunday, calendar: calendar), "2026-11-08")
        let log = ["2026-11-02": ReadingWeek.Day(seconds: 3600, pages: 20),
                   "2026-11-04": ReadingWeek.Day(seconds: 1200, pages: 9),
                   "2026-11-08": ReadingWeek.Day(seconds: 30, pages: 1),
                   "2026-11-09": ReadingWeek.Day(seconds: 999, pages: 99)]
        let week = ReadingWeek(today: sunday, log: log, calendar: calendar)
        XCTAssertEqual(week.keys.first, "2026-11-02")
        XCTAssertEqual(week.keys.last, "2026-11-08")
        XCTAssertEqual(week.todayIndex, 6)
        XCTAssertEqual(week.totalPages, 30)
        XCTAssertEqual(week.daysRead, 3)
        XCTAssertEqual(week.summary, "1 h 20 min, 30 sidor, läst 3 av 7 dagar")
        XCTAssertFalse(week.summary.contains("kvar"))
        XCTAssertEqual(ReadingWeek.duration(200 * 60), "3 h 20 min")
        XCTAssertEqual(ReadingWeek.duration(59), "0 min")
    }

    func testReadRangesMergeNearbyPages() {
        let step = 1.0 / 99
        let ranges = ReadingWeek.ranges([0, step, 2 * step, 10 * step, 11 * step], step: step)
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0].lowerBound, 0, accuracy: 0.0001)
        XCTAssertEqual(ranges[0].upperBound, 3 * step, accuracy: 0.0001)
        XCTAssertEqual(ranges[1].lowerBound, 10 * step, accuracy: 0.0001)
        XCTAssertTrue(ReadingWeek.ranges([], step: step).isEmpty)
    }

    // MARK: K5

    func testAnkiFiles() {
        XCTAssertEqual(AnkiFormat.cloze("Retoriken bygger på det sannolika."),
                       "Retoriken bygger på det {{c1::sannolika}}.")
        XCTAssertEqual(AnkiFormat.field("a<b>\tc\nd & e"), "a&lt;b&gt; c<br>d &amp; e")
        XCTAssertEqual(AnkiFormat.tag("Klassisk retorik"), "Klassisk_retorik")
        let highlight = Highlight(id: "abc", book: "b", section: 2, start: 0, length: 4, text: "Ethos är talarens karaktär",
                                  color: .blue, note: "Begrepp", created: Date(), updated: Date())
        let entry = NotebookEntry(highlight: highlight, bookID: "b", bookTitle: "Klassisk retorik", chapter: "", page: "63")
        let file = AnkiFormat.highlightsFile([entry], colorNames: [.blue: "Begrepp"])
        let lines = file.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "#separator:tab")
        XCTAssertTrue(lines.contains("#guid column:1"))
        XCTAssertTrue(lines.contains("#tags column:4"))
        let row = lines.last?.components(separatedBy: "\t") ?? []
        XCTAssertEqual(row.count, 4)
        XCTAssertEqual(row.first, "sensus-m-abc")
        XCTAssertEqual(row[safe: 1], "Ethos är talarens {{c1::karaktär}}")
        XCTAssertEqual(row[safe: 2], "Begrepp<br><br><i>Klassisk retorik, s. 63</i>")
        XCTAssertEqual(row[safe: 3], "Sensus Klassisk_retorik Begrepp")
        // Samma markering ger samma id i nästa export, så att Anki uppdaterar kortet.
        XCTAssertEqual(AnkiFormat.highlightsFile([entry], colorNames: [:]).components(separatedBy: "\t").first?
                        .components(separatedBy: "\n").last, "sensus-m-abc")
        let word = AnkiFormat.wordLine(id: "sensus-o-sv-etos", word: "etos", language: "svenska", answer: "Karaktär",
                                       sentence: "Talarens etos.", book: "Bok")
        XCTAssertEqual(word, "sensus-o-sv-etos\tetos\tKaraktär<br><br><i>Talarens etos.</i>\tSensus ord svenska Bok")
    }

    // MARK: K8 och K12

    func testConceptTermsAndDefinitions() {
        XCTAssertEqual(ConceptLogic.term(from: "ethos."), "ethos")
        XCTAssertEqual(ConceptLogic.term(from: "Retoriken bygger på det sannolika och rimliga"), "Retoriken bygger på det")
        XCTAssertEqual(ConceptLogic.suggestedDefinition(text: "ethos", note: " Talarens karaktär ", term: "ethos"),
                       "Talarens karaktär")
        XCTAssertEqual(ConceptLogic.suggestedDefinition(text: "ethos", note: "", term: "ethos"), "")
        let now = Date()
        let list = [Concept(id: "1", book: "b", term: "pathos", definition: "", highlight: "", created: now, updated: now),
                    Concept(id: "2", book: "b", term: "Ethos", definition: "", highlight: "", created: now, updated: now)]
        XCTAssertEqual(ConceptLogic.sorted(list).map(\.term), ["Ethos", "pathos"])
    }

    func testPageNotesInTheNotebook() {
        let highlight = Highlight(id: NotebookEntry.pageNotePrefix + "3", book: "b", section: 3, start: -1, length: 0,
                                  text: "Fråga till seminariet", color: .yellow, note: "", created: Date(), updated: Date())
        let note = NotebookEntry(highlight: highlight, bookID: "b", bookTitle: "Bok", chapter: "", page: "65", isPageNote: true)
        var filter = NotebookLogic.Filter()
        filter.notesOnly = true
        XCTAssertEqual(NotebookLogic.filter([note], filter).count, 1)
        filter.notesOnly = false
        filter.colors = [.yellow]
        XCTAssertEqual(NotebookLogic.filter([note], filter).count, 0)
        let marks = [entry("1", color: .yellow, chapter: "Kap 1"), entry("2", color: .blue, chapter: "Kap 1")]
        XCTAssertEqual(NotebookLogic.countText(shown: marks + [note], all: marks + [note]), "2 markeringar och 1 anteckning")
        XCTAssertEqual(NotebookLogic.countText(shown: [marks[0]], all: marks), "1 av 2: 1 markering")
        // Anteckningarna bredvid texten blir inga Anki-kort.
        XCTAssertFalse(AnkiFormat.highlightsFile([], colorNames: [:]).contains("sidanteckning"))
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
        // Steg 7 (K10): samma sida samma dag blir en rad med tiden adderad.
        for seconds in [30.0, 12.0] {
            try db.execute("""
                INSERT INTO reading_log (day, book, page, position, seconds) VALUES ('2026-11-08', 'bok', '3', 0.1, ?)
                ON CONFLICT(day, book, page) DO UPDATE SET seconds = seconds + excluded.seconds
                """, [seconds])
        }
        var log = ""
        try db.query("SELECT COUNT(*), SUM(seconds) FROM reading_log") { log = "\($0.int(0))|\($0.double(1))" }
        XCTAssertEqual(log, "1|42.0")
        // Steg 8 (K12) och steg 9 (K8).
        try db.execute("INSERT INTO page_notes (book, section, text, created, updated, deleted) VALUES ('bok', 3, 'Fråga', 1, 1, 0)")
        try db.execute("""
            INSERT INTO page_notes (book, section, text, created, updated, deleted) VALUES ('bok', 3, 'Ny fråga', 1, 2, 0)
            ON CONFLICT(book, section) DO UPDATE SET text = excluded.text, updated = excluded.updated
            """)
        var notes = ""
        try db.query("SELECT COUNT(*), MAX(text) FROM page_notes") { notes = "\($0.int(0))|\($0.string(1))" }
        XCTAssertEqual(notes, "1|Ny fråga")
        try db.execute("""
            INSERT INTO concepts (id, book, term, definition, highlight, created, updated, deleted)
            VALUES ('k', 'bok', 'ethos', 'Talarens karaktär', 'm', 1, 1, 0)
            """)
        var concept = ""
        try db.query("SELECT term, definition FROM concepts WHERE book = 'bok'") { concept = "\($0.string(0))|\($0.string(1))" }
        XCTAssertEqual(concept, "ethos|Talarens karaktär")
        // Trappan körd en gång till gör ingenting.
        let again = try db.migrate(AnnotationStore.migrations)
        XCTAssertEqual(again.from, again.to)
    }
}
