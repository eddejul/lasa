import PDFKit
import UIKit

/// Innehållsförteckningen, byggd av PDF:ens bokmärken (outline).
final class OutlineViewController: UITableViewController {

    struct Entry {
        let title: String
        let level: Int
        let pageIndex: Int?
        let pageLabel: String?
    }

    var onSelectPage: ((Int) -> Void)?
    var onGoToPage: (() -> Void)?

    private static let cellID = "entry"
    private static let maxEntries = 3000

    private let entries: [Entry]
    private let currentIndex: Int

    init(document: PDFDocument, currentIndex: Int) {
        self.entries = OutlineViewController.entries(in: document)
        self.currentIndex = currentIndex
        super.init(style: .plain)
        title = "Innehåll"
        preferredContentSize = CGSize(width: 420, height: 640)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Gå till sida",
                                                           style: .plain,
                                                           target: self,
                                                           action: #selector(goToPageTapped))
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done,
                                                            target: self,
                                                            action: #selector(doneTapped))
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.cellID)

        if entries.isEmpty {
            let label = UILabel()
            label.text = "Den här PDF:en har ingen innehållsförteckning.\nTryck på Gå till sida för att hoppa till ett sidnummer."
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
        guard let row = currentRow else { return }
        tableView.layoutIfNeeded()
        tableView.scrollToRow(at: IndexPath(row: row, section: 0), at: .middle, animated: false)
    }

    /// Avsnittet man läser i nu: det sista som börjar på eller före den aktuella sidan.
    private var currentRow: Int? {
        entries.indices.last { index in
            guard let page = entries[index].pageIndex else { return false }
            return page <= currentIndex
        }
    }

    @objc private func goToPageTapped() {
        onGoToPage?()
    }

    @objc private func doneTapped() {
        dismiss(animated: true)
    }

    // MARK: Tabellen

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        entries.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellID, for: indexPath)
        let entry = entries[indexPath.row]
        let isCurrent = indexPath.row == currentRow
        let accent: UIColor = tableView.tintColor ?? .systemBlue

        var content = UIListContentConfiguration.valueCell()
        content.text = entry.title
        content.secondaryText = entry.pageLabel
        content.textProperties.numberOfLines = 0
        content.textProperties.font = .preferredFont(forTextStyle: entry.level == 0 ? .headline : .body)
        if isCurrent {
            content.textProperties.color = accent
        } else {
            content.textProperties.color = entry.pageIndex == nil ? .secondaryLabel : .label
        }
        content.secondaryTextProperties.color = .secondaryLabel
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10,
                                                                   leading: 16 + CGFloat(min(entry.level, 4)) * 18,
                                                                   bottom: 10,
                                                                   trailing: 16)
        cell.contentConfiguration = content
        cell.selectionStyle = entry.pageIndex == nil ? .none : .default
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let index = entries[indexPath.row].pageIndex else { return }
        onSelectPage?(index)
    }

    // MARK: Bokmärkena i PDF:en

    private static func entries(in document: PDFDocument) -> [Entry] {
        guard let root = document.outlineRoot else { return [] }
        var result: [Entry] = []

        func visit(_ outline: PDFOutline, level: Int) {
            for childIndex in 0..<outline.numberOfChildren {
                guard result.count < maxEntries, let child = outline.child(at: childIndex) else { continue }

                let page = child.destination?.page ?? (child.action as? PDFActionGoTo)?.destination.page
                var pageIndex: Int?
                if let page = page {
                    let index = document.index(for: page)
                    if index >= 0, index < document.pageCount {
                        pageIndex = index
                    }
                }
                let title = (child.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    let label = pageIndex.map { index in
                        document.page(at: index)?.label ?? String(index + 1)
                    }
                    result.append(Entry(title: title, level: level, pageIndex: pageIndex, pageLabel: label))
                }
                visit(child, level: level + 1)
            }
        }

        visit(root, level: 0)
        return result
    }
}
