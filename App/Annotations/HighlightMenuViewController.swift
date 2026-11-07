import UIKit

/// Rutan som visas när man trycker på en markering: färg, anteckning, kopiera och ta bort.
final class HighlightMenuViewController: UIViewController, UIPopoverPresentationControllerDelegate {

    var onColor: ((HighlightColor) -> Void)?
    var onNote: (() -> Void)?
    var onDelete: (() -> Void)?

    private let highlight: Highlight
    private var colorButtons: [HighlightColor: UIButton] = [:]

    init(highlight: Highlight) {
        self.highlight = highlight
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    /// Visar rutan vid markeringen, som en liten popover även på iPhone.
    static func present(_ menu: HighlightMenuViewController,
                        from presenter: UIViewController,
                        sourceView: UIView,
                        sourceRect: CGRect) {
        menu.modalPresentationStyle = .popover
        if let popover = menu.popoverPresentationController {
            popover.sourceView = sourceView
            popover.sourceRect = sourceRect
            popover.permittedArrowDirections = [.up, .down]
            popover.delegate = menu
        }
        presenter.present(menu, animated: true)
    }

    func adaptivePresentationStyle(for controller: UIPresentationController,
                                   traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        .none
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let colors = UIStackView()
        colors.axis = .horizontal
        colors.spacing = 12
        colors.alignment = .center
        for color in HighlightColor.allCases {
            let button = UIButton(type: .system)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.backgroundColor = color.solid
            button.layer.cornerRadius = 17
            button.tintColor = .black
            button.accessibilityLabel = color.title
            button.addAction(UIAction { [weak self] _ in
                self?.choose(color)
            }, for: .touchUpInside)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 34),
                button.heightAnchor.constraint(equalToConstant: 34),
            ])
            colors.addArrangedSubview(button)
            colorButtons[color] = button
        }
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        colors.addArrangedSubview(spacer)

        let trash = UIButton(type: .system)
        trash.setImage(UIImage(systemName: "trash"), for: .normal)
        trash.tintColor = .systemRed
        trash.accessibilityLabel = "Ta bort markeringen"
        trash.addAction(UIAction { [weak self] _ in
            self?.dismiss(animated: true) {
                self?.onDelete?()
            }
        }, for: .touchUpInside)
        colors.addArrangedSubview(trash)
        updateSelection(highlight.color)

        var noteConfiguration = UIButton.Configuration.tinted()
        noteConfiguration.title = "Anteckning"
        noteConfiguration.image = UIImage(systemName: "square.and.pencil")
        noteConfiguration.imagePadding = 6
        noteConfiguration.cornerStyle = .medium
        let note = UIButton(configuration: noteConfiguration)
        note.addAction(UIAction { [weak self] _ in
            self?.dismiss(animated: true) {
                self?.onNote?()
            }
        }, for: .touchUpInside)

        var copyConfiguration = UIButton.Configuration.tinted()
        copyConfiguration.title = "Kopiera"
        copyConfiguration.image = UIImage(systemName: "doc.on.doc")
        copyConfiguration.imagePadding = 6
        copyConfiguration.cornerStyle = .medium
        let copy = UIButton(configuration: copyConfiguration)
        copy.addAction(UIAction { [weak self] _ in
            guard let self = self else { return }
            UIPasteboard.general.string = self.highlight.text
            self.dismiss(animated: true)
        }, for: .touchUpInside)

        let buttons = UIStackView(arrangedSubviews: [note, copy])
        buttons.axis = .horizontal
        buttons.spacing = 10
        buttons.distribution = .fillEqually

        let stack = UIStackView(arrangedSubviews: [colors])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        if highlight.hasNote {
            let label = UILabel()
            label.text = highlight.note
            label.numberOfLines = 5
            label.font = .preferredFont(forTextStyle: .callout)
            label.textColor = .secondaryLabel
            stack.addArrangedSubview(label)
        }
        stack.addArrangedSubview(buttons)
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.widthAnchor.constraint(equalToConstant: 288),
        ])
        let size = stack.systemLayoutSizeFitting(CGSize(width: 288, height: UIView.layoutFittingCompressedSize.height),
                                                 withHorizontalFittingPriority: .required,
                                                 verticalFittingPriority: .fittingSizeLevel)
        preferredContentSize = CGSize(width: 320, height: size.height + 28)
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
        guard !saved else { return }
        let text = currentText
        guard text != initialNote.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        saved = true
        onSave?(text)
    }

    /// Arket stängdes på något annat sätt än med Spara eller Avbryt, till exempel svept bort: spara.
    /// Samma sak som delegaten ovan, men oberoende av den.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true {
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
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Avbryt", style: .plain, target: self,
                                                           action: #selector(cancelTapped))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Spara", style: .done, target: self,
                                                            action: #selector(saveTapped))

        let quoteLabel = UILabel()
        quoteLabel.text = "»\(quote)«"
        quoteLabel.numberOfLines = 4
        quoteLabel.font = UIFont.preferredFont(forTextStyle: .callout).withSymbolicTraits(.traitItalic)
        quoteLabel.textColor = .secondaryLabel
        quoteLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(quoteLabel)

        textView.text = initialNote
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .secondarySystemBackground
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

extension UIFont {
    /// Samma typsnitt med till exempel kursiv stil, om det finns.
    func withSymbolicTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits)) else {
            return self
        }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
