import SafariServices
import UIKit

/// Steg för steg till AI-nyckeln (U7): öppna Google AI Studio, skapa en nyckel, tryck Klistra in. Appen provar
/// nyckeln med ett billigt anrop (frågar efter modellen, drar inte av kvoten för svar) och visar en grön bock
/// eller vad som är fel. Nyckeln sparas i nyckelringen, som förut. Öppnas från raden Förklaring med AI i
/// Inställningar och från rutan Förklaring när nyckeln saknas.
final class AIKeyGuideViewController: UITableViewController, UITextFieldDelegate {

    /// AI Studios sida för API-nycklar.
    static let keysURL = URL(string: "https://aistudio.google.com/app/apikey")!

    /// Anropas när en nyckel just har provats och fungerar.
    var onWorking: (() -> Void)?

    private enum Row {
        case openStudio
        case paste
        case typed
        case status
        case retest
        case remove
        case model
        case usage
    }

    private struct Section {
        let title: String?
        let rows: [Row]
        let footer: String?
    }

    private var sections: [Section] = []
    private var busy = false
    /// Utfallet av det senaste provet i guiden. Nil innan något provats här.
    private var result: Result<Void, AIClient.Failure>?
    /// Till självtestet.
    private(set) var statusText = ""

    init() {
        super.init(style: .insetGrouped)
        title = "Förklaring med AI"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        tableView.register(FieldCell.self, forCellReuseIdentifier: FieldCell.id)
        tableView.keyboardDismissMode = .onDrag
        rebuild()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Theme.style(tableView)
        rebuild()
    }

    private func rebuild() {
        var keyRows: [Row] = [.paste, .typed, .status]
        if AIClient.hasKey {
            keyRows += [.retest, .remove]
        }
        sections = [
            Section(title: "1. Skapa en nyckel", rows: [.openStudio],
                    footer: "Logga in med ditt Google-konto och tryck Create API key (Skapa API-nyckel). Kopiera "
                        + "nyckeln. Den är gratis och kräver inget kort."),
            Section(title: "2. Klistra in den här", rows: keyRows,
                    footer: "Appen provar nyckeln direkt. Den sparas bara i iPadens nyckelring."),
            Section(title: "Modell", rows: [.model, .usage],
                    footer: "Förklara i ordrutan och Förklara i markeringsraden använder Google Gemini på gratisnivån. "
                        + "Bara det du trycker på skickas: ordet och meningen, eller stycket med bokens titel och "
                        + "kapitlet. På gratisnivån får Google använda det för att förbättra sina tjänster. Hur mycket "
                        + "som ingår per dag syns i Google AI Studio. Svar som redan hämtats sparas och hämtas aldrig "
                        + "igen."),
        ]
        statusText = status.text
        tableView.reloadData()
    }

    // MARK: Läget

    private var status: (text: String, detail: String?, color: UIColor, symbol: String?) {
        let palette = Theme.current
        if busy {
            return ("Provar nyckeln …", nil, palette.inkSoft, nil)
        }
        if let result = result {
            switch result {
            case .success:
                return ("Nyckeln fungerar", "Modell \(GeminiClient.model).", palette.success, "checkmark.circle.fill")
            case .failure(let failure):
                let saved = AIClient.hasKey && failure != .badKey
                return (failure.needsSetup ? "Det blev fel" : "Kunde inte prova nyckeln",
                        (failure.errorDescription ?? "") + (saved && !failure.needsSetup ? " Nyckeln är sparad." : ""),
                        failure.needsSetup ? UIColor.systemRed : palette.warning, "exclamationmark.circle.fill")
            }
        }
        switch AIClient.keyStatus {
        case .notSet:
            return ("Ingen nyckel än", nil, palette.inkSoft, nil)
        case .untested:
            return ("Nyckeln är sparad men inte provad", nil, palette.inkSoft, nil)
        case .working:
            return ("Nyckeln fungerar", "Modell \(GeminiClient.model).", palette.success, "checkmark.circle.fill")
        case .failing(let message):
            return ("Det blev fel", message, UIColor.systemRed, "exclamationmark.circle.fill")
        }
    }

    // MARK: Tabellen

