import UIKit

/// Listan med bokens bokmärken eller markeringar. Tryck för att gå dit, svep för att ta bort.
final class AnnotationsViewController: UITableViewController {

    enum Kind {
        case bookmarks, highlights
    }

    struct Row {
        let id: String
        /// Bokmärkets namn, eller den markerade texten.
        let title: String
        /// Var i boken, till exempel "Sida 45".
        let detail: String?
        let note: String?
        let color: HighlightColor?
    }

    var kind: Kind {
        didSet {
            guard kind != oldValue else { return }
            reload()
        }
    }

    /// Raderna att visa, i läsordning.
    var rows: ((Kind) -> [Row])?
    var onSelect: ((Kind, String) -> Void)?
    var onDelete: ((Kind, String) -> Void)?

    private static let cellID = "annotation"
    private var items: [Row] = []

    init(kind: Kind) {
        self.kind = kind
        super.init(style: .plain)
        preferredContentSize = CGSize(width: 420, height: 640)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.cellID)
        tableView.estimatedRowHeight = 60
        tableView.rowHeight = UITableView.automaticDimension
        reload()
    }

    func reload() {
        items = rows?(kind) ?? []
        guard isViewLoaded else { return }
        tableView.reloadData()
        if items.isEmpty {
            let label = UILabel()
            switch kind {
            case .bookmarks:
                label.text = "Inga bokmärken än.\nTryck på bokmärket i menyn för att märka sidan du läser."
            case .highlights:
                label.text = "Inga markeringar än.\nTryck på pennan i menyn och dra över texten du vill markera."
            }
            label.numberOfLines = 0
            label.textAlignment = .center
            label.textColor = .secondaryLabel
            label.font = .preferredFont(forTextStyle: .body)
            tableView.backgroundView = label
            tableView.separatorStyle = .none
        } else {
            tableView.backgroundView = nil
            tableView.separatorStyle = .singleLine
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellID, for: indexPath)
        let row = items[indexPath.row]
        var content = UIListContentConfiguration.subtitleCell()
        switch kind {
        case .bookmarks:
            content.text = row.title
            content.image = UIImage(systemName: "bookmark.fill")
            content.imageProperties.tintColor = .systemRed
            content.secondaryText = row.detail
        case .highlights:
            content.text = row.title
            content.textProperties.numberOfLines = 4
            content.textProperties.font = .preferredFont(forTextStyle: .body)
            content.image = UIImage(systemName: row.note == nil ? "highlighter" : "text.bubble.fill")
            content.imageProperties.tintColor = row.color?.solid ?? .systemYellow
            var secondary = row.detail ?? ""
            if let note = row.note {
                secondary += secondary.isEmpty ? note : "\n" + note
            }
            content.secondaryText = secondary
            content.secondaryTextProperties.numberOfLines = 6
        }
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onSelect?(kind, items[indexPath.row].id)
    }

    override func tableView(_ tableView: UITableView,
                            titleForDeleteConfirmationButtonForRowAt indexPath: IndexPath) -> String? {
        "Ta bort"
    }

    override func tableView(_ tableView: UITableView,
                            commit editingStyle: UITableViewCell.EditingStyle,
                            forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, indexPath.row < items.count else { return }
        let id = items[indexPath.row].id
        items.remove(at: indexPath.row)
        tableView.deleteRows(at: [indexPath], with: .automatic)
        onDelete?(kind, id)
        if items.isEmpty {
            reload()
        }
    }
}

/// Innehåll, bokmärken och markeringar i samma ruta, med en väljare överst som i Apple Books.
final class ReaderContentsContainerViewController: UIViewController {

    private let pages: [UIViewController]
    private let picker = UISegmentedControl(items: ["Innehåll", "Bokmärken", "Markeringar"])
    private var current: UIViewController?

    /// `contents` är bokens innehållsförteckning, `annotations` visar bokmärken eller markeringar efter valet.
    init(contents: UIViewController, annotations: AnnotationsViewController, initial: Int) {
        self.annotations = annotations
        self.pages = [contents, annotations]
        self.initial = initial
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = CGSize(width: 420, height: 640)
    }

