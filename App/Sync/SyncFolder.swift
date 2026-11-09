import UIKit

/// Mappen i iCloud Drive som Sensus synkar och läser böcker i (F1, B4). Den väljs en gång med
/// dokumentväljaren och sparas som ett säkerhetsbokmärke. Åtkomsten startas första gången mappen behövs och
/// hålls öppen så länge appen kör, så att böckerna i mappen går att läsa i läsarna.
///
/// I mappen ligger böckerna (också i undermappar, som blir kurser) och undermappen "Sensus synk" med en fil per
/// enhet. Saknas åtkomsten (gammalt bokmärke, mappen borttagen) står det i `problem`, och ingenting tas bort.
/// Används från huvudtråden.
final class SyncFolder {

    static let shared = SyncFolder()
    static let didChange = Notification.Name("SyncFolderDidChange")

    private static let bookmarkKey = "sync.folder.bookmark"
    private static let nameKey = "sync.folder.name"
    private static let deviceKey = "sync.device.id"
    private static let vendorKey = "sync.device.vendor"

    private let defaults = UserDefaults.standard
    /// Mappen med åtkomst, när den är upplöst.
    private var resolved: URL?
    private var accessing: URL?
    private var resolvedOnce = false
    /// Varför mappen inte går att nå, på svenska. Nil när den fungerar eller inte är vald.
    private(set) var problem: String?

    private init() {}

    // MARK: Mappen

    /// Sant om en mapp är vald (även om den inte går att nå just nu).
    var isChosen: Bool {
        defaults.data(forKey: Self.bookmarkKey) != nil
    }

    /// Mappens namn som den hette när den valdes, till exempel Sensus.
    var name: String {
        defaults.string(forKey: Self.nameKey) ?? ""
    }

    /// Mappen med åtkomst, eller nil om ingen är vald eller den inte går att nå (se `problem`).
    var url: URL? {
        if !resolvedOnce {
            resolve()
        }
        return resolved
    }

    /// Undermappen med enheternas filer.
    var syncDirectory: URL? {
        url?.appendingPathComponent(SyncFile.folderName, isDirectory: true)
    }

    /// Läser bokmärket på nytt, till exempel när appen kommer fram eller i Inställningar.
    func refresh() {
        resolvedOnce = false
        resolve()
    }

