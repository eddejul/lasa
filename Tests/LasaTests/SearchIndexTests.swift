import XCTest
@testable import Lasa

/// Sökregistret (G11), i en databas i minnet: texten kommer tillbaka exakt, och sökningen i registret ger
/// samma träffar och platser som sökningen direkt i texten, både med FTS5 och med den vanliga tabellen.
final class SearchIndexTests: XCTestCase {

    /// Avsnitt med det som kan gå fel: avstavning över radbrytning, stora bokstäver, å ä ö, NUL, ett ensamt
    /// surrogattecken, emoji, citattecken och ett tomt avsnitt (som saknas i registret).
    private let texts: [NSString] = [
        "Kunskap är makt. Den som söker kun-\nskap måste läsa, och läsa igen.",
        "ÅSA ÄR ÖVER ÅN. Åsa och asa är inte samma ord.",
        NSString(string: "Före NUL\u{0}efter NUL, kunskap och mer kunskap."),
        NSString(characters: [0x61, 0x62, 0xD800, 0x63, 0x20, 0x6F, 0x63, 0x68], length: 8),
        "Ett \"citat\" med 😀 och en sista rad med kunskap.",
        "",
        "Nord-\nAmerika och nord-amerika. Kun- skap är inte avstavat.",
    ]

    private let words = ["kunskap", "och", "är", "åsa", "asa", "er", "ra", "\"citat\"", "nul", "nord- amerika",
                         "kun- skap", "efter nul", "😀 och", "läsa, och", "saknas inte"]

    private func makeIndex() throws -> (SearchIndex, SearchIndex.Key) {
        let index = SearchIndex(path: ":memory:")
        let key = SearchIndex.Key(book: "bok-1", version: "v1", name: "test")
        let stored = texts.enumerated().filter { $0.element.length > 0 }.map { (section: $0.offset, text: $0.element) }
        try index.store(key, sectionCount: texts.count, texts: stored)
        return (index, key)
    }

    /// Den gamla sökningen: varje avsnitts text viks och letas igenom.
    private func directHits(_ word: String) -> [SearchHit] {
        let query = FoldedText.query(word)
        var hits: [SearchHit] = []
        for (section, text) in texts.enumerated() where text.length > 0 {
            hits += BookSearch.find(query, in: FoldedText(text), original: text, section: section, limit: 500)
        }
        return hits
    }

    private func indexHits(_ word: String, index: SearchIndex, key: SearchIndex.Key, plain: Bool) -> [SearchHit]? {
        let query = FoldedText.query(word)
        guard let sections = index.sections(key, containing: query, plain: plain) else { return nil }
        var hits: [SearchHit] = []
        for section in sections {
            guard let original = index.original(key, section: section) else { return nil }
            hits += BookSearch.find(query, in: FoldedText(original), original: original, section: section, limit: 500)
        }
        return hits
    }

    func testTextComesBackExactly() {
        for text in texts {
            let back = SearchIndex.decode(SearchIndex.encode(text))
            XCTAssertEqual(back.length, text.length)
            for offset in 0..<text.length {
                XCTAssertEqual(back.character(at: offset), text.character(at: offset))
            }
        }
    }

    func testPrefilterTextHasNoNul() {
        let folded = FoldedText(texts[2]).text
        let prefilter = SearchIndex.prefilterText(folded)
        XCTAssertFalse(prefilter.contains("\u{0}"))
        XCTAssertTrue(prefilter.contains("efter nul"))
    }

    func testFtsPhrase() {
        XCTAssertNil(SearchIndex.ftsPhrase("er"))
        XCTAssertEqual(SearchIndex.ftsPhrase("och"), "\"och\"")
        XCTAssertEqual(SearchIndex.ftsPhrase("\"citat\""), "\"\"\"citat\"\"\"")
    }

    func testIndexGivesSameHitsAsDirectSearch() throws {
        let (index, key) = try makeIndex()
        XCTAssertTrue(index.isReady(key))
        for word in words {
            let expected = directHits(word)
            XCTAssertEqual(indexHits(word, index: index, key: key, plain: true), expected, "vanlig tabell: \(word)")
            XCTAssertEqual(indexHits(word, index: index, key: key, plain: false), expected,
                           "\(index.info.mode.rawValue): \(word)")
        }
        // Ordet finns i flera avsnitt, och platserna pekar på samma text som i originalet.
        let hits = directHits("kunskap")
        XCTAssertEqual(Set(hits.map { $0.section }), [0, 2, 4])
        XCTAssertEqual(texts[0].substring(with: NSRange(location: hits[1].start, length: hits[1].length)), "kun-\nskap")
    }

    func testEmptySectionIsNotStored() throws {
        let (index, key) = try makeIndex()
        XCTAssertEqual(index.storedSections(key), [0, 1, 2, 3, 4, 6])
    }

    func testNewVersionIsNotReady() throws {
        let (index, key) = try makeIndex()
        let newer = SearchIndex.Key(book: key.book, version: "v2", name: key.name)
        XCTAssertFalse(index.isReady(newer))
        XCTAssertNil(index.sections(newer, containing: "kunskap"))
        // En ny version ersätter den gamla helt.
        try index.store(newer, sectionCount: 1, texts: [(section: 0, text: "Bara kunskap.")])
        XCTAssertTrue(index.isReady(newer))
        XCTAssertFalse(index.isReady(key))
        XCTAssertEqual(index.storedSections(newer), [0])
        XCTAssertEqual(index.sections(newer, containing: "och"), [])
        XCTAssertEqual(index.sections(newer, containing: "kunskap"), [0])
        XCTAssertEqual(index.sections(newer, containing: "kunskap", plain: true), [0])
    }

    func testOtherBooksAreSeparate() throws {
        let (index, key) = try makeIndex()
        let other = SearchIndex.Key(book: "bok-2", version: "v1", name: "annan")
        try index.store(other, sectionCount: 3, texts: [(section: 2, text: "Kunskap i en annan bok.")])
        XCTAssertEqual(index.sections(other, containing: "kunskap"), [2])
        XCTAssertEqual(index.sections(key, containing: "kunskap"), [0, 2, 4])
        index.invalidate(book: other.book)
        XCTAssertFalse(index.isReady(other))
        XCTAssertTrue(index.isReady(key))
    }
}
