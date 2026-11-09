import Foundation

/// En fil i biblioteket.
struct Book: Equatable {

    enum Kind {
        case pdf, epub, text, other
    }

    let url: URL
    /// Bokens id i bokregistret (G3). Markeringar, bokmärken, läsposition och sparade ord hänger på det,
    /// så att de följer med när filen byter namn eller flyttas.
    let id: String
    /// Sökvägen i Böcker, till exempel "RETA30/Bok.pdf".
    let path: String

    var title: String {
        url.deletingPathExtension().lastPathComponent
    }

    /// Undermappen i Böcker, eller nil för böcker direkt i Böcker.
    var folder: String? {
        let parts = path.split(separator: "/")
        return parts.count > 1 ? parts.dropLast().joined(separator: "/") : nil
    }

    var kind: Kind {
        switch url.pathExtension.lowercased() {
        case "pdf":
            return .pdf
        case "epub":
            return .epub
        case "txt", "md", "markdown", "rtf", "html", "htm":
            return .text
        default:
            return .other
        }
    }

    var kindLabel: String {
        switch kind {
        case .pdf: return "PDF"
        case .epub: return "EPUB"
        case .text: return "Text"
        case .other: return url.pathExtension.uppercased()
        }
    }

    var symbolName: String {
        switch kind {
        case .pdf: return "doc.richtext"
        case .epub: return "book.closed"
        case .text: return "doc.plaintext"
        case .other: return "doc"
        }
    }
}

/// Böckerna ligger i appens mapp "Böcker", också i undermappar.
/// Den syns i Filer-appen under På min iPad, Läsa, så filer kan också läggas in därifrån.
/// Läspositionen sparas under bokens id (G3), inte under filnamnet.
/// Böcker kan också ligga i den valda mappen i iCloud Drive (B4). De får sökvägen "/iCloud/..." (`BookPlace`).
final class LibraryStore {

    static let shared = LibraryStore()

    let booksDirectory: URL
    private let defaults = UserDefaults.standard

    /// Filerna i Böcker och i iCloud-mappen.
    struct Listing {
        var files: [BookFile] = []
        var urls: [String: URL] = [:]
        /// Böcker i iCloud-mappen som inte är hämtade till iPaden än. Hämtningen har startats.
        var waiting: [String] = []
        /// Falskt när en iCloud-mapp är vald men inte går att nå. Dess böcker räknas då inte som borttagna.
        var cloudReachable = true
    }

    /// Böckerna i iCloud-mappen som hämtas just nu, till raden i biblioteket.
    private(set) var waitingCloudBooks: [String] = []
    /// Bara på `cloudQueue`.
    private var downloadRequested: [String: Date] = [:]

    /// Det som den senaste läsningen av iCloud-mappen gav (granskning 6, M1). Mappen läses aldrig på huvudtråden:
    /// biblioteket använder den senaste läsningen, och en ny görs i bakgrunden med gränser för antal filer och
    /// djup. Innan mappen lästs en första gång räknas dess böcker som utom räckhåll (inget markeras som borta).
    struct CloudListing: Equatable {
        /// Mappen läsningen gäller.
        let root: String
        var files: [BookFile] = []
        var urls: [String: URL] = [:]
        var waiting: [String] = []
        /// Falskt när mappen inte fanns eller inte gick att läsa (L2).
        var reachable = true
        /// Sant när gränsen för antal filer eller böcker nåddes.
        var truncated = false
    }

    /// Gränserna för läsningen av iCloud-mappen (M1): poster i mappen, böcker och djup (en bok direkt i mappen
    /// har djup 1). Guiden låter inte en större mapp väljas.
    static let cloudEntryLimit = 3000
    static let cloudBookLimit = 300
    static let cloudDepthLimit = 4
    /// Hur många böcker som högst börjar hämtas från iCloud per läsning.
    static let cloudDownloadLimit = 20

    /// Biblioteket läser om när läsningen av iCloud-mappen gett något nytt.
    static let cloudDidChange = Notification.Name("LibraryStoreCloudDidChange")

