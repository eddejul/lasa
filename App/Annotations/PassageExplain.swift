import PDFKit
import UIKit

/// Förklara stycket (A1): knappen Förklara i markeringsraden skickar stycket runt markeringen, bokens titel och
/// kapitlets rubrik till Gemini via `AIClient`. Svaret (kärnan på vanlig svenska, nyckelbegreppen, ett eget
/// exempel och en kontrollfråga) visas i en ruta och sparas som anteckning på markeringen, under en egen
/// anteckning om det redan finns en. Aldrig hela kapitel: kursböckerna är upphovsrättsskyddade.
enum PassageExplain {

    /// Var texten runt markeringen hämtas.
    enum Source {
        /// En PDF: markeringens sida läses ur ett eget dokument i bakgrunden, aldrig ur läsarens.
        case pdf(URL)
        /// Kapitlets HTML-fil i en EPUB eller textfil.
        case chapter(URL)
    }

    /// Frågetypen i de sparade svaren. Höj versionen när frågan eller schemat ändras på ett sätt som ska ge nya svar.
    static let kind = "stycke-1"

    /// Visar rutan och frågar. `onSaved` anropas när anteckningen sparats, så att läsaren ritar om markeringen.
    @MainActor
    static func present(highlight: Highlight, book: Book, chapter: String?, source: Source,
                        from presenter: UIViewController, sourceView: UIView, sourceRect: CGRect,
                        onSaved: @escaping () -> Void) {
        guard presenter.presentedViewController == nil else { return }
        let box = ExplainViewController(highlight: highlight, bookTitle: title(of: book),
                                        chapter: chapter, source: source)
        box.onSaved = onSaved
        let navigation = UINavigationController(rootViewController: box)
        Theme.style(navigation.navigationBar)
        if presenter.traitCollection.horizontalSizeClass == .regular {
            navigation.modalPresentationStyle = .popover
            navigation.preferredContentSize = CGSize(width: 440, height: 560)
            if let popover = navigation.popoverPresentationController {
                popover.sourceView = sourceView
                popover.sourceRect = sourceRect
                popover.permittedArrowDirections = [.up, .down, .left, .right]
                popover.backgroundColor = Theme.current.surface
            }
        } else {
            navigation.modalPresentationStyle = .pageSheet
            if let sheet = navigation.sheetPresentationController {
                sheet.detents = [.medium(), .large()]
                sheet.prefersGrabberVisible = true
            }
        }
        presenter.present(navigation, animated: true)
    }

    /// Bokens titel till frågan: bokinfon (K3), bibliotekets titel (B1) eller filnamnet.
    static func title(of book: Book) -> String {
        let info = BookInfoStore.shared.info(book: book.id).title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !info.isEmpty {
            return info
        }
        if let record = BookRegistry.shared.record(id: book.id), !record.displayTitle.isEmpty {
            return record.displayTitle
        }
        return book.title
    }

    // MARK: Frågan

