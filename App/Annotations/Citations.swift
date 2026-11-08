import UIKit

/// Citatstilarna i Kopiera som citat (K3).
enum CitationStyle: String, CaseIterable {
    case harvard
    case apa
    case oxford

    var title: String {
        switch self {
        case .harvard: return "Harvard"
        case .apa: return "APA 7"
        case .oxford: return "Oxford (fotnot)"
        }
    }
}

/// Bokinfon som ett citat byggs av.
struct CitationSource: Equatable {
    var author = ""
    var year = ""
    var title = ""
    var publisher = ""
    var place = ""
}

/// Citat och referenser i Harvard, APA 7 och Oxford, på svenska (s., u.å., m.fl.). Ren logik (G13).
enum Citation {

    /// Markeringens text som citat: avstavning vid radslut ihopskriven, radbrytningar och dubbla blanksteg bort.
    static func cleanQuote(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\r\n", with: "\n")
        if let regex = try? NSRegularExpression(pattern: #"(\p{Ll})[-­]\s*\n\s*(\p{Ll})"#) {
            let range = NSRange(location: 0, length: (result as NSString).length)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1$2")
        }
        result = result.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "\"”“»«'’ "))
    }

    /// En författare som (efternamn, förnamn).
    struct Name: Equatable {
        let family: String
        let given: String

        var initials: String {
            given.split(whereSeparator: { $0 == " " || $0 == "-" }).compactMap { $0.first }
                .map { "\($0)." }.joined(separator: " ")
        }

        var full: String {
            given.isEmpty ? family : "\(given) \(family)"
        }
    }

    /// Författarna ur ett fritt fält: "Lindqvist, Anders", "Anders Lindqvist", "A Lindqvist och M Hietanen",
    /// "Lindqvist; Hietanen" eller EPUB:ens "Anders Lindqvist, Mika Hietanen".
    static func names(_ author: String) -> [Name] {
        let trimmed = author.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var parts: [String]
        let separators = [";", " och ", " & ", " and "]
        if let separator = separators.first(where: { trimmed.contains($0) }) {
            parts = trimmed.components(separatedBy: separator)
            for other in separators where other != separator {
                parts = parts.flatMap { $0.components(separatedBy: other) }
            }
        } else {
            let commas = trimmed.components(separatedBy: ",")
            // "Lindqvist, Anders" är en person. "Anders Lindqvist, Mika Hietanen" är två.
            let isList = commas.count > 2
                || (commas.count == 2 && commas.allSatisfy { $0.trimmingCharacters(in: .whitespaces).contains(" ") })
            parts = isList ? commas : [trimmed]
        }
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.map(name)
    }

    private static func name(_ text: String) -> Name {
        if let comma = text.firstIndex(of: ",") {
            let family = text[..<comma].trimmingCharacters(in: .whitespaces)
            let given = text[text.index(after: comma)...].trimmingCharacters(in: .whitespaces)
            return Name(family: family, given: given)
        }
        let words = text.split(separator: " ").map(String.init)
        guard words.count > 1, let family = words.last else { return Name(family: text, given: "") }
        return Name(family: family, given: words.dropLast().joined(separator: " "))
    }

    private static func year(_ source: CitationSource) -> String {
        let year = source.year.trimmingCharacters(in: .whitespaces)
        return year.isEmpty ? "u.å." : year
    }

    /// Hänvisningen inom parentes, till exempel "(Lindqvist 2016, s. 63)" eller "(Lindqvist, 2016, s. 63)".
    static func inText(_ style: CitationStyle, source: CitationSource, page: String?) -> String {
        let people = Self.names(source.author)
        let who: String
        switch people.count {
        case 0:
            who = source.title.isEmpty ? "Okänd" : source.title
        case 1:
            who = people[0].family
        case 2:
            who = style == .apa ? "\(people[0].family) & \(people[1].family)" : "\(people[0].family) och \(people[1].family)"
        default:
            who = "\(people[0].family) m.fl."
        }
        let pageText = page.map { ", s. \($0)" } ?? ""
        switch style {
        case .apa:
            return "(\(who), \(year(source))\(pageText))"
        case .harvard, .oxford:
            return "(\(who) \(year(source))\(pageText))"
        }
    }

    /// Fotnoten i Oxford: "Anders Lindqvist, Klassisk retorik för vår tid (Lund: Studentlitteratur, 2016), s. 63."
    static func footnote(source: CitationSource, page: String?) -> String {
        let people = Self.names(source.author)
        var parts: [String] = []
        if !people.isEmpty {
            let list = people.map(\.full)
            parts.append(list.count > 3 ? "\(list[0]) m.fl." : joined(list, last: " och "))
        }
        var titlePart = source.title.isEmpty ? "Okänd titel" : source.title
        let imprint = [source.place, source.publisher].filter { !$0.isEmpty }.joined(separator: ": ")
        let publication = [imprint, year(source)].filter { !$0.isEmpty }.joined(separator: ", ")
        titlePart += " (\(publication))"
        parts.append(titlePart)
        if let page = page {
            parts.append("s. \(page)")
        }
        return parts.joined(separator: ", ") + "."
    }

    /// Referensen i referenslistan.
    static func reference(_ style: CitationStyle, source: CitationSource) -> String {
        let people = Self.names(source.author)
        let title = source.title.isEmpty ? "Okänd titel" : source.title
        switch style {
        case .harvard:
            let authors = joined(people.map { $0.given.isEmpty ? $0.family : "\($0.family), \($0.initials)" }, last: " och ")
            let imprint = [source.place, source.publisher].filter { !$0.isEmpty }.joined(separator: ": ")
            return [authors.isEmpty ? nil : authors, "(\(year(source)))", title + ".", imprint.isEmpty ? nil : imprint + "."]
                .compactMap { $0 }.joined(separator: " ")
        case .apa:
            let authors = joined(people.map { $0.given.isEmpty ? $0.family : "\($0.family), \($0.initials)" },
                                 last: ", & ", separator: ", ")
            let publisher = source.publisher.isEmpty ? nil : source.publisher + "."
            return [authors.isEmpty ? nil : authors, "(\(year(source))).", title + ".", publisher]
                .compactMap { $0 }.joined(separator: " ")
        case .oxford:
            let authors = joined(people.map { $0.given.isEmpty ? $0.family : "\($0.family), \($0.given)" }, last: " och ")
            let imprint = [source.place, source.publisher].filter { !$0.isEmpty }.joined(separator: ": ")
            let tail = [imprint, year(source)].filter { !$0.isEmpty }.joined(separator: ", ")
            return [authors.isEmpty ? nil : authors + ",", title + ".", tail + "."].compactMap { $0 }.joined(separator: " ")
        }
    }

    /// Det som kopieras: citatet med hänvisningen, i Oxford citatet med en fotnot under.
    static func quote(_ text: String, style: CitationStyle, source: CitationSource, page: String?) -> String {
        let quoted = "”\(cleanQuote(text))”"
        switch style {
        case .harvard, .apa:
            return "\(quoted) \(inText(style, source: source, page: page))"
        case .oxford:
            return "\(quoted)¹\n\n¹ \(footnote(source: source, page: page))"
        }
    }

    private static func joined(_ list: [String], last: String, separator: String = ", ") -> String {
        guard list.count > 1 else { return list.first ?? "" }
        return list.dropLast().joined(separator: separator) + last + (list.last ?? "")
    }

    /// Ett årtal i filnamnet, som förslag när bokinfon saknar år: "Lindqvist 2016 kap 3.pdf".
    static func year(inFileName name: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"(?<!\d)(1[5-9]\d\d|20\d\d)(?!\d)"#) else { return nil }
        let string = name as NSString
        guard let match = regex.firstMatch(in: name, range: NSRange(location: 0, length: string.length)) else { return nil }
        return string.substring(with: match.range(at: 1))
    }

    /// Årtalet i EPUB:ens dc:date ("2016-03-01" blir "2016").
    static func year(fromDate text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\d{4}"#),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else {
            return ""
        }
        return (text as NSString).substring(with: match.range)
    }
}

