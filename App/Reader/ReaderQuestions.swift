import UIKit
import UniformTypeIdentifiers

/// En prick i marginalen (K6), som bladen ritar. `anchorY` är höjden i bladets koordinater.
struct QuestionDotPlacement {
    let id: String
    let number: Int
    let status: QuestionStatus?
    let anchorY: CGFloat
}

/// Var prickarna står (K6). Ren logik (G13): i den yttre marginalen när den rymmer pricken, annars precis
/// innanför textens eller sidans kant, och utspridda så att de inte ligger på varandra.
enum QuestionDotLayout {

    static let size: CGFloat = 22
    static let smallSize: CGFloat = 18

    /// Prickens mitt i sidled. `contentMinX` och `contentMaxX` är sidans (PDF) eller textens (EPUB) kanter i
    /// bladet, `width` bladets bredd. Den yttre marginalen är till vänster på vänstersidan i ett uppslag,
    /// annars till höger.
    static func centerX(contentMinX: CGFloat, contentMaxX: CGFloat, width: CGFloat, outerIsLeft: Bool) -> (x: CGFloat, size: CGFloat) {
        let margin = outerIsLeft ? contentMinX : width - contentMaxX
        if margin >= size + 8 {
            let inset = min(margin / 2, size)
            return (outerIsLeft ? contentMinX - inset : contentMaxX + inset, size)
        }
        // Smal marginal: en mindre prick så långt ut som det går, delvis över sidans egen kant.
        let half = smallSize / 2 + 2
        return (outerIsLeft ? half : width - half, smallSize)
    }

    /// Höjderna, i samma ordning, utspridda med minst `gap` mellan sig och inom `top` och `bottom`.
    static func spread(_ ys: [CGFloat], gap: CGFloat, top: CGFloat, bottom: CGFloat) -> [CGFloat] {
        guard !ys.isEmpty else { return [] }
        let order = ys.indices.sorted { ys[$0] < ys[$1] }
        var placed = [CGFloat](repeating: 0, count: ys.count)
        var previous = -CGFloat.greatestFiniteMagnitude
        for index in order {
            let y = max(min(max(ys[index], top), bottom), previous + gap)
            placed[index] = y
            previous = y
        }
        // Gick de sista förbi nederkanten: skjut upp dem igen.
        var next = CGFloat.greatestFiniteMagnitude
        for index in order.reversed() {
            let y = min(placed[index], bottom, next - gap)
            placed[index] = y
            next = y
        }
        return placed
    }
}

/// Pricken: en liten numrerad cirkel i temats färger. Obesvarad har en ring, besvarad fylls i svarets färg.
final class QuestionDotView: UIView {

    let id: String
    private let label = UILabel()

    init(placement: QuestionDotPlacement, size: CGFloat) {
        id = placement.id
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
        isUserInteractionEnabled = false
        let palette = Theme.current
        layer.cornerRadius = size / 2
        label.text = String(placement.number)
        label.font = .systemFont(ofSize: size * 0.5, weight: .semibold)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        label.frame = bounds.insetBy(dx: 2, dy: 2)
        addSubview(label)
        switch placement.status {
        case nil:
            backgroundColor = palette.page
            layer.borderWidth = 1.5
            layer.borderColor = palette.accent.cgColor
            label.textColor = palette.accent
        case .known?:
            backgroundColor = palette.success
            label.textColor = palette.page
        case .unsure?:
            backgroundColor = palette.warning
            label.textColor = palette.page
        case .unknown?:
            backgroundColor = palette.ribbon
            label.textColor = palette.page
        }
        isAccessibilityElement = true
        accessibilityLabel = "Fråga \(placement.number)" + (placement.status.map { ", \($0.title)" } ?? "")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    /// Lägger prickarna i `host` och svarar med deras rutor per fråga (till tryck och rutans pil).
    static func layout(_ placements: [QuestionDotPlacement], in host: UIView, contentMinX: CGFloat, contentMaxX: CGFloat,
                       top: CGFloat, bottom: CGFloat, outerIsLeft: Bool) -> [String: CGRect] {
        guard !placements.isEmpty else { return [:] }
        let column = QuestionDotLayout.centerX(contentMinX: contentMinX, contentMaxX: contentMaxX,
                                               width: host.bounds.width, outerIsLeft: outerIsLeft)
        let half = column.size / 2
        let ys = QuestionDotLayout.spread(placements.map(\.anchorY), gap: column.size + 4,
                                          top: top + half, bottom: max(top + half, bottom - half))
        var frames: [String: CGRect] = [:]
        for (placement, y) in zip(placements, ys) {
            let dot = QuestionDotView(placement: placement, size: column.size)
            dot.center = CGPoint(x: column.x, y: y)
            host.addSubview(dot)
            frames[placement.id] = dot.frame
        }
        return frames
    }
}

/// Bokens frågor i läsaren (K6), gemensamt för PDF- och EPUB-läsaren (G12): frågefilen, var citaten står,
/// svaren, rutan med frågan och fliken Frågor i Innehåll. Utan frågefil kommer frågorna ur AI-frågorna (K6b,
/// `AIQuestionStore`), som görs i bakgrunden när ett kapitel visas. Bara från huvudtråden.
@MainActor
final class ReaderQuestions {

