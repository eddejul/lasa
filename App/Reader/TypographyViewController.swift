import UIKit

/// Textstorlek och typsnitt för EPUB och textfiler. Ändringar syns direkt i boken.
final class TypographyViewController: UITableViewController {

    var onChange: ((ReaderTypography) -> Void)?
    /// Mätvärden från läsaren (hur snabbt sidorna görs), visas längst ner.
    var diagnostics: (() -> String?)?

    private var typography: ReaderTypography
    private let fonts = ReaderTypography.Font.allCases
    private let sizeLabel = UILabel()
    private let smallerButton = UIButton(type: .system)
    private let largerButton = UIButton(type: .system)
    private lazy var sizeCell = makeSizeCell()

    init(typography: ReaderTypography) {
        self.typography = typography
        super.init(style: .insetGrouped)
        title = "Text"
        preferredContentSize = CGSize(width: 340, height: 560)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done,
                                                            target: self,
                                                            action: #selector(doneTapped))
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "font")
        updateSizeControls()
    }

    @objc private func doneTapped() {
        dismiss(animated: true)
    }

    // MARK: Storlek

    private func makeSizeCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none

        smallerButton.setTitle("A", for: .normal)
        smallerButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        smallerButton.accessibilityLabel = "Mindre text"
        smallerButton.addTarget(self, action: #selector(smallerTapped), for: .touchUpInside)

        largerButton.setTitle("A", for: .normal)
        largerButton.titleLabel?.font = .systemFont(ofSize: 26, weight: .medium)
        largerButton.accessibilityLabel = "Större text"
        largerButton.addTarget(self, action: #selector(largerTapped), for: .touchUpInside)

        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        sizeLabel.textColor = .secondaryLabel
        sizeLabel.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [smallerButton, sizeLabel, largerButton])
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -4),
            stack.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
        ])
        return cell
    }

    private func updateSizeControls() {
        sizeLabel.text = "\(Int((typography.scale * 100).rounded())) %"
        smallerButton.isEnabled = typography.canShrink
        largerButton.isEnabled = typography.canGrow
    }

    @objc private func smallerTapped() {
        guard typography.canShrink else { return }
        typography.sizeIndex -= 1
        updateSizeControls()
        onChange?(typography)
    }

    @objc private func largerTapped() {
        guard typography.canGrow else { return }
        typography.sizeIndex += 1
        updateSizeControls()
        onChange?(typography)
    }

    // MARK: Tabellen

    override func numberOfSections(in tableView: UITableView) -> Int {
        2
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 1 : fonts.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "Storlek" : "Typsnitt"
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == 1 else { return nil }
        var text = "Gäller EPUB och textfiler. Bokens eget betyder typsnittet som boken själv anger."
        if let details = diagnostics?() {
            text += "\n\n" + details
        }
        return text
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            return sizeCell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: "font", for: indexPath)
        let font = fonts[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = font.title
        content.textProperties.font = font.previewFont(size: 17)
        cell.contentConfiguration = content
        cell.accessoryType = font == typography.font ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 1 else { return }
        let font = fonts[indexPath.row]
        guard font != typography.font else { return }
        typography.font = font
        tableView.reloadSections(IndexSet(integer: 1), with: .none)
        onChange?(typography)
    }
}