/// Bokinfon för en bok: det som sparats (K3), annars titel och författare ur biblioteket (B1) och årtalet i filnamnet.
@MainActor
enum CitationSources {

    static func source(for book: Book) -> CitationSource {
        let info = BookInfoStore.shared.info(book: book.id)
        let record = BookRegistry.shared.record(id: book.id)
        var source = CitationSource(author: info.author, year: info.year, title: info.title,
                                    publisher: info.publisher, place: info.place)
        if source.author.isEmpty {
            source.author = record?.displayAuthor ?? ""
        }
        if source.title.isEmpty {
            source.title = record?.displayTitle ?? book.title
        }
        if source.year.isEmpty {
            source.year = Citation.year(inFileName: book.url.lastPathComponent) ?? ""
        }
        return source
    }

    /// EPUB fyller i själv (K3): år, förlag och författare ur OPF-filen, i bakgrunden, bara i tomma fält.
    static func fillFromEPUB(_ book: Book, completion: @escaping () -> Void) {
        guard book.kind == .epub else { return }
        let info = BookInfoStore.shared.info(book: book.id)
        guard info.year.isEmpty || info.publisher.isEmpty else { return }
        let url = book.url
        DispatchQueue.global(qos: .utility).async {
            let found = readEPUB(url: url)
            DispatchQueue.main.async {
                guard let found = found else { return }
                var current = BookInfoStore.shared.info(book: book.id)
                var changed = false
                if current.year.isEmpty, !found.year.isEmpty {
                    current.year = found.year
                    changed = true
                }
                if current.publisher.isEmpty, !found.publisher.isEmpty {
                    current.publisher = found.publisher
                    changed = true
                }
                if current.author.isEmpty, !found.author.isEmpty {
                    current.author = found.author
                    changed = true
                }
                if changed {
                    BookInfoStore.shared.save(current, book: book.id)
                    completion()
                }
            }
        }
    }