    /// EPUB: citatens span i webbvyn får id `fraga:` plus frågans id, och textens kolumn ett eget id.
    static let markPrefix = "fraga:"
    static let textColumnID = "fraga-kolumn"

    let book: Book
    let bookKey: String
    private(set) var questions: [BookQuestion] = []
    private(set) var places: [String: QuestionPlace] = [:]
    private(set) var statuses: [String: QuestionStatus] = [:]
    private(set) var fileURL: URL?
    private(set) var problem: String?
    /// Sant när citaten har letats upp (eller när det inte finns någon fil).
    private(set) var isLocated = false
    /// Räknas upp när platserna har ändrats (inte när ett svar sparas), så att EPUB-läsaren vet när citaten
    /// måste läggas in i webbvyn igen.
    private(set) var placesVersion = 0
    /// Anropas när frågorna eller svaren har ändrats, så att läsaren ritar om prickarna.
    var onChange: (() -> Void)?
    /// K6b: boken som AI-frågorna görs till (kapitlen och var texten finns). Sätts av läsaren.
    var aiContext: AIBookContext?
    /// Hoppar till ett ställe genom läsarens `hop(to:)` (fliken Frågor och Visa i boken). Sätts av läsaren.
    var jump: ((QuestionPlace) -> Void)?
    /// Läsaren, där rutorna och raden Läs för att ta reda på visas.
    weak var presenter: UIViewController?
    /// K6b: AI-frågornas rader, i läsordning.
    private(set) var aiRecords: [AIQuestionRecord] = []
    private var task: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var search: BookSearch?
    private var loadArguments: (titles: [String], count: Int)?
    private var requestedChapter: Int?
    private var requestToken = 0
    /// Kapitlet vars första sida syns just nu, och kapitlen där raden Läs för att ta reda på har visats.
    private var chapterAtStart: Int?
    private var shownBeforeReading: Set<String> = []

    /// Självtestet: frågorna i den senast öppnade boken och det senaste hoppet till källan.
    static weak var current: ReaderQuestions?
    private(set) var lastJump: QuestionPlace?

