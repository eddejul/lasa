import UIKit

/// Markeringsraden (U5): en smal rad som visas ovanför markeringen man tryckt på, eller under den när
/// det inte finns plats ovanför. Fyra färgprickar, och Anteckning, Kopiera, Slå upp och Ta bort med text
/// under ikonerna. Raden täcker aldrig markeringen, eftersom den pekar på markeringens hela ruta.
/// iOS 16:s redigeringsmeny går inte att använda på iPadOS 15, så raden är en egen popover.
final class HighlightMenuViewController: UIViewController, UIPopoverPresentationControllerDelegate {

    var onColor: ((HighlightColor) -> Void)?
    var onNote: (() -> Void)?
    var onDelete: (() -> Void)?
    /// Slå upp: läsaren visar ordrutan för markeringens första ord.
    var onLookUp: (() -> Void)?
    /// K3: Kopiera som citat. Läsaren visar rutan med citatstilarna.
    var onCite: (() -> Void)?

    private let highlight: Highlight
    private var colorButtons: [HighlightColor: UIButton] = [:]
    /// Två rader (färgerna över knapparna) när läsarens vy är smal, till exempel på iPhone.
    private var compact = false

    /// Hur rutan placerades, till självtestet: ovanför eller under markeringen.
    private(set) static var lastPlacement = ""

