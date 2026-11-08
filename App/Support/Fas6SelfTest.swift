import UIKit

/// Självtestet för fas 6 i simulatorn, utan bok: repetitionen, inställningarna, tolkningen av AI-svaret och
/// synken mot en låtsasserver (`tools/simtest/mock_supabase.py`). Körs bara med `-LasaSelfTest fas6`.
@MainActor
enum Fas6SelfTest {

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    static func run(from library: UIViewController) async {
        guard let navigation = library.navigationController else {
            SelfTest.finish()
            return
        }
        SelfTest.log("Fas 6. Ordboken: \(WordDictionary.shared == nil ? "SAKNAS" : "finns")")

        // Repetition: några ord sparas som om de slagits upp i en bok.
        UserWords.shared.save(word: "kunskap", lemma: "kunskap", language: .swedish,
                              sentence: "Kunskap kommer sällan av sig själv.", book: "test", pageIndex: 3)
        UserWords.shared.save(word: "difficulties", lemma: "difficulty", language: .english,
                              sentence: "The difficulties they encountered were greater than anyone had expected.",
                              book: "test", pageIndex: 5)
        UserWords.shared.save(word: "vacker", lemma: "vacker", language: .swedish,
                              sentence: "Alla var överens om att den var vacker.", book: "test", pageIndex: 7)
        let review = WordReviewViewController()
        navigation.pushViewController(review, animated: false)
        await pause(1.0)
        SelfTest.log("Repetition: \(review.remaining) ord på tur, först \(review.currentWord ?? "inget")")
        SelfTest.saveScreen(navigation.view, name: "01-kort")
        review.reveal()
        await pause(0.5)
        SelfTest.saveScreen(navigation.view, name: "02-svar")
        let first = review.currentWord
        review.grade(.good)
        await pause(0.4)
        review.reveal()
        review.grade(.again)
        await pause(0.4)
        SelfTest.log("Efter Bra och Igen: \(review.remaining) kvar (Igen kommer tillbaka), nu \(review.currentWord ?? "inget"), förut \(first ?? "")")
        let labels = ReviewGrade.allCases.map { grade in
            "\(grade.title) \(ReviewSchedule.label(days: ReviewSchedule.next(grade, interval: 3, ease: 2.5, reps: 2).interval))"
        }
        SelfTest.log("Schema för ett ord med 3 dagar: " + labels.joined(separator: ", "))
        navigation.popToRootViewController(animated: false)

        testDatabases()
        testBookMigration()
        await testImport(library: library)
        await testExpiryAndBackup(library: library)

        // AI-svaret: tolkningen av ett svar från Gemini, och att påhittade ord rensas bort.
        if let lookup = WordDictionary.shared?.lookup("vacker", sentence: "Alla var överens om att den var vacker.") {
            let candidates = GeminiClient.Candidates(lookup)
            SelfTest.log("AI-kandidater för vacker: \(candidates.senseLines.count) betydelser, ord: "
                         + candidates.words.prefix(8).joined(separator: ", "))
            let id = candidates.senseTexts.keys.sorted().first ?? ""
            let good = candidates.explanation(from: ["sense_id": id, "best_word": candidates.words.first ?? "",
                                                     "explanation": "Här betyder det att bron är fin att se på."])
            let invented = candidates.explanation(from: ["sense_id": id, "best_word": "påhittat ord",
                                                         "explanation": "Förklaring."])
            switch (good, invented) {
            case (.success(let a), .success(let b)):
                SelfTest.log("AI-svar: ord \(a.bestWord ?? "inget"), betydelse \(a.senseText ?? "ingen"). "
                             + "Påhittat ord rensat: \(b.bestWord == nil ? "ja" : "NEJ")")
            default:
                SelfTest.log("FEL: AI-svaret gick inte att tolka")
            }
            let api = #"{"candidates":[{"content":{"parts":[{"text":"```json\n{\"explanation\":\"Test\"}\n```"}]}}]}"#
            SelfTest.log("Svar i kodblock tolkas: \(GeminiClient.answerJSON(Data(api.utf8))?["explanation"] as? String ?? "FEL")")

            // Ordrutan med AI-knappen (en låtsasnyckel gör att den syns, den används inte).
            Keychain.set("test", for: .geminiAPIKey)
            let context = WordPopupViewController.Context(sentence: "Alla var överens om att den var vacker.",
                                                          rangeInSentence: nil, book: nil, pageIndex: nil,
                                                          triedWord: "vacker")
            WordPopupViewController.present(lookup: lookup, context: context, from: library, sourceView: library.view,
                                            sourceRect: CGRect(x: 200, y: 300, width: 10, height: 10),
                                            onReady: {}, onDismiss: {})
            await pause(1.2)
            SelfTest.saveScreen(library.view.window ?? library.view, name: "03-ordruta-ai")
            library.dismiss(animated: false)
            await pause(0.4)
            Keychain.set(nil, for: .geminiAPIKey)
        } else {
            SelfTest.log("FEL: vacker hittades inte i ordboken")
        }

        // Synken mot låtsasservern.
        await testSync(navigation: navigation)

        navigation.pushViewController(SettingsViewController(), animated: false)
        await pause(1.0)
        SelfTest.saveScreen(navigation.view, name: "05-installningar")
        if let settings = navigation.topViewController as? UITableViewController {
            // Säkerhetskopian och Diagnostik ligger längre ner.
            let table = settings.tableView!
            table.scrollRectToVisible(CGRect(x: 0, y: table.contentSize.height - 1, width: 1, height: 1), animated: false)
            await pause(0.6)
            SelfTest.saveScreen(navigation.view, name: "05b-installningar-nere")
        }
        navigation.popToRootViewController(animated: false)

        testLog()
        SelfTest.finish()
    }