    init(book: Book, bookKey: String) {
        self.book = book
        self.bookKey = bookKey
        Self.current = self
        statuses = QuestionStore.shared.statuses(book: bookKey)
        observers.append(NotificationCenter.default.addObserver(forName: QuestionStore.didChange, object: nil,
                                                                queue: .main) { [weak self] note in
            let book = note.object as? String
            Task { @MainActor [weak self] in
                guard let self = self, book == self.bookKey else { return }
                self.statuses = QuestionStore.shared.statuses(book: self.bookKey)
                self.loaded()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AIQuestionStore.didChange, object: nil,
                                                                queue: .main) { [weak self] note in
            let book = note.object as? String
            Task { @MainActor [weak self] in
                guard let self = self, book == self.bookKey, self.fileURL == nil, QuestionsSetting.isEnabled,
                      let search = self.search, let arguments = self.loadArguments else { return }
                self.load(search: search, chapterTitles: arguments.titles, sectionCount: arguments.count)
            }
        })
    }

    /// Skickas när frågorna, platserna eller svaren har lästs in på nytt (fliken Frågor). `object` är frågorna.
    static let didLoad = Notification.Name("ReaderQuestionsDidLoad")

    private func loaded() {
        onChange?()
        NotificationCenter.default.post(name: Self.didLoad, object: self)
    }

    /// Prickarna syns: inställningen är på och boken har frågor.
    var showsDots: Bool {
        QuestionsSetting.isEnabled && !questions.isEmpty
    }

    /// K6b: frågorna kommer ur AI-frågorna (boken har ingen frågefil).
    var usesAI: Bool {
        fileURL == nil
    }

    /// Läser frågefilen och letar upp citaten i bakgrunden. `chapterTitles` är kapitlens rubriker (EPUB och
    /// text), tomt för PDF. Utan frågefil läses AI-frågorna (K6b).
    func load(search: BookSearch, chapterTitles: [String], sectionCount: Int) {
        task?.cancel()
        self.search = search
        loadArguments = (chapterTitles, sectionCount)
        isLocated = false
        problem = nil
        fileURL = BookQuestionFile.url(for: book)
        guard let url = fileURL else {
            loadAI(search: search)
            return
        }
        let isPDF = chapterTitles.isEmpty
        task = Task { @MainActor [weak self] in
            // Granskning 5, L2: filen läses och tolkas utanför huvudtråden, och en fil över 2 MB läses inte.
            let read = await Task.detached(priority: .userInitiated) { () -> Result<[BookQuestion], Error> in
                Result { try BookQuestionFile.read(url) }
            }.value
            let list: [BookQuestion]
            do {
                // Läsaren hålls inte kvar medan citaten letas upp: `owner` gäller bara i det här blocket.
                guard let owner = self, !Task.isCancelled else { return }
                switch read {
                case .success(let parsed):
                    owner.questions = parsed
                case .failure(let error):
                    owner.questions = []
                    owner.problem = "Frågefilen kunde inte läsas: \(error)"
                    AppLog.shared.write("Frågor (K6): \(url.lastPathComponent) kunde inte läsas: \(error)")
                }
                list = owner.questions
                guard !list.isEmpty else {
                    owner.places = [:]
                    owner.placesVersion += 1
                    owner.isLocated = true
                    owner.loaded()
                    return
                }
            }
            let hints = list.map {
                BookQuestionFile.hint(for: $0, chapterTitles: chapterTitles, sectionCount: sectionCount)
            }
            let started = CACurrentMediaTime()
            let hits = await search.locate(list.map(\.quote), hints: hints)
            guard let self = self, !Task.isCancelled else { return }
            var found: [String: QuestionPlace] = [:]
            for (index, question) in list.enumerated() {
                if index < hits.count, let hit = hits[index] {
                    found[question.id] = QuestionPlace(section: hit.section, start: hit.start, length: hit.length,
                                                       y: question.y)
                } else if isPDF, let page = hints[index] {
                    // En fotad sida utan text: pricken står på sidan, på höjden `y`.
                    found[question.id] = QuestionPlace(section: page, start: 0, length: 0, y: question.y ?? 0.08)
                }
            }
            self.places = found
            self.placesVersion += 1
            self.isLocated = true
            AppLog.shared.write("Frågor (K6): \(found.count) av \(list.count) placerade på "
                                + "\(Int((CACurrentMediaTime() - started) * 1000)) ms")
            self.loaded()
        }
    }

    /// K6b: AI-frågorna ur databasen. Frågorna i texten letas upp med sin träffade text, i avsnittet där den
    /// stod när frågan gjordes, så att prickarna hamnar där markeringarna räknar.
    private func loadAI(search: BookSearch) {
        aiRecords = AIQuestionStore.shared.records(book: bookKey)
        let list = Self.aiBookQuestions(from: aiRecords, chapters: aiContext?.chapters ?? [])
        questions = list
        let located = list.filter { $0.timing == "efter" && !$0.quote.isEmpty }
        guard !located.isEmpty else {
            places = [:]
            placesVersion += 1
            isLocated = true
            loaded()
            maybeShowBeforeReading()
            return
        }
        task = Task { @MainActor [weak self] in
            let started = CACurrentMediaTime()
            let hits = await search.locate(located.map(\.quote), hints: located.map(\.hintSection))
            guard let self = self, !Task.isCancelled else { return }
            var found: [String: QuestionPlace] = [:]
            for (index, question) in located.enumerated() {
                if index < hits.count, let hit = hits[index] {
                    found[question.id] = QuestionPlace(section: hit.section, start: hit.start, length: hit.length, y: nil)
                }
            }
            // Samma platser som förut (en annan bok eller ett annat kapitel fick frågor): webbvyerna behöver
            // inte göra om citaten.
            if found != self.places {
                self.places = found
                self.placesVersion += 1
            }
            self.isLocated = true
            AppLog.shared.write("AI-frågor: \(list.count) frågor i \(self.aiRecords.count) delar, \(found.count) av "
                                + "\(located.count) i texten placerade på \(Int((CACurrentMediaTime() - started) * 1000)) ms")
            self.loaded()
            self.maybeShowBeforeReading()
        }
    }

    /// AI-frågorna som bokens frågor, i läsordning: kapitel för kapitel före läsningen, i texten och efter
    /// kapitlet. Frågorna i texten numreras i bokens ordning, de andra får ingen prick (nummer 0).
    static func aiBookQuestions(from records: [AIQuestionRecord], chapters: [AIChapter]) -> [BookQuestion] {
        var result: [BookQuestion] = []
        var used = Set<String>()
        var number = 0
        for record in records {
            let chapter = chapters.first { $0.key == record.chapter }
            for stored in record.questions where used.insert(stored.id).inserted {
                let inText = stored.nar == "efter"
                if inText {
                    number += 1
                }
                let anchor = (stored.ankare ?? "").isEmpty ? stored.plats : (stored.ankare ?? "")
                var item = BookQuestion(id: stored.id, number: inText ? number : 0,
                                        title: AIQuestions.title(type: stored.typ, book: stored.bok),
                                        question: stored.fraga, answer: stored.svar, quote: inText ? anchor : "",
                                        page: nil, chapterNumber: nil, chapterTitle: record.chapterTitle, y: nil)
                item.kind = stored.typ
                item.timing = stored.nar
                item.source = stored.kalla
                item.isOpen = stored.oppen
                item.otherBook = stored.bok
                item.isAI = true
                item.chapterKey = record.chapter
                item.chapterName = record.chapterTitle
                item.chapterSections = chapter?.sections
                item.hintSection = stored.avsnitt ?? chapter?.sections.lowerBound
                item.sourceAnchor = stored.kallaAnkare ?? ""
                item.sourceSection = stored.kallaAvsnitt ?? chapter?.sections.lowerBound
                result.append(item)
            }
        }
        return result
    }

    func question(id: String) -> BookQuestion? {
        questions.first { $0.id == id }
    }

    func place(of id: String) -> QuestionPlace? {
        places[id]
    }

    /// Frågorna med prick i ett avsnitt (en PDF-sida eller ett kapitel), i textens ordning. Frågor före
    /// läsningen och efter kapitlet får ingen prick.
    func questions(inSection section: Int) -> [BookQuestion] {
        questions.filter { places[$0.id]?.section == section && $0.timing == "efter" }
            .sorted { (places[$0.id]?.start ?? 0, $0.number) < (places[$1.id]?.start ?? 0, $1.number) }
    }

    /// Kapitlets frågor till självtestet efter kapitlet (K7): AI-frågorna i kapitlet (före, i texten och
    /// efter), eller frågefilens frågor som står i avsnitten.
    func chapterQuestions(sections: Range<Int>) -> [BookQuestion] {
        if usesAI {
            return questions.filter { $0.chapterSections?.overlaps(sections) ?? false }
        }
        return questions.filter { question in
            places[question.id].map { sections.contains($0.section) } ?? false
        }
    }

    /// Avsnitten där frågor står, till K7 (kapitlets frågor i testet).
    func sections() -> Set<Int> {
        Set(places.values.map(\.section))
    }

    func setStatus(_ status: QuestionStatus, for id: String) {
        statuses[id] = status
        QuestionStore.shared.setStatus(status, question: id, book: bookKey)
    }

    /// Prickens nummer och svaret, till bladen. Nil när prickarna inte ska synas.
    func info(for id: String) -> (number: Int, status: QuestionStatus?)? {
        guard showsDots, let question = question(id: id) else { return nil }
        return (question.number, statuses[id])
    }

    /// EPUB och text: citaten i ett kapitel som markeringar utan färg, så att webbvyn ger deras rutor.
    func markArguments(forChapter chapter: Int) -> [[String: Any]] {
        guard showsDots else { return [] }
        return questions(inSection: chapter).compactMap { question in
            guard let place = places[question.id], place.length > 0 else { return nil }
            return ["id": Self.markPrefix + question.id, "start": place.start, "length": place.length,
                    "text": question.quote, "color": "fraga", "note": false]
        }
    }

    // MARK: AI-frågorna görs (K6b)

    /// Sant när AI-frågor kan göras i boken: ingen frågefil, båda inställningarna och en nyckel.
    var canMakeAI: Bool {
        usesAI && aiContext != nil && AIQuestionMaker.shared.isEnabled
    }

    /// Läsaren visar ett avsnitt. Saknar kapitlet frågor görs de i bakgrunden (och sedan nästa kapitels),
    /// efter två sekunder i samma kapitel så att en snabb bläddring inte startar något. `atChapterStart` är
    /// sant när kapitlets första sida syns (raden Läs för att ta reda på), nil för PDF där det räknas ur sidan.
    func pageShown(section: Int, atChapterStart: Bool? = nil) {
        guard QuestionsSetting.isEnabled, usesAI, let context = aiContext,
              let chapter = context.chapterIndex(containing: section) else { return }
        let atStart = atChapterStart ?? (context.chapters[chapter].sections.lowerBound == section)
        chapterAtStart = atStart ? chapter : nil
        maybeShowBeforeReading()
        // Nyckelringen läses först när kapitlet byts, inte vid varje sidvändning.
        guard chapter != requestedChapter else { return }
        requestedChapter = chapter
        guard AIQuestionMaker.shared.isEnabled else { return }
        requestToken += 1
        let token = requestToken
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: SelfTest.isActive ? 200_000_000 : 2_000_000_000)
            guard let self = self, token == self.requestToken, let context = self.aiContext else { return }
            AIQuestionMaker.shared.request(context, chapter: chapter)
        }
    }

