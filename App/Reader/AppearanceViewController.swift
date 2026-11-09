import UIKit

/// Utseenderutan bakom Aa (U2): allt som rör sidans utseende på ett ställe. Fyra bakgrunder som små sidor
/// i rätt färg, och för EPUB och text storlek, typsnitt (varje namn i sitt eget typsnitt), marginal,
/// radavstånd, justering och Återställ. PDF visar bara bakgrunderna och Zooma sidan.
/// Ändringar syns direkt i boken. Bläddringsljudet ligger i Inställningar.
final class AppearanceViewController: UIViewController {

    var onTheme: ((ReaderTheme) -> Void)?
    var onTypography: ((ReaderTypography) -> Void)?
    var onZoom: (() -> Void)?

    private var theme: ReaderTheme
    /// Nil i PDF.
    private var typography: ReaderTypography?
    private var themeButtons: [ReaderTheme: UIButton] = [:]
    private var fontButtons: [ReaderTypography.Font: UIButton] = [:]
    private let sizeLabel = UILabel()
    private let smallerButton = UIButton(type: .system)
    private let largerButton = UIButton(type: .system)
    private let marginControl = UISegmentedControl(items: ReaderTypography.Margin.allCases.map(\.title))
    private let spacingControl = UISegmentedControl(items: ReaderTypography.LineSpacing.allCases.map(\.title))
    private let justifySwitch = UISwitch()
    private let stack = UIStackView()

    init(theme: ReaderTheme, typography: ReaderTypography?) {
        self.theme = theme
        self.typography = typography
        super.init(nibName: nil, bundle: nil)
        title = typography == nil ? "Utseende" : "Utseende och text"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self,
                                                            action: #selector(doneTapped))
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = false
        view.addSubview(scroll)

        stack.axis = .vertical
        stack.spacing = 18
        stack.alignment = .fill
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

        stack.addArrangedSubview(makeThemeRow())
        stack.addArrangedSubview(makeSavedWordsRow())
        stack.addArrangedSubview(makeQuestionsRow())
        if typography != nil {
            stack.addArrangedSubview(section("Storlek", makeSizeRow()))
            stack.addArrangedSubview(section("Typsnitt", makeFontRow()))
            marginControl.addAction(UIAction { [weak self] _ in self?.marginChanged() }, for: .valueChanged)
            stack.addArrangedSubview(section("Marginal", marginControl))
            spacingControl.addAction(UIAction { [weak self] _ in self?.spacingChanged() }, for: .valueChanged)
            stack.addArrangedSubview(section("Radavstånd", spacingControl))
            stack.addArrangedSubview(makeJustifyRow())
            let reset = UIButton(type: .system)
            reset.setTitle("Återställ", for: .normal)
            reset.titleLabel?.font = .preferredFont(forTextStyle: .body)
            reset.accessibilityHint = "Bokens eget typsnitt, normal storlek, marginal och radavstånd"
            reset.addAction(UIAction { [weak self] _ in self?.resetTapped() }, for: .touchUpInside)
            stack.addArrangedSubview(reset)
            let note = UILabel()
            note.text = "Gäller EPUB och textfiler. Raden hålls till ungefär 66 tecken med normal marginal."
            note.numberOfLines = 0
            note.font = .preferredFont(forTextStyle: .footnote)
            stack.addArrangedSubview(note)
        } else {
            var configuration = UIButton.Configuration.tinted()
            configuration.title = "Zooma sidan"
            configuration.image = UIImage(systemName: "plus.magnifyingglass")
            configuration.imagePadding = 8
            let zoom = UIButton(configuration: configuration)
            zoom.addAction(UIAction { [weak self] _ in
                self?.dismiss(animated: true) {
                    self?.onZoom?()
                }
            }, for: .touchUpInside)
            stack.addArrangedSubview(zoom)
        }
        applyPalette()
        updateControls()
        let width: CGFloat = 360
        let fitting = stack.systemLayoutSizeFitting(CGSize(width: width - 40, height: 0),
                                                    withHorizontalFittingPriority: .required,
                                                    verticalFittingPriority: .fittingSizeLevel)
        preferredContentSize = CGSize(width: width, height: min(ceil(fitting.height) + 36, 640))
    }

    @objc private func doneTapped() {
        dismiss(animated: true)
    }

    /// Rutan själv följer bakgrunden som valts.
    private func applyPalette() {
        let palette = Theme.palette(for: theme)
        view.backgroundColor = palette.surface
        view.tintColor = palette.accent
        overrideUserInterfaceStyle = palette.interfaceStyle
        navigationController?.overrideUserInterfaceStyle = palette.interfaceStyle
        for label in labels(in: stack) {
            label.textColor = label.font.pointSize < 14 ? palette.inkSoft : palette.ink
        }
        for (option, button) in themeButtons {
            let selected = option == theme
            button.layer.borderWidth = selected ? 2.5 : 1
            button.layer.borderColor = (selected ? palette.accent : palette.rule).cgColor
        }
        for (font, button) in fontButtons {
            let selected = font == typography?.font
            button.backgroundColor = selected ? palette.accentSoft : palette.surfaceSunk
            button.layer.borderWidth = selected ? 1.5 : 0
            button.layer.borderColor = palette.accent.cgColor
            button.setTitleColor(palette.ink, for: .normal)
        }
    }