    private let annotations: AnnotationsViewController
    private let initial: Int

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        picker.selectedSegmentIndex = min(max(initial, 0), 2)
        picker.addTarget(self, action: #selector(pickerChanged), for: .valueChanged)
        navigationItem.titleView = picker
        show(picker.selectedSegmentIndex)
    }

    @objc private func pickerChanged() {
        show(picker.selectedSegmentIndex)
    }

    /// Väljer flik med kod: 0 innehåll, 1 bokmärken, 2 markeringar.
    func showTab(_ index: Int) {
        picker.selectedSegmentIndex = min(max(index, 0), 2)
        show(picker.selectedSegmentIndex)
    }

    /// Används av självtestet: hur många listor som syns (ska vara en).
    var visibleListCount: Int {
        pages.filter { $0.isViewLoaded && $0.view.superview != nil && !$0.view.isHidden }.count
    }

    private func show(_ index: Int) {
        let target: UIViewController = index == 0 ? pages[0] : annotations
        if index == 1 {
            annotations.kind = .bookmarks
        } else if index == 2 {
            annotations.kind = .highlights
        }
        for page in pages where page.parent !== self {
            addChild(page)
            page.view.frame = view.bounds
            page.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            page.view.backgroundColor = .systemBackground
            view.addSubview(page.view)
            page.didMove(toParent: self)
        }
        for page in pages {
            page.view.isHidden = page !== target
        }
        view.bringSubviewToFront(target.view)
        current = target
        // Innehållsförteckningens egna knappar (som Gå till sida) följer med.
        navigationItem.leftBarButtonItem = index == 0 ? target.navigationItem.leftBarButtonItem : nil
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done,
                                                            target: self,
                                                            action: #selector(doneTapped))
    }

    @objc private func doneTapped() {
        dismiss(animated: true)
    }
}

/// Raden som visas medan man markerar: färgerna, bläddring och Klar.
final class HighlightModeBar: UIView {

    var onColor: ((HighlightColor) -> Void)?
    var onTurn: ((Bool) -> Void)?
    var onDone: (() -> Void)?

    private let background = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    private var colorButtons: [HighlightColor: UIButton] = [:]

    init(color: HighlightColor) {
        super.init(frame: .zero)
        layer.cornerRadius = 22
        layer.masksToBounds = true
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        let label = UILabel()
        label.text = "Dra över texten"
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .secondaryLabel

        let previous = Self.iconButton("chevron.left", label: "Förra sidan")
        previous.addAction(UIAction { [weak self] _ in self?.onTurn?(false) }, for: .touchUpInside)
        let next = Self.iconButton("chevron.right", label: "Nästa sida")
        next.addAction(UIAction { [weak self] _ in self?.onTurn?(true) }, for: .touchUpInside)

        var items: [UIView] = [previous, label]
        for option in HighlightColor.allCases {
            let button = UIButton(type: .system)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.backgroundColor = option.solid
            button.layer.cornerRadius = 13
            button.tintColor = .black
            button.accessibilityLabel = option.title
            button.addAction(UIAction { [weak self] _ in
                self?.markSelected(option)
                self?.onColor?(option)
            }, for: .touchUpInside)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 26),
                button.heightAnchor.constraint(equalToConstant: 26),
            ])
            colorButtons[option] = button
            items.append(button)
        }

        var doneConfiguration = UIButton.Configuration.filled()
        doneConfiguration.title = "Klar"
        doneConfiguration.cornerStyle = .capsule
        let done = UIButton(configuration: doneConfiguration)
        done.addAction(UIAction { [weak self] _ in self?.onDone?() }, for: .touchUpInside)
        items += [next, done]

        let stack = UIStackView(arrangedSubviews: items)
        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            heightAnchor.constraint(equalToConstant: 44),
        ])
        markSelected(color)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    private static func iconButton(_ symbol: String, label: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.accessibilityLabel = label
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }

    private func markSelected(_ selected: HighlightColor) {
        for (color, button) in colorButtons {
            let isSelected = color == selected
            button.setImage(isSelected ? UIImage(systemName: "checkmark",
                                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)) : nil,
                            for: .normal)
            button.layer.borderWidth = isSelected ? 2 : 0
            button.layer.borderColor = UIColor.label.withAlphaComponent(0.6).cgColor
        }
    }
}
