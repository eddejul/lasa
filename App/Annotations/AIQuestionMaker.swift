import Foundation
import PDFKit

/// K6b: Gör frågor med AI, under Frågor i marginalen. Påslaget från början.
enum AIQuestionsSetting {

    static let didChange = Notification.Name("AIQuestionsSettingDidChange")
    private static let key = "reader.aiQuestions"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }
}

/// Var boken får sin text till AI-frågorna.
enum AIBookText: Equatable {
    /// Kapitlen i en EPUB eller textfil, som filer på disk (samma som markeringarna räknar i).
    case chapters([URL])
    /// En PDF, och textfilen från OCR:en (P4) när den finns.
    case pdf(URL, textFile: URL?)
}

/// Ett kapitel för AI-frågorna: nyckeln (`k3` eller `p11-20`), rubriken och avsnitten (kapitlet eller sidorna).
struct AIChapter: Equatable {
    let key: String
    let title: String
    let sections: Range<Int>
}

/// Boken som frågorna görs till.
struct AIBookContext: Equatable {
    let book: String
    let title: String
    let author: String
    let chapters: [AIChapter]
    let text: AIBookText

    var isPDF: Bool {
        if case .pdf = text { return true }
        return false
    }

    func chapterIndex(containing section: Int) -> Int? {
        chapters.lastIndex { $0.sections.lowerBound <= section }
    }
}

/// Kapitlen och deras text (K6b). Texten tas fram utanför huvudtråden.
enum AIChapterText {

    /// EPUB och text: ett kapitel i läsordningen.
    static func chapters(titles: [String]) -> [AIChapter] {
        titles.enumerated().map { (index, title) -> AIChapter in
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return AIChapter(key: AIQuestions.chapterKey(chapter: index),
                             title: trimmed.isEmpty ? "Kapitel \(index + 1)" : trimmed, sections: index..<(index + 1))
        }
    }

    /// PDF: ett kapitel i innehållet (sidorna fram till nästa kapitel). Utan innehåll tio sidor i taget.
    static func chapters(starts: [(index: Int, title: String)], pageCount: Int) -> [AIChapter] {
        guard pageCount > 0 else { return [] }
        var unique: [(index: Int, title: String)] = []
        for start in starts.sorted(by: { $0.index < $1.index }) where start.index >= 0 && start.index < pageCount {
            if unique.last?.index != start.index {
                unique.append(start)
            }
        }
        var bounds: [(start: Int, title: String)] = []
        if unique.isEmpty {
            var first = 0
            while first < pageCount {
                let last = min(first + 10, pageCount)
                bounds.append((start: first, title: "Sidorna \(first + 1) till \(last)"))
                first = last
            }
        } else {
            if unique[0].index > 0 {
                bounds.append((start: 0, title: "Början"))
            }
            for item in unique {
                bounds.append((start: item.index, title: item.title))
            }
        }
        return bounds.enumerated().map { (index, bound) -> AIChapter in
            let end = index + 1 < bounds.count ? bounds[index + 1].start : pageCount
            return AIChapter(key: AIQuestions.chapterKey(firstPage: bound.start + 1, lastPage: end),
                             title: bound.title, sections: bound.start..<max(end, bound.start + 1))
        }
    }

    /// Kapitlets text och var varje avsnitt börjar i den (UTF-16).
    struct Text {
        let text: String
        let offsets: [(section: Int, offset: Int)]

        /// Avsnittet där tecknet `position` står.
        func section(at position: Int) -> (section: Int, offset: Int) {
            offsets.last { $0.offset <= position } ?? offsets.first ?? (0, 0)
        }

        /// Texten i intervallet, inom avsnittet där intervallet slutar (eller börjar, med `atStart`).
        func slice(_ range: NSRange, atStart: Bool = false) -> (section: Int, text: String) {
            let all = text as NSString
            let point = atStart ? range.location : max(NSMaxRange(range) - 1, range.location)
            let here = section(at: point)
            let next = offsets.first { $0.offset > here.offset }?.offset ?? all.length
            let start = max(range.location, here.offset)
            let end = min(NSMaxRange(range), next)
            guard end > start, end <= all.length else { return (here.section, "") }
            return (here.section, all.substring(with: NSRange(location: start, length: end - start)))
        }
    }

