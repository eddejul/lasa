import XCTest
@testable import Lasa

/// G3: böckerna känns igen på innehållet. Matchningen av filer mot registret, och flytten av gamla nycklar
/// från filnamnet till bokens id, med påhittade gamla data i en databas i minnet och en egen UserDefaults.
final class BookMatcherTests: XCTestCase {

    private func record(_ id: String, file: String, sha: String = "abc", size: Int = 100, modified: Int = 5,
                        missing: Bool = false) -> BookRecord {
        let name = (file as NSString).lastPathComponent
        let title = (name as NSString).deletingPathExtension
        return BookRecord(id: id, sha256: sha, file: file, title: title,
                          size: size, modified: modified, added: 0, missing: missing)
    }

    func testSamePathSizeAndDateIsKnown() {
        let records = [record("a", file: "Bok.pdf")]
        let file = BookFile(path: "Bok.pdf", size: 100, modified: 5)
        XCTAssertEqual(BookMatcher.match(file, hash: nil, records: records, present: ["Bok.pdf"]), .known(id: "a"))
    }

    func testNewFileWithoutAbsentBooksIsNewWithoutHash() {
        let records = [record("a", file: "Bok.pdf")]
        let file = BookFile(path: "Annan.pdf", size: 7, modified: 1)
        XCTAssertEqual(BookMatcher.match(file, hash: nil, records: records, present: ["Bok.pdf", "Annan.pdf"]), .new)
    }

    func testRenamedFileIsFoundByContent() {
        // Bok.pdf heter nu RETA30/Kursbok.pdf: samma innehåll, och den gamla platsen finns inte längre.
        let records = [record("a", file: "Bok.pdf", sha: "h1")]
        let file = BookFile(path: "RETA30/Kursbok.pdf", size: 100, modified: 9)
        let present: Set<String> = ["RETA30/Kursbok.pdf"]
        XCTAssertEqual(BookMatcher.match(file, hash: nil, records: records, present: present), .needsHash)
        XCTAssertEqual(BookMatcher.match(file, hash: "h1", records: records, present: present), .moved(id: "a"))
    }

    func testNewContentAtSamePathIsANewVersion() {
        let records = [record("a", file: "Bok.pdf", sha: "h1")]
        let file = BookFile(path: "Bok.pdf", size: 120, modified: 9)
        XCTAssertEqual(BookMatcher.match(file, hash: nil, records: records, present: ["Bok.pdf"]), .needsHash)
        XCTAssertEqual(BookMatcher.match(file, hash: "h2", records: records, present: ["Bok.pdf"]), .newVersion(id: "a"))
        // Samma innehåll med ny ändringstid (filen sparades om) är samma bok.
        XCTAssertEqual(BookMatcher.match(file, hash: "h1", records: records, present: ["Bok.pdf"]), .known(id: "a"))
    }

    func testBookFromBeforeTheRegistryKeepsItsIdWhenSavedAgain() {
        // Böcker från före G3 har ingen kontrollsumma än: samma storlek med ny ändringstid är samma bok.
        let records = [record("a", file: "Bok.pdf", sha: "")]
        let file = BookFile(path: "Bok.pdf", size: 100, modified: 9)
        XCTAssertEqual(BookMatcher.match(file, hash: "h2", records: records, present: ["Bok.pdf"]), .known(id: "a"))
    }

    func testReplacedBookFromBeforeTheRegistryIsANewVersion() {
        // Granskningens fynd 8: filen ersätts på samma plats innan kontrollsumman räknats (annan storlek).
        let records = [record("a", file: "Bok.pdf", sha: "")]
        let file = BookFile(path: "Bok.pdf", size: 120, modified: 9)
        XCTAssertEqual(BookMatcher.match(file, hash: nil, records: records, present: ["Bok.pdf"]), .needsHash)
        XCTAssertEqual(BookMatcher.match(file, hash: "h2", records: records, present: ["Bok.pdf"]),
                       .newVersion(id: "a"))
    }