    nonisolated private static func readEPUB(url: URL) -> CitationSource? {
        guard let archive = try? ZipArchive(url: url),
              let containerEntry = archive.entry(named: "META-INF/container.xml"),
              let containerData = try? archive.contents(of: containerEntry),
              let container = XMLTree.parse(containerData),
              let rootPath = container.descendants(named: "rootfile").compactMap({ $0["full-path"] }).first,
              let packageEntry = archive.entry(named: rootPath),
              let packageData = try? archive.contents(of: packageEntry),
              let package = XMLTree.parse(packageData),
              let metadata = package.descendants(named: "metadata").first else {
            return nil
        }
        func first(_ name: String) -> String {
            BookFileReader.clean(metadata.descendants(named: name).first?.text ?? "")
        }
        let creators = metadata.descendants(named: "creator").map { BookFileReader.clean($0.text) }.filter { !$0.isEmpty }
        return CitationSource(author: creators.prefix(3).joined(separator: "; "),
                              year: Citation.year(fromDate: first("date")),
                              title: first("title"), publisher: first("publisher"), place: "")
    }
}

/// Rutan Kopiera som citat (K3): de tre stilarna med citatet, en knapp per stil och referensen, och bokinfon
/// längst ner med Ändra. Popover på iPad, ark på iPhone.
final class CitationViewController: UIViewController, UIPopoverPresentationControllerDelegate {

    private let book: Book
    private let text: String
    private let page: String?
    /// Varför citatet saknar sida (D4-1), och knappen till Bokens sidnummer i PDF.
    private let pageHint: String?
    private let onSetPages: (() -> Void)?
    private let stack = UIStackView()
    private let scroll = UIScrollView()

    /// Det som kopierades senast, till självtestet.
    private(set) static var lastCopied = ""