    private func labels(in view: UIView) -> [UILabel] {
        view.subviews.flatMap { sub -> [UILabel] in
            if sub is UIButton { return [] }
            if let label = sub as? UILabel { return [label] }
            return labels(in: sub)
        }
    }

    // MARK: Bakgrunderna

    /// Fyra små sidor i bakgrundens färger, med namnet under.
    private func makeThemeRow() -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.spacing = 12
        for option in ReaderTheme.allCases {
            let palette = Theme.palette(for: option)
            let button = UIButton(type: .custom)
            button.backgroundColor = palette.page
            button.layer.cornerRadius = 6
            button.setTitle("Aa", for: .normal)
            button.titleLabel?.font = Theme.serif(.title2, size: 22, weight: .regular)
            button.setTitleColor(palette.ink, for: .normal)
            button.accessibilityLabel = option.title
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(equalToConstant: 76).isActive = true
            button.addAction(UIAction { [weak self] _ in self?.chooseTheme(option) }, for: .touchUpInside)
            themeButtons[option] = button
            let name = UILabel()
            name.text = option.title
            name.font = .systemFont(ofSize: 12, weight: .medium)
            name.textAlignment = .center
            let column = UIStackView(arrangedSubviews: [button, name])
            column.axis = .vertical
            column.spacing = 6
            row.addArrangedSubview(column)
        }
        return row
    }

    private func chooseTheme(_ option: ReaderTheme) {
        guard option != theme else { return }
        theme = option
        onTheme?(option)
        applyPalette()
    }

    // MARK: Text

    private func section(_ title: String, _ content: UIView) -> UIView {
        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        let column = UIStackView(arrangedSubviews: [label, content])
        column.axis = .vertical
        column.spacing = 8
        return column
    }

    private func makeSizeRow() -> UIView {
        smallerButton.setTitle("A", for: .normal)
        smallerButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        smallerButton.accessibilityLabel = "Mindre text"
        smallerButton.addAction(UIAction { [weak self] _ in self?.changeSize(by: -1) }, for: .touchUpInside)
        largerButton.setTitle("A", for: .normal)
        largerButton.titleLabel?.font = .systemFont(ofSize: 26, weight: .medium)
        largerButton.accessibilityLabel = "Större text"
        largerButton.addAction(UIAction { [weak self] _ in self?.changeSize(by: 1) }, for: .touchUpInside)
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        sizeLabel.textAlignment = .center
        let row = UIStackView(arrangedSubviews: [smallerButton, sizeLabel, largerButton])
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.alignment = .center
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return row
    }

    /// Typsnitten som en vågrät rad av knappar, varje namn i sitt eget typsnitt.
    private func makeFontRow() -> UIView {
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(row)
        for font in ReaderTypography.Font.allCases {
            let button = UIButton(type: .custom)
            button.setTitle(font.shortTitle, for: .normal)
            button.titleLabel?.font = font.previewFont(size: 16)
            button.contentEdgeInsets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
            button.layer.cornerRadius = 10
            button.accessibilityLabel = font.title
            button.addAction(UIAction { [weak self] _ in self?.chooseFont(font) }, for: .touchUpInside)
            fontButtons[font] = button
            row.addArrangedSubview(button)
        }
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            row.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 40),
        ])
        return scroll
    }

    /// O4: strecken under sparade ord i texten, av och på. Gäller alla böcker.
    private func makeSavedWordsRow() -> UIView {
        let label = UILabel()
        label.text = "Dina ord i texten"
        label.font = .preferredFont(forTextStyle: .body)
        label.numberOfLines = 0
        let toggle = UISwitch()
        toggle.isOn = SavedWordMarks.shared.isEnabled
        toggle.accessibilityLabel = "Streck under sparade ord"
        toggle.addAction(UIAction { action in
            SavedWordMarks.shared.isEnabled = (action.sender as? UISwitch)?.isOn ?? true
        }, for: .valueChanged)
        let row = UIStackView(arrangedSubviews: [label, toggle])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        return row
    }

    /// K6: frågorna ur frågefilen som prickar i marginalen och fliken Frågor i Innehåll, av och på.
    /// Avstängt ser läsaren ut som utan frågor. Gäller alla böcker.
    private func makeQuestionsRow() -> UIView {
        let label = UILabel()
        label.text = "Frågor i marginalen"
        label.font = .preferredFont(forTextStyle: .body)
        label.numberOfLines = 0
        let toggle = UISwitch()
        toggle.isOn = QuestionsSetting.isEnabled
        toggle.accessibilityLabel = "Frågor i marginalen"
        toggle.accessibilityHint = "Frågor ur en frågefil bredvid boken"
        let row = UIStackView(arrangedSubviews: [label, toggle])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        // K6b: Gör frågor med AI, under Frågor i marginalen och bara valbar när den är på.
        let aiLabel = UILabel()
        aiLabel.text = "Gör frågor med AI"
        aiLabel.font = .preferredFont(forTextStyle: .subheadline)
        aiLabel.numberOfLines = 0
        let aiToggle = UISwitch()
        aiToggle.isOn = AIQuestionsSetting.isEnabled
        aiToggle.isEnabled = QuestionsSetting.isEnabled
        aiToggle.accessibilityLabel = "Gör frågor med AI"
        aiToggle.accessibilityHint = "Gemini gör frågor kapitel för kapitel i böcker utan frågefil"
        aiToggle.addAction(UIAction { action in
            AIQuestionsSetting.isEnabled = (action.sender as? UISwitch)?.isOn ?? true
        }, for: .valueChanged)
        let aiRow = UIStackView(arrangedSubviews: [aiLabel, aiToggle])
        aiRow.axis = .horizontal
        aiRow.alignment = .center
        aiRow.spacing = 12
        aiRow.isLayoutMarginsRelativeArrangement = true
        aiRow.layoutMargins = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)
        aiLabel.alpha = QuestionsSetting.isEnabled ? 1 : 0.4
        toggle.addAction(UIAction { [weak aiToggle, weak aiLabel] action in
            let on = (action.sender as? UISwitch)?.isOn ?? false
            QuestionsSetting.isEnabled = on
            aiToggle?.isEnabled = on
            aiLabel?.alpha = on ? 1 : 0.4
        }, for: .valueChanged)
        let rows = UIStackView(arrangedSubviews: [row, aiRow])
        rows.axis = .vertical
        rows.spacing = 10
        return rows
    }

    private func makeJustifyRow() -> UIView {
        let label = UILabel()
        label.text = "Justera kanterna"
        label.font = .preferredFont(forTextStyle: .body)
        justifySwitch.addAction(UIAction { [weak self] _ in self?.justifyChanged() }, for: .valueChanged)
        let row = UIStackView(arrangedSubviews: [label, justifySwitch])
        row.axis = .horizontal
        row.alignment = .center
        return row
    }

    private func updateControls() {
        guard let typography = typography else { return }
        sizeLabel.text = "\(Int((typography.scale * 100).rounded())) %"
        smallerButton.isEnabled = typography.canShrink
        largerButton.isEnabled = typography.canGrow
        marginControl.selectedSegmentIndex = ReaderTypography.Margin.allCases.firstIndex(of: typography.margin) ?? 1
        spacingControl.selectedSegmentIndex = ReaderTypography.LineSpacing.allCases
            .firstIndex(of: typography.lineSpacing) ?? 1
        justifySwitch.isOn = typography.justify
        applyPalette()
    }

    private func change(_ body: (inout ReaderTypography) -> Void) {
        guard var value = typography else { return }
        body(&value)
        guard value != typography else { return }
        typography = value
        updateControls()
        onTypography?(value)
    }

    private func changeSize(by step: Int) {
        change { value in
            value.sizeIndex = min(max(value.sizeIndex + step, 0), ReaderTypography.sizes.count - 1)
        }
    }

    private func chooseFont(_ font: ReaderTypography.Font) {
        change { $0.font = font }
    }

    private func marginChanged() {
        let index = marginControl.selectedSegmentIndex
        guard ReaderTypography.Margin.allCases.indices.contains(index) else { return }
        change { $0.margin = ReaderTypography.Margin.allCases[index] }
    }

    private func spacingChanged() {
        let index = spacingControl.selectedSegmentIndex
        guard ReaderTypography.LineSpacing.allCases.indices.contains(index) else { return }
        change { $0.lineSpacing = ReaderTypography.LineSpacing.allCases[index] }
    }

    private func justifyChanged() {
        change { $0.justify = justifySwitch.isOn }
    }

    private func resetTapped() {
        change { $0 = ReaderTypography.standard }
    }

    // MARK: Självtestet

    /// Ett tryck i rutan, som självtestet gör medan rutan är öppen (samma väg som fingret).
    enum TestAction {
        case theme(ReaderTheme)
        case larger
        case smaller
        case font(ReaderTypography.Font)
        case margin(Int)
        case spacing(Int)
        case justify(Bool)
        case reset
    }

    func perform(_ action: TestAction) {
        switch action {
        case .theme(let option):
            chooseTheme(option)
        case .larger:
            changeSize(by: 1)
        case .smaller:
            changeSize(by: -1)
        case .font(let font):
            chooseFont(font)
        case .margin(let index):
            marginControl.selectedSegmentIndex = index
            marginChanged()
        case .spacing(let index):
            spacingControl.selectedSegmentIndex = index
            spacingChanged()
        case .justify(let on):
            justifySwitch.isOn = on
            justifyChanged()
        case .reset:
            resetTapped()
        }
    }
}