    /// Hur många kapitel som har AI-frågor (eller sparats som för korta), av hur många.
    var aiChapterCount: (done: Int, total: Int) {
        let keys = Set(aiRecords.map(\.chapter))
        let total = aiContext?.chapters.count ?? 0
        return (aiContext?.chapters.filter { keys.contains($0.key) }.count ?? keys.count, total)
    }

    func makeWholeBook() {
        guard let context = aiContext else { return }
        AIQuestionMaker.shared.makeWholeBook(context)
    }

    func remake(chapterKey: String) {
        guard let context = aiContext, let index = context.chapters.firstIndex(where: { $0.key == chapterKey }) else { return }
        AIQuestionMaker.shared.remake(context, chapter: index)
    }

    // MARK: Läs för att ta reda på (K6b)

    /// Frågorna före läsningen i ett kapitel.
    func beforeQuestions(chapterKey: String) -> [BookQuestion] {
        questions.filter { $0.chapterKey == chapterKey && $0.timing == "fore" }
    }

    /// Raden överst när första sidan i ett kapitel med frågor före läsningen visas, en gång per kapitel medan
    /// boken är öppen.
    private func maybeShowBeforeReading() {
        guard QuestionsSetting.isEnabled, usesAI, let chapter = chapterAtStart, let context = aiContext,
              chapter < context.chapters.count, let presenter = presenter, presenter.presentedViewController == nil
        else { return }
        let key = context.chapters[chapter].key
        let before = beforeQuestions(chapterKey: key)
        guard let first = before.first, !shownBeforeReading.contains(key) else { return }
        shownBeforeReading.insert(key)
        BeforeReadingBanner.show(question: first.question, in: presenter.view) { [weak self] in
            self?.presentBeforeReading(before)
        }
    }

