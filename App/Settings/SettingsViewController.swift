import UIKit

/// Inställningar (fas 6): bläddringsljud, Förklaring med AI (raden öppnar guiden för nyckeln, U7), synken,
/// säkerhetskopian (G1) och loggen (G4).
/// Hemligheter sparas i nyckelringen, aldrig i filer.
final class SettingsViewController: UITableViewController, UITextFieldDelegate {

    private enum Row {
        case followSystem
        case pageSound
        case aiStatus
        case syncURL
        case syncAnonKey
        case syncEmail
        case syncPassword
        case syncSignIn
        case syncNow
        case syncPaused
        case syncResume
        case syncStatus
        case syncSignOut
        case backupStatus
        case backupNow
        case backupRestore
        case shareLog
    }

    private struct Section {
        let title: String?
        let rows: [Row]
        let footer: String?
    }

    private var sections: [Section] = []
    private var password = ""
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

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Theme.style(tableView)
        // Raden Förklaring med AI visar läget efter guiden (U7).
        rebuild()
    }

    @objc private func syncFinished() {
        rebuild()
    }

    private func rebuild() {
        let client = SyncClient.shared
        var syncRows: [Row] = [.syncURL, .syncAnonKey, .syncEmail]
        let paused = SyncEngine.shared.isPaused
        if paused {
            syncRows += [.syncPaused, .syncResume]
        }
        if client.isSignedIn {
            syncRows += (paused ? [] : [.syncNow]) + [.syncStatus, .syncSignOut]
        } else {
            syncRows += [.syncPassword, .syncSignIn]
        }
        sections = [
            Section(title: "Utseende och läsaren", rows: [.followSystem, .pageSound],
                    footer: "Med Följ systemet blir appen mörk när iPaden är i mörkt läge och har annars "
                        + "bakgrunden du valt i läsaren. Väljer du en bakgrund i läsaren stängs Följ systemet av."),
            Section(title: "Förklaring med AI", rows: [.aiStatus],
                    footer: "Förklara i meningen i ordrutan och Förklara i markeringsraden använder Google Gemini på "
                        + "gratisnivån. Tryck på raden för att skapa och klistra in en gratis nyckel, steg för steg. "
                        + "Bara det du trycker på skickas till Google, och på gratisnivån får Google använda det för "
                        + "att förbättra sina tjänster."),
            Section(title: "Säkerhetskopia", rows: [.backupStatus, .backupNow, .backupRestore],
                    footer: "En kopia sparas varje dag i Filer under \(Self.filesLocation), Säkerhetskopia, och de "
                        + "sju senaste dagarna sparas. Dagens kopior sparas alla, också de du gör själv. Kopian från "
                        + "före en uppdatering (Före uppdateringen) sparas alltid. Den har markeringar, anteckningar, "
                        + "sparade ord och läspositioner. "
                        + "Kopiorna försvinner om appen tas bort, så flytta gärna en till iCloud Drive."),
            Section(title: "Synk med Windows-appen", rows: syncRows,
                    footer: "Läsposition, markeringar, bokmärken och sparade ord synkas via ditt eget Supabase-projekt "
                        + "(gratisnivån). Böckerna känns igen på innehållet, så samma fil måste finnas på båda ställena. "
                        + "Hur projektet skapas står i docs/SYNK.md i repot. Lösenordet sparas inte."),
            Section(title: "Diagnostik", rows: [.shareLog],
                    footer: "Appen skriver en logg i Filer under \(Self.filesLocation), Diagnostik: starter, tider för "
                        + "sidor, minnesvarningar och fel. Den har boktitlar men ingen text ur böckerna. Dela den när "
                        + "något har krånglat."),
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
        case .followSystem:
            content.text = "Följ systemet"
            let toggle = UISwitch()
            toggle.isOn = ReaderTheme.followsSystem
            toggle.addAction(UIAction { [weak self, weak toggle] _ in
                ReaderTheme.followsSystem = toggle?.isOn ?? false
                Theme.apply()
                if let table = self?.tableView {
                    Theme.style(table)
                }
            }, for: .valueChanged)
            cell.accessoryView = toggle
            cell.selectionStyle = .none
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
        case .aiStatus:
            content = UIListContentConfiguration.subtitleCell()
            content.text = "Förklaring med AI"
            let status = AIClient.keyStatus
            let palette = Theme.current
            switch status {
            case .notSet:
                content.secondaryText = "Inte uppsatt. Tryck för att komma igång."
                content.secondaryTextProperties.color = palette.inkSoft
                content.image = UIImage(systemName: "circle")
                content.imageProperties.tintColor = palette.inkFaint
            case .untested:
                content.secondaryText = "Nyckeln är sparad men inte provad. Tryck för att prova den."
                content.secondaryTextProperties.color = palette.warning
                content.image = UIImage(systemName: "circle.dashed")
                content.imageProperties.tintColor = palette.warning
            case .working:
                let calls = AIClient.callsToday
                content.secondaryText = "Fungerar. \(calls) anrop till Gemini i dag."
                content.secondaryTextProperties.color = palette.success
                content.image = UIImage(systemName: "checkmark.circle.fill")
                content.imageProperties.tintColor = palette.success
            case .failing(let message):
                content.secondaryText = "Fel. " + message
                content.secondaryTextProperties.color = .systemRed
                content.image = UIImage(systemName: "exclamationmark.circle.fill")
                content.imageProperties.tintColor = .systemRed
            }
            content.secondaryTextProperties.numberOfLines = 0
            cell.accessoryType = .disclosureIndicator
        case .syncSignIn:
            content = UIListContentConfiguration.subtitleCell()
            content.text = syncBusy ? "Loggar in …" : "Logga in"
            content.textProperties.color = view.tintColor
            content.secondaryText = syncMessage
            content.secondaryTextProperties.numberOfLines = 0
        case .syncNow:
            content.text = SyncEngine.shared.isRunning || syncBusy ? "Synkar …" : "Synka nu"
            content.textProperties.color = view.tintColor
        case .syncPaused:
            content = UIListContentConfiguration.subtitleCell()
            content.text = "Synken är pausad"
            content.textProperties.color = Theme.current.warning
            content.secondaryText = "Den pausades när du återställde från en säkerhetskopia, så att servern inte tar "
                + "tillbaka det du ångrade. Den startar inte av sig själv, inte heller när appen startas om."
            content.secondaryTextProperties.numberOfLines = 0
            cell.selectionStyle = .none
        case .syncResume:
            content.text = "Starta synken igen"
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
            if let latest = Backup.dailyCopies().first {
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
        case .shareLog:
            content.text = "Dela loggen"
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
        case .aiStatus:
            navigationController?.pushViewController(AIKeyGuideViewController(), animated: true)
        case .syncSignIn:
            signIn()
        case .syncNow:
            syncNow()
        case .syncResume:
            confirmResumeSync()
        case .syncSignOut:
            SyncClient.shared.signOut()
            syncMessage = nil
            rebuild()
        case .backupNow:
            backupNow()
        case .backupRestore:
            chooseBackup(from: tableView.cellForRow(at: indexPath))
        case .shareLog:
            shareLog(from: tableView.cellForRow(at: indexPath))
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
            sheet.addAction(UIAlertAction(title: Self.backupTitle(copy), style: .default) { [weak self] _ in
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

    /// Kopians namn i listan: Före uppdateringen (före flytten till bokens id), Din kopia (Spara en kopia nu)
    /// och Före återställningen.
    static func backupTitle(_ copy: Backup.Copy) -> String {
        if copy.isBeforeUpdate {
            return "Före uppdateringen, \(backupDate(copy.date))"
        }
        switch copy.kind {
        case .automatic: return backupDate(copy.date)
        case .manual: return "Din kopia, \(backupDate(copy.date))"
        case .beforeRestore: return "Före återställningen, \(backupDate(copy.date))"
        }
    }

    /// Starta synken igen efter pausen (granskning 2, fynd 3), med vad som då händer.
    private func confirmResumeSync() {
        let alert = UIAlertController(
            title: "Starta synken igen?",
            message: "Ändringar som är nyare än säkerhetskopian hämtas från servern, också markeringar som tagits bort "
                + "på datorn. Det du har på iPaden nu skickas till servern.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Avbryt", style: .cancel))
        alert.addAction(UIAlertAction(title: "Starta synken", style: .default) { [weak self] _ in
            SyncEngine.shared.resume()
            self?.rebuild()
            self?.syncNow()
        })
        present(alert, animated: true)
    }

    private func confirmRestore(_ copy: Backup.Copy) {
        var message = "Markeringar, anteckningar, sparade ord och läspositioner ersätts med kopians. Det du har nu "
            + "sparas först som en ny kopia, så att du kan gå tillbaka."
        if SyncClient.shared.isSignedIn {
            // Granskning 2, fynd 3: synken skulle annars ta tillbaka nyare ändringar från servern.
            message += " Synken pausas efter återställningen och startar inte av sig själv, inte heller när appen "
                + "startas om. Du startar den igen under Synk med Windows-appen, och då hämtas ändringar som är "
                + "nyare än kopian från servern."
        }
        let alert = UIAlertController(
            title: "Återställ från \(Self.backupTitle(copy))?",
            message: message,
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
            if SyncClient.shared.isSignedIn {
                SyncEngine.shared.pauseAfterRestore()
            }
            backupMessage = "Återställt från \(Self.backupTitle(copy))."
            rebuild()
        } catch {
            showAlert(title: "Kunde inte återställa", message: error.localizedDescription)
        }
    }

    // MARK: Loggen (G4)

    private func shareLog(from cell: UITableViewCell?) {
        let files = AppLog.shared.shareableFiles + DiagnosticReports.files()
        guard !files.isEmpty else {
            showAlert(title: "Ingen logg än", message: "Loggen skrivs när appen används.")
            return
        }
        let share = UIActivityViewController(activityItems: files, applicationActivities: nil)
        if let popover = share.popoverPresentationController {
            popover.sourceView = cell ?? view
            popover.sourceRect = cell?.bounds ?? CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        }
        present(share, animated: true)
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