    private static let blockEnd = try? NSRegularExpression(
        pattern: "</(p|div|h[1-6]|li|blockquote|section|article|header|footer|aside|figure|figcaption|tr|dd|dt|pre|table|ul|ol)\\s*>|<br\\s*/?\\s*>|<hr[^>]*>",
        options: [.caseInsensitive])

    /// EPUB och text: kapitlets text utan taggar, med stycken åtskilda av en tom rad.
    static func chapterText(html: String) -> String {
        let marked = blockEnd?.stringByReplacingMatches(in: html, range: NSRange(location: 0, length: (html as NSString).length),
                                                        withTemplate: "\u{2029}$0") ?? html
        let plain = BookSearch.plainText(html: marked)
        let paragraphs = plain.components(separatedBy: "\u{2029}").map { paragraph in
            paragraph.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        }
        return paragraphs.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Texten i ett kapitel. PDF: sidornas text i ordning med en tom rad emellan, och textfilens sida (P4)
    /// där PDF:en saknar text. `document` och `ocrPages` öppnas av den som anropar, en gång per jobb.
    static func text(of chapter: AIChapter, source: AIBookText, document: PDFDocument?, ocrPages: [String]?) -> Text {
        switch source {
        case .chapters(let urls):
            let index = chapter.sections.lowerBound
            guard index >= 0, index < urls.count, let data = try? Data(contentsOf: urls[index]) else {
                return Text(text: "", offsets: [(index, 0)])
            }
            let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
            return Text(text: chapterText(html: html), offsets: [(index, 0)])
        case .pdf:
            var parts: [String] = []
            var offsets: [(section: Int, offset: Int)] = []
            var length = 0
            for page in chapter.sections {
                var string = document?.page(at: page)?.string ?? ""
                if string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let ocr = ocrPages, page < ocr.count {
                    string = ocr[page]
                }
                if !parts.isEmpty {
                    length += 2
                }
                offsets.append((page, length))
                parts.append(string)
                length += (string as NSString).length
            }
            return Text(text: parts.joined(separator: "\n\n"), offsets: offsets)
        }
    }

    /// Textfilens sidor (P4), bara när de är lika många som PDF:ens.
    static func ocrPages(_ url: URL?, pageCount: Int) -> [String]? {
        guard let url = url, let text = try? TextBookConverter.readText(url),
              let pages = OCRPagedText.parse(text), pages.count == pageCount else { return nil }
        return pages.map(\.text)
    }
}

/// Kön som gör AI-frågorna (K6b): ett anrop till Gemini åt gången i hela appen. När ett kapitel visas och
/// saknar frågor görs det kapitlets frågor, och sedan nästa kapitels. Gör frågor till hela boken lägger resten
/// av kapitlen i kön i läsordning, med fyra sekunders paus mellan anropen. Bara från huvudtråden.
@MainActor
final class AIQuestionMaker {

    static let shared = AIQuestionMaker()

    /// Skickas när kön, förloppet eller ett besked har ändrats. `object` är bokens id eller nil.
    static let didChange = Notification.Name("AIQuestionMakerDidChange")

    /// Det som hindrar frågorna, till fliken Frågor.
    enum Problem: Equatable {
        case setup(String)
        case quotaToday
        case quotaMinute
        case offline
        case failed(String)

        var message: String {
            switch self {
            case .setup(let message): return message
            case .quotaToday:
                return "Dagens gratiskvot hos Google är slut. Den fylls på klockan \(AIClient.quotaResetText) svensk tid, "
                    + "då fortsätter frågorna."
            case .quotaMinute: return "Gratiskvoten för den här minuten är slut. Frågorna fortsätter när du bläddrar vidare."
            case .offline: return "Ingen kontakt med Google. Frågorna görs när iPaden är ansluten till internet."
            case .failed(let message): return message
            }
        }

        var needsSetup: Bool {
            if case .setup = self { return true }
            return false
        }
    }