    init(book: Book, text: String, page: String?, pageHint: String? = nil, onSetPages: (() -> Void)? = nil) {
        self.book = book
        self.text = text
        self.page = page
        self.pageHint = pageHint
        self.onSetPages = onSetPages
        super.init(nibName: nil, bundle: nil)
        title = "Kopiera som citat"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    static func present(book: Book, text: String, page: String?, pageHint: String? = nil,
                        onSetPages: (() -> Void)? = nil, from presenter: UIViewController,
                        sourceView: UIView, sourceRect: CGRect) {
        guard presenter.presentedViewController == nil else { return }
        let controller = CitationViewController(book: book, text: text, page: page, pageHint: pageHint,
                                                onSetPages: onSetPages)
        let navigation = UINavigationController(rootViewController: controller)
        if presenter.traitCollection.horizontalSizeClass == .regular {
            navigation.modalPresentationStyle = .popover
            navigation.popoverPresentationController?.sourceView = sourceView
            navigation.popoverPresentationController?.sourceRect = sourceRect
            navigation.popoverPresentationController?.backgroundColor = Theme.current.surface
        } else {
            navigation.modalPresentationStyle = .pageSheet
        }
        presenter.present(navigation, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.current.surface
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Klar", style: .done, target: self,
                                                            action: #selector(close))
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -16),
        ])
        rebuild()
        CitationSources.fillFromEPUB(book) { [weak self] in
            self?.rebuild()
        }
    }

    private func rebuild() {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let palette = Theme.current
        let source = CitationSources.source(for: book)
        for style in CitationStyle.allCases {
            let header = UILabel()
            header.text = style.title.uppercased()
            header.font = .systemFont(ofSize: 12, weight: .semibold)
            header.textColor = palette.inkSoft
            let quote = Citation.quote(text, style: style, source: source, page: page)
            let body = UILabel()
            body.text = quote
            body.numberOfLines = 6
            body.lineBreakMode = .byTruncatingMiddle
            body.font = Theme.serif(.callout)
            body.textColor = palette.ink
            let reference = Citation.reference(style, source: source)
            let copy = button("Kopiera citatet", filled: true) { [weak self] in
                self?.copy(quote, style: style)
            }
            let copyReference = button("Kopiera referensen", filled: false) { [weak self] in
                self?.copy(reference, style: style)
            }
            copy.accessibilityLabel = "Kopiera citatet i \(style.title)"
            copyReference.accessibilityLabel = "Kopiera referensen i \(style.title)"
            let buttons = UIStackView(arrangedSubviews: [copy, copyReference, UIView()])
            buttons.spacing = 8
            let group = UIStackView(arrangedSubviews: [header, body, buttons])
            group.axis = .vertical
            group.spacing = 6
            stack.addArrangedSubview(group)
        }
        let rule = UIView()
        rule.backgroundColor = palette.rule
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        stack.addArrangedSubview(rule)
        let infoLabel = UILabel()
        infoLabel.numberOfLines = 0
        infoLabel.font = .preferredFont(forTextStyle: .footnote)
        infoLabel.textColor = palette.inkSoft
        let pageText = page.map { "Sida \($0) i boken." }
            ?? pageHint ?? "Ingen sida (EPUB och text har inga fasta sidor)."
        infoLabel.text = "Bokinfo: " + Citation.reference(.harvard, source: source) + "\n" + pageText
        let edit = button("Ändra bokinfo", filled: false) { [weak self] in
            guard let self = self else { return }
            BookInfoEditor.present(book: self.book, from: self) { [weak self] in
                self?.rebuild()
            }
        }
        var infoViews: [UIView] = [infoLabel, edit]
        if page == nil, let onSetPages = onSetPages {
            let pages = button("Ställ in bokens sidnummer", filled: false) { [weak self] in
                self?.dismiss(animated: true) {
                    onSetPages()
                }
            }
            infoViews.insert(pages, at: 1)
        }
        let infoRow = UIStackView(arrangedSubviews: infoViews)
        infoRow.axis = .vertical
        infoRow.alignment = .leading
        infoRow.spacing = 6
        stack.addArrangedSubview(infoRow)
        let width: CGFloat = 420
        let fitting = stack.systemLayoutSizeFitting(CGSize(width: width - 32, height: 0),
                                                    withHorizontalFittingPriority: .required,
                                                    verticalFittingPriority: .fittingSizeLevel)
        preferredContentSize = CGSize(width: width, height: min(ceil(fitting.height) + 34, 640))
    }

    private func button(_ title: String, filled: Bool, action: @escaping () -> Void) -> UIButton {
        var configuration = filled ? UIButton.Configuration.filled() : UIButton.Configuration.bordered()
        configuration.title = title
        configuration.baseBackgroundColor = filled ? Theme.current.accent : Theme.current.surfaceSunk
        configuration.baseForegroundColor = filled ? .white : Theme.current.accent
        configuration.cornerStyle = .medium
        configuration.buttonSize = .small
        let button = UIButton(configuration: configuration)
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func copy(_ text: String, style: CitationStyle) {
        UIPasteboard.general.string = text
        Self.lastCopied = text
        AppLog.shared.write("K3: citat kopierat (\(style.title))")
        dismiss(animated: true)
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    func adaptivePresentationStyle(for controller: UIPresentationController,
                                   traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        .none
    }
}

/// Ändra bokinfo (K3): författare, år, titel, förlag och ort. Fylls i en gång per bok.
@MainActor
enum BookInfoEditor {

    static func present(book: Book, from presenter: UIViewController, completion: @escaping () -> Void) {
        let source = CitationSources.source(for: book)
        let alert = UIAlertController(title: "Bokinfo", message: "Används i citaten. Flera författare skiljs med semikolon.",
                                      preferredStyle: .alert)
        let fields: [(String, String)] = [("Författare, till exempel Lindqvist, Anders", source.author),
                                          ("År", source.year), ("Titel", source.title),
                                          ("Förlag", source.publisher), ("Ort", source.place)]
        for (placeholder, value) in fields {
            alert.addTextField { field in
                field.placeholder = placeholder
                field.text = value
                field.clearButtonMode = .whileEditing
                field.autocapitalizationType = .words
                if placeholder == "År" {
                    field.keyboardType = .numbersAndPunctuation
                }
            }
        }
        alert.addAction(UIAlertAction(title: "Avbryt", style: .cancel))
        alert.addAction(UIAlertAction(title: "Spara", style: .default) { [weak alert] _ in
            let values = (alert?.textFields ?? []).map { ($0.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            guard values.count == 5 else { return }
            var info = BookInfoStore.shared.info(book: book.id)
            info.author = values[0]
            info.year = values[1]
            info.title = values[2]
            info.publisher = values[3]
            info.place = values[4]
            BookInfoStore.shared.save(info, book: book.id)
            completion()
        })
        presenter.present(alert, animated: true)
    }
}