    override func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].rows.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].title
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        sections[section].footer
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = sections[indexPath.section].rows[indexPath.row]
        switch row {
        case .typed:
            return field(indexPath, title: "Eller skriv in den", text: "", placeholder: "AIza…", secure: true, tag: 1)
        case .model:
            return field(indexPath, title: "Modell", text: GeminiClient.model,
                         placeholder: GeminiClient.defaultModel, secure: false, tag: 2)
        default:
            break
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        cell.accessoryView = nil
        cell.accessoryType = .none
        cell.selectionStyle = .default
        var content = UIListContentConfiguration.valueCell()
        let tint = view.tintColor ?? Theme.current.accent
        switch row {
        case .openStudio:
            content = UIListContentConfiguration.subtitleCell()
            content.text = "Öppna Google AI Studio"
            content.textProperties.color = tint
            content.secondaryText = "aistudio.google.com, API keys"
            content.image = UIImage(systemName: "safari")
            cell.accessoryType = .disclosureIndicator
        case .paste:
            content.text = "Klistra in nyckeln"
            content.textProperties.color = tint
            content.image = UIImage(systemName: "doc.on.clipboard")
        case .status:
            let current = status
            content = UIListContentConfiguration.subtitleCell()
            content.text = current.text
            content.textProperties.color = current.color
            content.textProperties.font = .preferredFont(forTextStyle: .headline)
            content.secondaryText = current.detail
            content.secondaryTextProperties.numberOfLines = 0
            if let symbol = current.symbol {
                content.image = UIImage(systemName: symbol)
                content.imageProperties.tintColor = current.color
            }
            if busy {
                let spinner = UIActivityIndicatorView(style: .medium)
                spinner.startAnimating()
                cell.accessoryView = spinner
            }
            cell.selectionStyle = .none
        case .retest:
            content.text = "Prova igen"
            content.textProperties.color = tint
        case .remove:
            content.text = "Ta bort nyckeln"
            content.textProperties.color = .systemRed
        case .usage:
            content.text = "Anrop i dag"
            content.secondaryText = "\(AIClient.callsToday)"
            cell.selectionStyle = .none
        default:
            break
        }
        cell.contentConfiguration = content
        return cell
    }

    private func field(_ indexPath: IndexPath, title: String, text: String, placeholder: String, secure: Bool,
                       tag: Int) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: FieldCell.id, for: indexPath)
        guard let fieldCell = cell as? FieldCell else { return cell }
        fieldCell.label.text = title
        fieldCell.field.text = text
        fieldCell.field.placeholder = placeholder
        fieldCell.field.isSecureTextEntry = secure
        fieldCell.field.keyboardType = .default
        fieldCell.field.tag = tag
        fieldCell.field.delegate = self
        fieldCell.field.accessibilityLabel = title
        return fieldCell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        view.endEditing(true)
        switch sections[indexPath.section].rows[indexPath.row] {
        case .openStudio:
            openStudio()
        case .paste:
            pasteKey()
        case .retest:
            if let key = Keychain.string(.geminiAPIKey) {
                test(key, saving: false)
            }
        case .remove:
            confirmRemove(from: tableView.cellForRow(at: indexPath))
        default:
            break
        }
    }

    // MARK: Fälten

    func textFieldDidEndEditing(_ textField: UITextField) {
        let text = (textField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch textField.tag {
        case 1:
            if !text.isEmpty {
                textField.text = ""
                test(text, saving: true)
            }
        case 2:
            if text != GeminiClient.model {
                GeminiClient.model = text
                AIClient.resetKeyStatus()
                result = nil
                rebuild()
            }
        default:
            break
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    // MARK: Stegen

    private func openStudio() {
        let safari = SFSafariViewController(url: Self.keysURL)
        safari.modalPresentationStyle = .pageSheet
        present(safari, animated: true)
    }

    /// Läser nyckeln ur urklippet. En nyckel är ett ord utan mellanslag, oftast 39 tecken som börjar med AIza.
    private func pasteKey() {
        let text = (UIPasteboard.general.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key = Self.keyCandidate(text) else {
            result = .failure(.noKey)
            rebuild()
            showAlert(title: "Ingen nyckel i urklippet",
                      message: "Kopiera nyckeln i Google AI Studio först (knappen bredvid nyckeln), och tryck sedan "
                        + "Klistra in nyckeln igen.")
            return
        }
        test(key, saving: true)
    }

    /// Texten som nyckel, eller nil om den inte kan vara en (tom, med mellanslag eller för kort).
    static func keyCandidate(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20, trimmed.count <= 200,
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        return trimmed
    }

    /// Provar nyckeln. En ny nyckel sparas om Google godkänner den, eller om provet inte kunde göras (inget
    /// nät, kvoten), men inte om Google säger att den är fel. Då ligger den gamla kvar.
    func test(_ key: String, saving: Bool) {
        guard !busy else { return }
        busy = true
        result = nil
        rebuild()
        AIClient.testKey(key) { [weak self] outcome in
            guard let self = self else { return }
            self.busy = false
            self.result = outcome
            let rejected: Bool
            if case .failure(let failure) = outcome, failure.needsSetup {
                rejected = true
            } else {
                rejected = false
            }
            var stored = !saving
            if saving, !rejected || failureOf(outcome) == .unknownModel(GeminiClient.model) {
                // Fel modell säger inget om nyckeln: den sparas, och modellen rättas nedanför.
                Keychain.set(key, for: .geminiAPIKey)
                // En ny nyckel ärver inte den gamlas läge: utan svar från Google är den inte provad.
                AIClient.resetKeyStatus()
                stored = true
            }
            if stored {
                AIClient.noteKey(outcome)
            }
            self.rebuild()
            SelfTest.log("U7 guiden: \(self.statusText). \(self.status.detail ?? "") Sparad: \(stored)")
            if case .success = outcome {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                self.onWorking?()
            }
        }
    }

    private func confirmRemove(from cell: UITableViewCell?) {
        let alert = UIAlertController(title: "Ta bort nyckeln?",
                                      message: "Förklara slutar fungera tills du klistrar in en nyckel igen. Sparade "
                                        + "förklaringar finns kvar som anteckningar.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Avbryt", style: .cancel))
        alert.addAction(UIAlertAction(title: "Ta bort", style: .destructive) { [weak self] _ in
            Keychain.set(nil, for: .geminiAPIKey)
            AIClient.resetKeyStatus()
            self?.result = nil
            self?.rebuild()
        })
        present(alert, animated: true)
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

/// Felet i ett utfall, eller nil.
private func failureOf(_ outcome: Result<Void, AIClient.Failure>) -> AIClient.Failure? {
    if case .failure(let failure) = outcome {
        return failure
    }
    return nil
}