    /// G4: loggen i Filer har startraden och raderna som de andra självtesten gav upphov till.
    private static func testLog() {
        AppLog.shared.flush()
        let text = (try? String(contentsOf: AppLog.fileURL, encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n")
        let start = lines.last { $0.contains("Start:") }.map(String.init) ?? "SAKNAS"
        SelfTest.log("Loggen i Filer: \(lines.count) rader. Senaste start: \(start)")
        let pageFailures = lines.filter { $0.contains("kunde inte ritas") }.count
        let opened = lines.filter { $0.contains("Öppnade ") }.count
        let backups = lines.filter { $0.contains("Säkerhetskopia sparad") }.count
        SelfTest.log("I loggen: \(opened) böcker öppnade, \(pageFailures) rader om sidbilder som inte kunde ritas, "
                     + "\(backups) säkerhetskopior. Delas: \(AppLog.shared.shareableFiles.map(\.lastPathComponent))")
    }

    /// G8: databasernas versioner, trappan av uppdateringar och att en avbruten transaktion inte sparar något.
    /// Trappan provas i en databas i minnet, så att användarens filer inte rörs.
    private static func testDatabases() {
        SelfTest.log("Databasernas versioner: markeringar \(AnnotationStore.shared.schemaVersion), "
                     + "sparade ord \(UserWords.shared.schemaVersion) (ska vara \(AnnotationStore.migrations.count) och \(UserWords.migrations.count))")
        struct Stop: Error {}
        do {
            let memory = try SQLiteDatabase(path: ":memory:", readOnly: false)
            let first = try memory.migrate(["CREATE TABLE t (a INTEGER);"])
            let second = try memory.migrate(["CREATE TABLE t (a INTEGER);",
                                             "ALTER TABLE t ADD COLUMN b TEXT NOT NULL DEFAULT '';"])
            try memory.execute("INSERT INTO t (a, b) VALUES (1, 'ett')")
            try? memory.transaction { () throws -> Void in
                try memory.execute("INSERT INTO t (a, b) VALUES (2, 'två')")
                throw Stop()
            }
            var rows = 0
            try memory.query("SELECT COUNT(*) FROM t") { row in rows = row.int(0) }
            SelfTest.log("Trappan: \(first.from) till \(first.to), sedan \(second.from) till \(second.to). "
                         + "Rader efter en avbruten transaktion: \(rows) (ska vara 1)")
        } catch {
            SelfTest.log("FEL: databastestet: \(error)")
        }
        SelfTest.log("Fel vid sparning hittills: \(SaveProblems.count)")
    }

    /// G3: flytten från filnamn till bokens id, med påhittade gamla data i en egen databas och en egen
    /// UserDefaults, så att användarens data inte rörs. Gamla nycklar in, nya ut, samma antal markeringar
    /// på samma sida, och en andra körning ändrar ingenting.
    private static func testBookMigration() {
        let suite = "se.edvin.lasa.migreringsprov"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("migreringsprov.sqlite")
        try? FileManager.default.removeItem(at: url)
        guard let defaults = UserDefaults(suiteName: suite) else {
            SelfTest.log("FEL: provets UserDefaults gick inte att skapa")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: url)
        }
        do {
            let db = try SQLiteDatabase(path: url.path, readOnly: false)
            // Databasen som den såg ut före G3, med markeringar och ett bokmärke under filnamnen.
            try db.migrate(Array(AnnotationStore.migrations.prefix(1)))
            for (index, start) in [10, 40, 90].enumerated() {
                try db.execute("""
                    INSERT INTO highlights (id, book, section, start, length, text, color, note, created, updated, deleted)
                    VALUES (?, 'Gammal bok.pdf', 4, ?, 5, 'text', 'yellow', ?, 1, 2, 0)
                    """, ["prov-\(index)", start, index == 1 ? "en anteckning" : ""])
            }
            try db.execute("""
                INSERT INTO highlights (id, book, section, start, length, text, color, note, created, updated, deleted)
                VALUES ('prov-epub', 'Roman.epub', 2, 0, 5, 'text', 'blue', '', 1, 2, 0)
                """)
            try db.execute("""
                INSERT INTO bookmarks (id, book, section, progression, label, created, updated, deleted)
                VALUES ('prov-bm', 'Gammal bok.pdf', 9, 0, 'Sidan 10', 1, 2, 0)
                """)
            defaults.set(41, forKey: "position.Gammal bok.pdf")
            defaults.set(1_700_000_000.0, forKey: "positionDate.Gammal bok.pdf")
            defaults.set("3|0.25", forKey: "location.Roman.epub")
            let versions = try db.migrate(AnnotationStore.migrations)
            let records = [
                BookRecord(id: "id-pdf", sha256: "", file: "Gammal bok.pdf", title: "Gammal bok", size: 1, modified: 1,
                           added: 1, missing: false),
                BookRecord(id: "id-epub", sha256: "", file: "Roman.epub", title: "Roman", size: 1, modified: 1,
                           added: 1, missing: false),
            ]
            let work = LegacyBookMigration.hasWork(db: db, records: records, defaults: defaults)
            let first = try LegacyBookMigration.run(db: db, records: records, defaults: defaults)
            func count(_ sql: String) throws -> Int {
                var value = 0
                try db.query(sql) { value = $0.int(0) }
                return value
            }
            let onPage = try count("SELECT COUNT(*) FROM highlights WHERE book = 'id-pdf' AND section = 4")
            let notes = try count("SELECT COUNT(*) FROM highlights WHERE book = 'id-pdf' AND note <> ''")
            let epub = try count("SELECT COUNT(*) FROM highlights WHERE book = 'id-epub' AND section = 2")
            let marks = try count("SELECT COUNT(*) FROM bookmarks WHERE book = 'id-pdf' AND section = 9")
            let left = try count("SELECT COUNT(*) FROM highlights WHERE book LIKE '%.pdf' OR book LIKE '%.epub'")
            let oldKeys = ["position.Gammal bok.pdf", "positionDate.Gammal bok.pdf", "location.Roman.epub"]
                .filter { defaults.object(forKey: $0) != nil }.count
            let position = defaults.integer(forKey: "bookPosition.id-pdf")
            let location = defaults.string(forKey: "bookLocation.id-epub") ?? "saknas"
            let done = try LegacyBookMigration.isDone(db)
            let ok = work && onPage == 3 && notes == 1 && epub == 1 && marks == 1 && left == 0 && oldKeys == 0
                && position == 41 && location == "3|0.25" && done
            SelfTest.log("Flytten till bokens id (påhittade gamla data, version \(versions.from) till \(versions.to)): "
                         + "\(first.summary). Efter: \(onPage) markeringar på sidan 5 varav \(notes) med anteckning, "
                         + "\(epub) i romanen, \(marks) bokmärke, \(left) kvar under filnamn, \(oldKeys) gamla nycklar kvar, "
                         + "läsposition \(position), plats \(location). \(ok ? "Rätt" : "FEL")")
            let second = try LegacyBookMigration.run(db: db, records: records, defaults: defaults)
            let again = try count("SELECT COUNT(*) FROM highlights WHERE book = 'id-pdf' AND section = 4")
            let stillThere = defaults.integer(forKey: "bookPosition.id-pdf")
            SelfTest.log("Flytten en gång till: \(second.summary), \(again) markeringar på sidan 5, läsposition "
                         + "\(stillThere). \(again == 3 && stillThere == 41 && second.highlights == 0 ? "Rätt" : "FEL")")
        } catch {
            SelfTest.log("FEL: provet av flytten till bokens id: \(error)")
        }

        // Registret i appen: varje testbok har ett id, och Böcker/Kurs/ (undermappen) syns.
        let books = LibraryStore.shared.allBooks()
        let ids = Set(books.map(\.id))
        SelfTest.log("Bokregistret i appen: \(books.count) böcker, \(ids.count) olika id, "
                     + "i undermappar: \(books.compactMap(\.folder).joined(separator: ", "))")
    }

    /// G10: import i bakgrunden. En stor fil läggs in medan huvudtråden mäts, sedan ett upptaget namn
    /// (Behåll båda och Ersätt och behåll markeringarna) och samma innehåll en gång till (finns redan).
    private static func testImport(library: UIViewController) async {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent("importprov", isDirectory: true)
        try? manager.removeItem(at: folder)
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        func importing(_ url: URL, move: Bool) async -> [Book] {
            await withCheckedContinuation { continuation in
                BookImporter.shared.start([url], move: move, presenter: library) { books in
                    continuation.resume(returning: books)
                }
            }
        }

        // En stor fil (40 MB text) kopieras medan en klocka på huvudtråden mäter längsta pausen.
        let big = folder.appendingPathComponent("Storbok.txt")
        let line = String(repeating: "En rad text i en stor bok som läggs in i bakgrunden. ", count: 20) + "\n"
        let block = Data(String(repeating: line, count: 1000).utf8)
        if manager.createFile(atPath: big.path, contents: nil), let handle = try? FileHandle(forWritingTo: big) {
            for _ in 0..<(40 * 1_048_576 / block.count) {
                handle.write(block)
            }
            try? handle.close()
        }
        final class Gauge {
            var longest: CFTimeInterval = 0
            var last = CACurrentMediaTime()
            var progressSeen = ""
        }
        let gauge = Gauge()
        let list = library as? LibraryViewController
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                let now = CACurrentMediaTime()
                gauge.longest = max(gauge.longest, now - gauge.last)
                gauge.last = now
                if gauge.progressSeen.isEmpty, let text = list?.footerText, text.contains("%") {
                    gauge.progressSeen = text
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        let started = CACurrentMediaTime()
        let imported = await importing(big, move: false)
        ticker.cancel()
        let longest = gauge.longest
        let progressSeen = gauge.progressSeen
        let record = imported.first.flatMap { BookRegistry.shared.record(id: $0.id) }
        SelfTest.log("Import av 40 MB: \(imported.first?.path ?? "FEL, ingen bok") efter "
                     + "\(Int(((CACurrentMediaTime() - started) * 1000).rounded())) ms, längsta paus på huvudtråden "
                     + "\(Int((longest * 1000).rounded())) ms\(longest > 0.25 ? " FEL, appen låste sig" : ""), "
                     + "kontrollsumma \(record?.sha256.isEmpty == false ? "räknad" : "FEL, saknas"), "
                     + "förlopp i biblioteket: \(progressSeen.isEmpty ? "syntes inte" : progressSeen)")
        if let list = library as? LibraryViewController {
            list.reload()
            SelfTest.saveScreen(library.navigationController?.view ?? library.view, name: "07-import")
        }

        // Upptaget namn med nytt innehåll: Behåll båda, sedan Ersätt och behåll markeringarna.
        let first = folder.appendingPathComponent("Importprov.md")
        try? Data("# Importprov\n\nForsta versionen.\n".utf8).write(to: first)
        let original = await importing(first, move: true).first
        let movedAway = !manager.fileExists(atPath: first.path)
        if let book = original {
            AnnotationStore.shared.addHighlight(book: book.id, section: 0, start: 2, length: 9, text: "Importprov",
                                                color: .yellow)
        }
        try? Data("# Importprov\n\nAndra versionen, lite längre.\n".utf8).write(to: first)
        BookImporter.selfTestAnswer = .keepBoth
        let both = await importing(first, move: true).first
        try? Data("# Importprov\n\nTredje versionen, ännu lite längre.\n".utf8).write(to: first)
        BookImporter.selfTestAnswer = .replaceKeepingMarks
        let replaced = await importing(first, move: true).first
        let marksKept = replaced.map { AnnotationStore.shared.highlights(book: $0.id).count } ?? 0
        SelfTest.log("Upptaget namn: första \(original?.path ?? "FEL") (källan flyttades: \(movedAway ? "ja" : "NEJ")), "
                     + "Behåll båda gav \(both?.path ?? "FEL"), Ersätt och behåll gav \(replaced?.path ?? "FEL") med "
                     + "\(replaced?.id == original?.id ? "samma id" : "FEL, nytt id") och \(marksKept) markering kvar")

        // Samma innehåll en gång till: ingen ny fil.
        try? Data("# Importprov\n\nTredje versionen, ännu lite längre.\n".utf8).write(to: first)
        let before = LibraryStore.shared.allBooks().count
        let again = await importing(first, move: true).first
        let after = LibraryStore.shared.allBooks().count
        SelfTest.log("Samma innehåll igen: \(again?.path ?? "ingen bok") och \(after - before) nya böcker "
                     + "\(after == before ? "(rätt)" : "FEL")")
        BookImporter.selfTestAnswer = nil

        for book in LibraryStore.shared.allBooks() where book.path.hasPrefix("Importprov") || book.path == "Storbok.txt" {
            try? LibraryStore.shared.delete(book)
        }
        try? manager.removeItem(at: folder)
        (library as? LibraryViewController)?.reload()
    }

    /// G1: utgångsdatumet ur profilen, raden i biblioteket, och en säkerhetskopia som sparas och återställs.
    private static func testExpiryAndBackup(library: UIViewController) async {
        // Profilen är en signerad fil med en plist i mitten. Här en påhittad med skräp runt plisten.
        let expiry = Date(timeIntervalSince1970: 1_900_000_000)
        var fake = Data([0x30, 0x82, 0x0A, 0x00]) + Data("signerat".utf8)
        if let plist = try? PropertyListSerialization.data(fromPropertyList: ["ExpirationDate": expiry, "Name": "Test"],
                                                            format: .xml, options: 0) {
            fake.append(plist)
        }
        fake.append(Data([0x00, 0xA0, 0x82, 0x01]))
        let parsed = AppExpiry.parse(fake)
        SelfTest.log("Profilens utgångsdatum: \(parsed == expiry ? "läses rätt" : "FEL, \(String(describing: parsed))")")
        SelfTest.log("Profil i appen i simulatorn: \(AppExpiry.profileExpirationDate == nil ? "ingen (rätt)" : "FEL, finns")")

        let now = Date()
        SelfTest.log("Varning tre dagar före: "
                     + (AppExpiry.warning(expiring: now.addingTimeInterval(3 * 86_400), now: now) ?? "ingen (rätt)"))
        AppExpiry.overrideDate = now.addingTimeInterval(30 * 3600)
        SelfTest.log("Varning 30 timmar före: \(AppExpiry.warning() ?? "FEL, ingen")")
        let libraryList = library as? LibraryViewController
        libraryList?.reload()
        await pause(0.8)
        SelfTest.saveScreen(library.navigationController?.view ?? library.view, name: "06-utgang")
        AppExpiry.overrideDate = nil
        libraryList?.reload()

        // Säkerhetskopian: spara, ändra, återställ.
        let positionKey = "position.kopieprov.pdf"
        UserWords.shared.save(word: "kopieprov", lemma: "kopieprov", language: .swedish,
                              sentence: "Ett ord för säkerhetskopian.", book: "test", pageIndex: 1)
        UserDefaults.standard.set(7, forKey: positionKey)
        let made: Result<Backup.Copy, Error> = await withCheckedContinuation { continuation in
            Backup.make { continuation.resume(returning: $0) }
        }
        guard case .success(let copy) = made else {
            SelfTest.log("FEL: säkerhetskopian sparades inte")
            return
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: copy.url.path)) ?? []
        SelfTest.log("Säkerhetskopia \(copy.url.lastPathComponent): \(files.sorted().joined(separator: ", "))")
        UserWords.shared.delete(lemma: "kopieprov", language: .swedish)
        UserDefaults.standard.set(1, forKey: positionKey)
        do {
            try Backup.restore(copy)
            let back = UserWords.shared.isSaved(lemma: "kopieprov", language: .swedish)
            let position = UserDefaults.standard.integer(forKey: positionKey)
            SelfTest.log("Återställning: ordet \(back ? "är tillbaka" : "FEL, saknas"), läsposition \(position) "
                         + "(ska vara 7), \(Backup.copies().count) kopior, databaserna version "
                         + "\(AnnotationStore.shared.schemaVersion) och \(UserWords.shared.schemaVersion)")
        } catch {
            SelfTest.log("FEL: återställningen: \(error.localizedDescription)")
        }
        UserDefaults.standard.removeObject(forKey: positionKey)
        UserWords.shared.delete(lemma: "kopieprov", language: .swedish)
    }

    private static func testSync(navigation: UINavigationController) async {
        guard let url = UserDefaults.standard.string(forKey: "LasaSyncURL") else {
            SelfTest.log("Synk: ingen låtsasserver angiven, hoppar över")
            return
        }
        let client = SyncClient.shared
        client.projectURL = url
        client.anonKey = "test-anon"
        client.email = "test@example.com"
        SelfTest.log("Synk: nyckelringen svarade \(Keychain.lastStatus) (0 är ok, annars sparas nyckeln bara i minnet)")
        do {
            try await client.signIn(email: "test@example.com", password: "test-password")
            SelfTest.log("Synk: inloggad som \(client.userID ?? "?")")
        } catch {
            SelfTest.log("FEL: inloggningen misslyckades: \(error.localizedDescription)")
            return
        }

        // Något lokalt att skicka: en markering och ett bokmärke i testboken, och läspositionen.
        let book = LibraryStore.shared.allBooks().first { $0.url.lastPathComponent == "test.epub" }
        if let book = book {
            let key = AnnotationStore.key(for: book)
            AnnotationStore.shared.addHighlight(book: key, section: 2, start: 10, length: 20, text: "lokal markering",
                                                color: .green)
            AnnotationStore.shared.addBookmark(book: key, section: 3, progression: 0.5, label: "Lokalt bokmärke")
        } else {
            SelfTest.log("FEL: test.epub finns inte i biblioteket")
        }
        UserWords.shared.save(word: "tillfällig", lemma: "tillfällig", language: .swedish,
                              sentence: "Ett tillfälligt ord.", book: "test", pageIndex: 1)

        do {
            let first = try await SyncEngine.shared.sync()
            SelfTest.log("Synk 1: \(first.summary)")
        } catch {
            SelfTest.log("FEL: synk 1 misslyckades: \(error.localizedDescription)")
            return
        }
        let remoteWord = UserWords.shared.isSaved(lemma: "fjärrord", language: .swedish)
        SelfTest.log("Ord från servern finns lokalt: \(remoteWord ? "ja" : "NEJ")")
        if let book = book {
            let marks = AnnotationStore.shared.highlights(book: AnnotationStore.key(for: book))
            SelfTest.log("Markeringar i test.epub efter synk: \(marks.map(\.text).joined(separator: " | "))")
            let location = LibraryStore.shared.savedLocation(for: book)
            SelfTest.log("Läsposition i test.epub efter synk: kapitel \(location?.chapter ?? -1), andel \(location?.progression ?? -1)")
        }

        // En gång till: inget nytt ska skickas eller hämtas.
        do {
            let second = try await SyncEngine.shared.sync()
            SelfTest.log("Synk 2 (ska vara 0 och 0): \(second.summary)")
        } catch {
            SelfTest.log("FEL: synk 2 misslyckades: \(error.localizedDescription)")
        }

        // Ta bort ett ord: borttagningen ska skickas.
        await pause(0.05)
        UserWords.shared.delete(lemma: "tillfällig", language: .swedish)
        do {
            let third = try await SyncEngine.shared.sync()
            SelfTest.log("Synk 3 efter borttaget ord: \(third.summary)")
        } catch {
            SelfTest.log("FEL: synk 3 misslyckades: \(error.localizedDescription)")
        }

        navigation.pushViewController(SettingsViewController(), animated: false)
        await pause(1.0)
        SelfTest.saveScreen(navigation.view, name: "04-synk")
        navigation.popToRootViewController(animated: false)
        client.signOut()
    }
}
