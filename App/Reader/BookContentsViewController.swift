import UIKit

/// Innehållsförteckningen för EPUB och textfiler.
final class BookContentsViewController: UITableViewController {

    struct Entry {
        let title: String
        let level: Int
    }

    var onSelect: ((Int) -> Void)?

    private static let cellID = "entry"
    private let entries: [Entry]
    private let currentRow: Int?
    private let emptyText: String

    init(entries: [Entry], currentRow: Int?, emptyText: String) {
        self.entries = entries
        self.currentRow = currentRow
        self.emptyText = emptyText
        super.init(style: .plain)
        title = "Innehåll"
        preferredContentSize = CGSize(width: 420, height: 640)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done,
                                                            target: self,
                                                            action: #selector(doneTapped))
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.cellID)

        if entries.isEmpty {
            let label = UILabel()
            label.text = emptyText
            label.numberOfLines = 0
            label.textAlignment = .center
            label.textColor = .secondaryLabel
            label.font = .preferredFont(forTextStyle: .body)
            tableView.backgroundView = label
            tableView.separatorStyle = .none
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard let row = currentRow, row < entries.count else { return }
        tableView.layoutIfNeeded()
        tableView.scrollToRow(at: IndexPath(row: row, section: 0), at: .middle, animated: false)
    }

    @objc private func doneTapped() {
        dismiss(animated: true)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        entries.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellID, for: indexPath)
        let entry = entries[indexPath.row]

        var content = UIListContentConfiguration.cell()
        content.text = entry.title
        content.textProperties.numberOfLines = 0
        content.textProperties.font = .preferredFont(forTextStyle: entry.level == 0 ? .headline : .body)
        content.textProperties.color = indexPath.row == currentRow ? (tableView.tintColor ?? .systemBlue) : .label
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10,
                                                                   leading: 16 + CGFloat(min(entry.level, 4)) * 18,
                                                                   bottom: 10,
                                                                   trailing: 16)
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onSelect?(indexPath.row)
    }
}