    func presentBeforeReading(_ list: [BookQuestion]) {
        guard let presenter = presenter, presenter.presentedViewController == nil, !list.isEmpty else { return }
        let navigation = UINavigationController(rootViewController: BeforeReadingViewController(questions: list))
        Self.presentAsPopover(navigation, from: presenter, sourceView: presenter.view,
                              sourceRect: CGRect(x: presenter.view.bounds.midX, y: 80, width: 2, height: 2))
    }

    // MARK: Rutan med frågan

    /// Visar frågan vid pricken. Svaret ligger bakom ett tryck, och Kan, Osäker och Kan inte sparar hur det gick.
    /// AI-frågor (och frågefilens frågor med typ eller källa) får rutan med Ditt svar, Ur boken och Jämför.
    func presentCard(for id: String, from presenter: UIViewController, sourceView: UIView, sourceRect: CGRect) {
        guard presenter.presentedViewController == nil, let question = question(id: id) else { return }
        let card: UIViewController
        if question.usesAnswerCard {
            card = AIQuestionCardViewController(question: question, status: statuses[id], book: bookKey,
                                                onStatus: { [weak self] status in self?.setStatus(status, for: id) },
                                                onShowInBook: { [weak self] question in self?.showInBook(question) })
        } else {
            card = QuestionCardViewController(question: question, status: statuses[id]) { [weak self] status in
                self?.setStatus(status, for: id)
            }
        }
        Self.presentAsPopover(UINavigationController(rootViewController: card), from: presenter,
                              sourceView: sourceView, sourceRect: sourceRect)
    }

    static func presentAsPopover(_ navigation: UINavigationController, from presenter: UIViewController,
                                 sourceView: UIView, sourceRect: CGRect) {
        if presenter.traitCollection.horizontalSizeClass == .regular {
            navigation.modalPresentationStyle = .popover
            navigation.popoverPresentationController?.sourceView = sourceView
            navigation.popoverPresentationController?.sourceRect = sourceRect
            navigation.popoverPresentationController?.permittedArrowDirections = [.left, .right, .up, .down]
            navigation.popoverPresentationController?.backgroundColor = Theme.current.surface
        } else {
            navigation.modalPresentationStyle = .pageSheet
            if let sheet = navigation.sheetPresentationController {
                sheet.detents = [.medium(), .large()]
            }
        }
        presenter.present(navigation, animated: true)
    }

    /// Visa i boken: letar upp källan i bakgrunden och hoppar dit genom läsarens hopp (med i historiken).
    func showInBook(_ question: BookQuestion) {
        let quote = question.sourceAnchor.isEmpty ? question.source : question.sourceAnchor
        guard !quote.isEmpty, let search = search else { return }
        let hint = question.sourceSection ?? question.chapterSections?.lowerBound
        Task { @MainActor [weak self] in
            let hits = await search.locate([quote], hints: [hint])
            guard let self = self else { return }
            guard let hit = hits.first ?? nil else {
                AppLog.shared.write("AI-frågor: källan hittades inte i boken (Visa i boken)")
                return
            }
            let place = QuestionPlace(section: hit.section, start: hit.start, length: hit.length, y: nil)
            self.lastJump = place
            self.jump?(place)
        }
    }

    // MARK: Fliken Frågor

    /// Fliken Frågor i Innehåll. `placeLabel` ger stället (sida eller kapitel), `onSelect` hoppar dit.
    func makeList(placeLabel: @escaping (QuestionPlace) -> String,
                  onSelect: @escaping (BookQuestion, QuestionPlace) -> Void) -> QuestionListViewController {
        let list = QuestionListViewController(questions: self, placeLabel: placeLabel)
        list.onSelect = onSelect
        return list
    }
}

/// Rutan med en fråga (K6): numret och rubriken, frågan, Visa svaret och Kan, Osäker och Kan inte.
final class QuestionCardViewController: UIViewController {

