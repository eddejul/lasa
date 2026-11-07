import UIKit

/// Sparade ord: varje ord som har slagits upp i en bok, med meningen det stod i. Senast först.
final class SavedWordsViewController: UITableViewController {

    private var words: [SavedWord] = []
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "sv_SE")
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    init() {
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Sparade ord"
        navigationItem.largeTitleDisplayMode = .never
        let review = UIBarButtonItem(title: "Repetera", style: .plain, target: self, action: #selector(reviewTapped))
        navigationItem.rightBarButtonItems = [editButtonItem, review]
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        words = UserWords.shared.savedWords()
        tableView.reloadData()
        updateEmptyState()
    }

    @objc private func reviewTapped() {
        navigationController?.pushViewController(WordReviewViewController(), animated: true)
    }

    private func updateEmptyState() {
        guard words.isEmpty else {
            tableView.backgroundView = nil
            return
        }
        let label = UILabel()
        label.text = "Inga sparade ord än.\nHåll fingret på ett ord i en bok och släpp, så sparas det här."
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .body)
        tableView.backgroundView = label
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        words.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let word = words[indexPath.row]
        var content = UIListContentConfiguration.subtitleCell()
        var title = word.lemma
        if word.language == .english {
            title += " (engelska)"
        }
        content.text = title
        content.textProperties.font = .preferredFont(forTextStyle: .headline)
        var lines: [String] = []
        if !word.sentence.isEmpty, word.sentence != word.word {
            lines.append(word.sentence)
        }
        var place = "\(word.book), s. \(word.pageIndex + 1), \(dateFormatter.string(from: word.date))"
        if word.lookups > 1 {
            place += ", uppslaget \(word.lookups) gånger"
        }
        lines.append(place)
        content.secondaryText = lines.joined(separator: "\n")
        content.secondaryTextProperties.numberOfLines = 4
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let word = words[indexPath.row]
        let lookup = WordDictionary.shared?.lookup(word.lemma,
                                                   sentence: word.sentence,
                                                   language: word.language,
                                                   hidden: UserWords.shared.hiddenPairs)
        let context = WordPopupViewController.Context(sentence: word.sentence, rangeInSentence: nil, book: nil,
                                                      pageIndex: nil, triedWord: word.lemma)
        navigationController?.pushViewController(WordPopupViewController(lookup: lookup, context: context),
                                                 animated: true)
    }

    override func tableView(_ tableView: UITableView,
                            titleForDeleteConfirmationButtonForRowAt indexPath: IndexPath) -> String? {
        "Ta bort"
    }

    override func tableView(_ tableView: UITableView,
                            commit editingStyle: UITableViewCell.EditingStyle,
                            forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        UserWords.shared.delete(savedWordID: words[indexPath.row].id)
        words.remove(at: indexPath.row)
        tableView.deleteRows(at: [indexPath], with: .automatic)
        updateEmptyState()
    }
}