    struct Job: Equatable {
        let context: AIBookContext
        let chapter: Int
        let replace: Bool
    }

    /// Paus mellan anropen (självtestet kortar den).
    var pauseBetweenCalls: TimeInterval = 4
    private(set) var problem: Problem?
    private(set) var current: Job?
    private var queue: [Job] = []
    /// Böcker där en PDF saknade text att göra frågor av.
    private(set) var booksWithoutText: Set<String> = []
    /// Gör frågor till hela boken: hur många kapitel som skulle göras och hur många som är klara.
    private var wholeBook: [String: (total: Int, done: Int)] = [:]
    private var lastCall: Date?
    private var quotaUntil: Date?

    private init() {}

    /// Allt som krävs utom frågefilen (som läsaren kontrollerar): båda inställningarna och en nyckel.
    var isEnabled: Bool {
        QuestionsSetting.isEnabled && AIQuestionsSetting.isEnabled && AIClient.hasKey
    }

    func isWorking(book: String) -> Bool {
        current?.context.book == book || queue.contains { $0.context.book == book }
    }

    func isWorking(book: String, chapter: Int) -> Bool {
        (current?.context.book == book && current?.chapter == chapter)
            || queue.contains { $0.context.book == book && $0.chapter == chapter }
    }

    /// Förloppet för Gör frågor till hela boken, eller nil.
    func progress(book: String) -> (total: Int, done: Int)? {
        wholeBook[book]
    }

    /// Ett kapitel visas: gör dess frågor och sedan nästa kapitels, om de saknas.
    func request(_ context: AIBookContext, chapter: Int) {
        guard isEnabled, chapter >= 0, chapter < context.chapters.count else { return }
        clearProblemIfRetryable()
        guard problem == nil else { return }
        let done = AIQuestionStore.shared.chapterKeys(book: context.book)
        for index in [chapter, chapter + 1] where index < context.chapters.count {
            if !done.contains(context.chapters[index].key), !isWorking(book: context.book, chapter: index) {
                queue.append(Job(context: context, chapter: index, replace: false))
            }
        }
        pump()
    }

    /// Gör frågor till hela boken: resten av kapitlen i läsordning.
    func makeWholeBook(_ context: AIBookContext) {
        guard isEnabled else { return }
        clearProblemIfRetryable(force: true)
        let done = AIQuestionStore.shared.chapterKeys(book: context.book)
        var added = 0
        for (index, chapter) in context.chapters.enumerated() where !done.contains(chapter.key) {
            if !isWorking(book: context.book, chapter: index) {
                queue.append(Job(context: context, chapter: index, replace: false))
            }
            added += 1
        }
        wholeBook[context.book] = (added, 0)
        AppLog.shared.write("AI-frågor: hela boken, \(added) kapitel i kön")
        post(context.book)
        pump()
    }

    /// Gör nya frågor till kapitlet: byter ut kapitlets frågor.
    func remake(_ context: AIBookContext, chapter: Int) {
        guard isEnabled, chapter >= 0, chapter < context.chapters.count else { return }
        clearProblemIfRetryable(force: true)
        queue.removeAll { $0.context.book == context.book && $0.chapter == chapter }
        queue.insert(Job(context: context, chapter: chapter, replace: true), at: 0)
        post(context.book)
        pump()
    }

    /// Avbryt: kön för boken töms (anropet som pågår får göras klart).
    func cancel(book: String) {
        queue.removeAll { $0.context.book == book }
        wholeBook[book] = nil
        post(book)
    }

    private func clearProblemIfRetryable(force: Bool = false) {
        guard let problem = problem else { return }
        switch problem {
        case .quotaToday:
            if let until = quotaUntil, Date() >= until {
                self.problem = nil
            }
        case .setup:
            if AIClient.hasKey, case .failing = AIClient.keyStatus {
                return
            }
            if AIClient.hasKey {
                self.problem = nil
            }
        case .offline, .quotaMinute, .failed:
            self.problem = nil
        }
        if force, self.problem == nil {
            post(nil)
        }
    }