    private let question: BookQuestion
    private var status: QuestionStatus?
    private let onStatus: (QuestionStatus) -> Void
    private let stack = UIStackView()
    private let answerLabel = UILabel()
    private let showButton = UIButton(type: .system)
    private var statusButtons: [QuestionStatus: UIButton] = [:]

    init(question: BookQuestion, status: QuestionStatus?, onStatus: @escaping (QuestionStatus) -> Void) {
        self.question = question
        self.status = status
        self.onStatus = onStatus
        super.init(nibName: nil, bundle: nil)
        title = "Fråga \(question.number)"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    /// Självtestet: om svaret syns.
    var showsAnswer: Bool {
        !answerLabel.isHidden
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let palette = Theme.current
        view.backgroundColor = palette.surface
        view.tintColor = palette.accent
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Klar", style: .done, target: self,
                                                            action: #selector(close))
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20),
        ])

        if !question.title.isEmpty {
            let title = UILabel()
            title.text = question.title
            title.font = Theme.serif(.title3, weight: .semibold)
            title.textColor = palette.ink
            title.numberOfLines = 0
            stack.addArrangedSubview(title)
        }
        let text = UILabel()
        text.text = question.question
        text.font = Theme.serif(.body, size: 19)
        text.textColor = palette.ink
        text.numberOfLines = 0
        stack.addArrangedSubview(text)

        let quote = UILabel()
        quote.text = question.quote.isEmpty ? nil : "\u{201D}\(question.quote)\u{201D}"
        quote.font = Theme.serif(.footnote).withSymbolicTraits(.traitItalic)
        quote.textColor = palette.inkSoft
        quote.numberOfLines = 3
        quote.isHidden = question.quote.isEmpty
        stack.addArrangedSubview(quote)

        var showConfiguration = UIButton.Configuration.tinted()
        showConfiguration.title = question.answer.isEmpty ? "Inget svar i filen" : "Visa svaret"
        showConfiguration.cornerStyle = .large
        showButton.configuration = showConfiguration
        showButton.isEnabled = !question.answer.isEmpty
        showButton.addAction(UIAction { [weak self] _ in self?.revealAnswer() }, for: .touchUpInside)
        stack.addArrangedSubview(showButton)

        answerLabel.text = question.answer.count == 1
            ? question.answer[0]
            : question.answer.map { "\u{2022} " + $0 }.joined(separator: "\n")
        answerLabel.font = .preferredFont(forTextStyle: .body)
        answerLabel.adjustsFontForContentSizeCategory = true
        answerLabel.textColor = palette.ink
        answerLabel.numberOfLines = 0
        answerLabel.isHidden = true
        stack.addArrangedSubview(answerLabel)

        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 8
        row.distribution = .fillEqually
        let colors: [QuestionStatus: UIColor] = [.unknown: palette.ribbon, .unsure: palette.warning, .known: palette.success]
        for option in QuestionStatus.allCases {
            var configuration = UIButton.Configuration.tinted()
            configuration.title = option.title
            configuration.baseForegroundColor = colors[option]
            configuration.baseBackgroundColor = colors[option]
            configuration.cornerStyle = .large
            let button = UIButton(configuration: configuration)
            button.addAction(UIAction { [weak self] _ in self?.choose(option) }, for: .touchUpInside)
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            statusButtons[option] = button
            row.addArrangedSubview(button)
        }
        stack.addArrangedSubview(row)
        updateStatusButtons()

        let width: CGFloat = 380
        let fitting = stack.systemLayoutSizeFitting(CGSize(width: width - 40, height: 0),
                                                    withHorizontalFittingPriority: .required,
                                                    verticalFittingPriority: .fittingSizeLevel)
        preferredContentSize = CGSize(width: width, height: min(ceil(fitting.height) + 36 + 140, 620))
    }

    func revealAnswer() {
        guard answerLabel.isHidden, !question.answer.isEmpty else { return }
        answerLabel.alpha = 0
        answerLabel.isHidden = false
        showButton.isHidden = true
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.25) {
            self.answerLabel.alpha = 1
        }
    }

    func choose(_ option: QuestionStatus) {
        status = option
        updateStatusButtons()
        onStatus(option)
        Haptics.shared.wordTapped()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self = self, !SelfTest.isActive else { return }
            self.dismiss(animated: true)
        }
    }

    private func updateStatusButtons() {
        for (option, button) in statusButtons {
            var configuration = button.configuration
            let chosen = option == status
            configuration?.image = chosen ? UIImage(systemName: "checkmark") : nil
            configuration?.imagePadding = 4
            button.configuration = configuration
            button.accessibilityTraits = chosen ? [.button, .selected] : .button
        }
    }

    @objc private func close() {
        dismiss(animated: true)
    }
}

