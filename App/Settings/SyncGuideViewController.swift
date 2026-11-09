import UIKit
import UniformTypeIdentifiers

/// Synkens läge i ord och färg, samma i biblioteket (G9) och i Inställningar (U7).
enum SyncStatusText {

    struct Line {
        let title: String
        let detail: String?
        let color: UIColor
        let symbol: String
        /// Sant när något inte fungerar (orange i biblioteket).
        let isProblem: Bool
    }

    @MainActor
    static func line(_ status: SyncEngine.Status, palette given: Palette? = nil) -> Line {
        let palette = given ?? Theme.current
        switch status {
        case .off:
            return Line(title: "Inte uppsatt", detail: "Tryck för att välja en mapp i iCloud Drive.",
                        color: palette.inkSoft, symbol: "circle", isProblem: false)
        case .paused:
            return Line(title: "Synken är pausad", detail: "Den pausades när du återställde från en säkerhetskopia. "
                            + "Tryck för att starta den igen.",
                        color: palette.warning, symbol: "pause.circle.fill", isProblem: true)
        case .running:
            return Line(title: "Synkar …", detail: nil, color: palette.inkSoft, symbol: "arrow.triangle.2.circlepath",
                        isProblem: false)
        case .ok(let date):
            return Line(title: date.map { "Synkat " + time($0) } ?? "Mappen är vald, inte synkad än",
                        detail: SyncFolder.shared.name.isEmpty ? nil : "Mappen \(SyncFolder.shared.name) i iCloud Drive",
                        color: palette.success, symbol: "checkmark.circle.fill", isProblem: false)
        case .failing(let message):
            return Line(title: "Synken fungerar inte", detail: message + " Tryck för detaljer.",
                        color: palette.warning, symbol: "exclamationmark.triangle.fill", isProblem: true)
        }
    }

    /// "kl. 14.02" i dag, "i går kl. 14.02", annars "8 nov. kl. 14.02".
    static func time(_ date: Date, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "sv_SE")
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "'kl.' HH.mm"
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                  calendar.isDate(date, inSameDayAs: yesterday) {
            formatter.dateFormat = "'i går kl.' HH.mm"
        } else {
            formatter.dateFormat = "d MMM 'kl.' HH.mm"
        }
        return formatter.string(from: date)
    }
}

/// Steg för steg till synken (U7, F1): välj en mapp i iCloud Drive, appen provar att skriva och läsa där och
/// visar en grön bock eller vad som är fel. Här syns också de andra enheterna, Synka nu, pausen efter en
/// återställning och Sluta synka. Öppnas från raden Synk i Inställningar och från raden i biblioteket.
final class SyncGuideViewController: UITableViewController, UIDocumentPickerDelegate {

    private enum Row {
        case choose
        case status
        case syncNow
        case peer(Int)
        case noPeers
        case skipped(Int)
        case paused
        case resume
        case forget
    }

    private struct Section {
        let title: String?
        let rows: [Row]
        let footer: String?
    }

    private var sections: [Section] = []
    private var busy = false
    /// Utfallet av provet i mappen. Nil innan något provats här.
    private var probeResult: String??
    private var message: String?
    /// Till självtestet.
    private(set) var statusText = ""