    func testRenamedBookFromBeforeTheRegistryIsFoundOnSizeAndDate() {
        // Granskningens fynd 4: döps om i Filer innan kontrollsumman räknats. Storlek och ändringstid är kvar.
        let records = [record("a", file: "Retorik.pdf", sha: "", size: 100, modified: 5)]
        let file = BookFile(path: "RETA30/Retorik kap 1.pdf", size: 100, modified: 5)
        let present: Set<String> = ["RETA30/Retorik kap 1.pdf"]
        XCTAssertEqual(BookMatcher.match(file, hash: nil, records: records, present: present), .moved(id: "a"))
        XCTAssertEqual(BookMatcher.match(file, hash: "h1", records: records, present: present), .moved(id: "a"))
        // Annan storlek eller annan filtyp: inte samma bok.
        let other = BookFile(path: "Annan.pdf", size: 101, modified: 5)
        XCTAssertEqual(BookMatcher.match(other, hash: "h2", records: records, present: ["Annan.pdf"]), .new)
        let epub = BookFile(path: "Annan.epub", size: 100, modified: 5)
        XCTAssertEqual(BookMatcher.match(epub, hash: "h3", records: records, present: ["Annan.epub"]), .new)
    }

    func testBookWithoutFileAtFirstStartComesBack() {
        // Granskningens fynd 5: raden från flytten (storlek 0, tom kontrollsumma, borta) och samma filnamn igen.
        let records = [record("a", file: "Bok.pdf", sha: "", size: 0, modified: 0, missing: true)]
        let file = BookFile(path: "Bok.pdf", size: 4000, modified: 9)
        XCTAssertEqual(BookMatcher.match(file, hash: nil, records: records, present: ["Bok.pdf"]), .needsHash)
        XCTAssertEqual(BookMatcher.match(file, hash: "h1", records: records, present: ["Bok.pdf"]), .known(id: "a"))
    }

    func testVersionQuestionShowsBothNames() {
        // Granskningens fynd 12: Föreläsning 3 och Föreläsning 4 liknar varandra, och frågan visar båda.
        let old = record("a", file: "Föreläsning 3.pdf", sha: "h1", missing: true)
        let file = BookFile(path: "Föreläsning 4.pdf", size: 120, modified: 9)
        XCTAssertEqual(BookMatcher.match(file, hash: "h2", records: [old], present: ["Föreläsning 4.pdf"]),
                       .newVersion(id: "a"))
        let question = BookRegistry.VersionQuestion(file: file, hash: "h2", record: old)
        XCTAssertTrue(question.message.contains("Föreläsning 4.pdf"))
        XCTAssertTrue(question.message.contains("Föreläsning 3.pdf"))
    }

    func testSimilarNameOfAbsentBookIsANewVersion() {
        let records = [record("a", file: "Retorik.pdf", sha: "h1")]
        let file = BookFile(path: "Retorik (OCR) 2.pdf", size: 120, modified: 9)
        XCTAssertEqual(BookMatcher.match(file, hash: "h2", records: records, present: ["Retorik (OCR) 2.pdf"]),
                       .newVersion(id: "a"))
        // Annan filtyp eller annan titel är en ny bok.
        let epub = BookFile(path: "Retorik.epub", size: 120, modified: 9)
        XCTAssertEqual(BookMatcher.match(epub, hash: "h3", records: records, present: ["Retorik.epub"]), .new)
        let other = BookFile(path: "Filosofi.pdf", size: 120, modified: 9)
        XCTAssertEqual(BookMatcher.match(other, hash: "h4", records: records, present: ["Filosofi.pdf"]), .new)
    }

