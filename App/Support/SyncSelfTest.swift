import UIKit

/// Självtestet för synken (F1) och bokplatsen (B4) i simulatorn. Simulatorn har inget iCloud, så en vanlig mapp
/// (Documents/Synkprov) står för mappen i iCloud Drive. `tools/simtest/run.sh` lägger en fil från en påhittad
/// Windows-dator där, och en trasig, en tom och en från en nyare version. Resten av fallen skriver testet själv.
/// Körs i `-LasaSelfTest fas6`. Allt står i fas6.log med Rätt eller FEL.
@MainActor
enum SyncSelfTest {

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Synkprov", isDirectory: true)
    }

    private static var syncDirectory: URL {
        folder.appendingPathComponent(SyncFile.folderName, isDirectory: true)
    }

    private static func verdict(_ ok: Bool) -> String {
        ok ? "Rätt" : "FEL"
    }

    static func run(navigation: UINavigationController, library: LibraryViewController) async {
        let manager = FileManager.default
        guard manager.fileExists(atPath: syncDirectory.path) else {
            SelfTest.log("Synk (F1): ingen provmapp från run.sh, hoppar över")
            return
        }
        guard let epub = LibraryStore.shared.allBooks().first(where: { $0.url.lastPathComponent == "test.epub" }) else {
            SelfTest.log("FEL: test.epub finns inte i biblioteket")
            return
        }
        // Något lokalt: en markering, ett bokmärke och ett ord, före den första synken.
        _ = AnnotationStore.shared.addHighlight(book: epub.id, section: 2, start: 10, length: 20, text: "lokal markering",
                                                color: .green)
        _ = AnnotationStore.shared.addBookmark(book: epub.id, section: 3, progression: 0.5, label: "Lokalt bokmärke")
        UserWords.shared.save(word: "tillfällig", lemma: "tillfällig", language: .swedish,
                              sentence: "Ett tillfälligt ord.", book: "test", pageIndex: 1)
        let localBefore = AnnotationStore.shared.highlights(book: epub.id).count

        // U7: guiden väljer mappen, provar att skriva och läsa och synkar.
        let guide = SyncGuideViewController()
        navigation.pushViewController(guide, animated: false)
        await pause(0.5)
        let before = SyncEngine.shared.lastSync
        guide.use(folder)
        // Provet i mappen går först, sedan synken: vänta tills synken är klar (eller gav fel).
        for _ in 0..<80 {
            await pause(0.25)
            let engine = SyncEngine.shared
            if !engine.isRunning, engine.lastSync != before || engine.lastError != nil {
                break
            }
        }
        await pause(0.5)
        SelfTest.log("Synkguiden (U7): \(guide.statusText). Läget: \(SyncStatusText.line(SyncEngine.shared.status).title)")
        SelfTest.saveScreen(navigation.view, name: "13-synkguide")
        let first = SyncEngine.shared.lastReport
        SelfTest.log("Synk 1: \(first?.summary ?? "ingen rapport") \(SyncEngine.shared.lastError ?? "")")

        // Det som kom från Windows-filen.
        let marks = AnnotationStore.shared.highlights(book: epub.id)
        let fromWindows = marks.contains { $0.text == "från Windows" }
        let location = LibraryStore.shared.savedLocation(for: epub)
        let remoteWord = UserWords.shared.isSaved(lemma: "fjärrord", language: .swedish)
        SelfTest.log("Från Windows-filen: markering \(fromWindows ? "ja" : "NEJ"), ord \(remoteWord ? "ja" : "NEJ"), "
                     + "läsposition kapitel \(location?.chapter ?? -1) andel \(location?.progression ?? -1). "
                     + verdict(fromWindows && remoteWord && location?.chapter == 4))
        let skipped = SyncEngine.shared.skippedFiles
        let skippedFiles = first?.skippedFiles ?? -1
        let rowSkip = skipped.contains { $0.hasPrefix("windows-prov.json") && $0.contains("rader") }
        SelfTest.log("Överhoppade filer (\(skippedFiles), ska vara 3, och en trasig rad i Windows-filen): "
                     + "\(skipped.joined(separator: " | ")). " + verdict(skippedFiles == 3 && rowSkip))
        SelfTest.log("Väntar på en bok som inte finns här: \(first?.waiting ?? -1). " + verdict(first?.waiting == 1))
        let localAfter = AnnotationStore.shared.highlights(book: epub.id).count
        SelfTest.log("Lokala markeringar kvar efter de trasiga filerna: \(localBefore) före, \(localAfter) efter (en till "
                     + "från Windows). \(verdict(localAfter == localBefore + 1))")

        // Den egna filen: atomiskt skriven, med format, de lokala raderna och det som lästs från Windows.
        let device = SyncFolder.shared.device
        let ownURL = syncDirectory.appendingPathComponent(SyncFolder.fileName(for: device.id))
        let own = (try? Data(contentsOf: ownURL)).map(SyncFile.decode)
        if case .success(let snapshot)? = own {
            let hasLocal = snapshot.highlights.values.contains { $0.text == "lokal markering" }
            let hasRemote = snapshot.highlights.values.contains { $0.text == "från Windows" }
                && snapshot.highlights["7a000000-0000-4000-8000-0000000000ff"] != nil
            let leftovers = (try? manager.contentsOfDirectory(atPath: syncDirectory.path))?
                .filter { $0.hasSuffix(".tmp") } ?? []
            SelfTest.log("Egna filen \(ownURL.lastPathComponent): \(snapshot.positions.count) lägen, "
                         + "\(snapshot.highlights.count) markeringar, \(snapshot.bookmarks.count) bokmärken, "
                         + "\(snapshot.words.count) ord, egen markering \(hasLocal ? "ja" : "NEJ"), Windows markering "
                         + "\(hasRemote ? "ja" : "NEJ"), tillfälliga filer kvar \(leftovers.count). "
                         + verdict(hasLocal && hasRemote && leftovers.isEmpty))
        } else {
            SelfTest.log("FEL: den egna synkfilen gick inte att läsa (\(ownURL.lastPathComponent))")
        }

        // En gång till: inget nytt.
        await syncOnce()
        let second = SyncEngine.shared.lastReport
        SelfTest.log("Synk 2 (ska vara 0 och 0): \(second?.summary ?? "") "
                     + verdict(second?.pushed == 0 && second?.pulled == 0))

        await testConflicts(epub: epub)

        // Ett borttaget ord skrivs som borttaget i filen.
        await pause(0.05)
        _ = UserWords.shared.delete(lemma: "tillfällig", language: .swedish)
        await syncOnce()
        if case .success(let snapshot)? = (try? Data(contentsOf: ownURL)).map(SyncFile.decode) {
            let word = snapshot.words["sv|tillfällig"]
            SelfTest.log("Borttaget ord i egna filen: \(word.map { $0.deleted ? "borttaget" : "FEL, levande" } ?? "FEL, saknas"). "
                         + verdict(word?.deleted == true))
        }

        navigation.popToRootViewController(animated: false)
        await testPlaces(library: library, navigation: navigation)
        await testUnreachable(library: library, navigation: navigation)

        navigation.pushViewController(SettingsViewController(), animated: false)
        await pause(0.8)
        SelfTest.saveScreen(navigation.view, name: "13d-installningar-synk")
        navigation.popToRootViewController(animated: false)
        SyncFolder.shared.forget()
        library.reload()
    }

    private static func syncOnce() async {
        do {
            try await SyncEngine.shared.sync()
        } catch {
            SelfTest.log("Synken gav fel: \(error.localizedDescription)")
        }
    }

    /// Krockar: en äldre ändring från Windows skriver inte över en nyare lokal, en nyare borttagning tar bort, och
    /// en fil där markeringarna saknas tar inte bort något.
    private static func testConflicts(epub: Book) async {
        guard let sha = BookRegistry.shared.record(id: epub.id)?.sha256, !sha.isEmpty,
              let local = AnnotationStore.shared.highlights(book: epub.id).first(where: { $0.text == "lokal markering" }),
              let windows = AnnotationStore.shared.highlights(book: epub.id).first(where: { $0.text == "från Windows" }) else {
            SelfTest.log("FEL: krockprovet hittade inte markeringarna")
            return
        }
        let old = SyncHighlight(id: local.id.lowercased(), bookID: sha, section: local.section, start: local.start,
                                length: local.length, text: local.text, color: "pink", note: "gammal från Windows",
                                created: 1_600_000_000, updated: 1_600_000_000, deleted: false)
        let removed = SyncHighlight(id: windows.id.lowercased(), bookID: sha, section: windows.section, start: windows.start,
                                    length: windows.length, text: windows.text, color: windows.color.rawValue, note: "",
                                    created: windows.created.timeIntervalSince1970,
                                    // Windows-filens markering är från 2030, så borttagningen är en timme senare.
                                    updated: windows.updated.timeIntervalSince1970 + 3600, deleted: true)
        var conflict = SyncSnapshot(device: SyncDevice(id: "krock-prov", name: "Krockdator", platform: "windows"),
                                    written: Date().timeIntervalSince1970)
        conflict.highlights[old.id] = old
        conflict.highlights[removed.id] = removed
        // En fil helt utan rader: ska inte ta bort något.
        let empty = SyncSnapshot(device: SyncDevice(id: "tom-prov", name: "Tom dator", platform: "windows"),
                                 written: Date().timeIntervalSince1970)
        do {
            try SyncFiles.writeAtomically(try SyncFile.encode(conflict),
                                          to: syncDirectory.appendingPathComponent("krock-prov.json"))
            try SyncFiles.writeAtomically(try SyncFile.encode(empty),
                                          to: syncDirectory.appendingPathComponent("tom-prov.json"))
        } catch {
            SelfTest.log("FEL: krockfilerna gick inte att skriva: \(error.localizedDescription)")
            return
        }
        let before = AnnotationStore.shared.highlights(book: epub.id).count
        await syncOnce()
        let after = AnnotationStore.shared.highlights(book: epub.id)
        let kept = after.first { $0.id == local.id }
        let gone = !after.contains { $0.id == windows.id }
        SelfTest.log("Krock: lokal markering \(kept?.color == .green && kept?.note.isEmpty == true ? "orörd" : "FEL, ändrad"), "
                     + "nyare borttagning \(gone ? "tog bort" : "FEL, kvar"), \(before) markeringar före och "
                     + "\(after.count) efter (en borttagen). "
                     + verdict(kept?.color == .green && gone && after.count == before - 1))
    }

    /// B4: en bok flyttas till iCloud-mappen och tillbaka. Kopian kontrolleras, originalet tas bort först sedan,
    /// och bokens id, markeringar och kurs följer med.
    private static func testPlaces(library: LibraryViewController, navigation: UINavigationController) async {
        library.reload()
        guard let book = library.books.first(where: { $0.path == "Kurs/Anteckningar.md" }) else {
            SelfTest.log("FEL: Kurs/Anteckningar.md finns inte i biblioteket")
            return
        }
        _ = AnnotationStore.shared.addHighlight(book: book.id, section: 0, start: 2, length: 11, text: "Anteckningar",
                                                color: .yellow)
        let marks = AnnotationStore.shared.highlights(book: book.id).count
        let courseBefore = library.allItems.first { $0.book.id == book.id }?.courses ?? []
        // K6: en frågefil bredvid boken följer med.
        let questions = LibraryStore.shared.booksDirectory.appendingPathComponent("Kurs/Anteckningar.md.fragor.json")
        try? Data("[]".utf8).write(to: questions)
        let moved = await move(book, toCloud: true, library: library)
        let questionsMoved = FileManager.default.fileExists(atPath: folder.appendingPathComponent("Kurs/Anteckningar.md.fragor.json").path)
            && !FileManager.default.fileExists(atPath: questions.path)
        SelfTest.log("Frågefilen följer med till mappen: \(questionsMoved ? "ja" : "NEJ"). " + verdict(questionsMoved))
        let cloudFile = folder.appendingPathComponent("Kurs/Anteckningar.md")
        let localFile = LibraryStore.shared.booksDirectory.appendingPathComponent("Kurs/Anteckningar.md")
        let record = BookRegistry.shared.record(id: book.id)
        let item = library.allItems.first { $0.book.id == book.id }
        SelfTest.log("Till iCloud-mappen (B4): \(moved.map { "klar, \($0.path)" } ?? "FEL"), filen i mappen "
                     + "\(FileManager.default.fileExists(atPath: cloudFile.path) ? "finns" : "SAKNAS"), i Böcker "
                     + "\(FileManager.default.fileExists(atPath: localFile.path) ? "FEL, kvar" : "borta"), registret "
                     + "\(record?.file ?? "?"), samma id \(moved?.id == book.id ? "ja" : "NEJ"), markeringar "
                     + "\(AnnotationStore.shared.highlights(book: book.id).count) av \(marks), i biblioteket "
                     + "\(item == nil ? "NEJ" : "ja"), kurs \(item?.courses == courseBefore && !courseBefore.isEmpty ? "samma" : "FEL"). "
                     + verdict(moved?.path == "/iCloud/Kurs/Anteckningar.md" && record?.file == moved?.path
                                && !FileManager.default.fileExists(atPath: localFile.path)
                                && AnnotationStore.shared.highlights(book: book.id).count == marks
                                && item?.courses == courseBefore))
        SelfTest.saveScreen(navigation.view, name: "13b-bibliotek-synk")
        SelfTest.log("Synkens rad i biblioteket (G9): \(library.syncLineForSelfTest)")
        if let current = moved {
            let back = await move(current, toCloud: false, library: library)
            let questionsBack = FileManager.default.fileExists(atPath: questions.path)
            try? FileManager.default.removeItem(at: questions)
            SelfTest.log("Tillbaka till Böcker: \(back.map { "klar, \($0.path)" } ?? "FEL"), samma id "
                         + "\(back?.id == book.id ? "ja" : "NEJ"), frågefilen \(questionsBack ? "med" : "FEL, kvar i mappen"), i mappen "
                         + "\(FileManager.default.fileExists(atPath: cloudFile.path) ? "FEL, kvar" : "borta"). "
                         + verdict(back?.id == book.id && back?.path == "Kurs/Anteckningar.md"
                                    && !FileManager.default.fileExists(atPath: cloudFile.path)))
        }

        // Samma namn finns redan i Böcker när en bok flyttas tillbaka: ett nytt namn, inget skrivs över.
        library.reload()
        guard let text = library.books.first(where: { $0.path == "test.txt" }),
              let inCloud = await move(text, toCloud: true, library: library) else {
            SelfTest.log("FEL: test.txt flyttades inte till mappen")
            return
        }
        let blocker = LibraryStore.shared.booksDirectory.appendingPathComponent("test.txt")
        try? Data("En annan fil med samma namn.\n".utf8).write(to: blocker)
        library.reload()
        let back = await move(inCloud, toCloud: false, library: library)
        let blockerText = (try? String(contentsOf: blocker, encoding: .utf8)) ?? ""
        SelfTest.log("Tillbaka med upptaget namn: \(back.map { "klar, \($0.path)" } ?? "FEL"), samma id "
                     + "\(back?.id == text.id ? "ja" : "NEJ"), filen med samma namn "
                     + "\(blockerText.contains("annan fil") ? "orörd" : "FEL, överskriven"). "
                     + verdict(back?.id == text.id && back?.path == "test 2.txt" && blockerText.contains("annan fil")))
        try? FileManager.default.removeItem(at: blocker)
        library.reload()
    }

    private static func move(_ book: Book, toCloud: Bool, library: LibraryViewController) async -> Book? {
        await withCheckedContinuation { continuation in
            library.move(book, toCloud: toCloud) { result in
                switch result {
                case .success(let book): continuation.resume(returning: book)
                case .failure: continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Mappen går inte att nå: biblioteket säger till i orange, och böckerna i mappen räknas inte som borttagna.
    private static func testUnreachable(library: LibraryViewController, navigation: UINavigationController) async {
        library.reload()
        guard let book = library.books.first(where: { $0.url.lastPathComponent == "test.md" }) else {
            SelfTest.log("FEL: test.md finns inte")
            return
        }
        guard let moved = await move(book, toCloud: true, library: library) else {
            SelfTest.log("FEL: test.md flyttades inte till mappen")
            return
        }
        // Ett bokmärke följer en flyttad mapp, så mappen läggs i papperskorgen (som när den tas bort i Filer).
        let trash = folder.deletingLastPathComponent().appendingPathComponent(".Trash", isDirectory: true)
        try? FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let away = trash.appendingPathComponent("Synkprov")
        do {
            try FileManager.default.moveItem(at: folder, to: away)
        } catch {
            SelfTest.log("FEL: provmappen gick inte att flytta undan: \(error.localizedDescription)")
            return
        }
        SyncFolder.shared.refresh()
        library.reload()
        await syncOnce()
        await pause(0.4)
        let record = BookRegistry.shared.record(id: moved.id)
        let line = library.syncLineForSelfTest
        SelfTest.saveScreen(navigation.view, name: "13c-bibliotek-mappen-borta")
        SelfTest.log("Mappen borta: raden säger \(line). Boken \(record?.missing == false ? "inte borttagen" : "FEL, markerad som borta"). "
                     + verdict(record?.missing == false && SyncFolder.shared.problem != nil))
        try? FileManager.default.moveItem(at: away, to: folder)
        SyncFolder.shared.refresh()
        library.reload()
        let back = await move(moved, toCloud: false, library: library)
        await syncOnce()
        let recovered = SyncStatusText.line(SyncEngine.shared.status).title
        SelfTest.log("Mappen tillbaka: test.md \(back?.path ?? "FEL"), samma id \(back?.id == book.id ? "ja" : "NEJ"), "
                     + "läget \(recovered). " + verdict(back?.path == "test.md" && !SyncStatusText.line(SyncEngine.shared.status).isProblem))
    }
}