    init(highlight: Highlight) {
        self.highlight = highlight
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    /// Visar raden vid markeringen, som en liten popover även på iPhone. `sourceRect` ska vara markeringens
    /// hela ruta (alla rader), så att raden hamnar helt ovanför eller under den.
    static func present(_ menu: HighlightMenuViewController,
                        from presenter: UIViewController,
                        sourceView: UIView,
                        sourceRect: CGRect) {
        menu.compact = presenter.view.bounds.width < 470
        menu.loadViewIfNeeded()
        let height = menu.preferredContentSize.height + 24
        let bounds = sourceView.bounds
        let top = sourceView.safeAreaInsets.top
        let bottom = sourceView.safeAreaInsets.bottom
        let roomAbove = sourceRect.minY - bounds.minY - top
        let roomBelow = bounds.maxY - bottom - sourceRect.maxY
        let directions: UIPopoverArrowDirection
        if roomAbove >= height {
            // Pilen pekar ner: raden ligger ovanför markeringen.
            directions = .down
            lastPlacement = "ovanför"
        } else if roomBelow >= height {
            directions = .up
            lastPlacement = "under"
        } else {
            directions = [.down, .up]
            lastPlacement = "där det fanns plats"
        }
        menu.modalPresentationStyle = .popover
        if let popover = menu.popoverPresentationController {
            popover.sourceView = sourceView
            popover.sourceRect = sourceRect
            popover.permittedArrowDirections = directions
            popover.backgroundColor = Theme.current.surface
            popover.delegate = menu
        }
        presenter.present(menu, animated: true)
    }

    /// Markeringens ruta i `view`, av rutorna i en sidas vy. Klipps till vyn och blir aldrig tom.
    static func anchor(for rects: [CGRect], in view: UIView, from pageView: UIView, fallback point: CGPoint) -> CGRect {
        let converted = rects.map { view.convert($0, from: pageView) }
        guard var union = converted.first else {
            return CGRect(x: point.x - 1, y: point.y - 10, width: 2, height: 20)
        }
        for rect in converted.dropFirst() {
            union = union.union(rect)
        }
        let clipped = union.intersection(view.bounds)
        return clipped.isNull || clipped.isEmpty ? CGRect(x: point.x - 1, y: point.y - 10, width: 2, height: 20) : clipped
    }

    func adaptivePresentationStyle(for controller: UIPresentationController,
                                   traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        .none
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let palette = Theme.current
        view.backgroundColor = palette.surface

        let colors = UIStackView()
        colors.axis = .horizontal
        colors.spacing = 8
        colors.alignment = .center
        for color in HighlightColor.allCases {
            let button = UIButton(type: .system)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.backgroundColor = color.solid
            button.layer.cornerRadius = 15
            button.tintColor = .black
            button.accessibilityLabel = HighlightColorNames.name(color)
            button.addAction(UIAction { [weak self] _ in
                self?.choose(color)
            }, for: .touchUpInside)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 30),
                button.heightAnchor.constraint(equalToConstant: 30),
            ])
            colors.addArrangedSubview(button)
            colorButtons[color] = button
        }
        updateSelection(highlight.color)

        let note = actionButton("Anteckning", symbol: highlight.hasNote ? "note.text" : "square.and.pencil",
                                color: palette.ink) { [weak self] in
            self?.dismiss(animated: true) {
                self?.onNote?()
            }
        }
        let copy = actionButton("Kopiera", symbol: "doc.on.doc", color: palette.ink) { [weak self] in
            guard let self = self else { return }
            UIPasteboard.general.string = self.highlight.text
            self.dismiss(animated: true)
        }
        let cite = actionButton("Citat", symbol: "text.quote", color: palette.ink) { [weak self] in
            self?.dismiss(animated: true) {
                self?.onCite?()
            }
        }
        cite.accessibilityLabel = "Kopiera som citat"
        let lookUp = actionButton("Slå upp", symbol: "character.book.closed", color: palette.ink) { [weak self] in
            self?.dismiss(animated: true) {
                self?.onLookUp?()
            }
        }
        let trash = actionButton("Ta bort", symbol: "trash", color: palette.ribbon) { [weak self] in
            self?.dismiss(animated: true) {
                self?.onDelete?()
            }
        }
        trash.accessibilityLabel = "Ta bort markeringen"
        var actionViews = [note, copy]
        if onCite != nil {
            actionViews.append(cite)
        }
        if onLookUp != nil {
            actionViews.append(lookUp)
        }
        actionViews.append(trash)
        let actions = UIStackView(arrangedSubviews: actionViews)
        actions.axis = .horizontal
        actions.spacing = 2
        actions.distribution = .fillEqually

        let divider = UIView()
        divider.backgroundColor = palette.rule
        divider.translatesAutoresizingMaskIntoConstraints = false

        let row = UIStackView()
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        if compact {
            row.axis = .vertical
            row.spacing = 10
            row.addArrangedSubview(colors)
            row.addArrangedSubview(actions)
        } else {
            row.axis = .horizontal
            row.spacing = 12
            row.addArrangedSubview(colors)
            row.addArrangedSubview(divider)
            row.addArrangedSubview(actions)
            NSLayoutConstraint.activate([
                divider.widthAnchor.constraint(equalToConstant: 1),
                divider.heightAnchor.constraint(equalToConstant: 34),
            ])
        }

        let stack = UIStackView(arrangedSubviews: [row])
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        if highlight.hasNote {
            // Anteckningen i en rad under, så att man ser den utan att öppna den.
            let label = UILabel()
            label.text = highlight.note
            label.numberOfLines = 2
            label.font = .preferredFont(forTextStyle: .footnote)
            label.textColor = palette.inkSoft
            stack.addArrangedSubview(label)
        }
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
        ])
        let fitting = stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize,
                                                    withHorizontalFittingPriority: .fittingSizeLevel,
                                                    verticalFittingPriority: .fittingSizeLevel)
        preferredContentSize = CGSize(width: ceil(fitting.width) + 24, height: ceil(fitting.height) + 16)
    }

    /// En knapp med ikonen överst och texten under, bred nog för Anteckning utan avstavning.
    private func actionButton(_ title: String, symbol: String, color: UIColor,
                              action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol,
                                      withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular))
        configuration.imagePlacement = .top
        configuration.imagePadding = 3
        configuration.baseForegroundColor = color
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 2, bottom: 4, trailing: 2)
        var attributes = AttributeContainer()
        attributes.font = UIFont.systemFont(ofSize: 11, weight: .medium)
        configuration.attributedTitle = AttributedString(title, attributes: attributes)
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = title
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 66).isActive = true
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func choose(_ color: HighlightColor) {
        updateSelection(color)
        onColor?(color)
        dismiss(animated: true)
    }

    private func updateSelection(_ selected: HighlightColor) {
        for (color, button) in colorButtons {
            let isSelected = color == selected
            button.setImage(isSelected ? UIImage(systemName: "checkmark") : nil, for: .normal)
            button.layer.borderWidth = isSelected ? 2 : 0
            button.layer.borderColor = UIColor.label.withAlphaComponent(0.6).cgColor
        }
    }
}

/// Skriv eller ändra anteckningen till en markering.
/// Sveps arket bort sparas texten, som i Anteckningar. Bara Avbryt kastar den.
final class NoteEditorViewController: UIViewController, UIAdaptivePresentationControllerDelegate {

    var onSave: ((String) -> Void)?

    private let quote: String
    private let initialNote: String
    private let textView = UITextView()
    private var saved = false

