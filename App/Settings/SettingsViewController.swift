import UIKit

/// Inställningar (fas 6): bläddringsljud, nyckeln till AI-knappen, synken och säkerhetskopian (G1).
/// Hemligheter sparas i nyckelringen, aldrig i filer.
final class SettingsViewController: UITableViewController, UITextFieldDelegate {

    private enum Row {
        case pageSound
        case geminiKey
        case geminiModel
        case geminiTest
        case syncURL
        case syncAnonKey
        case syncEmail
        case syncPassword
        case syncSignIn
        case syncNow
        case syncStatus
        case syncSignOut
        case backupStatus
        case backupNow
        case backupRestore
    }

    private struct Section {
        let title: String?
        let rows: [Row]
        let footer: String?
    }

    private var sections: [Section] = []
    private var password = ""
    private var geminiStatus: String?
    private var syncBusy = false
    private var syncMessage: String?
    private var backupBusy = false
    private var backupMessage: String?

    init() {
        super.init(style: .insetGrouped)
        title = "Inställningar"
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
        NotificationCenter.default.addObserver(self, selector: #selector(syncFinished),
                                               name: SyncEngine.didFinish, object: nil)
        rebuild()
    }

    @objc private func syncFinished() {
        rebuild()
    }

    private func rebuild() {
        let client = SyncClient.shared
        var syncRows: [Row] = [.syncURL, .syncAnonKey, .syncEmail]
        if client.isSignedIn {
            syncRows += [.syncNow, .syncStatus, .syncSignOut]
        } else {
            syncRows += [.syncPassword, .syncSignIn]
        }
        sections = [
            Section(title: "Läsaren", rows: [.pageSound], footer: nil),
            Section(title: "Förklaring med AI", rows: [.geminiKey, .geminiModel, .geminiTest],
                    footer: "Knappen Förklara i meningen i ordrutan använder Google Gemini. En gratis nyckel skapas i "
                        + "Google AI Studio (aistudio.google.com, Get API key). Nyckeln sparas bara i iPadens nyckelring. "
                        + "Meningen och ordet skickas till Google, och på gratisnivån får Google använda det för att "
                        + "förbättra sina tjänster. Utan nyckel syns ingen AI-knapp."),
            Section(title: "Säkerhetskopia", rows: [.backupStatus, .backupNow, .backupRestore],
                    footer: "En kopia sparas varje dag i Filer under \(Self.filesLocation), Säkerhetskopia, och de "
                        + "sju senaste sparas. Den har markeringar, anteckningar, sparade ord och läspositioner. "
                        + "Kopiorna försvinner om appen tas bort, så flytta gärna en till iCloud Drive."),
            Section(title: "Synk med Windows-appen", rows: syncRows,
                    footer: "Läsposition, markeringar, bokmärken och sparade ord synkas via ditt eget Supabase-projekt "
                        + "(gratisnivån). Böckerna känns igen på innehållet, så samma fil måste finnas på båda ställena. "
                        + "Hur projektet skapas står i docs/SYNK.md i repot. Lösenordet sparas inte."),
        ]
        tableView.reloadData()
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
        case .geminiKey:
            return field(indexPath, title: "API-nyckel", text: Keychain.string(.geminiAPIKey) ?? "",
                         placeholder: "Klistra in nyckeln", secure: true, tag: 1)
        case .geminiModel:
            return field(indexPath, title: "Modell", text: GeminiClient.model,
                         placeholder: GeminiClient.defaultModel, secure: false, tag: 2)
        case .syncURL:
            return field(indexPath, title: "Projektets adress", text: SyncClient.shared.projectURL,
                         placeholder: "https://abcd.supabase.co", secure: false, tag: 3, keyboard: .URL)
        case .syncAnonKey:
            return field(indexPath, title: "Publik nyckel", text: SyncClient.shared.anonKey,
                         placeholder: "sb_publishable_…", secure: true, tag: 4)
        case .syncEmail:
            return field(indexPath, title: "E-post", text: SyncClient.shared.email,
                         placeholder: "namn@exempel.se", secure: false, tag: 5, keyboard: .emailAddress)
        case .syncPassword:
            return field(indexPath, title: "Lösenord", text: password, placeholder: "Lösenordet i Supabase",
                         secure: true, tag: 6)
        default:
            break
        }

        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        cell.accessoryView = nil
        cell.accessoryType = .none
        cell.selectionStyle = .default
        var content = UIListContentConfiguration.valueCell()
        switch row {
        case .pageSound:
            content.text = "Bläddringsljud"
            let toggle = UISwitch()
            toggle.isOn = ReaderSettings.pageSound
            toggle.addAction(UIAction { [weak toggle] _ in
                let on = toggle?.isOn ?? false
                ReaderSettings.pageSound = on
                if on {
                    PageTurnSound.shared.play()
                }
            }, for: .valueChanged)
            cell.accessoryView = toggle
            cell.selectionStyle = .none
        case .geminiTest:
            content = UIListContentConfiguration.subtitleCell()
            content.text = "Prova nyckeln"
            content.textProperties.color = view.tintColor
            content.secondaryText = geminiStatus
            content.secondaryTextProperties.numberOfLines = 0
        case .syncSignIn:
            content = UIListContentConfiguration.subtitleCell()
            content.text = syncBusy ? "Loggar in …" : "Logga in"
            content.textProperties.color = view.tintColor
            content.secondaryText = syncMessage
            content.secondaryTextProperties.numberOfLines = 0
        case .syncNow:
            content.text = SyncEngine.shared.isRunning || syncBusy ? "Synkar …" : "Synka nu"
            content.textProperties.color = view.tintColor
        case .syncStatus:
            content = UIListContentConfiguration.subtitleCell()
            content.text = "Inloggad som \(SyncClient.shared.email)"
            var lines: [String] = []
            if let last = SyncEngine.shared.lastSync {
                lines.append("Senast synkad " + AnnotationFormat.date(last))
            }
            if let report = SyncEngine.shared.lastReport {
                lines.append(report.summary)
            }
            if let error = SyncEngine.shared.lastError ?? syncMessage {
                lines.append(error)
            }
            content.secondaryText = lines.isEmpty ? "Inte synkad än." : lines.joined(separator: "\n")
            content.secondaryTextProperties.numberOfLines = 0
            cell.selectionStyle = .none
        case .syncSignOut:
            content.text = "Logga ut"
            content.textProperties.color = .systemRed
        case .backupStatus:
            content = UIListContentConfiguration.subtitleCell()
            content.text = "Senaste kopian"
            if let latest = Backup.copies().first {
                content.secondaryText = Self.backupDate(latest.date)
            } else {
                content.secondaryText = "Ingen kopia än."
            }
            if let message = backupMessage {
                content.secondaryText = (content.secondaryText ?? "") + "\n" + message
            }
            content.secondaryTextProperties.numberOfLines = 0
            cell.selectionStyle = .none
        case .backupNow:
            content.text = backupBusy ? "Sparar …" : "Spara en kopia nu"
            content.textProperties.color = view.tintColor
        case .backupRestore:
            content.text = "Återställ från säkerhetskopia"
            content.textProperties.color = view.tintColor
        default:
            break
        }
        cell.contentConfiguration = content
        return cell
    }

    /// Var appens mapp syns i Filer.
    private static var filesLocation: String {
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        return "På min \(device), \(AppExpiry.appName)"
    }

    static func backupDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "sv_SE")
        formatter.dateFormat = "d MMMM yyyy 'kl.' HH.mm"
        return formatter.string(from: date)
    }

    private func field(_ indexPath: IndexPath, title: String, text: String, placeholder: String, secure: Bool,
                       tag: Int, keyboard: UIKeyboardType = .default) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: FieldCell.id, for: indexPath)
        guard let fieldCell = cell as? FieldCell else { return cell }
        fieldCell.label.text = title
        fieldCell.field.text = text
        fieldCell.field.placeholder = placeholder
        fieldCell.field.isSecureTextEntry = secure
        fieldCell.field.keyboardType = keyboard
        fieldCell.field.tag = tag
        fieldCell.field.delegate = self
        fieldCell.field.accessibilityLabel = title
        return fieldCell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        view.endEditing(true)
        switch sections[indexPath.section].rows[indexPath.row] {
        case .geminiTest:
            testGemini()
        case .syncSignIn:
            signIn()
        case .syncNow:
            syncNow()
        case .syncSignOut:
            SyncClient.shared.signOut()
            syncMessage = nil
            rebuild()
        case .backupNow:
            backupNow()
        case .backupRestore:
            chooseBackup(from: tableView.cellForRow(at: indexPath))
        default:
            break
        }
    }

    // MARK: Säkerhetskopian (G1)

    private func backupNow() {
        guard !backupBusy else { return }
        backupBusy = true
        backupMessage = nil
        rebuild()
        Backup.make { [weak self] result in
            guard let self = self else { return }
            self.backupBusy = false
            if case .failure(let error) = result {
                self.backupMessage = "Kopian kunde inte sparas: \(error.localizedDescription)"
            }
            self.rebuild()
        }
    }

    private func chooseBackup(from cell: UITableViewCell?) {
        let copies = Backup.copies()
        guard !copies.isEmpty else {
            showAlert(title: "Ingen säkerhetskopia", message: "Det finns ingen kopia att återställa från än.")
            return
        }
        let sheet = UIAlertController(title: "Återställ från säkerhetskopia",
                                      message: "Välj vilken kopia du vill gå tillbaka till.",
                                      preferredStyle: .actionSheet)
        for copy in copies {
            sheet.addAction(UIAlertAction(title: Self.backupDate(copy.date), style: .default) { [weak self] _ in
                self?.confirmRestore(copy)
            })
        }
        sheet.addAction(UIAlertAction(title: "Avbryt", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = cell ?? view
            popover.sourceRect = cell?.bounds ?? CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        }
        present(sheet, animated: true)
    }

    private func confirmRestore(_ copy: Backup.Copy) {
        let alert = UIAlertController(
            title: "Återställ från \(Self.backupDate(copy.date))?",
            message: "Markeringar, anteckningar, sparade ord och läspositioner ersätts med kopians. Det du har nu "
                + "sparas först som en ny kopia, så att du kan gå tillbaka.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Avbryt", style: .cancel))
        alert.addAction(UIAlertAction(title: "Återställ", style: .destructive) { [weak self] _ in
            self?.restore(copy)
        })
        present(alert, animated: true)
    }

    private func restore(_ copy: Backup.Copy) {
        do {
            try Backup.restore(copy)
            backupMessage = "Återställt från \(Self.backupDate(copy.date))."
            rebuild()
        } catch {
            showAlert(title: "Kunde inte återställa", message: error.localizedDescription)
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: Fälten

    func textFieldDidEndEditing(_ textField: UITextField) {
        let text = textField.text ?? ""
        switch textField.tag {
        case 1:
            Keychain.set(text, for: .geminiAPIKey)
            geminiStatus = nil
        case 2:
            GeminiClient.model = text
        case 3:
            SyncClient.shared.projectURL = text
        case 4:
            SyncClient.shared.anonKey = text
        case 5:
            SyncClient.shared.email = text
        case 6:
            password = text
        default:
            break
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    // MARK: Knapparna

    private func testGemini() {
        guard let key = Keychain.string(.geminiAPIKey) else {
            geminiStatus = "Skriv in en nyckel först."
            rebuild()
            return
        }
        geminiStatus = "Frågar Gemini …"
        rebuild()
        GeminiClient.test(key: key) { [weak self] result in
            switch result {
            case .success:
                self?.geminiStatus = "Nyckeln fungerar med \(GeminiClient.model)."
            case .failure(let error):
                self?.geminiStatus = error.localizedDescription
            }
            self?.rebuild()
        }
    }

    private func signIn() {
        let client = SyncClient.shared
        guard client.isConfigured else {
            syncMessage = SyncClient.Failure.notConfigured.errorDescription
            rebuild()
            return
        }
        guard !client.email.isEmpty, !password.isEmpty else {
            syncMessage = "Fyll i e-post och lösenord."
            rebuild()
            return
        }
        syncBusy = true
        syncMessage = nil
        rebuild()
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                try await client.signIn(email: client.email, password: self.password)
                self.password = ""
                self.syncBusy = false
                self.syncMessage = nil
                self.rebuild()
                try await SyncEngine.shared.sync()
            } catch {
                self.syncBusy = false
                self.syncMessage = error.localizedDescription
                self.rebuild()
            }
        }
    }

    private func syncNow() {
        guard !syncBusy else { return }
        syncBusy = true
        syncMessage = nil
        rebuild()
        Task { @MainActor [weak self] in
            do {
                try await SyncEngine.shared.sync()
                self?.syncMessage = nil
            } catch {
                self?.syncMessage = error.localizedDescription
            }
            self?.syncBusy = false
            self?.rebuild()
        }
    }
}

/// En rad med en rubrik och ett textfält.
final class FieldCell: UITableViewCell {

    static let id = "field"
    let label = UILabel()
    let field = UITextField()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        label.font = .preferredFont(forTextStyle: .body)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        field.font = .preferredFont(forTextStyle: .body)
        field.textAlignment = .right
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.clearButtonMode = .whileEditing
        field.returnKeyType = .done
        let stack = UIStackView(arrangedSubviews: [label, field])
        stack.axis = .horizontal
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 11),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -11),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }
}