    private func resolve() {
        resolvedOnce = true
        guard let data = defaults.data(forKey: Self.bookmarkKey) else {
            stopAccess()
            resolved = nil
            problem = nil
            return
        }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            if accessing?.standardizedFileURL != url.standardizedFileURL {
                stopAccess()
                if url.startAccessingSecurityScopedResource() {
                    accessing = url
                }
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  !url.path.contains("/.Trash/") else {
                resolved = nil
                problem = "Mappen \(name) finns inte längre i iCloud Drive. Välj en mapp igen under Inställningar, Synk."
                AppLog.shared.write("Synkmappen finns inte längre (\(url.lastPathComponent))")
                return
            }
            if stale, let fresh = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil,
                                                       relativeTo: nil) {
                defaults.set(fresh, forKey: Self.bookmarkKey)
                AppLog.shared.write("Synkmappens bokmärke förnyat")
            }
            resolved = url
            problem = nil
        } catch {
            stopAccess()
            resolved = nil
            problem = "Sensus kommer inte åt mappen \(name) längre. Välj den igen under Inställningar, Synk."
            AppLog.shared.write("Synkmappens bokmärke gick inte att läsa: \(error.localizedDescription)")
        }
    }

    private func stopAccess() {
        accessing?.stopAccessingSecurityScopedResource()
        accessing = nil
    }

    /// Sparar mappen som dokumentväljaren gav. Inget i mappen ändras här, det gör provet (`probe`).
    func choose(_ url: URL) throws {
        let started = url.startAccessingSecurityScopedResource()
        defer {
            if started {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let data = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(data, forKey: Self.bookmarkKey)
        defaults.set(url.lastPathComponent, forKey: Self.nameKey)
        AppLog.shared.write("Synkmappen vald: \(url.lastPathComponent)")
        refresh()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Slutar använda mappen. Ingenting i mappen eller i appen tas bort.
    func forget() {
        stopAccess()
        defaults.removeObject(forKey: Self.bookmarkKey)
        defaults.removeObject(forKey: Self.nameKey)
        resolved = nil
        problem = nil
        resolvedOnce = true
        AppLog.shared.write("Synkmappen glömd (inget togs bort)")
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    // MARK: Enheten

    /// Enhetens id i synken: ett UUID som sparas en gång. Om appen förs över till en annan iPad via en
    /// säkerhetskopia av iPaden följer UserDefaults med, men identifierForVendor gör det inte, och då får den
    /// nya enheten ett eget id, så att två enheter aldrig skriver samma fil.
    @MainActor
    var device: SyncDevice {
        let vendor = UIDevice.current.identifierForVendor?.uuidString ?? ""
        var id = defaults.string(forKey: Self.deviceKey) ?? ""
        let savedVendor = defaults.string(forKey: Self.vendorKey) ?? ""
        if id.isEmpty || (!vendor.isEmpty && !savedVendor.isEmpty && vendor != savedVendor) {
            id = UUID().uuidString.lowercased()
            defaults.set(id, forKey: Self.deviceKey)
            AppLog.shared.write("Synken: nytt id för enheten")
        }
        if !vendor.isEmpty, vendor != savedVendor {
            defaults.set(vendor, forKey: Self.vendorKey)
        }
        let model = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        let name = UIDevice.current.name
        return SyncDevice(id: id, name: name.isEmpty ? model : name, platform: "ios")
    }

    static func fileName(for deviceID: String) -> String {
        deviceID + "." + SyncFile.fileExtension
    }
}

/// Filerna i synkmappen. Allt här körs i bakgrunden och rör bara filer, inga databaser.
enum SyncFiles {

    /// En enhets fil, som den gick att läsa (eller varför inte).
    struct Entry {
        let name: String
        let snapshot: SyncSnapshot?
        /// Varför filen hoppades över, till loggen.
        let skipped: String?
        /// Filen finns men är inte hämtad från iCloud än.
        var notDownloaded = false
        /// Felet när filen inte gick att tolka.
        var error: SyncFile.ReadError?
    }

    /// Läser alla enheters filer i `directory`. Filer som inte är hämtade från iCloud än börjar hämtas och
    /// hoppas över den här gången. Trasiga, tomma och okända filer hoppas över med en rad i `skipped`.
    /// `waitForDownloads`: väntar högst så många sekunder på filer som håller på att hämtas.
    static func readAll(in directory: URL, waitForDownloads: Double) -> [Entry] {
        var pending = startDownloads(in: directory)
        let deadline = Date().addingTimeInterval(waitForDownloads)
        while !pending.isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            pending = pending.filter { !isDownloaded($0) }
        }
        var entries: [Entry] = []
        for url in jsonFiles(in: directory) {
            let name = url.lastPathComponent
            if !isDownloaded(url) {
                entries.append(Entry(name: name, snapshot: nil, skipped: "inte hämtad från iCloud än", notDownloaded: true))
                continue
            }
            switch read(url) {
            case .success(let snapshot):
                entries.append(Entry(name: name, snapshot: snapshot,
                                     skipped: snapshot.skippedRows > 0 ? "\(snapshot.skippedRows) rader gick inte att läsa"
                                        : nil))
            case .failure(let error):
                entries.append(Entry(name: name, snapshot: nil, skipped: error.text, error: error))
            }
        }
        for url in pending where !entries.contains(where: { $0.name == url.lastPathComponent }) {
            entries.append(Entry(name: url.lastPathComponent, snapshot: nil, skipped: "inte hämtad från iCloud än",
                                 notDownloaded: true))
        }
        return entries
    }

    /// Filerna som slutar på .json, utan tillfälliga filer.
    static func jsonFiles(in directory: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                                 options: [])) ?? []
        return urls.filter { url in
            let name = url.lastPathComponent
            return !name.hasPrefix(".") && url.pathExtension.lowercased() == SyncFile.fileExtension
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Ber iCloud hämta filer som bara finns som platshållare (".namn.json.icloud" i iOS 15 och 16, eller en
    /// fil som inte är nedladdad). Ger adresserna till filerna som hämtas.
    static func startDownloads(in directory: URL) -> [URL] {
        let manager = FileManager.default
        let urls = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [])) ?? []
        var pending: [URL] = []
        for url in urls {
            let name = url.lastPathComponent
            if let real = placeholderTarget(name) {
                guard (real as NSString).pathExtension.lowercased() == SyncFile.fileExtension else { continue }
                let target = directory.appendingPathComponent(real)
                try? manager.startDownloadingUbiquitousItem(at: target)
                pending.append(target)
            } else if url.pathExtension.lowercased() == SyncFile.fileExtension, !isDownloaded(url) {
                try? manager.startDownloadingUbiquitousItem(at: url)
                pending.append(url)
            }
        }
        return pending
    }

    /// ".Bok.pdf.icloud" ger "Bok.pdf", annat ger nil.
    static func placeholderTarget(_ name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > ".x.icloud".count else { return nil }
        return String(name.dropFirst().dropLast(".icloud".count))
    }

    /// Sant om filen finns på enheten och går att läsa: en vanlig fil, eller en fil i iCloud som är hämtad.
    static func isDownloaded(_ url: URL) -> Bool {
        var url = url
        url.removeAllCachedResourceValues()
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard values?.isUbiquitousItem == true, let status = values?.ubiquitousItemDownloadingStatus else { return true }
        return status == .current || status == .downloaded
    }

    /// Läser en fil genom filkoordineringen, så att iCloud inte skriver den samtidigt.
    static func read(_ url: URL) -> Result<SyncSnapshot, SyncFile.ReadError> {
        var data: Data?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [.withoutChanges],
                                                         error: &coordinationError) { readable in
            data = try? Data(contentsOf: readable)
        }
        guard let bytes = data else { return .failure(.notJSON) }
        return SyncFile.decode(bytes)
    }

    enum WriteError: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .failed(let message): return message
            }
        }
    }

    /// Skriver filen atomiskt: först till en tillfällig fil bredvid, sedan byts namnet, så att en annan enhet
    /// aldrig ser en halvskriven fil. Läser sedan tillbaka filen och kontrollerar att den går att tolka.
    static func writeAtomically(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [.forReplacing],
                                                         error: &coordinationError) { target in
            let temporary = target.deletingLastPathComponent()
                .appendingPathComponent(target.lastPathComponent + ".tmp")
            do {
                try? manager.removeItem(at: temporary)
                try data.write(to: temporary)
                if manager.fileExists(atPath: target.path) {
                    // rename(2) byter filen i ett steg. Går det inte används Foundations ersättning.
                    if rename(temporary.path, target.path) != 0 {
                        _ = try manager.replaceItemAt(target, withItemAt: temporary)
                    }
                } else {
                    try manager.moveItem(at: temporary, to: target)
                }
            } catch {
                try? manager.removeItem(at: temporary)
                writeError = error
            }
        }
        if let error = coordinationError ?? writeError {
            throw WriteError.failed("Synkfilen kunde inte sparas: \(error.localizedDescription)")
        }
        guard let back = try? Data(contentsOf: url), back == data else {
            throw WriteError.failed("Synkfilen som sparades gick inte att läsa tillbaka.")
        }
    }

    /// Byter namn på en egen fil som inte går att läsa, så att den inte skrivs över (den kan behövas).
    static func setAside(_ url: URL) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let aside = url.deletingPathExtension()
            .appendingPathExtension("trasig-\(formatter.string(from: Date()))")
        try? FileManager.default.moveItem(at: url, to: aside)
    }

    /// Provet i guiden (U7): skriver en liten fil i synkmappen, läser tillbaka den och tar bort den.
    static func probe(_ directory: URL) -> String? {
        let url = directory.appendingPathComponent(".sensus-prov-\(UUID().uuidString.prefix(8)).txt")
        let text = Data("Sensus provar att skriva här. Filen tas bort direkt.".utf8)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try writeAtomically(text, to: url)
        } catch {
            return "Sensus kunde inte skriva i mappen: \(error.localizedDescription)"
        }
        var deleteError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [.forDeleting],
                                                         error: &deleteError) { target in
            try? FileManager.default.removeItem(at: target)
        }
        return nil
    }
}