    init(quote: String, note: String) {
        self.quote = quote
        self.initialNote = note
        super.init(nibName: nil, bundle: nil)
        title = "Anteckning"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    /// Visar redigeraren som ett ark.
    static func present(quote: String, note: String, from presenter: UIViewController, onSave: @escaping (String) -> Void) {
        let editor = NoteEditorViewController(quote: quote, note: note)
        editor.onSave = onSave
        let navigation = UINavigationController(rootViewController: editor)
        navigation.modalPresentationStyle = presenter.traitCollection.userInterfaceIdiom == .pad ? .formSheet : .pageSheet
        // Delegaten får veta när arket sveps bort, så att texten kan sparas.
        navigation.presentationController?.delegate = editor
        presenter.present(navigation, animated: true)
    }

    /// Texten som den skulle sparas: utan blanktecken i början och slutet.
    private var currentText: String {
        (textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Arket sveptes bort. Spara om texten ändrats.
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        saveIfChanged()
    }

    private func saveIfChanged() {
        let text = currentText
        SelfTest.log("Anteckningsarket stängs: sparad förut \(saved), ändrad \(text != initialNote), "
                     + "mottagare \(onSave == nil ? "saknas" : "finns")")
        guard !saved else { return }
        guard text != initialNote.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        saved = true
        onSave?(text)
    }

    /// Arket stängdes på något annat sätt än med Spara eller Avbryt, till exempel svept bort: spara.
    /// Samma sak som delegaten ovan, men oberoende av den.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        let dismissed = isBeingDismissed || navigationController?.isBeingDismissed == true
        SelfTest.log("Anteckningsarket försvann, stängt: \(dismissed)")
        if dismissed {
            saveIfChanged()
        }
    }

    /// Självtestet: skriv en text och stäng arket utan Spara, som när det sveps bort.
    /// Svarar med om arket har en presentationskontroll med delegaten satt.
    @discardableResult
    func simulateSwipeAway(typing text: String) -> Bool {
        textView.text = text
        let hasDelegate = navigationController?.presentationController?.delegate === self
        navigationController?.dismiss(animated: false)
        return hasDelegate
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.current.surface
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Avbryt", style: .plain, target: self,
                                                           action: #selector(cancelTapped))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Spara", style: .done, target: self,
                                                            action: #selector(saveTapped))

        let quoteLabel = UILabel()
        quoteLabel.text = "»\(quote)«"
        quoteLabel.numberOfLines = 4
        quoteLabel.font = Theme.serif(.callout).withSymbolicTraits(.traitItalic)
        quoteLabel.textColor = Theme.current.inkSoft
        quoteLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(quoteLabel)

        textView.text = initialNote
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = Theme.current.surfaceSunk
        textView.layer.cornerRadius = 10
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.accessibilityLabel = "Anteckning"
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            quoteLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            quoteLabel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            quoteLabel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            textView.topAnchor.constraint(equalTo: quoteLabel.bottomAnchor, constant: 14),
            textView.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        textView.becomeFirstResponder()
    }

    @objc private func cancelTapped() {
        saved = true
        dismiss(animated: true)
    }

    @objc private func saveTapped() {
        let text = currentText
        saved = true
        dismiss(animated: true) { [onSave] in
            onSave?(text)
        }
    }
}

/// Slå upp i markeringsraden (U5): ordrutan för markeringens första ord, med markeringen som mening.
/// Gemensam för båda läsarna.
@MainActor
enum HighlightLookUp {

    /// Det första ordet med bokstäver i texten och dess plats.
    static func firstWord(in text: String) -> (word: String, range: NSRange)? {
        let string = text as NSString
        var found: (String, NSRange)?
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byWords) { word, range, _, stop in
            if let word = word, word.rangeOfCharacter(from: .letters) != nil {
                found = (word, range)
                stop.pointee = true
            }
        }
        return found
    }

    static func present(_ highlight: Highlight, book: Book, pageIndex: Int?, from presenter: UIViewController,
                        sourceView: UIView, sourceRect: CGRect) {
        guard presenter.presentedViewController == nil else { return }
        guard let dictionary = WordDictionary.shared else { return }
        guard let found = firstWord(in: highlight.text) else { return }
        let word = found.word
        let range = found.range
        let lookup = dictionary.lookup(word, sentence: highlight.text, rangeInSentence: range,
                                       hidden: UserWords.shared.hiddenPairs)
        let context = WordPopupViewController.Context(sentence: highlight.text, rangeInSentence: range,
                                                      book: book.title, pageIndex: pageIndex, triedWord: word,
                                                      bookID: book.id)
        WordPopupViewController.present(lookup: lookup, context: context, from: presenter, sourceView: sourceView,
                                        sourceRect: sourceRect, onReady: {}, onDismiss: {})
    }
}

extension UIFont {
    /// Samma typsnitt med till exempel kursiv stil, om det finns.
    func withSymbolicTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits)) else {
            return self
        }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