    private func post(_ book: String?) {
        NotificationCenter.default.post(name: Self.didChange, object: book)
    }

    private func stop(_ problem: Problem, book: String) {
        self.problem = problem
        if problem == .quotaToday {
            quotaUntil = Self.nextQuotaReset()
        }
        queue.removeAll()
        wholeBook.removeAll()
        AppLog.shared.write("AI-frågor: kön stoppad, \(problem.message)")
        post(book)
    }

    /// Midnatt i Kalifornien, då Googles dagliga kvot fylls på.
    static func nextQuotaReset() -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
        return calendar.nextDate(after: Date(), matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime)
            ?? Date().addingTimeInterval(3600)
    }

    private func pump() {
        guard current == nil, problem == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        let chapter = job.context.chapters[job.chapter]
        if !job.replace, AIQuestionStore.shared.chapterKeys(book: job.context.book).contains(chapter.key) {
            countDone(job.context.book)
            pump()
            return
        }
        current = job
        post(job.context.book)
        Task { @MainActor [weak self] in
            await self?.run(job)
            guard let self = self else { return }
            self.current = nil
            self.countDone(job.context.book)
            self.post(job.context.book)
            self.pump()
        }
    }

    private func countDone(_ book: String) {
        guard var progress = wholeBook[book] else { return }
        progress.done = min(progress.done + 1, progress.total)
        wholeBook[book] = progress
        if !queue.contains(where: { $0.context.book == book }) {
            wholeBook[book] = nil
        }
    }

    // MARK: Ett kapitel

    private struct Prepared {
        let text: AIChapterText.Text
        let isLast: Bool
    }

    /// Kapitlets text och om det är bokens sista kapitel med text, utanför huvudtråden.
    nonisolated private static func prepare(_ context: AIBookContext, chapter index: Int) -> Prepared {
        var document: PDFDocument?
        var ocr: [String]?
        if case .pdf(let url, let textFile) = context.text {
            document = PDFDocument(url: url)
            ocr = AIChapterText.ocrPages(textFile, pageCount: document?.pageCount ?? 0)
        }
        let text = AIChapterText.text(of: context.chapters[index], source: context.text, document: document, ocrPages: ocr)
        // Bokens sista kapitel med text: inget senare kapitel har tillräckligt med text.
        var isLast = true
        var next = index + 1
        while next < context.chapters.count {
            let later = AIChapterText.text(of: context.chapters[next], source: context.text, document: document,
                                           ocrPages: ocr)
            if (later.text as NSString).length >= AIQuestions.minimumLength {
                isLast = false
                break
            }
            next += 1
        }
        return Prepared(text: text, isLast: isLast)
    }

