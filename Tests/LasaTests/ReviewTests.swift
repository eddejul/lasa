import XCTest
@testable import Lasa

/// U6: repetitionen som kortläge. Schemat (Svårt alltid kortare än Bra), småorden som aldrig sparas, kön utan
/// småord och ord utan svar, och filtret per bok och kurs. Provas i en egen databasfil.
final class ReviewTests: XCTestCase {

    private var url: URL!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory.appendingPathComponent("repetition-\(UUID().uuidString).sqlite")
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
        super.tearDown()
    }

    // MARK: Schemat

    func testNewWordGradesGrowFromTenMinutesToFourDays() {
        let days = ReviewGrade.allCases.map { ReviewSchedule.next($0, interval: 0, ease: 2.5, reps: 0).interval }
        XCTAssertEqual(days[0], 10.0 / 1440.0, accuracy: 0.000_001)
        XCTAssertEqual(days[1], 0.25, accuracy: 0.000_001)
        XCTAssertEqual(days[2], 1)
        XCTAssertEqual(days[3], 4)
        XCTAssertEqual(ReviewGrade.allCases.map { ReviewSchedule.label(days: ReviewSchedule.next($0, interval: 0,
                                                                                                    ease: 2.5, reps: 0).interval) },
                       ["10 min", "6 tim", "1 dag", "4 dagar"])
    }

    func testHardOnANewWordKeepsItNew() {
        let next = ReviewSchedule.next(.hard, interval: 0, ease: 2.5, reps: 0)
        XCTAssertEqual(next.reps, 0)
        XCTAssertFalse(next.lapse)
        XCTAssertEqual(next.ease, 2.35, accuracy: 0.000_1)
    }

    /// Igen, Svårt, Bra och Lätt ger alltid allt längre tid, i alla lägen (samma rutnät som review.test.mjs).
    func testGradesAreAlwaysInOrder() {
        for reps in [0, 1, 2, 5] {
            for interval in [10.0 / 1440.0, 0.25, 1, 3, 4, 10, 40] {
                for ease in [1.3, 1.7, 2.5, 3.0] {
                    let days = ReviewGrade.allCases.map {
                        ReviewSchedule.next($0, interval: interval, ease: ease, reps: reps).interval
                    }
                    for i in 1..<days.count {
                        XCTAssertGreaterThan(days[i], days[i - 1], "reps \(reps), \(interval) dagar, ease \(ease): \(days)")
                    }
                }
            }
        }
    }

    func testGoodAfterEasyIsLongerThanHard() {
        // Lätt på ett nytt ord ger 4 dagar. Nästa gång var Bra förut 3 dagar och Svårt 4,8.
        let hard = ReviewSchedule.next(.hard, interval: 4, ease: 2.65, reps: 1).interval
        let good = ReviewSchedule.next(.good, interval: 4, ease: 2.65, reps: 1).interval
        XCTAssertEqual(hard, 4.8, accuracy: 0.000_1)
        XCTAssertEqual(good, 10.6, accuracy: 0.000_1)
    }

    func testLabelsUnderADay() {
        XCTAssertEqual(ReviewSchedule.label(days: 10.0 / 1440.0), "10 min")
        XCTAssertEqual(ReviewSchedule.label(days: 59.0 / 1440.0), "59 min")
        XCTAssertEqual(ReviewSchedule.label(days: 1.0 / 24.0), "1 tim")
        XCTAssertEqual(ReviewSchedule.label(days: 0.25), "6 tim")
        XCTAssertEqual(ReviewSchedule.label(days: 1.2), "1 dag")
    }

    // MARK: Småorden

    func testStopWords() {
        for word in ["att", "det", "och", "en", "ett", "i", "på", "som", "är", "vara", "Det", "ÄR", "att,", "Dem"] {
            XCTAssertTrue(ReviewStopWords.contains(word: word, language: .swedish), word)
        }
        for word in ["the", "a", "of", "to", "The", "was"] {
            XCTAssertTrue(ReviewStopWords.contains(word: word, language: .english), word)
        }
        // Vanliga innehållsord är inte med, och språket spelar roll.
        for word in ["kunskap", "mitt", "min", "vacker", "vår", "här", "för", "men", "vad", "väl"] {
            XCTAssertFalse(ReviewStopWords.contains(word: word, language: .swedish), word)
        }
        XCTAssertFalse(ReviewStopWords.contains(word: "den", language: .english))
        XCTAssertFalse(ReviewStopWords.contains(word: "difficulties", language: .english))
        XCTAssertFalse(ReviewStopWords.contains(word: "might", language: .english))
        XCTAssertFalse(ReviewStopWords.contains(word: "being", language: .english))
    }

    /// Granskning 5, M1: bara ordet som det stod i texten jämförs. Innehållsord vars grundform är ett småord
    /// (jaget, våren, hären, fören, varor, varade) och innehållsord som förut stod i listan (väl, might) sparas och
    /// kommer med i kön. Att, och och det sparas inte.
    func testContentWordsWithStopWordLemmaAreSaved() {
        let words = UserWords(fileURL: url)
        let content: [(String, String, WordLanguage)] = [
            ("jaget", "jag", .swedish), ("våren", "vår", .swedish), ("hären", "här", .swedish),
            ("fören", "för", .swedish), ("väl", "väl", .swedish), ("varor", "vara", .swedish),
            ("might", "might", .english),
        ]
        for (word, lemma, language) in content {
            words.save(word: word, lemma: lemma, language: language, sentence: "En mening med \(word).",
                       book: "Kursboken", pageIndex: 1, bookID: "bok-1")
            XCTAssertTrue(words.isSaved(lemma: lemma, language: language), word)
        }
        // Varade har samma grundform som varor och räknas upp på samma rad.
        words.save(word: "varade", lemma: "vara", language: .swedish, sentence: "Det varade länge.",
                   book: "Kursboken", pageIndex: 2, bookID: "bok-1")
        XCTAssertEqual(words.savedWords().first { $0.lemma == "vara" }?.word, "varade")
        XCTAssertEqual(words.savedWords().first { $0.lemma == "vara" }?.lookups, 2)
        for (word, lemma) in [("att", "att"), ("och", "och"), ("det", "det"), ("Det", "den")] {
            words.save(word: word, lemma: lemma, language: .swedish, sentence: "Det är svårt att veta.",
                       book: "Kursboken", pageIndex: 1, bookID: "bok-1")
            XCTAssertFalse(words.isSaved(lemma: lemma, language: .swedish), word)
        }
        XCTAssertEqual(words.savedWords().count, content.count)
        let queue = Set(words.reviewQueue(hasAnswer: { _ in true }).map(\.word.lemma))
        XCTAssertEqual(queue, Set(content.map { $0.1 }))
    }

    func testStopWordsAreNeverSaved() {
        let words = UserWords(fileURL: url)
        words.save(word: "att", lemma: "att", language: .swedish, sentence: "Det är svårt att veta.", book: "Kursboken",
                   pageIndex: 1, bookID: "bok-1")
        words.save(word: "The", lemma: "the", language: .english, sentence: "The book.", book: "Kursboken",
                   pageIndex: 1, bookID: "bok-1")
        words.save(word: "kunskap", lemma: "kunskap", language: .swedish, sentence: "Kunskap.", book: "Kursboken",
                   pageIndex: 1, bookID: "bok-1")
        XCTAssertEqual(words.savedWords().map(\.lemma), ["kunskap"])
        XCTAssertFalse(words.isSaved(lemma: "att", language: .swedish))
    }

    // MARK: Kön

    /// Ett småord som sparades före U6 och ett ord utan svar finns kvar bland de sparade orden men kommer inte
    /// med i kön. Filtret på böcker tar bara ord med bokens id.
    func testQueueSkipsStopWordsWordsWithoutAnswerAndOtherBooks() {
        let words = UserWords(fileURL: url)
        // Från före U6 (eller från en annan enhet): småordet "att" finns redan.
        words.applySynced(SyncWord(lemma: "att", language: "sv", word: "att", sentence: "Svårt att veta.",
                                   book: "Kursboken", created: 1, updated: 1))
        words.save(word: "kunskap", lemma: "kunskap", language: .swedish, sentence: "Kunskap.", book: "Kursboken",
                   pageIndex: 1, bookID: "bok-1")
        words.save(word: "retorik", lemma: "retorik", language: .swedish, sentence: "Retorik.", book: "Andra boken",
                   pageIndex: 2, bookID: "bok-2")
        words.save(word: "xqzv", lemma: "xqzv", language: .swedish, sentence: "Xqzv.", book: "Kursboken",
                   pageIndex: 3, bookID: "bok-1")
        words.save(word: "gammalt", lemma: "gammal", language: .swedish, sentence: "Gammalt.", book: "Kursboken",
                   pageIndex: 4)
        XCTAssertEqual(words.savedWords().count, 5)
        let hasAnswer: (SavedWord) -> Bool = { $0.lemma != "xqzv" }

        let all = Set(words.reviewQueue(hasAnswer: hasAnswer).map(\.word.lemma))
        XCTAssertEqual(all, ["kunskap", "retorik", "gammal"])
        let first = Set(words.reviewQueue(books: ["bok-1"], hasAnswer: hasAnswer).map(\.word.lemma))
        XCTAssertEqual(first, ["kunskap"])
        let both = Set(words.reviewQueue(books: ["bok-1", "bok-2"], hasAnswer: hasAnswer).map(\.word.lemma))
        XCTAssertEqual(both, ["kunskap", "retorik"])
        XCTAssertTrue(words.reviewQueue(books: [], hasAnswer: hasAnswer).isEmpty)
        // Bokens id följer med orden.
        XCTAssertEqual(words.savedWords().first { $0.lemma == "retorik" }?.bookID, "bok-2")
    }

    // MARK: Filtret

    func testFilterStorage() {
        for filter in [ReviewFilter.all, .book("bok-1"), .course("kurs-1")] {
            XCTAssertEqual(ReviewFilter(storage: filter.storage), filter)
        }
        XCTAssertEqual(ReviewFilter(storage: ""), .all)
        XCTAssertEqual(ReviewFilter(storage: "bok:"), .all)
        XCTAssertEqual(ReviewFilter(storage: "något annat"), .all)
    }

    func testCourseFilterTakesFolderAndOwnBooks() {
        let courses = [Course(id: "k1", name: "RETA30", color: "", folder: "RETA30", added: 0),
                       Course(id: "k2", name: "Högskoleprovet", color: "", folder: "", added: 0),
                       Course(id: "k3", name: "Borttagen", color: "", folder: "", added: 0, deleted: true)]
        let records = [(id: "a", path: "RETA30/Retorik.pdf"), (id: "b", path: "Ordlista.pdf"),
                       (id: "c", path: "Annat/Bok.epub")]
        let explicit: [String: Set<String>] = ["b": ["k2", "k1"], "c": ["k3"]]
        XCTAssertNil(ReviewLogic.books(for: .all, records: records, courses: courses, explicit: explicit))
        XCTAssertEqual(ReviewLogic.books(for: .book("c"), records: records, courses: courses, explicit: explicit), ["c"])
        XCTAssertEqual(ReviewLogic.books(for: .course("k1"), records: records, courses: courses, explicit: explicit),
                       ["a", "b"])
        XCTAssertEqual(ReviewLogic.books(for: .course("k2"), records: records, courses: courses, explicit: explicit), ["b"])
        XCTAssertEqual(ReviewLogic.books(for: .course("k3"), records: records, courses: courses, explicit: explicit), [])
    }

    func testTextsShowNoTime() {
        XCTAssertEqual(ReviewLogic.remainingText(12), "12 kvar")
        XCTAssertEqual(ReviewLogic.cardText(14), "14 ord att repetera")
        XCTAssertEqual(ReviewLogic.cardText(1), "1 ord att repetera")
        XCTAssertEqual(ReviewLogic.cardText(0), "Inga ord väntar just nu")
        for text in [ReviewLogic.remainingText(3), ReviewLogic.cardText(3)] {
            XCTAssertFalse(text.contains("min"), text)
            XCTAssertFalse(text.contains("cirka"), text)
        }
    }
}