    func testDuplicateOfPresentBookIsANewBook() {
        // Samma innehåll som en bok som finns kvar: en kopia, som får ett eget id.
        let records = [record("a", file: "Bok.pdf", sha: "h1"), record("b", file: "Borta.pdf", sha: "h9")]
        let file = BookFile(path: "Kopia/Bok.pdf", size: 100, modified: 5)
        XCTAssertEqual(BookMatcher.match(file, hash: "h1", records: records,
                                         present: ["Bok.pdf", "Kopia/Bok.pdf"]), .new)
    }

    func testPresentRowWinsOverMissingRowAtSamePath() {
        let records = [record("gammal", file: "Bok.pdf", sha: "h1", size: 1, missing: true),
                       record("ny", file: "Bok.pdf", sha: "h2", size: 100)]
        let file = BookFile(path: "Bok.pdf", size: 100, modified: 5)
        XCTAssertEqual(BookMatcher.match(file, hash: nil, records: records, present: ["Bok.pdf"]), .known(id: "ny"))
    }

    func testNormalizedTitle() {
        XCTAssertEqual(BookMatcher.normalizedTitle("Retorik (OCR) v2"), "retorik")
        XCTAssertEqual(BookMatcher.normalizedTitle("Kursbok - ny version 2026"), "kursbok")
    }
}