    private func run(_ job: Job) async {
        let context = job.context
        let chapter = context.chapters[job.chapter]
        let started = Date()
        let prepared = await Task.detached(priority: .utility) {
            AIQuestionMaker.prepare(context, chapter: job.chapter)
        }.value
        let text = prepared.text.text as NSString
        guard text.length >= AIQuestions.minimumLength else {
            if context.isPDF, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                booksWithoutText.insert(context.book)
            }
            AppLog.shared.write("AI-frågor \(chapter.key): \(text.length) tecken, för kort, sparas utan frågor")
            AIQuestionStore.shared.replace(book: context.book, chapter: chapter.key, with: [
                AIQuestionRecord(book: context.book, chapter: chapter.key, part: 1, chapterTitle: chapter.title,
                                 model: GeminiClient.model, created: Date().timeIntervalSince1970, summary: "",
                                 concepts: [], questions: []),
            ])
            return
        }
        booksWithoutText.remove(context.book)
        let parts = AIQuestions.parts(of: text)
        var records: [AIQuestionRecord] = []
        let previous = previousChapters(book: context.book, before: AIQuestions.order(ofChapterKey: chapter.key))
        let others = otherBooks(excluding: context.book)
        for (index, range) in parts.enumerated() {
            let partText = text.substring(with: range)
            let count = AIQuestions.count(characters: range.length, part: index + 1, parts: parts.count,
                                          lastChapter: prepared.isLast)
            let prompt = AIQuestions.prompt(
                book: AIQuestions.PromptBook(title: context.title, author: context.author),
                chapter: AIQuestions.PromptChapter(title: chapter.title, part: index + 1, parts: parts.count,
                                                   text: partText, isLast: prepared.isLast),
                previous: previous, others: others, count: count)
            guard let answer = await ask(prompt, replace: job.replace, book: context.book) else {
                return
            }
            let titles = others.map(\.title)
            let cap = AIQuestions.cap(for: count)
            let partNumber = index + 1
            let result = await Task.detached(priority: .utility) {
                AIQuestions.check(answer: answer, text: partText, book: context.book, chapter: chapter.key,
                                  part: partNumber, otherTitles: titles, cap: cap)
            }.value
            AppLog.shared.write(result.logLine(chapter: chapter.key) + (parts.count > 1 ? " i del \(partNumber)" : ""))
            let stored = result.kept.map { kept -> AIStoredQuestion in
                var question = AIStoredQuestion(id: kept.id, typ: kept.type, nar: kept.timing, fraga: kept.question,
                                                svar: kept.answer, oppen: kept.isOpen, plats: kept.anchor,
                                                kalla: kept.source, bok: kept.book, position: nil)
                if let anchor = kept.anchorRange {
                    let whole = NSRange(location: anchor.location + range.location, length: anchor.length)
                    question.position = NSMaxRange(whole)
                    let slice = prepared.text.slice(whole)
                    question.avsnitt = slice.section
                    question.ankare = slice.text
                }
                if let source = kept.sourceRange {
                    let whole = NSRange(location: source.location + range.location, length: source.length)
                    let slice = prepared.text.slice(whole, atStart: true)
                    question.kallaAvsnitt = slice.section
                    question.kallaAnkare = slice.text
                }
                return question
            }
            records.append(AIQuestionRecord(book: context.book, chapter: chapter.key, part: partNumber,
                                            chapterTitle: chapter.title, model: GeminiClient.model,
                                            created: Date().timeIntervalSince1970,
                                            summary: AIQuestions.summary(of: answer),
                                            concepts: AIQuestions.concepts(of: answer), questions: stored))
        }
        if AIQuestionStore.shared.replace(book: context.book, chapter: chapter.key, with: records) {
            let total = records.map(\.questions.count).reduce(0, +)
            AppLog.shared.write("AI-frågor \(chapter.key): \(total) frågor sparade i \(parts.count) del(ar) på "
                                + "\(Int(Date().timeIntervalSince(started))) s")
        }
    }

    /// Ett anrop med kravets regler: minutens kvot väntar och försöker en gång till, ett svar som inte går att
    /// läsa försöks en gång till. Nil när kapitlet inte blev av (kön är då stoppad eller kapitlet hoppas över).
    private func ask(_ prompt: String, replace: Bool, book: String) async -> [String: Any]? {
        var waitedForMinute = false
        var retriedUnreadable = false
        var useCache = !replace
        while true {
            if let last = lastCall {
                let wait = pauseBetweenCalls - Date().timeIntervalSince(last)
                if wait > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                }
            }
            lastCall = Date()
            let result = await generate(prompt, useCache: useCache)
            switch result {
            case .success(let json) where AIQuestions.isReadable(json):
                return json
            case .success, .failure(.invalidResponse):
                guard !retriedUnreadable else {
                    AppLog.shared.write("AI-frågor: svaret gick inte att läsa två gånger, kapitlet görs nästa gång")
                    return nil
                }
                retriedUnreadable = true
                useCache = false
            case .failure(.quotaPerMinute(let seconds)):
                guard !waitedForMinute else {
                    stop(.quotaMinute, book: book)
                    return nil
                }
                waitedForMinute = true
                let wait = Double(min(max(seconds ?? 60, 1), 60))
                AppLog.shared.write("AI-frågor: minutens kvot, väntar \(Int(wait)) s")
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            case .failure(.quotaToday):
                stop(.quotaToday, book: book)
                return nil
            case .failure(.offline), .failure(.network):
                stop(.offline, book: book)
                return nil
            case .failure(let failure) where failure.needsSetup:
                stop(.setup(failure.errorDescription ?? "Nyckeln fungerar inte."), book: book)
                return nil
            case .failure(let failure):
                AppLog.shared.write("AI-frågor: \(failure.errorDescription ?? "fel"), kapitlet görs nästa gång")
                return nil
            }
        }
    }

    private func generate(_ prompt: String, useCache: Bool) async -> Result<[String: Any], AIClient.Failure> {
        await withCheckedContinuation { continuation in
            AIClient.generate(kind: AIQuestions.questionsKind, prompt: prompt, schema: AIQuestions.questionSchema,
                              maxTokens: AIQuestions.maxOutputTokens, timeout: AIQuestions.timeout,
                              useCache: useCache) { result in
                continuation.resume(returning: result.map(\.json))
            }
        }
    }

    // MARK: Tidigare kapitel och andra böcker

    /// Sammanfattningarna för bokens tidigare kapitel, i läsordning, högst de tolv senaste.
    func previousChapters(book: String, before order: Int) -> [AIQuestions.PreviousChapter] {
        let rows = AIQuestionStore.shared.summaries(book: book).filter { $0.order < order && !$0.summary.isEmpty }
        return rows.suffix(12).map { AIQuestions.PreviousChapter(title: $0.title, summary: $0.summary) }
    }

    /// Högst fem andra böcker med AI-frågor, de senast lästa först, med en kort sammanfattning och begrepp.
    func otherBooks(excluding book: String) -> [AIQuestions.OtherBook] {
        let books = AIQuestionStore.shared.books().filter { $0.book != book }
        let sorted = books.sorted { left, right in
            let a = LibraryStore.shared.positionDate(forID: left.book)?.timeIntervalSince1970 ?? left.latest
            let b = LibraryStore.shared.positionDate(forID: right.book)?.timeIntervalSince1970 ?? right.latest
            return a > b
        }
        var result: [AIQuestions.OtherBook] = []
        for entry in sorted where result.count < 5 {
            guard let record = BookRegistry.shared.record(id: entry.book) else { continue }
            let title = BookInfoStore.shared.info(book: entry.book).title.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = title.isEmpty ? record.displayTitle : title
            let rows = AIQuestionStore.shared.summaries(book: entry.book).filter { !$0.summary.isEmpty }
            let latest = rows.sorted { $0.created > $1.created }.prefix(2).sorted { ($0.order, $0.part) < ($1.order, $1.part) }
            var summary = latest.map(\.summary).joined(separator: " ")
            if summary.count > 400 {
                summary = String(summary.prefix(400))
            }
            var concepts: [String] = []
            for row in rows.sorted(by: { $0.created > $1.created }) {
                for concept in row.concepts where !concepts.contains(concept) && concepts.count < 8 {
                    concepts.append(concept)
                }
            }
            guard !summary.isEmpty else { continue }
            result.append(AIQuestions.OtherBook(title: name, summary: summary, concepts: concepts))
        }
        return result
    }
}

extension AIQuestionStore {

    struct Summary {
        let chapter: String
        let part: Int
        let title: String
        let created: Double
        let summary: String
        let concepts: [String]

        var order: Int {
            AIQuestions.order(ofChapterKey: chapter)
        }
    }

    /// Sammanfattningar och begrepp per kapitel och del, i läsordning, utan frågorna.
    func summaries(book: String) -> [Summary] {
        var result: [Summary] = []
        AnnotationStore.shared.readBooks { db in
            try db.query("SELECT chapter, part, chapter_title, created, summary, concepts FROM ai_questions WHERE book = ?",
                         [book]) { row in
                let concepts = (try? JSONDecoder().decode([String].self, from: Data(row.string(5).utf8))) ?? []
                result.append(Summary(chapter: row.string(0), part: row.int(1), title: row.string(2),
                                      created: row.double(3), summary: row.string(4), concepts: concepts))
            }
        }
        return result.sorted { ($0.order, $0.part) < ($1.order, $1.part) }
    }
}
