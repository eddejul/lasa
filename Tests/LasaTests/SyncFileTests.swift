import XCTest
@testable import Lasa

/// Synkfilerna och sammanslagningen (F1), med påhittade filer från två enheter.
final class SyncFileTests: XCTestCase {

    private let ipad = SyncDevice(id: "ipad-1", name: "iPad", platform: "ios")
    private let windows = SyncDevice(id: "win-1", name: "Datorn", platform: "windows")
    private let book = String(repeating: "a", count: 64)

    private func highlight(_ id: String, updated: Double, note: String = "", deleted: Bool = false) -> SyncHighlight {
        SyncHighlight(id: id, bookID: book, section: 1, start: 5, length: 10, text: "text", color: "yellow", note: note,
                      created: 1_000, updated: updated, deleted: deleted)
    }

    private func word(_ lemma: String, updated: Double, reviewUpdated: Double? = nil, interval: Double = 1,
                      deleted: Bool = false) -> SyncWord {
        var word = SyncWord(lemma: lemma, language: "sv")
        word.word = lemma
        word.created = 1_000
        word.updated = updated
        word.deleted = deleted
        if let reviewUpdated = reviewUpdated {
            word.due = 2_000
            word.interval = interval
            word.ease = 2.5
            word.reps = 1
            word.lapses = 0
            word.reviewUpdated = reviewUpdated
        }
        return word
    }

    private func snapshot(_ device: SyncDevice, highlights: [SyncHighlight] = [], words: [SyncWord] = [],
                          positions: [SyncPosition] = []) -> SyncSnapshot {
        var snapshot = SyncSnapshot(device: device, written: 5_000)
        for item in highlights { snapshot.highlights[item.id] = item }
        for item in words { snapshot.words[item.key] = item }
        for item in positions { snapshot.positions[item.bookID] = item }
        return snapshot
    }

    // MARK: Filen