final class LegacyBookMigrationTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "se.edvin.lasa.tests.migrering"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func count(_ db: SQLiteDatabase, _ sql: String) throws -> Int {
        var value = 0
        try db.query(sql) { value = $0.int(0) }
        return value
    }

    func testOldKeysMoveToTheBookIdAndNothingIsLost() throws {
        let db = try SQLiteDatabase(path: ":memory:", readOnly: false)
        try db.migrate(Array(AnnotationStore.migrations.prefix(1)))
        for start in [10, 40] {
            try db.execute("""
                INSERT INTO highlights (id, book, section, start, length, text, color, note, created, updated, deleted)
                VALUES (?, 'Bok.pdf', 4, ?, 5, 't', 'yellow', '', 1, 2, 0)
                """, ["h\(start)", start])
        }
        try db.execute("""
            INSERT INTO bookmarks (id, book, section, progression, label, created, updated, deleted)
            VALUES ('b1', 'Roman.epub', 2, 0.5, 'Kap 3', 1, 2, 0)
            """)
        // En markering i en bok som inte finns längre står kvar under filnamnet.
        try db.execute("""
            INSERT INTO highlights (id, book, section, start, length, text, color, note, created, updated, deleted)
            VALUES ('borta', 'Borttagen.pdf', 1, 0, 5, 't', 'yellow', '', 1, 2, 0)
            """)
        defaults.set(12, forKey: "position.Bok.pdf")
        defaults.set("2|0.5", forKey: "location.Roman.epub")
        defaults.set(99.0, forKey: "positionDate.Roman.epub")
        try db.migrate(AnnotationStore.migrations)

        let records = [
            BookRecord(id: "p", sha256: "", file: "Bok.pdf", title: "Bok", size: 1, modified: 1, added: 0, missing: false),
            BookRecord(id: "e", sha256: "", file: "Roman.epub", title: "Roman", size: 1, modified: 1, added: 0,
                       missing: false),
        ]
        XCTAssertTrue(LegacyBookMigration.hasWork(db: db, records: records, defaults: defaults))
        XCTAssertFalse(try LegacyBookMigration.isDone(db))
        let result = try LegacyBookMigration.run(db: db, records: records, defaults: defaults)
        XCTAssertEqual(result, LegacyBookMigration.Result(highlights: 3, bookmarks: 1, keys: 3, placeholders: 1))

        XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM highlights WHERE book = 'p' AND section = 4"), 2)
        XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM bookmarks WHERE book = 'e' AND section = 2"), 1)
        // Granskningens fynd 5: en bok som inte finns längre får en rad i registret, och markeringen följer med.
        XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM highlights WHERE book = 'Borttagen.pdf'"), 0)
        XCTAssertEqual(try count(db, """
            SELECT COUNT(*) FROM highlights h JOIN books b ON b.id = h.book
            WHERE b.file = 'Borttagen.pdf' AND b.missing = 1 AND b.sha256 = '' AND b.size = 0
            """), 1)
        XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM highlights WHERE updated = 2"), 3, "Ändringstiden rörs inte")
        XCTAssertEqual(defaults.integer(forKey: "bookPosition.p"), 12)
        XCTAssertEqual(defaults.string(forKey: "bookLocation.e"), "2|0.5")
        XCTAssertEqual(defaults.double(forKey: "bookPositionDate.e"), 99.0)
        XCTAssertNil(defaults.object(forKey: "position.Bok.pdf"))
        XCTAssertNil(defaults.object(forKey: "location.Roman.epub"))
        XCTAssertTrue(try LegacyBookMigration.isDone(db))
        XCTAssertFalse(LegacyBookMigration.hasWork(db: db, records: records, defaults: defaults))

        // En gång till: ingenting ändras.
        let again = try LegacyBookMigration.run(db: db, records: records, defaults: defaults)
        XCTAssertEqual(again, LegacyBookMigration.Result(highlights: 0, bookmarks: 0, keys: 0, placeholders: 0))
        XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM books"), 1)
        XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM highlights WHERE book = 'p'"), 2)
        XCTAssertEqual(defaults.integer(forKey: "bookPosition.p"), 12)
    }

    func testExistingNewValueIsNotOverwritten() throws {
        let db = try SQLiteDatabase(path: ":memory:", readOnly: false)
        try db.migrate(AnnotationStore.migrations)
        defaults.set(3, forKey: "position.Bok.pdf")
        defaults.set(8, forKey: "bookPosition.p")
        let records = [BookRecord(id: "p", sha256: "", file: "Bok.pdf", title: "Bok", size: 1, modified: 1, added: 0,
                                  missing: false)]
        try LegacyBookMigration.run(db: db, records: records, defaults: defaults)
        XCTAssertEqual(defaults.integer(forKey: "bookPosition.p"), 8)
        XCTAssertNil(defaults.object(forKey: "position.Bok.pdf"))
    }

    func testBookInSubfolderGetsItsOldData() throws {
        // Granskningens fynd 5: boken flyttades till en undermapp före första starten.
        let db = try SQLiteDatabase(path: ":memory:", readOnly: false)
        try db.migrate(AnnotationStore.migrations)
        try db.execute("""
            INSERT INTO highlights (id, book, section, start, length, text, color, note, created, updated, deleted)
            VALUES ('h1', 'Bok.pdf', 3, 0, 5, 't', 'yellow', '', 1, 2, 0)
            """)
        defaults.set(17, forKey: "position.Bok.pdf")
        let records = [BookRecord(id: "p", sha256: "", file: "RETA30/Bok.pdf", title: "Bok", size: 1, modified: 1,
                                  added: 0, missing: false)]
        XCTAssertTrue(LegacyBookMigration.hasWork(db: db, records: records, defaults: defaults))
        let result = try LegacyBookMigration.run(db: db, records: records, defaults: defaults)
        XCTAssertEqual(result, LegacyBookMigration.Result(highlights: 1, bookmarks: 0, keys: 1, placeholders: 0))
        XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM highlights WHERE book = 'p'"), 1)
        XCTAssertEqual(defaults.integer(forKey: "bookPosition.p"), 17)
        XCTAssertFalse(LegacyBookMigration.hasWork(db: db, records: records, defaults: defaults))
    }

    func testNewerOldPositionWinsAfterDowngrade() throws {
        // Granskningens fynd 6: en äldre version av appen har sparat en nyare läsposition och en ny markering
        // under filnamnet efter att flytten redan gjorts. Flytten körs igen, och den nyaste platsen vinner.
        let db = try SQLiteDatabase(path: ":memory:", readOnly: false)
        try db.migrate(AnnotationStore.migrations)
        let records = [BookRecord(id: "p", sha256: "", file: "Bok.pdf", title: "Bok", size: 1, modified: 1, added: 0,
                                  missing: false)]
        try BookRegistry.insert(records[0], into: db)
        defaults.set(8, forKey: "bookPosition.p")
        defaults.set(100.0, forKey: "bookPositionDate.p")
        try LegacyBookMigration.run(db: db, records: records, defaults: defaults)
        XCTAssertTrue(try LegacyBookMigration.isDone(db))

        defaults.set(30, forKey: "position.Bok.pdf")
        defaults.set(200.0, forKey: "positionDate.Bok.pdf")
        try db.execute("""
            INSERT INTO highlights (id, book, section, start, length, text, color, note, created, updated, deleted)
            VALUES ('ny', 'Bok.pdf', 3, 0, 5, 't', 'yellow', '', 1, 2, 0)
            """)
        XCTAssertTrue(LegacyBookMigration.hasWork(db: db, records: records, defaults: defaults))
        try LegacyBookMigration.run(db: db, records: records, defaults: defaults)
        XCTAssertEqual(defaults.integer(forKey: "bookPosition.p"), 30)
        XCTAssertEqual(defaults.double(forKey: "bookPositionDate.p"), 200.0)
        XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM highlights WHERE book = 'p'"), 1)
        XCTAssertNil(defaults.object(forKey: "position.Bok.pdf"))

        // En äldre plats under filnamnet vinner inte över en nyare under bokens id.
        defaults.set(2, forKey: "position.Bok.pdf")
        defaults.set(50.0, forKey: "positionDate.Bok.pdf")
        try LegacyBookMigration.run(db: db, records: records, defaults: defaults)
        XCTAssertEqual(defaults.integer(forKey: "bookPosition.p"), 30)
        XCTAssertNil(defaults.object(forKey: "position.Bok.pdf"))
    }
}