    static var schema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "core": ["type": "string"],
                "concepts": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": ["term": ["type": "string"], "definition": ["type": "string"]],
                        "required": ["term", "definition"],
                    ],
                ],
                "example": ["type": "string"],
                "question": ["type": "string"],
                "answer": ["type": "string"],
            ],
            "required": ["core", "concepts", "example", "question", "answer"],
        ]
    }

    static func prompt(passage: Passage, bookTitle: String, chapter: String?) -> String {
        var lines = [
            "Du hjälper en svensk student att förstå ett svårt stycke i en kursbok.",
            "Bok: \(bookTitle)",
        ]
        if let chapter = chapter?.trimmingCharacters(in: .whitespacesAndNewlines), !chapter.isEmpty {
            lines.append("Kapitel: \(chapter)")
        }
        lines += ["", "Stycket:", "\"\"\"", passage.context, "\"\"\""]
        if passage.marked != passage.context {
            lines += ["", "Det markerade: \"\(passage.marked)\""]
        }
        lines += [
            "",
            "Förklara det markerade i sitt sammanhang. Svara alltid på svenska, även om boken är på engelska.",
            "core: kärnan på vanlig svenska, två till fyra korta meningar, utan facktermer som inte förklaras.",
            "concepts: de två till fyra viktigaste begreppen i stycket. term som det står i boken, definition på "
                + "högst en mening.",
            "example: ett eget, konkret exempel ur vardagen som visar idén. Inte ett exempel ur boken.",
            "question: en kontrollfråga som visar om man har förstått kärnan.",
            "answer: ett kort svar på kontrollfrågan, en eller två meningar.",
            "Lägg inte till något som stycket inte säger. Skriv utan tankstreck.",
            "Svara bara med JSON enligt schemat.",
        ]
        return lines.joined(separator: "\n")
    }

    // MARK: Svaret

    struct Explanation: Equatable {
        struct Concept: Equatable {
            let term: String
            let definition: String
        }

        let core: String
        let concepts: [Concept]
        let example: String
        let question: String
        let answer: String

        init?(json: [String: Any]) {
            func text(_ key: String, limit: Int) -> String {
                let value = (json[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return String(value.prefix(limit))
            }
            core = text("core", limit: 900)
            guard !core.isEmpty else { return nil }
            concepts = ((json["concepts"] as? [[String: Any]]) ?? []).compactMap { item -> Concept? in
                let term = (item["term"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let definition = (item["definition"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !term.isEmpty, !definition.isEmpty else { return nil }
                return Concept(term: String(term.prefix(80)), definition: String(definition.prefix(300)))
            }.prefix(5).map { $0 }
            example = text("example", limit: 600)
            question = text("question", limit: 300)
            answer = text("answer", limit: 400)
        }

        /// Anteckningens text. Rubriken känns igen, så att samma förklaring inte läggs till två gånger.
        var noteText: String {
            var parts = ["\(PassageExplain.noteHeading):", core]
            if !concepts.isEmpty {
                parts.append("Begrepp:\n" + concepts.map { "• \($0.term): \($0.definition)" }.joined(separator: "\n"))
            }
            if !example.isEmpty {
                parts.append("Exempel: \(example)")
            }
            if !question.isEmpty {
                var line = "Kontrollfråga: \(question)"
                if !answer.isEmpty {
                    line += "\nSvar: \(answer)"
                }
                parts.append(line)
            }
            return parts.joined(separator: "\n\n")
        }
    }

    static let noteHeading = "Förklaring med AI"

    /// Anteckningen efter att förklaringen lagts till: under den egna texten, aldrig i stället för den.
    /// Nil när exakt samma förklaring redan finns i anteckningen.
    static func note(adding explanation: Explanation, to existing: String) -> String? {
        let addition = explanation.noteText
        let current = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        if current.contains(addition) {
            return nil
        }
        return current.isEmpty ? addition : current + "\n\n" + addition
    }

    /// Sparar förklaringen på markeringen. Svarar med om anteckningen ändrades.
    @discardableResult
    static func save(_ explanation: Explanation, highlightID: String) -> Bool {
        guard var current = AnnotationStore.shared.highlight(id: highlightID),
              let note = note(adding: explanation, to: current.note) else { return false }
        current.note = note
        AnnotationStore.shared.update(current)
        return true
    }
}

// MARK: Texten runt markeringen

/// Det som skickas: stycket (EPUB) eller meningarna runt markeringen (PDF), och markeringen själv.
struct Passage: Equatable {
    let context: String
    let marked: String
}

/// Tar fram texten runt en markering. Ren logik i bakgrunden, testas i självtestet.
enum PassageText {

    /// Högst så här många tecken skickas, även om stycket är längre.
    static let maxLength = 2400
    /// Markeringen själv kortas till detta i frågan.
    static let maxMarked = 1200

    /// Hämtar texten i bakgrunden och svarar på huvudtråden.
    static func load(_ highlight: Highlight, source: PassageExplain.Source,
                     completion: @escaping (Passage) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let passage: Passage
            switch source {
            case .pdf(let url):
                passage = pdfPassage(highlight, url: url)
            case .chapter(let url):
                passage = chapterPassage(highlight, url: url)
            }
            DispatchQueue.main.async {
                completion(passage)
            }
        }
    }

    static func markedOnly(_ highlight: Highlight) -> Passage {
        let marked = String(collapse(highlight.text).prefix(maxMarked))
        return Passage(context: marked, marked: marked)
    }

    // MARK: PDF

    /// PDF: meningen med markeringen och två meningar före och två efter, på markeringens sida. Är markeringen
    /// själv längre än så, eller går sidan inte att läsa, skickas bara markeringen.
    static func pdfPassage(_ highlight: Highlight, url: URL) -> Passage {
        guard let document = PDFDocument(url: url), let page = document.page(at: highlight.section),
              let string = page.string, !string.isEmpty else { return markedOnly(highlight) }
        return sentencePassage(highlight, in: string)
    }

    /// Meningarna runt markeringen i en text där markeringens intervall gäller (UTF-16).
    static func sentencePassage(_ highlight: Highlight, in string: String, around: Int = 2) -> Passage {
        let text = string as NSString
        var range = NSRange(location: highlight.start, length: highlight.length)
        if NSMaxRange(range) > text.length || collapse(text.substring(with: range)) != collapse(highlight.text) {
            // Platsen stämmer inte: leta upp markeringens text.
            let found = text.range(of: highlight.text)
            guard found.location != NSNotFound else { return markedOnly(highlight) }
            range = found
        }
        var sentences: [NSRange] = []
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.bySentences, .substringNotRequired]) { _, sentence, _, _ in
            sentences.append(sentence)
        }
        let touching = sentences.indices.filter { NSIntersectionRange(sentences[$0], range).length > 0 }
        guard let first = touching.first, let last = touching.last else { return markedOnly(highlight) }
        let marked = String(collapse(highlight.text).prefix(maxMarked))
        for spread in stride(from: around, through: 0, by: -1) {
            let lower = max(first - spread, 0)
            let upper = min(last + spread, sentences.count - 1)
            let span = NSUnionRange(sentences[lower], sentences[upper])
            let context = collapse(text.substring(with: span))
            if context.count <= maxLength {
                return Passage(context: context, marked: marked)
            }
        }
        return Passage(context: marked, marked: marked)
    }

    // MARK: EPUB och text

    /// EPUB och text: stycket (eller styckena) där markeringen ligger. Ett mycket långt stycke kortas till
    /// meningarna runt markeringen.
    static func chapterPassage(_ highlight: Highlight, url: URL) -> Passage {
        guard let data = try? Data(contentsOf: url),
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return markedOnly(highlight)
        }
        return paragraphPassage(highlight, paragraphs: paragraphs(html: html))
    }

    static func paragraphPassage(_ highlight: Highlight, paragraphs: [String]) -> Passage {
        let marked = collapse(highlight.text)
        guard !marked.isEmpty, !paragraphs.isEmpty else { return markedOnly(highlight) }
        let head = String(marked.prefix(60))
        let tail = String(marked.suffix(60))
        guard let first = paragraphs.firstIndex(where: { $0.contains(head) }) else {
            return markedOnly(highlight)
        }
        let last = paragraphs[first...].firstIndex(where: { $0.contains(tail) }) ?? first
        guard last - first <= 3 else { return markedOnly(highlight) }
        let context = paragraphs[first...last].joined(separator: "\n\n")
        let shortMarked = String(marked.prefix(maxMarked))
        if context.count <= maxLength {
            return Passage(context: context, marked: shortMarked)
        }
        // För långt: meningarna runt markeringen i stycket.
        let joined = context as NSString
        let found = joined.range(of: head)
        guard found.location != NSNotFound else { return Passage(context: shortMarked, marked: shortMarked) }
        let local = Highlight(id: highlight.id, book: highlight.book, section: highlight.section,
                              start: found.location, length: min((marked as NSString).length, joined.length - found.location),
                              text: highlight.text, color: highlight.color, note: highlight.note,
                              created: highlight.created, updated: highlight.updated)
        return sentencePassage(local, in: context)
    }

    private static let removals: [NSRegularExpression] = [
        "<head[\\s>].*?</head\\s*>",
        "<script[\\s>].*?</script\\s*>",
        "<style[\\s>].*?</style\\s*>",
        "<!--.*?-->",
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive, .dotMatchesLineSeparators]) }

    /// Taggar som avslutar ett stycke: de blir styckegränser.
    private static let blocks = try? NSRegularExpression(
        pattern: "<(?:/?(?:p|div|h[1-6]|li|blockquote|section|article|aside|header|footer|tr|td|th|dd|dt|"
            + "figcaption|pre|table|ul|ol|nav)\\b[^>]*|br\\s*/?)>",
        options: [.caseInsensitive])
    private static let tags = try? NSRegularExpression(pattern: "<[^>]*>", options: [])
    private static let entity = try? NSRegularExpression(pattern: "&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);")
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "shy": "",
        "mdash": "\u{2014}", "ndash": "\u{2013}", "hellip": "\u{2026}", "laquo": "\u{00AB}", "raquo": "\u{00BB}",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "lsquo": "\u{2018}", "rsquo": "\u{2019}",
    ]

    /// Kapitlets stycken som text, i dokumentordning.
    static func paragraphs(html source: String) -> [String] {
        var html = source
        for expression in removals {
            html = expression.stringByReplacingMatches(in: html, range: NSRange(location: 0, length: (html as NSString).length),
                                                       withTemplate: " ")
        }
        if let blocks = blocks {
            html = blocks.stringByReplacingMatches(in: html, range: NSRange(location: 0, length: (html as NSString).length),
                                                   withTemplate: "\u{2029}")
        }
        if let tags = tags {
            html = tags.stringByReplacingMatches(in: html, range: NSRange(location: 0, length: (html as NSString).length),
                                                 withTemplate: "")
        }
        let decoded = decodeEntities(html)
        return decoded.components(separatedBy: "\u{2029}").map { collapse($0) }.filter { !$0.isEmpty }
    }

    private static func decodeEntities(_ text: String) -> String {
        guard let entity = entity else { return text }
        let source = text as NSString
        var output = ""
        var position = 0
        for match in entity.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            output += source.substring(with: NSRange(location: position, length: match.range.location - position))
            let name = source.substring(with: match.range(at: 1))
            var replacement: String?
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                replacement = UInt32(name.dropFirst(2), radix: 16).flatMap { Unicode.Scalar($0) }.map { String(Character($0)) }
            } else if name.hasPrefix("#") {
                replacement = UInt32(name.dropFirst()).flatMap { Unicode.Scalar($0) }.map { String(Character($0)) }
            } else {
                replacement = named[name]
            }
            output += replacement ?? source.substring(with: match.range)
            position = NSMaxRange(match.range)
        }
        output += source.substring(from: position)
        return output
    }

    /// Ett mellanslag mellan orden, avstavningar över radbrytningar ihopslagna, inga mjuka bindestreck.
    static func collapse(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\u{00AD}", with: "")
        for hyphen in ["-", "\u{2010}", "\u{2011}"] {
            result = result.replacingOccurrences(of: hyphen + "\r\n", with: "")
            result = result.replacingOccurrences(of: hyphen + "\n", with: "")
        }
        var output = ""
        var lastWasSpace = true
        for character in result {
            if character.isWhitespace {
                if !lastWasSpace {
                    output.append(" ")
                }
                lastWasSpace = true
            } else {
                output.append(character)
                lastWasSpace = false
            }
        }
        return output.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: Rutan

/// Rutan med förklaringen: först Frågar Gemini, sedan svaret, eller ett begripligt besked med en knapp till
/// guiden för nyckeln (U7). Svaret sparas som anteckning direkt.
final class ExplainViewController: UIViewController {

    var onSaved: (() -> Void)?

    private let highlight: Highlight
    private let bookTitle: String
    private let chapter: String?
    private let source: PassageExplain.Source
    private let scroll = UIScrollView()
    private let stack = UIStackView()

    /// Till självtestet: läget i rutan och det senaste svaret.
    private(set) var stateText = "väntar"
    private(set) var lastExplanation: PassageExplain.Explanation?
    private(set) var lastPrompt: String?
    private(set) var lastFailure: AIClient.Failure?
    private(set) var lastWasCached = false
    private(set) var noteWasSaved = false
    /// Självtestet väntar på att rutan blir klar.
    var onFinished: (() -> Void)?

    init(highlight: Highlight, bookTitle: String, chapter: String?, source: PassageExplain.Source) {
        self.highlight = highlight
        self.bookTitle = bookTitle
        self.chapter = chapter
        self.source = source
        super.init(nibName: nil, bundle: nil)
        title = "Förklaring"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.current.surface
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Klar", style: .done, target: self,
                                                            action: #selector(close))
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        view.addSubview(scroll)
        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
        ])
        ask()
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    /// Hämtar texten runt markeringen och frågar. Ett sparat svar visas direkt, utan anrop.
    func ask() {
        showLoading()
        let current = AnnotationStore.shared.highlight(id: highlight.id) ?? highlight
        PassageText.load(current, source: source) { [weak self] passage in
            guard let self = self else { return }
            let prompt = PassageExplain.prompt(passage: passage, bookTitle: self.bookTitle, chapter: self.chapter)
            self.lastPrompt = prompt
            AIClient.generate(kind: PassageExplain.kind, prompt: prompt, schema: PassageExplain.schema,
                              maxTokens: 2048) { [weak self] result in
                self?.handle(result)
            }
        }
    }

    private func handle(_ result: Result<AIClient.Answer, AIClient.Failure>) {
        defer { onFinished?() }
        switch result {
        case .success(let answer):
            guard let explanation = PassageExplain.Explanation(json: answer.json) else {
                show(failure: .invalidResponse)
                return
            }
            lastExplanation = explanation
            lastWasCached = answer.cached
            noteWasSaved = PassageExplain.save(explanation, highlightID: highlight.id)
            if noteWasSaved {
                onSaved?()
            }
            show(explanation, cached: answer.cached)
            AppLog.shared.write("Förklara stycket: \(answer.cached ? "sparat svar" : "nytt svar"), "
                                + "\(AIClient.callsToday) anrop i dag")
        case .failure(let failure):
            show(failure: failure)
            AppLog.shared.write("Förklara stycket: \(failure)")
        }
    }

    // MARK: Lägena

    private func clear() {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func showLoading() {
        stateText = "frågar"
        clear()
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        let label = makeLabel("Frågar Gemini …", style: .body, color: Theme.current.inkSoft)
        let row = UIStackView(arrangedSubviews: [spinner, label])
        row.spacing = 10
        row.alignment = .center
        stack.addArrangedSubview(row)
        stack.addArrangedSubview(quoteLabel())
        fitPopover()
    }

    /// Rutan som popover (iPad) blir lika hög som innehållet, mellan 220 och 620 punkter.
    private func fitPopover() {
        guard let navigation = navigationController, navigation.modalPresentationStyle == .popover else { return }
        let width: CGFloat = 440
        let fitting = stack.systemLayoutSizeFitting(
            CGSize(width: width - 40, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        let height = min(max(fitting.height + 36 + navigation.navigationBar.frame.height, 220), 620)
        navigation.preferredContentSize = CGSize(width: width, height: ceil(height))
    }

    private func show(failure: AIClient.Failure) {
        stateText = "fel"
        lastFailure = failure
        clear()
        let palette = Theme.current
        let icon = UIImageView(image: UIImage(systemName: failure.needsSetup ? "key" : "exclamationmark.circle"))
        icon.tintColor = failure.needsSetup ? palette.accent : palette.warning
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let message = makeLabel(failure.errorDescription ?? "", style: .body, color: palette.ink)
        let row = UIStackView(arrangedSubviews: [icon, message])
        row.spacing = 10
        row.alignment = .top
        stack.addArrangedSubview(row)
        if failure.needsSetup {
            stack.addArrangedSubview(button(AIClient.hasKey ? "Kontrollera nyckeln" : "Ställ in Förklaring med AI") {
                [weak self] in
                self?.openGuide()
            })
        } else {
            stack.addArrangedSubview(button("Försök igen") { [weak self] in
                self?.ask()
            })
        }
        stack.addArrangedSubview(footer(cached: false))
        fitPopover()
    }

    private func show(_ explanation: PassageExplain.Explanation, cached: Bool) {
        stateText = "svar"
        clear()
        let palette = Theme.current
        stack.addArrangedSubview(makeLabel(explanation.core, style: .body, color: palette.ink, serif: true))
        if !explanation.concepts.isEmpty {
            stack.addArrangedSubview(heading("Begrepp"))
            for concept in explanation.concepts {
                let text = NSMutableAttributedString(
                    string: concept.term, attributes: [.font: UIFont.preferredFont(forTextStyle: .headline),
                                                       .foregroundColor: palette.ink])
                text.append(NSAttributedString(
                    string: "  " + concept.definition,
                    attributes: [.font: UIFont.preferredFont(forTextStyle: .subheadline),
                                 .foregroundColor: palette.inkSoft]))
                let label = UILabel()
                label.attributedText = text
                label.numberOfLines = 0
                stack.addArrangedSubview(label)
            }
        }
        if !explanation.example.isEmpty {
            stack.addArrangedSubview(heading("Exempel"))
            stack.addArrangedSubview(makeLabel(explanation.example, style: .subheadline, color: palette.ink))
        }
        if !explanation.question.isEmpty {
            stack.addArrangedSubview(heading("Kontrollfråga"))
            stack.addArrangedSubview(makeLabel(explanation.question, style: .subheadline, color: palette.ink))
            if !explanation.answer.isEmpty {
                let answer = makeLabel(explanation.answer, style: .subheadline, color: palette.inkSoft)
                answer.isHidden = true
                let reveal = button("Visa svaret") {}
                reveal.addAction(UIAction { [weak reveal, weak answer] _ in
                    answer?.isHidden = false
                    reveal?.isHidden = true
                }, for: .touchUpInside)
                stack.addArrangedSubview(reveal)
                stack.addArrangedSubview(answer)
            }
        }
        stack.addArrangedSubview(footer(cached: cached))
        fitPopover()
    }

    /// Visar svaret på kontrollfrågan, till självtestets bild.
    func revealAnswerForSelfTest() {
        for case let button as UIButton in stack.arrangedSubviews where button.configuration?.title == "Visa svaret" {
            button.sendActions(for: .touchUpInside)
        }
    }

    private func footer(cached: Bool) -> UILabel {
        var lines: [String] = []
        if lastExplanation != nil, stateText == "svar" {
            lines.append(noteWasSaved ? "Sparad som anteckning på markeringen." : "Finns redan i anteckningen på markeringen.")
        }
        let usage = "\(AIClient.callsToday) anrop till Gemini i dag."
        if cached {
            lines.append("Sparat svar, inget nytt anrop. " + usage)
        } else if stateText == "svar" {
            lines.append(usage + " Bara stycket, bokens titel och kapitlet skickades till Google.")
        } else {
            lines.append(usage)
        }
        return makeLabel(lines.joined(separator: "\n"), style: .caption1, color: Theme.current.inkFaint)
    }

    private func quoteLabel() -> UILabel {
        let label = makeLabel("»\(PassageText.collapse(highlight.text).prefix(240))«", style: .callout,
                              color: Theme.current.inkSoft, serif: true)
        label.font = Theme.serif(.callout).withSymbolicTraits(.traitItalic)
        label.numberOfLines = 4
        return label
    }

    private func heading(_ text: String) -> UILabel {
        let label = makeLabel(text.uppercased(with: Locale(identifier: "sv_SE")), style: .caption1,
                              color: Theme.current.inkSoft)
        label.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        return label
    }

    private func makeLabel(_ text: String, style: UIFont.TextStyle, color: UIColor, serif: Bool = false) -> UILabel {
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.font = serif ? Theme.serif(style) : .preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        return label
    }

    private func button(_ title: String, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.baseForegroundColor = Theme.current.accent
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)
        let button = UIButton(configuration: configuration)
        button.contentHorizontalAlignment = .leading
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func openGuide() {
        let guide = AIKeyGuideViewController()
        guide.onWorking = { [weak self] in
            guard let self = self else { return }
            self.navigationController?.popToViewController(self, animated: true)
            self.ask()
        }
        navigationController?.pushViewController(guide, animated: true)
    }
}