    func testRoundTrip() throws {
        var original = snapshot(ipad, highlights: [highlight("h1", updated: 2_000.25, note: "Anteckning å ä ö")],
                                words: [word("ord", updated: 2_000, reviewUpdated: 2_500), word("borta", updated: 3_000,
                                                                                                 deleted: true)],
                                positions: [SyncPosition(bookID: book, title: "Bok", kind: "pdf", section: 12,
                                                         progression: 0, updated: 2_100.5)])
        original.bookmarks["b1"] = SyncBookmark(id: "b1", bookID: book, section: 3, progression: 0.5, label: "Märke",
                                                created: 1_000, updated: 1_500, deleted: false)
        let data = try SyncFile.encode(original)
        guard case .success(let decoded) = SyncFile.decode(data) else { return XCTFail("gick inte att läsa") }
        XCTAssertEqual(decoded.device, ipad)
        XCTAssertEqual(decoded.highlights, original.highlights)
        XCTAssertEqual(decoded.bookmarks, original.bookmarks)
        XCTAssertEqual(decoded.positions, original.positions)
        XCTAssertEqual(decoded.words, original.words)
        XCTAssertEqual(decoded.skippedRows, 0)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("\"format\":1"))
        XCTAssertTrue(text.contains("\"review_updated_at\":null"), "borttaget ord har ingen repetition")
    }

    func testBrokenFilesAreRejected() {
        XCTAssertEqual(SyncFile.decode(Data()).failureValue, .empty)
        XCTAssertEqual(SyncFile.decode(Data("inte json".utf8)).failureValue, .notJSON)
        XCTAssertEqual(SyncFile.decode(Data(#"{"format": 1, "device": {"id": "halv"#.utf8)).failureValue, .notJSON)
        XCTAssertEqual(SyncFile.decode(Data("[]".utf8)).failureValue, .notJSON)
        XCTAssertEqual(SyncFile.decode(Data(#"{"positions": []}"#.utf8)).failureValue, .notSensus)
        XCTAssertEqual(SyncFile.decode(Data(#"{"format": 1, "device": {"name": "utan id"}}"#.utf8)).failureValue, .notSensus)
        XCTAssertEqual(SyncFile.decode(Data(#"{"format": 2, "device": {"id": "x"}}"#.utf8)).failureValue, .newerFormat(2))
    }

    func testBadRowsAreSkippedAndUnknownFieldsIgnored() {
        let json = """
        {"format": 1, "device": {"id": "win-1", "platform": "windows"}, "nytt_falt": [1, 2],
         "positions": [{"book_id": "\(book)", "kind": "pdf", "section": 3, "updated_at": "2030-01-01T10:00:00.123Z",
                        "okänt": true},
                       {"book_id": "\(book)", "kind": "bild", "section": 3, "updated_at": "2030-01-01T10:00:00Z"}],
         "highlights": [{"id": "", "book_id": "x"}, "inte en rad",
                        {"id": "H1", "book_id": "\(book.uppercased())", "section": 0, "start": 1, "length": 2,
                         "updated_at": "2030-01-01T10:00:00.5+00:00", "deleted": 1}],
         "bookmarks": {"fel": "typ"},
         "saved_words": [{"lemma": "ord", "language": "de", "updated_at": "2030-01-01T10:00:00Z"}]}
        """
        guard case .success(let snapshot) = SyncFile.decode(Data(json.utf8)) else { return XCTFail("gick inte att läsa") }
        XCTAssertEqual(snapshot.positions.count, 1)
        XCTAssertEqual(snapshot.highlights.count, 1)
        XCTAssertEqual(snapshot.highlights["h1"]?.bookID, book, "id och bok med gemener")
        XCTAssertEqual(snapshot.highlights["h1"]?.deleted, true)
        XCTAssertEqual(snapshot.words.count, 0)
        XCTAssertEqual(snapshot.skippedRows, 5)
    }

    // MARK: Sammanslagningen

    func testNewestWinsAndTieKeepsLocal() {
        let local = snapshot(ipad, highlights: [highlight("a", updated: 2_000, note: "ny lokal"),
                                                highlight("b", updated: 2_000, note: "lokal"),
                                                highlight("c", updated: 2_000, note: "lika")])
        let remote = snapshot(windows, highlights: [highlight("a", updated: 1_000, note: "gammal"),
                                                    highlight("b", updated: 3_000, note: "nyare från datorn"),
                                                    highlight("c", updated: 2_000.0004, note: "lika i millisekunder")])
        let merged = SyncMerge.merge([local, remote], device: ipad, written: 9_000)
        XCTAssertEqual(merged.highlights["a"]?.note, "ny lokal", "en äldre rad skriver aldrig över en nyare lokal")
        XCTAssertEqual(merged.highlights["b"]?.note, "nyare från datorn")
        XCTAssertEqual(merged.highlights["c"]?.note, "lika", "lika tid: den lokala står kvar")
        let changes = SyncMerge.changes(local: local, merged: merged)
        XCTAssertEqual(changes.highlights.map(\.id), ["b"])
    }

    func testDeletionsAndAbsence() {
        let local = snapshot(ipad, highlights: [highlight("kvar", updated: 5_000), highlight("tas bort", updated: 2_000),
                                                highlight("lever", updated: 4_000)])
        // Datorn tog bort en markering senare, och en annan tidigare. En tredje saknas i filen.
        let remote = snapshot(windows, highlights: [highlight("tas bort", updated: 3_000, deleted: true),
                                                    highlight("lever", updated: 1_000, deleted: true)])
        let merged = SyncMerge.merge([local, remote], device: ipad, written: 9_000)
        XCTAssertEqual(merged.highlights["tas bort"]?.deleted, true)
        XCTAssertEqual(merged.highlights["lever"]?.deleted, false, "en äldre borttagning tar inte bort en nyare ändring")
        XCTAssertEqual(merged.highlights["kvar"]?.deleted, false, "det som saknas i en fil tas inte bort")
        XCTAssertEqual(SyncMerge.changes(local: local, merged: merged).highlights.map(\.id), ["tas bort"])

        // En tom fil och en fil från en annan dator ändrar ingenting lokalt.
        let empty = SyncSnapshot(device: windows, written: 9_000)
        let unchanged = SyncMerge.merge([local, empty], device: ipad, written: 9_000)
        XCTAssertEqual(unchanged.highlights, local.highlights)
        XCTAssertEqual(SyncMerge.changes(local: local, merged: unchanged).count, 0)
    }

    func testThreeDevicesConverge() {
        let a = snapshot(ipad, highlights: [highlight("x", updated: 1_000, note: "a")])
        let b = snapshot(windows, highlights: [highlight("x", updated: 3_000, note: "b")])
        let c = snapshot(SyncDevice(id: "c", name: "", platform: "ios"), highlights: [highlight("x", updated: 2_000, note: "c")])
        for order in [[a, b, c], [a, c, b], [c, a, b]] {
            XCTAssertEqual(SyncMerge.merge(order, device: ipad, written: 1).highlights["x"]?.note, "b")
        }
    }

    func testWordAndReviewMergeSeparately() {
        // Ordet ändrades senast på iPaden, repetitionen senast på datorn.
        let local = snapshot(ipad, words: [word("ord", updated: 3_000, reviewUpdated: 1_000, interval: 1)])
        let remote = snapshot(windows, words: [word("ord", updated: 2_000, reviewUpdated: 4_000, interval: 7)])
        let merged = SyncMerge.merge([local, remote], device: ipad, written: 9_000)
        XCTAssertEqual(merged.words["sv|ord"]?.updated, 3_000)
        XCTAssertEqual(merged.words["sv|ord"]?.interval, 7)
        XCTAssertEqual(merged.words["sv|ord"]?.reviewUpdated, 4_000)
        XCTAssertEqual(SyncMerge.changes(local: local, merged: merged).words.count, 1, "repetitionen är nyare")

        // Borttaget senare på datorn: ingen repetition kvar.
        let deleted = snapshot(windows, words: [word("ord", updated: 5_000, deleted: true)])
        let gone = SyncMerge.merge([local, remote, deleted], device: ipad, written: 9_000).words["sv|ord"]
        XCTAssertEqual(gone?.deleted, true)
        XCTAssertNil(gone?.reviewUpdated)
        XCTAssertNil(gone?.due)

        // Sparat igen efter borttagningen: ordet lever.
        let again = snapshot(ipad, words: [word("ord", updated: 6_000, reviewUpdated: 6_000)])
        XCTAssertEqual(SyncMerge.merge([again, deleted], device: ipad, written: 9_000).words["sv|ord"]?.deleted, false)
    }

    func testPositionsAndChangedRows() {
        let old = SyncPosition(bookID: book, title: "Bok", kind: "reflow", section: 2, progression: 0.1, updated: 1_000)
        let new = SyncPosition(bookID: book, title: "Bok", kind: "reflow", section: 5, progression: 0.6, updated: 2_000)
        let local = snapshot(ipad, positions: [old])
        let merged = SyncMerge.merge([local, snapshot(windows, positions: [new])], device: ipad, written: 9_000)
        XCTAssertEqual(merged.positions[book]?.section, 5)
        XCTAssertEqual(SyncMerge.changes(local: local, merged: merged).positions.count, 1)
        XCTAssertEqual(SyncMerge.changedRows(from: local, to: merged), 1)
        XCTAssertEqual(SyncMerge.changedRows(from: merged, to: merged), 0)
        XCTAssertEqual(SyncMerge.changedRows(from: nil, to: merged), 1)
    }

    // MARK: Filerna på disk

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("synkprov-\(UUID().uuidString)",
                                                                                isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    func testAtomicWriteAndReadAll() throws {
        let directory = try temporaryDirectory()
        let own = directory.appendingPathComponent("ipad-1.json")
        try SyncFiles.writeAtomically(try SyncFile.encode(snapshot(ipad, highlights: [highlight("a", updated: 1)])), to: own)
        try SyncFiles.writeAtomically(try SyncFile.encode(snapshot(ipad, highlights: [highlight("a", updated: 2)])), to: own)
        try SyncFiles.writeAtomically(try SyncFile.encode(snapshot(windows)), to: directory.appendingPathComponent("win-1.json"))
        try Data(#"{"format": 1, "device": {"id": "halv"#.utf8).write(to: directory.appendingPathComponent("trasig.json"))
        try Data().write(to: directory.appendingPathComponent("tom.json"))
        try Data(#"{"format": 7, "device": {"id": "ny"}}"#.utf8).write(to: directory.appendingPathComponent("ny.json"))
        try Data("halvskriven".utf8).write(to: directory.appendingPathComponent("win-1.json.tmp"))
        try Data("undan".utf8).write(to: directory.appendingPathComponent("gammal.trasig-20261109-010000"))

        let entries = SyncFiles.readAll(in: directory, waitForDownloads: 0)
        XCTAssertEqual(entries.map(\.name), ["ipad-1.json", "ny.json", "tom.json", "trasig.json", "win-1.json"])
        XCTAssertEqual(entries.first { $0.name == "ipad-1.json" }?.snapshot?.highlights["a"]?.updated, 2)
        XCTAssertEqual(entries.first { $0.name == "tom.json" }?.error, .empty)
        XCTAssertEqual(entries.first { $0.name == "trasig.json" }?.error, .notJSON)
        XCTAssertEqual(entries.first { $0.name == "ny.json" }?.error, .newerFormat(7))
        XCTAssertNotNil(entries.first { $0.name == "win-1.json" }?.snapshot)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(names.contains("ipad-1.json.tmp"), "ingen tillfällig fil blir kvar")

        XCTAssertNil(SyncFiles.probe(directory))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".sensus-prov") })
    }

    func testPlaceholderNames() {
        XCTAssertEqual(SyncFiles.placeholderTarget(".win-1.json.icloud"), "win-1.json")
        XCTAssertEqual(SyncFiles.placeholderTarget(".Bok med mellanslag.pdf.icloud"), "Bok med mellanslag.pdf")
        XCTAssertNil(SyncFiles.placeholderTarget("win-1.json"))
        XCTAssertNil(SyncFiles.placeholderTarget(".icloud"))
    }

    // MARK: Bokplatsen (B4)

    func testCloudPaths() {
        XCTAssertTrue(BookPlace.isCloud("/iCloud/RETA30/Bok.pdf"))
        XCTAssertFalse(BookPlace.isCloud("iCloud/Bok.pdf"), "en mapp i Böcker som heter iCloud är ingen iCloud-bok")
        XCTAssertEqual(BookPlace.relative("/iCloud/RETA30/Bok.pdf"), "RETA30/Bok.pdf")
        XCTAssertEqual(BookPlace.relative("RETA30/Bok.pdf"), "RETA30/Bok.pdf")
        XCTAssertEqual(BookPlace.path("Bok.pdf", cloud: true), "/iCloud/Bok.pdf")
        XCTAssertEqual(CourseLogic.topFolder(of: "/iCloud/RETA30/Bok.pdf"), "RETA30")
        XCTAssertNil(CourseLogic.topFolder(of: "/iCloud/Bok.pdf"))
        XCTAssertEqual(CourseLogic.topFolder(of: "RETA30/Bok.pdf"), "RETA30")
        let file = BookFile(path: "/iCloud/RETA30/Bok.pdf", size: 1, modified: 1)
        XCTAssertEqual(file.name, "Bok.pdf")
        XCTAssertEqual(file.title, "Bok")
        XCTAssertEqual(SyncEngine.kind(of: "/iCloud/Bok.epub"), "reflow")
        XCTAssertEqual(SyncEngine.kind(of: "Bok.PDF"), "pdf")
        XCTAssertNil(SyncEngine.kind(of: "Bok.docx"))
    }

    func testCloudBookMatchesLikeLocal() {
        // Samma bok flyttad från Böcker till iCloud-mappen känns igen på kontrollsumman (G3).
        let record = BookRecord(id: "id-1", sha256: "abc", file: "Bok.pdf", title: "Bok", size: 10, modified: 5, added: 1,
                                missing: false)
        let moved = BookFile(path: "/iCloud/Bok.pdf", size: 10, modified: 5)
        XCTAssertEqual(BookMatcher.match(moved, hash: "abc", records: [record], present: ["/iCloud/Bok.pdf"]),
                       .moved(id: "id-1"))
        // En bok i iCloud-mappen som hämtas räknas som närvarande och tas inte över av en annan fil.
        let cloud = BookRecord(id: "id-2", sha256: "def", file: "/iCloud/Kurs.pdf", title: "Kurs", size: 10, modified: 5,
                               added: 1, missing: false)
        let other = BookFile(path: "Kurs.pdf", size: 10, modified: 5)
        XCTAssertEqual(BookMatcher.match(other, hash: "def", records: [cloud], present: ["Kurs.pdf", "/iCloud/Kurs.pdf"]),
                       .new)
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let error) = self {
            return error
        }
        return nil
    }
}