/// Granskningens fynd 1 och 2: vilka säkerhetskopior som rensas.
final class BackupPruneTests: XCTestCase {

    private func copy(daysAgo: Double, hour: Double = 10, beforeUpdate: Bool = false, name: String? = nil) -> Backup.Copy {
        let base = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let date = base.addingTimeInterval(-daysAgo * 86_400 + hour * 3600)
        let url = URL(fileURLWithPath: "/kopior/\(name ?? "\(daysAgo)-\(hour)")", isDirectory: true)
        return Backup.Copy(url: url, date: date, isBeforeUpdate: beforeUpdate)
    }

    func testSevenDaysAreKeptAndTheNewestCopyPerDay() {
        var copies = (0..<9).map { copy(daysAgo: Double($0)) }
        copies.append(copy(daysAgo: 0, hour: 8))
        copies.append(copy(daysAgo: 30, beforeUpdate: true, name: "fore"))
        let removed = Backup.copiesToRemove(copies, keep: 7, protecting: nil)
        let removedNames = Set(removed.map { $0.url.lastPathComponent })
        // Dag 7 och 8 rensas, och den äldre kopian i dag ersätts av den nyare. Kopian före flytten rörs aldrig.
        XCTAssertEqual(removedNames, ["7.0-10.0", "8.0-10.0", "0.0-8.0"])
    }

    func testRestoredCopyIsNeverRemoved() {
        // Sju dagar, plus kopian före återställningen i dag: den äldsta (som återställts) får vara kvar.
        var copies = (0..<7).map { copy(daysAgo: Double($0) + 1) }
        copies.append(copy(daysAgo: 0))
        let oldest = copies[6]
        XCTAssertEqual(Backup.copiesToRemove(copies, keep: 7, protecting: nil).map(\.url), [oldest.url])
        XCTAssertTrue(Backup.copiesToRemove(copies, keep: 7, protecting: oldest.url).isEmpty)
    }
}