    private let cloudQueue = DispatchQueue(label: "se.edvin.lasa.icloudmappen", qos: .utility)
    /// Bara på huvudtråden.
    private var cloudListing: CloudListing?
    private var cloudRefreshRunning = false
    private var cloudRefreshAgain = false
    private var cloudRefreshed: Date?
    /// Räknas upp när appen själv ändrar i mappen (flytt, borttagning), så att en läsning som började före
    /// ändringen aldrig ersätter den.
    private var cloudGeneration = 0
    private var didCleanLocalLeftovers = false

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        booksDirectory = documents.appendingPathComponent("Böcker", isDirectory: true)
        try? FileManager.default.createDirectory(at: booksDirectory, withIntermediateDirectories: true)
    }

    private static func key(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Alla filer i Böcker, också i undermappar (G3), och i iCloud-mappen (B4), med sökvägen som nyckel.
    func listFiles() -> (files: [BookFile], urls: [String: URL]) {
        let listed = listing()
        return (listed.files, listed.urls)
    }

    func listing() -> Listing {
        var result = Listing()
        listLocal(into: &result)
        cleanLocalLeftoversOnce()
        if SyncFolder.shared.isChosen {
            if let cloud = SyncFolder.shared.url {
                // M1: den senaste läsningen av mappen, och en ny i bakgrunden.
                if let listed = cloudListing, listed.root == Self.key(cloud), listed.reachable {
                    result.files += listed.files
                    for (path, url) in listed.urls where result.urls[path] == nil {
                        result.urls[path] = url
                    }
                    result.waiting += listed.waiting
                } else {
                    // Inte läst än, eller mappen saknades (L2): böckerna där räknas inte som borttagna.
                    result.cloudReachable = false
                }
                refreshCloud()
            } else {
                result.cloudReachable = false
            }
        } else if cloudListing != nil {
            // Mappen är bortvald: en senare vald mapp läses från början.
            cloudListing = nil
            cloudGeneration += 1
        }
        return result
    }

    /// Läser iCloud-mappen i bakgrunden (M1). Högst en läsning åt gången och, utan `force`, högst en var annan
    /// sekund. Ger läsningen något nytt läser biblioteket om (`cloudDidChange`).
    func refreshCloud(force: Bool = false) {
        guard SyncFolder.shared.isChosen, let root = SyncFolder.shared.url else { return }
        if cloudRefreshRunning {
            cloudRefreshAgain = cloudRefreshAgain || force
            return
        }
        if !force, let last = cloudRefreshed, Date().timeIntervalSince(last) < 2 {
            return
        }
        cloudRefreshRunning = true
        let key = Self.key(root)
        let generation = cloudGeneration
        cloudQueue.async { [weak self] in
            guard let self = self else { return }
            let started = Date()
            let listed = self.readCloud(root, key: key)
            let elapsed = Date().timeIntervalSince(started)
            DispatchQueue.main.async {
                self.cloudRefreshRunning = false
                self.cloudRefreshed = Date()
                if elapsed > 2 || listed.truncated {
                    AppLog.shared.write("iCloud-mappen lästes på \(Int((elapsed * 1000).rounded())) ms: \(listed.files.count) "
                                        + "böcker\(listed.truncated ? ", gränsen nåddes" : "")")
                }
                let current = SyncFolder.shared.isChosen ? SyncFolder.shared.url.map(Self.key) : nil
                // En läsning som började före en egen ändring, eller gäller en annan mapp, används inte.
                guard generation == self.cloudGeneration, current == key else {
                    self.cloudRefreshAgain = false
                    if current != nil {
                        self.refreshCloud(force: true)
                    }
                    return
                }
                let changed = self.cloudListing != listed
                self.cloudListing = listed
                if !listed.reachable {
                    // L2: mappen finns inte längre där den var. Bokmärket läses om, och problemet syns i biblioteket.
                    SyncFolder.shared.refresh()
                }
                if changed {
                    NotificationCenter.default.post(name: Self.cloudDidChange, object: nil)
                }
                if self.cloudRefreshAgain {
                    self.cloudRefreshAgain = false
                    self.refreshCloud(force: true)
                }
            }
        }
    }

    /// En egen ändring i iCloud-mappen (B4): en flyttad bok kommer med i den senaste läsningen direkt, och en
    /// borttagen eller bortflyttad försvinner ur den, så att biblioteket inte visar den eller markerar den som borta
    /// medan mappen läses om.
    func noteCloudChange(added: BookFile? = nil, url: URL? = nil, removed: String? = nil) {
        cloudGeneration += 1
        if var listed = cloudListing {
            if let removed = removed {
                listed.files.removeAll { $0.path == removed }
                listed.urls[removed] = nil
                listed.waiting.removeAll { $0 == removed }
            }
            if let added = added, let url = url {
                listed.files.removeAll { $0.path == added.path }
                listed.waiting.removeAll { $0 == added.path }
                listed.files.append(added)
                listed.urls[added.path] = url
            }
            cloudListing = listed
        }
        refreshCloud(force: true)
    }

    /// Platserna som räknas som närvarande när en fil matchas mot registret: filerna, böcker i iCloud-mappen som
    /// hämtas, och alla böcker i iCloud-mappen när den inte går att nå (de är inte borttagna, bara utom räckhåll).
    func presentPaths(_ listing: Listing? = nil) -> Set<String> {
        let listed = listing ?? self.listing()
        var present = Set(listed.files.map(\.path)).union(listed.waiting)
        if !listed.cloudReachable {
            present.formUnion(BookRegistry.shared.records().map(\.file).filter { BookPlace.isCloud($0) })
        }
        return present
    }

    private func listLocal(into result: inout Listing) {
        let base = booksDirectory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: booksDirectory,
                                                              includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return
        }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory != true else { continue }
            // K6: frågefilerna bredvid böckerna (Bok.pdf.fragor.json) är inga böcker.
            guard !BookQuestionFile.isQuestionFile(url.lastPathComponent) else { continue }
            let components = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            guard components.count > base.count, Array(components.prefix(base.count)) == base else { continue }
            let path = components.dropFirst(base.count).joined(separator: "/")
            let file = BookFile(path: path,
                                size: values?.fileSize ?? 0,
                                modified: Int(values?.contentModificationDate?.timeIntervalSince1970 ?? 0))
            result.files.append(file)
            result.urls[path] = url
        }
    }

    /// Böckerna i iCloud-mappen (B4): bara filer som är böcker, inte undermappen Sensus synk. En bok som bara
    /// finns som platshållare (".Bok.pdf.icloud" i iOS 15) börjar hämtas och kommer med när den är hämtad.
    /// Körs på `cloudQueue`, aldrig på huvudtråden (M1), och slutar vid gränserna för antal poster, böcker och djup.
    /// Finns mappen inte (borttagen, i papperskorgen) blir `reachable` falskt (L2).
    private func readCloud(_ root: URL, key: String) -> CloudListing {
        var result = CloudListing(root: key)
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
              !key.contains("/.Trash/") else {
            result.reachable = false
            return result
        }
        let base = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey,
                                      .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: keys,
                                                  options: [.skipsPackageDescendants]) else {
            result.reachable = false
            return result
        }
        var entries = 0
        var downloads = 0
        for case let url as URL in enumerator {
            entries += 1
            if entries > Self.cloudEntryLimit || result.files.count + result.waiting.count >= Self.cloudBookLimit {
                result.truncated = true
                break
            }
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: Set(keys))
            let components = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            guard components.count > base.count, Array(components.prefix(base.count)) == base else { continue }
            let inside = Array(components.dropFirst(base.count))
            if values?.isDirectory == true {
                if name.hasPrefix(".") || (inside.count == 1 && name == SyncFile.folderName)
                    || inside.count >= Self.cloudDepthLimit {
                    enumerator.skipDescendants()
                }
                continue
            }
            if name.hasPrefix(BookPlace.temporaryPrefix) {
                // L5: en kopia som blev kvar när appen stängdes mitt i en flytt.
                Self.removeLeftover(url, created: values?.creationDate, coordinated: true)
                continue
            }
            if name.hasPrefix(".") {
                // En platshållare för en bok som inte är hämtad.
                guard let real = SyncFiles.placeholderTarget(name),
                      BookPlace.bookExtensions.contains((real as NSString).pathExtension.lowercased()) else { continue }
                let path = BookPlace.cloudPrefix + (inside.dropLast() + [real]).joined(separator: "/")
                result.waiting.append(path)
                if downloads < Self.cloudDownloadLimit,
                   requestDownload(url.deletingLastPathComponent().appendingPathComponent(real), path: path) {
                    downloads += 1
                }
                continue
            }
            guard BookPlace.bookExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let path = BookPlace.cloudPrefix + inside.joined(separator: "/")
            if values?.isUbiquitousItem == true, let status = values?.ubiquitousItemDownloadingStatus,
               status != .current, status != .downloaded {
                result.waiting.append(path)
                if downloads < Self.cloudDownloadLimit, requestDownload(url, path: path) {
                    downloads += 1
                }
                continue
            }
            let file = BookFile(path: path, size: values?.fileSize ?? 0,
                                modified: Int(values?.contentModificationDate?.timeIntervalSince1970 ?? 0))
            result.files.append(file)
            result.urls[path] = url
        }
        return result
    }

    /// Ber iCloud hämta en bok, högst en gång i minuten per bok. Sant om hämtningen begärdes nu. På `cloudQueue`.
    private func requestDownload(_ url: URL, path: String) -> Bool {
        if let last = downloadRequested[path], Date().timeIntervalSince(last) < 60 {
            return false
        }
        downloadRequested[path] = Date()
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        } catch {
            AppLog.shared.write("Boken \(path) kunde inte hämtas från iCloud: \(error.localizedDescription)")
        }
        return true
    }

    /// L5: tar bort en kvarlämnad kopia från en avbruten flytt, om den skapades för mer än en timme sedan.
    /// Skapelsetiden avgör, inte ändringstiden (kopian får originalets ändringstid).
    private static func removeLeftover(_ url: URL, created: Date?, coordinated: Bool) {
        guard let created = created, Date().timeIntervalSince(created) > 3600 else { return }
        do {
            if coordinated {
                try BookPlace.removeCoordinated(url)
            } else {
                try FileManager.default.removeItem(at: url)
            }
            AppLog.shared.write("Tog bort en kvarlämnad kopia från en avbruten flytt: \(url.lastPathComponent)")
        } catch {
            AppLog.shared.write("Kvarlämnad kopia gick inte att ta bort: \(error.localizedDescription)")
        }
    }

    /// L5: kvarlämnade kopior i Böcker tas bort en gång per start, i bakgrunden.
    private func cleanLocalLeftoversOnce() {
        guard !didCleanLocalLeftovers else { return }
        didCleanLocalLeftovers = true
        let directory = booksDirectory
        cloudQueue.async {
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys:
                                                                    [.creationDateKey, .isDirectoryKey],
                                                                  options: [.skipsPackageDescendants]) else { return }
            var entries = 0
            for case let url as URL in enumerator {
                entries += 1
                if entries > Self.cloudEntryLimit { break }
                guard url.lastPathComponent.hasPrefix(BookPlace.temporaryPrefix) else { continue }
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                Self.removeLeftover(url, created: created, coordinated: false)
            }
        }
    }

    /// Böckerna som känns igen direkt, och filer som behöver sin kontrollsumma först (G3).
    func scan() -> (books: [Book], pending: [BookFile], urls: [String: URL]) {
        let listed = listing()
        waitingCloudBooks = listed.waiting
        let result = BookRegistry.shared.scan(files: listed.files, urls: listed.urls, present: presentPaths(listed))
        let books = result.books.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return (books, result.pending, listed.urls)
    }

    func allBooks() -> [Book] {
        scan().books
    }

    /// Boken för en fil i Böcker, om den är känd i registret.
    func book(at url: URL) -> Book? {
        let target = url.resolvingSymlinksInPath().standardizedFileURL.path
        return allBooks().first { $0.url.resolvingSymlinksInPath().standardizedFileURL.path == target }
    }

    /// Filen i Böcker som den ser ut på disken, med sökvägen i Böcker.
    func bookFile(at url: URL) -> BookFile? {
        let listed = listFiles()
        let target = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard let match = listed.urls.first(where: {
            $0.value.resolvingSymlinksInPath().standardizedFileURL.path == target
        }) else {
            return nil
        }
        return listed.files.first { $0.path == match.key }
    }

    /// Lägger in en fil som ligger i Böcker i registret, med kontrollsumman räknad (vid import, G10).
    /// `asNew`: filen blir en ny bok även om den ersatt en annan med samma namn (Ersätt och börja om).
    func registerFile(at url: URL, hash: String, asNew: Bool = false) -> Book? {
        let listed = listFiles()
        let target = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard let match = listed.urls.first(where: {
            $0.value.resolvingSymlinksInPath().standardizedFileURL.path == target
        }), let file = listed.files.first(where: { $0.path == match.key }) else {
            return nil
        }
        let id = asNew ? BookRegistry.shared.registerNew(file, hash: hash) : BookRegistry.shared.register(file, hash: hash)
        return Book(url: match.value, id: id, path: match.key)
    }

    /// Tar bort filen. Läspositionen står kvar (granskning 3, D3-5), liksom tiden och sidan i registret, så att
    /// samma fil som läggs in igen öppnas där man var och Fortsätt läsa stämmer. Så gör Windows-appen också.
    func delete(_ book: Book) throws {
        if BookPlace.isCloud(book.path) {
            // B4: en bok i iCloud-mappen tas bort genom filkoordineringen (den försvinner på alla enheter).
            try BookPlace.removeCoordinated(book.url)
            noteCloudChange(removed: book.path)
        } else {
            try FileManager.default.removeItem(at: book.url)
        }
        ReflowableBookLoader.removeCaches(for: book)
        SearchIndex.shared.remove(book: book.id)
        if let record = BookRegistry.shared.record(id: book.id) {
            CoverStore.shared.forget(record)
        }
        // Bokens rad, markeringar och läsposition finns kvar, så att de kommer tillbaka om samma fil läggs in igen.
        BookRegistry.shared.markMissing(id: book.id)
    }

    // MARK: Läsposition

    func savedPageIndex(for book: Book) -> Int {
        defaults.integer(forKey: positionKey(for: book))
    }

    /// Sidan i en PDF för bokens id, nil om ingen är sparad (synken, F1).
    func savedPageIndex(forID id: String) -> Int? {
        defaults.object(forKey: "bookPosition.\(id)") == nil ? nil : defaults.integer(forKey: "bookPosition.\(id)")
    }

    /// Kapitel och andel för bokens id (synken, F1).
    func savedLocation(forID id: String) -> ReflowLocation? {
        guard let text = defaults.string(forKey: "bookLocation.\(id)") else { return nil }
        let parts = text.split(separator: "|")
        guard parts.count == 2, let chapter = Int(parts[0]), let progression = Double(parts[1]) else { return nil }
        return ReflowLocation(chapter: chapter, progression: progression)
    }

    /// När läspositionen för bokens id senast ändrades (synken, F1).
    func positionDate(forID id: String) -> Date? {
        let value = defaults.double(forKey: "bookPositionDate.\(id)")
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }

    /// En läsposition från en annan enhet, för bokens id i registret (också en bok vars fil saknas just nu,
    /// så att den öppnas på rätt ställe när den läggs in igen). Tiden följer med.
    func applySyncedPosition(section: Int, progression: Double, date: Date, forID id: String, isPDF: Bool) {
        guard BookRegistry.shared.isAvailable else { return }
        if isPDF {
            defaults.set(section, forKey: "bookPosition.\(id)")
        } else {
            defaults.set("\(section)|\(progression)", forKey: "bookLocation.\(id)")
        }
        defaults.set(date.timeIntervalSince1970, forKey: "bookPositionDate.\(id)")
    }

    func savePageIndex(_ index: Int, for book: Book) {
        // Granskningens fynd 9: utan registret är bokens id tillfälligt, och platsen skulle aldrig hittas igen.
        guard BookRegistry.shared.isAvailable else { return }
        defaults.set(index, forKey: positionKey(for: book))
        markPositionChanged(for: book)
    }

    private func positionKey(for book: Book) -> String {
        "bookPosition.\(book.id)"
    }

    // MARK: Läsposition i EPUB och textfiler

    /// Kapitel och andel av kapitlet, så att platsen överlever byte av typsnitt och storlek.
    func savedLocation(for book: Book) -> ReflowLocation? {
        guard let text = defaults.string(forKey: locationKey(for: book)) else { return nil }
        let parts = text.split(separator: "|")
        guard parts.count == 2, let chapter = Int(parts[0]), let progression = Double(parts[1]) else { return nil }
        return ReflowLocation(chapter: chapter, progression: progression)
    }

    func saveLocation(_ location: ReflowLocation, for book: Book) {
        guard BookRegistry.shared.isAvailable else { return }
        defaults.set("\(location.chapter)|\(location.progression)", forKey: locationKey(for: book))
        markPositionChanged(for: book)
    }

    // MARK: Synk av läspositionen (fas 6)

    /// När läspositionen senast ändrades på den här enheten, eller kom från synken.
    func positionDate(for book: Book) -> Date? {
        let value = defaults.double(forKey: positionDateKey(for: book))
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }

    /// En läsposition från en annan enhet. Tiden följer med, så att den inte skickas tillbaka som ny.
    func applySyncedPosition(section: Int, progression: Double, date: Date, for book: Book) {
        // Granskning 2, N6: samma vakt som när läspositionen sparas. Utan registret är bokens id tillfälligt.
        guard BookRegistry.shared.isAvailable else { return }
        if book.kind == .pdf {
            defaults.set(section, forKey: positionKey(for: book))
        } else {
            defaults.set("\(section)|\(progression)", forKey: locationKey(for: book))
        }
        defaults.set(date.timeIntervalSince1970, forKey: positionDateKey(for: book))
    }

    /// Var man är och hur långt man läst, till biblioteket (B1, B2). Sparas i bokregistret.
    func saveStatus(_ status: ReadingStatus, for book: Book) {
        guard BookRegistry.shared.isAvailable else { return }
        BookRegistry.shared.setStatus(id: book.id, status)
    }

    private func markPositionChanged(for book: Book) {
        defaults.set(Date().timeIntervalSince1970, forKey: positionDateKey(for: book))
    }

    private func positionDateKey(for book: Book) -> String {
        "bookPositionDate.\(book.id)"
    }

    private func locationKey(for book: Book) -> String {
        "bookLocation.\(book.id)"
    }
}