    init() {
        super.init(style: .insetGrouped)
        title = "Synk"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: SyncEngine.didFinish, object: nil)
        rebuild()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Theme.style(tableView)
        SyncFolder.shared.refresh()
        rebuild()
    }

    @objc private func changed() {
        rebuild()
    }

    private func rebuild() {
        let engine = SyncEngine.shared
        let chosen = SyncFolder.shared.isChosen
        var sections: [Section] = [
            Section(title: "1. Välj mappen i iCloud Drive", rows: [.choose],
                    footer: "Skapa gärna en mapp som heter Sensus i iCloud Drive först, i appen Filer. Sensus lägger en "
                        + "undermapp, Sensus synk, där med en liten fil per enhet. Böcker du lägger i mappen syns i "
                        + "biblioteket och finns då på alla dina enheter."),
        ]
        if chosen {
            var statusRows: [Row] = [.status]
            if !engine.isPaused {
                statusRows.append(.syncNow)
            }
            sections.append(Section(title: "2. Provet", rows: statusRows,
                                    footer: "Sensus provar att skriva en fil i mappen och läsa den igen. Synken går av "
                                        + "sig själv när appen öppnas och när du stänger en bok."))
            if engine.isPaused {
                sections.append(Section(title: "Pausad", rows: [.paused, .resume], footer: nil))
            }
            var peerRows: [Row] = engine.peers.indices.map { Row.peer($0) }
            if peerRows.isEmpty {
                peerRows = [.noPeers]
            }
            peerRows += engine.skippedFiles.indices.map { Row.skipped($0) }
            sections.append(Section(title: "Andra enheter", rows: peerRows,
                                    footer: "På datorn: installera iCloud för Windows och välj samma mapp i Sensus för "
                                        + "Windows, under Inställningar, Synk. Läsposition, markeringar, bokmärken och "
                                        + "sparade ord följer med. Den nyaste ändringen vinner, och inget tas bort för att "
                                        + "en fil saknas eller inte går att läsa."))
            sections.append(Section(title: nil, rows: [.forget],
                                    footer: "Inget tas bort, varken i mappen eller i appen."))
        }
        self.sections = sections
        statusText = status.title
        tableView.reloadData()
    }

    // MARK: Läget

    private var status: (title: String, detail: String?, color: UIColor, symbol: String?) {
        let palette = Theme.current
        if busy {
            return ("Provar mappen …", nil, palette.inkSoft, nil)
        }
        if let result = probeResult {
            if let problem = result {
                return ("Det blev fel", problem, .systemRed, "exclamationmark.circle.fill")
            }
            return ("Mappen fungerar", "Sensus kunde skriva och läsa i \(SyncFolder.shared.name).", palette.success,
                    "checkmark.circle.fill")
        }
        let line = SyncStatusText.line(SyncEngine.shared.status, palette: palette)
        var detail = line.detail
        if let report = SyncEngine.shared.lastReport, case .ok = SyncEngine.shared.status {
            detail = [detail, report.summary].compactMap { $0 }.joined(separator: "\n")
        }
        return (line.title, detail, line.color, line.symbol)
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
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        cell.accessoryView = nil
        cell.accessoryType = .none
        cell.selectionStyle = .default
        var content = UIListContentConfiguration.subtitleCell()
        content.secondaryTextProperties.numberOfLines = 0
        let palette = Theme.current
        let tint = view.tintColor ?? palette.accent
        switch sections[indexPath.section].rows[indexPath.row] {
        case .choose:
            let chosen = SyncFolder.shared.isChosen
            content.text = chosen ? "Byt mapp" : "Välj mapp i iCloud Drive"
            content.textProperties.color = tint
            content.secondaryText = chosen ? "Vald: \(SyncFolder.shared.name)" : "Öppnar Filer, välj mappen och tryck Öppna."
            content.image = UIImage(systemName: "folder")
            cell.accessoryType = .disclosureIndicator
        case .status:
            let current = status
            content.text = current.title
            content.textProperties.color = current.color
            content.textProperties.font = .preferredFont(forTextStyle: .headline)
            content.secondaryText = [current.detail, message].compactMap { $0 }.joined(separator: "\n")
            if let symbol = current.symbol {
                content.image = UIImage(systemName: symbol)
                content.imageProperties.tintColor = current.color
            }
            if busy || SyncEngine.shared.isRunning {
                let spinner = UIActivityIndicatorView(style: .medium)
                spinner.startAnimating()
                cell.accessoryView = spinner
            }
            cell.selectionStyle = .none
        case .syncNow:
            content = UIListContentConfiguration.valueCell()
            content.text = SyncEngine.shared.isRunning ? "Synkar …" : "Synka nu"
            content.textProperties.color = tint
        case .peer(let index):
            let peers = SyncEngine.shared.peers
            guard index < peers.count else { break }
            let peer = peers[index]
            let platform = peer.device.platform == "windows" ? "Windows" : (peer.device.platform == "ios" ? "iPad eller iPhone"
                                                                             : peer.device.platform)
            content.text = peer.device.name.isEmpty ? platform : peer.device.name
            content.secondaryText = platform + (peer.written.map { ", senast " + SyncStatusText.time($0) } ?? "")
            content.image = UIImage(systemName: peer.device.platform == "windows" ? "desktopcomputer" : "ipad")
            content.imageProperties.tintColor = palette.inkSoft
            cell.selectionStyle = .none
        case .noPeers:
            content.text = "Inga andra enheter än"
            content.secondaryText = "Den här enhetens fil finns i mappen. När datorn har synkat syns den här."
            content.textProperties.color = palette.inkSoft
            cell.selectionStyle = .none
        case .skipped(let index):
            let skipped = SyncEngine.shared.skippedFiles
            guard index < skipped.count else { break }
            content.text = "Hoppades över"
            content.textProperties.color = palette.warning
            content.secondaryText = skipped[index]
            content.image = UIImage(systemName: "exclamationmark.triangle")
            content.imageProperties.tintColor = palette.warning
            cell.selectionStyle = .none
        case .paused:
            content.text = "Synken är pausad"
            content.textProperties.color = palette.warning
            content.secondaryText = "Den pausades när du återställde från en säkerhetskopia, så att de andra enheterna "
                + "inte tar tillbaka det du ångrade. Den startar inte av sig själv, inte heller när appen startas om."
            cell.selectionStyle = .none
        case .resume:
            content = UIListContentConfiguration.valueCell()
            content.text = "Starta synken igen"
            content.textProperties.color = tint
        case .forget:
            content = UIListContentConfiguration.valueCell()
            content.text = "Sluta synka med mappen"
            content.textProperties.color = .systemRed
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section].rows[indexPath.row] {
        case .choose:
            chooseFolder()
        case .syncNow:
            syncNow()
        case .resume:
            confirmResume()
        case .forget:
            confirmForget()
        default:
            break
        }
    }

    // MARK: Stegen

    private func chooseFolder() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        use(url)
    }

    /// Sparar mappen, provar att skriva och läsa där och synkar om provet gick bra. Också till självtestet.
    func use(_ url: URL) {
        do {
            try SyncFolder.shared.choose(url)
        } catch {
            probeResult = .some("Mappen gick inte att spara: \(error.localizedDescription)")
            rebuild()
            return
        }
        guard let directory = SyncFolder.shared.syncDirectory else {
            probeResult = .some(SyncFolder.shared.problem ?? "Sensus kommer inte åt mappen.")
            rebuild()
            return
        }
        busy = true
        probeResult = nil
        message = nil
        rebuild()
        Task { @MainActor [weak self] in
            let problem = await Task.detached(priority: .userInitiated) { SyncFiles.probe(directory) }.value
            guard let self = self else { return }
            self.busy = false
            self.probeResult = .some(problem)
            self.rebuild()
            SelfTest.log("U7 synkguiden: \(self.statusText). \(problem ?? "")")
            guard problem == nil else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            if !SyncEngine.shared.isPaused {
                self.syncNow()
            }
        }
    }

    private func syncNow() {
        guard !SyncEngine.shared.isRunning else { return }
        message = nil
        Task { @MainActor [weak self] in
            do {
                try await SyncEngine.shared.sync()
                self?.probeResult = nil
            } catch {
                self?.message = error.localizedDescription
            }
            self?.rebuild()
        }
        rebuild()
    }

    /// Starta synken igen efter pausen (granskning 2, fynd 3), med vad som då händer.
    private func confirmResume() {
        let alert = UIAlertController(
            title: "Starta synken igen?",
            message: "Ändringar på de andra enheterna som är nyare än säkerhetskopian hämtas, också markeringar som "
                + "tagits bort på datorn. Det du har på iPaden nu sparas i mappen.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Avbryt", style: .cancel))
        alert.addAction(UIAlertAction(title: "Starta synken", style: .default) { [weak self] _ in
            SyncEngine.shared.resume()
            self?.rebuild()
            self?.syncNow()
        })
        present(alert, animated: true)
    }

    private func confirmForget() {
        let alert = UIAlertController(
            title: "Sluta synka med \(SyncFolder.shared.name)?",
            message: "Inget tas bort, varken i mappen eller i appen. Böckerna i mappen syns inte i biblioteket förrän du "
                + "väljer mappen igen, och deras markeringar finns kvar.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Avbryt", style: .cancel))
        alert.addAction(UIAlertAction(title: "Sluta synka", style: .destructive) { [weak self] _ in
            SyncFolder.shared.forget()
            self?.probeResult = nil
            self?.message = nil
            self?.rebuild()
        })
        present(alert, animated: true)
    }
}