/// Fliken Frågor i Innehåll (K6): bokens frågor i ordning med stället och svaret. Utan frågefil visas
/// AI-frågorna (K6b) kapitel för kapitel, med Före läsningen, I texten och Efter kapitlet, och överst en rad om
/// AI-frågorna (Gör frågor till hela boken och beskeden). Med en frågefil som förut, och utan frågor alls visas
/// hur en frågefil läggs till.
final class QuestionListViewController: UITableViewController, UIDocumentPickerDelegate {

    var onSelect: ((BookQuestion, QuestionPlace) -> Void)?
    private let questions: ReaderQuestions
    private let placeLabel: (QuestionPlace) -> String
    private static let cellID = "question"
    private static let actionID = "action"
    private var groups: [(key: String, title: String, items: [BookQuestion])] = []
    private var actions: [(title: String, run: () -> Void)] = []
    private var observers: [NSObjectProtocol] = []

    init(questions: ReaderQuestions, placeLabel: @escaping (QuestionPlace) -> String) {
        self.questions = questions
        self.placeLabel = placeLabel
        super.init(style: .insetGrouped)
        title = "Frågor"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Självtestet: antalet frågor.
    var count: Int {
        questions.questions.count
    }

    /// Självtestet: raden om AI-frågorna och knapparna under den.
    var aiStatusText: String {
        aiStatus().text
    }

    var actionTitles: [String] {
        actions.map { $0.title }
    }

    /// Självtestet: kör en av knapparna under raden om AI-frågorna.
    func runAction(_ title: String) {
        actions.first { $0.title == title }?.run()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.cellID)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.actionID)
        for name in [ReaderQuestions.didLoad, AIQuestionMaker.didChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.reload()
                }
            })
        }
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    private var showsAI: Bool {
        questions.usesAI && questions.aiContext != nil
    }

    private func reload() {
        if showsAI {
            var result: [(key: String, title: String, items: [BookQuestion])] = []
            for question in questions.questions {
                if result.last?.key == question.chapterKey {
                    result[result.count - 1].items.append(question)
                } else {
                    result.append((question.chapterKey, question.chapterName, [question]))
                }
            }
            groups = result
        } else {
            groups = questions.questions.isEmpty ? [] : [("", "", questions.questions)]
        }
        actions = showsAI ? aiStatus().actions : []
        tableView.reloadData()
        updateEmptyState()
    }

    /// Raden om AI-frågorna: hur många kapitel som har frågor, förloppet och det som hindrar.
    private func aiStatus() -> (text: String, actions: [(title: String, run: () -> Void)]) {
        let maker = AIQuestionMaker.shared
        let book = questions.bookKey
        let counts = questions.aiChapterCount
        var lines = ["\(counts.done) av \(counts.total) kapitel har AI-frågor."]
        var buttons: [(title: String, run: () -> Void)] = []
        if !AIQuestionsSetting.isEnabled {
            lines.append("Gör frågor med AI är avstängt (Aa, under Frågor i marginalen).")
        } else if !AIClient.hasKey {
            lines.append("Frågorna görs med Gemini. Lägg in en gratis nyckel först.")
            buttons.append(("Lägg in en nyckel", { [weak self] in self?.openGuide() }))
        } else if maker.booksWithoutText.contains(book) && questions.questions.isEmpty {
            lines.append("Boken har ingen text att göra frågor av. Gör den sökbar först.")
        } else if let problem = maker.problem {
            lines.append(problem.message)
            if problem.needsSetup {
                buttons.append(("Öppna nyckelguiden", { [weak self] in self?.openGuide() }))
            }
        }
        if let progress = maker.progress(book: book) {
            lines.append("Gör frågor till hela boken: \(progress.done) av \(progress.total) kapitel klara.")
            buttons.append(("Avbryt", { AIQuestionMaker.shared.cancel(book: book) }))
        } else if maker.isWorking(book: book) {
            lines.append("Frågor görs just nu.")
        }
        if AIQuestionsSetting.isEnabled, AIClient.hasKey, maker.problem == nil, maker.progress(book: book) == nil,
           counts.done < counts.total {
            buttons.append(("Gör frågor till hela boken", { [weak self] in self?.questions.makeWholeBook() }))
        }
        return (lines.joined(separator: " "), buttons)
    }

    private func openGuide() {
        let guide = AIKeyGuideViewController()
        guide.onWorking = { [weak self] in
            guard let self = self else { return }
            self.navigationController?.popToViewController(self, animated: true)
            self.reload()
        }
        navigationController?.pushViewController(guide, animated: true)
    }

    private func updateEmptyState() {
        guard !showsAI, questions.questions.isEmpty else {
            tableView.backgroundView = nil
            return
        }
        let name = BookQuestionFile.target(for: questions.book).lastPathComponent
        let label = UILabel()
        label.text = (questions.problem.map { $0 + "\n\n" } ?? "")
            + "Boken har inga frågor än. Lägg en fil som heter \(name) i samma mapp som boken (Filer, På min iPad, "
            + "Sensus, Böcker), eller välj en frågefil nedan."
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .body)
        var configuration = UIButton.Configuration.tinted()
        configuration.title = "Välj frågefil"
        configuration.cornerStyle = .large
        let button = UIButton(configuration: configuration)
        button.addAction(UIAction { [weak self] _ in self?.chooseFile() }, for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [label, button])
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        let background = UIView()
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -28),
        ])
        tableView.backgroundView = background
    }

    private func chooseFile() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json], asCopy: true)
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let target = BookQuestionFile.target(for: questions.book)
        do {
            // Granskning 5, L2: samma gräns som när boken öppnas, så att en jättefil aldrig läses in här.
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= BookQuestionFile.maxBytes else {
                throw BookQuestionFile.Failure(description: "Filen är större än 2 MB")
            }
            let data = try Data(contentsOf: url)
            let parsed = try BookQuestionFile.parse(data)
            guard !parsed.isEmpty else {
                throw BookQuestionFile.Failure(description: "Filen har inga frågor med citat eller sida")
            }
            try data.write(to: target, options: .atomic)
            AppLog.shared.write("Frågor (K6): frågefil vald, \(parsed.count) frågor")
            questions.onChange?()
            NotificationCenter.default.post(name: QuestionsSetting.didChange, object: nil)
        } catch {
            let alert = UIAlertController(title: "Frågefilen kunde inte användas", message: "\(error)",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }

    // MARK: Tabellen

    /// Avsnitt 0 är raden om AI-frågorna (bara utan frågefil), sedan ett avsnitt per kapitel.
    private var offset: Int {
        showsAI ? 1 : 0
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        offset + groups.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section < offset {
            return "AI-frågor"
        }
        let title = groups[section - offset].title
        return title.isEmpty ? nil : title
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section < offset ? aiStatus().text : nil
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section < offset {
            return actions.count
        }
        let group = groups[section - offset]
        return group.items.count + (showsAI ? 1 : 0)
    }

    private func phase(_ question: BookQuestion) -> String {
        switch question.timing {
        case "fore": return "Före läsningen"
        case "slut": return "Efter kapitlet"
        default:
            if let place = questions.place(of: question.id) {
                return "I texten, " + placeLabel(place)
            }
            return questions.isLocated ? "I texten (stället hittades inte)" : "I texten"
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section < offset || indexPath.row >= groups[indexPath.section - offset].items.count {
            let cell = tableView.dequeueReusableCell(withIdentifier: Self.actionID, for: indexPath)
            var content = UIListContentConfiguration.cell()
            content.text = indexPath.section < offset ? actions[indexPath.row].title : "Gör nya frågor till kapitlet"
            content.textProperties.color = Theme.current.accent
            cell.contentConfiguration = content
            cell.accessoryType = .none
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellID, for: indexPath)
        let question = groups[indexPath.section - offset].items[indexPath.row]
        var content = UIListContentConfiguration.subtitleCell()
        if question.usesAnswerCard {
            content.text = question.question
        } else {
            content.text = "\(question.number). " + (question.title.isEmpty ? question.question : question.title)
        }
        content.textProperties.numberOfLines = 2
        var detail: [String] = []
        if question.usesAnswerCard {
            detail.append(question.heading)
            detail.append(phase(question))
        } else if let place = questions.place(of: question.id) {
            detail.append(placeLabel(place))
        } else if questions.isLocated {
            detail.append("Citatet hittades inte i boken")
        }
        if let status = questions.statuses[question.id] {
            detail.append(status.title)
        }
        content.secondaryText = detail.joined(separator: ", ")
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content
        cell.accessoryType = questions.place(of: question.id) == nil && !question.usesAnswerCard ? .none : .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section < offset {
            actions[indexPath.row].run()
            reload()
            return
        }
        let group = groups[indexPath.section - offset]
        guard indexPath.row < group.items.count else {
            confirmRemake(chapterKey: group.key, title: group.title)
            return
        }
        let question = group.items[indexPath.row]
        if question.usesAnswerCard {
            let rect = tableView.rectForRow(at: indexPath)
            questions.presentCard(for: question.id, from: self, sourceView: tableView, sourceRect: rect)
            return
        }
        guard let place = questions.place(of: question.id) else { return }
        onSelect?(question, place)
    }

    /// Gör nya frågor till kapitlet, med en bekräftelse: de gamla svaren hör då inte längre till någon fråga.
    private func confirmRemake(chapterKey: String, title: String) {
        let alert = UIAlertController(title: "Gör nya frågor till kapitlet?",
                                      message: "Frågorna till \(title.isEmpty ? "kapitlet" : title) byts ut mot nya. "
                                        + "Dina svar på de gamla frågorna hör då inte längre till någon fråga.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Avbryt", style: .cancel))
        alert.addAction(UIAlertAction(title: "Gör nya frågor", style: .default) { [weak self] _ in
            self?.questions.remake(chapterKey: chapterKey)
            self?.reload()
        })
        present(alert, animated: true)
    }
}
