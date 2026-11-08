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
        SelfTest.log("Repetition (U6), nytt ord: \(review.summaryForTest)")
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
        await testReviewFilters(navigation: navigation)

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

        await testWordCard(navigation: navigation)

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

        // Biblioteket (B1 och framåt): titlar, omslag, hållmenyn och bilder.
        if let list = library as? LibraryViewController {
            await LibrarySelfTest.run(library: list)
        }

        testLog()
        SelfTest.finish()
    }

    /// U6: småord sparas inte, ord utan svar i ordboken kommer inte med i kön, och filtret per bok, sparat till
    /// nästa gång. Bilder av repetitionen med filtret, med svaret framme och i iPhone-bredd.
    private static func testReviewFilters(navigation: UINavigationController) async {
        UserWords.shared.save(word: "att", lemma: "att", language: .swedish, sentence: "Det är svårt att veta.",
                              book: "test", pageIndex: 1)
        UserWords.shared.save(word: "The", lemma: "the", language: .english, sentence: "The book was red.",
                              book: "test", pageIndex: 1)
        let stopSaved = UserWords.shared.isSaved(lemma: "att", language: .swedish)
            || UserWords.shared.isSaved(lemma: "the", language: .english)
        // Ett ord utan svar i ordboken, som från en annan enhet (synken filtrerar inte).
        UserWords.shared.applySynced(SyncWord(lemma: "xqzvord", language: "sv", word: "xqzvord", sentence: "Xqzvord.",
                                              book: "test", created: 1, updated: Date().timeIntervalSince1970))
        let inQueue = UserWords.shared.reviewQueue().contains { $0.word.lemma == "xqzvord" }
        let saved = UserWords.shared.isSaved(lemma: "xqzvord", language: .swedish)
        SelfTest.log("Småord (U6): att och the \(stopSaved ? "FEL, sparades" : "sparas inte"). Ord utan svar: "
                     + "\(saved ? "sparat" : "FEL, inte sparat"), i kön \(inQueue ? "FEL, ja" : "nej")")
        UserWords.shared.delete(lemma: "xqzvord", language: .swedish)

        guard let record = BookRegistry.shared.records().first(where: { !$0.missing }) else {
            SelfTest.log("FEL: ingen bok i registret till filtret (U6)")
            return
        }
        for (word, sentence) in [("vacker", "Alla var överens om att den var vacker."),
                                 ("retorik", "Retorik är konsten att övertyga med ord.")] {
            UserWords.shared.save(word: word, lemma: word, language: .swedish, sentence: sentence,
                                  book: record.displayTitle, pageIndex: 11, bookID: record.id)
        }
        let before = UserDefaults.standard.string(forKey: WordReviewViewController.filterKey)
        UserDefaults.standard.set(ReviewFilter.book(record.id).storage, forKey: WordReviewViewController.filterKey)
        let review = WordReviewViewController()
        navigation.pushViewController(review, animated: false)
        await pause(0.8)
        SelfTest.log("Repetition med filter (U6): \(review.summaryForTest), först \(review.currentWord ?? "inget"), "
                     + "\(review.remaining) ord. Valen: \(review.filterChoicesForTest.joined(separator: " | "))")
        SelfTest.saveScreen(navigation.view, name: "08a-repetition-bok")
        review.reveal()
        await pause(0.5)
        SelfTest.saveScreen(navigation.view, name: "08b-repetition-bok-svar")
        let container = navigation.view!
        let original = container.frame
        container.frame = CGRect(x: 0, y: 0, width: 390, height: min(844, original.height))
        container.layoutIfNeeded()
        await pause(0.6)
        SelfTest.saveScreen(container, name: "08c-repetition-iphone")
        container.frame = original
        container.layoutIfNeeded()
        review.setFilter(.all)
        await pause(0.5)
        SelfTest.log("Filtret Alla ord (U6): \(review.summaryForTest), \(review.remaining) ord, sparat som "
                     + (UserDefaults.standard.string(forKey: WordReviewViewController.filterKey) ?? "inget"))
        navigation.popToRootViewController(animated: false)
        UserDefaults.standard.set(before, forKey: WordReviewViewController.filterKey)
        await pause(0.3)
    }

    /// U4 och O7: ordkortet, fotograferat i en ruta i kortets storlek på en tom sida (popovers kommer inte med i
    /// appens egna bilder i iOS 26), betydelsen som väljs och repetitionen som sedan bara visar den.
    private static func testWordCard(navigation: UINavigationController) async {
        guard let dictionary = WordDictionary.shared else { return }
        // En låtsasnyckel, så att AI-knappen syns. Den används inte.
        Keychain.set("test", for: .geminiAPIKey)
        defer { Keychain.set(nil, for: .geminiAPIKey) }
        let host = UIViewController()
        host.view.backgroundColor = Theme.current.canvas
        // Liten menyrad, så att den inte går in över kortet i bilderna.
        host.navigationItem.largeTitleDisplayMode = .never
        navigation.pushViewController(host, animated: false)
        await pause(0.3)

        func card(_ word: String, _ sentence: String, book: String? = "Retorikens grunder") -> WordPopupViewController {
            let found = (sentence as NSString).range(of: word, options: .caseInsensitive)
            let range: NSRange? = found.location == NSNotFound ? nil : found
            let lookup = dictionary.lookup(word, sentence: sentence, rangeInSentence: range,
                                           hidden: UserWords.shared.hiddenPairs)
            let context = WordPopupViewController.Context(sentence: sentence, rangeInSentence: range, book: book,
                                                          pageIndex: 87, triedWord: word)
            return WordPopupViewController(lookup: lookup, context: context)
        }
        func mount(_ card: WordPopupViewController, width: CGFloat = WordPopupViewController.cardWidth,
                   height: CGFloat? = nil) async -> UINavigationController {
            let wrapper = WordPopupNavigationController(rootViewController: card)
            wrapper.setNavigationBarHidden(true, animated: false)
            host.addChild(wrapper)
            wrapper.view.frame = CGRect(x: 24, y: 140, width: width, height: height ?? 640)
            wrapper.view.layer.cornerRadius = 20
            wrapper.view.clipsToBounds = true
            host.view.addSubview(wrapper.view)
            wrapper.didMove(toParent: host)
            await pause(0.6)
            if height == nil {
                wrapper.view.frame.size.height = card.contentHeight
                await pause(0.3)
            }
            return wrapper
        }
        func unmount(_ wrapper: UINavigationController) {
            wrapper.willMove(toParent: nil)
            wrapper.view.removeFromSuperview()
            wrapper.removeFromParent()
        }

        // Svenskt och engelskt ord.
        let swedish = card("vacker", "Alla var överens om att den var vacker.")
        var wrapper = await mount(swedish)
        SelfTest.log("Ordkort (U4) vacker: höjd \(Int(swedish.contentHeight)), \(swedish.senseSummaryForTest)")
        SelfTest.saveScreen(host.view, name: "07a-ordkort-svenskt")
        unmount(wrapper)
        let english = card("difficulties", "The difficulties they encountered were greater than anyone had expected.")
        wrapper = await mount(english)
        SelfTest.log("Ordkort (U4) difficulties: höjd \(Int(english.contentHeight)), \(english.senseSummaryForTest)")
        SelfTest.saveScreen(host.view, name: "07b-ordkort-engelskt")
        unmount(wrapper)

        // O10: uttal, ursprung och fler översättningar ur Wiktionary.
        var wiktionary: [String] = []
        let samples: [(String, WordLanguage)] = [("vacker", .swedish), ("retorik", .swedish), ("eklatant", .swedish),
                                                 ("difficulty", .english), ("striking", .english)]
        for (word, language) in samples {
            guard let entry = dictionary.lookup(word, language: language)?.entries.first else { continue }
            let extras = dictionary.extras(for: entry, language: language)
            wiktionary.append("\(word): uttal \(extras.ipa ?? "inget"), ursprung \(extras.etymology ?? "inget"), "
                              + "fler översättningar \(extras.moreTranslations.joined(separator: ", "))")
        }
        SelfTest.log("Wiktionary (O10): " + wiktionary.joined(separator: " | "))

        // iPhone: ark i halv höjd (iPhone 12 är 390 x 844 punkter) med stängknapp.
        let phone = card("difficulties", "The difficulties they encountered were greater than anyone had expected.")
        phone.showsCloseButton = true
        wrapper = await mount(phone, width: 390, height: 422)
        SelfTest.saveScreen(host.view, name: "07f-ordkort-iphone")
        unmount(wrapper)

        // O7: ett ord med flera betydelser. AI:n föreslår den andra, betydelserna fälls ut och den andra väljs.
        let sentence = "Det var inte lätt att förstå vad talaren menade."
        let candidates = ["lätt", "fast", "slå", "skarp", "bära"]
        guard let word = candidates.first(where: { (dictionary.lookup($0)?.entries.first?.senses.count ?? 0) > 1 }),
              let lookup = dictionary.lookup(word, sentence: sentence),
              let entry = lookup.entries.first else {
            SelfTest.log("FEL: inget testord med flera betydelser")
            navigation.popToRootViewController(animated: false)
            return
        }
        UserWords.shared.save(word: word, lemma: entry.lemma, language: lookup.language, sentence: sentence,
                              book: "Retorikens grunder", pageIndex: 87)
        let multi = card(word, sentence)
        wrapper = await mount(multi)
        multi.showAIAnswerForTest(WordExplanation(senseText: WordText.gloss(entry.senses[1]),
                                                  bestWord: entry.senses[1].synonyms.first?.word,
                                                  explanation: "Här betyder det att något inte var enkelt."))
        await pause(0.4)
        wrapper.view.frame.size.height = multi.contentHeight
        await pause(0.3)
        SelfTest.saveScreen(host.view, name: "07e-ordkort-ai")
        multi.expandSensesForTest()
        await pause(0.4)
        wrapper.view.frame.size.height = multi.contentHeight
        await pause(0.3)
        SelfTest.log("Ordkort (O7) \(word): \(multi.senseSummaryForTest), höjd med betydelserna \(Int(multi.contentHeight))")
        SelfTest.saveScreen(host.view, name: "07c-ordkort-betydelser")
        if let id = multi.senseIDForTest(1) {
            multi.choose(senseID: id)
        }
        await pause(0.5)
        wrapper.view.frame.size.height = multi.contentHeight
        await pause(0.3)
        SelfTest.saveScreen(host.view, name: "07d-ordkort-vald-betydelse")
        unmount(wrapper)
        let stored = UserWords.shared.senseID(lemma: entry.lemma, language: lookup.language)
        SelfTest.log("Vald betydelse sparad: \(stored ?? "INGEN") (ska vara \(entry.senses[1].id)), \(multi.senseSummaryForTest)")

        // Ett nytt kort för samma ord visar den valda betydelsen överst.
        let again = card(word, sentence)
        wrapper = await mount(again)
        SelfTest.log("Nytt kort för \(word): \(again.senseSummaryForTest)")
        unmount(wrapper)

        // Repetitionen visar bara den valda betydelsen.
        if let saved = UserWords.shared.savedWords().first(where: { $0.lemma == entry.lemma && $0.language == lookup.language }) {
            let answer = WordReviewViewController.answer(for: saved)
            let chosen = entry.senses[1]
            let expected = chosen.definition ?? WordText.synonymLine(chosen)
            let other = entry.senses[0].definition ?? WordText.synonymLine(entry.senses[0])
            let showsChosen = answer.contains(expected) ? "visar den" : "VISAR INTE DEN"
            let showsOther = answer.contains(other) && other != expected ? "VISAS OCKSÅ" : "visas inte"
            SelfTest.log("Repetitionen med vald betydelse (\(saved.senseID)): \(showsChosen), första betydelsen \(showsOther)")
            let review = WordReviewViewController()
            navigation.pushViewController(review, animated: false)
            await pause(0.6)
            review.showOnlyForTest(saved)
            await pause(0.4)
            SelfTest.saveScreen(navigation.view, name: "07g-repetition-vald-betydelse")
        } else {
            SelfTest.log("FEL: \(word) sparades inte")
        }

        // D3-1: Sparat i kortet tar bort ordet och visar raden Ångra. Ångra lägger tillbaka samma rad (id, bok,
        // betydelse, mening) och hela repetitionen, och borttagningen glöms så att synken inte tar bort ordet.
        navigation.popToViewController(host, animated: false)
        await pause(0.3)
        UserWords.shared.save(word: word, lemma: entry.lemma, language: lookup.language, sentence: sentence,
                              book: "Retorikens grunder", pageIndex: 87, bookID: "självtest-bok")
        if let saved = UserWords.shared.savedWords().first(where: { $0.lemma == entry.lemma && $0.language == lookup.language }) {
            UserWords.shared.record(.good, for: ReviewCard(word: saved, interval: 0, ease: 2.5, reps: 0, lapses: 0,
                                                           isNew: true))
        }
        let before = UserWords.shared.savedWordRecord(lemma: entry.lemma, language: lookup.language)
        let undoCard = card(word, sentence)
        wrapper = await mount(undoCard)
        undoCard.toggleSavedForTest()
        await pause(0.4)
        let removed = !UserWords.shared.isSaved(lemma: entry.lemma, language: lookup.language)
            && UserWords.shared.deletionTime(lemma: entry.lemma, language: lookup.language) != nil
        let shown = UndoBar.current != nil
        SelfTest.saveScreen(host.view.window ?? host.view, name: "07h-ordkort-angra")
        UndoBar.current?.performUndo()
        await pause(0.4)
        let after = UserWords.shared.savedWordRecord(lemma: entry.lemma, language: lookup.language)
        var expected = before
        expected?.updated = after?.updated ?? -1
        let same = before?.review != nil && before?.bookID == "självtest-bok" && after != nil && after == expected
        let forgotten = UserWords.shared.deletionTime(lemma: entry.lemma, language: lookup.language) == nil
        let synced = UserWords.shared.wordsForSync().first { $0.lemma == entry.lemma && $0.language == lookup.language.rawValue }
        let live = synced?.deleted == false && synced?.reps == before?.review?.reps
        let ok = removed && shown && same && forgotten && live
        let ids = "id \(before?.id ?? -1) och \(after?.id ?? -1)"
        let reps = "repetitioner \(before?.review?.reps ?? -1) och \(after?.review?.reps ?? -1)"
        let removedText = removed ? "borttaget" : "FEL, kvar"
        let shownText = shown ? "visas" : "saknas"
        let sameText = same ? "samma rad och repetition" : "FEL, raden skiljer"
        let forgottenText = forgotten ? "glömd" : "FEL, kvar"
        let liveText = live ? "levande" : "FEL, borttaget"
        SelfTest.log("Sparat i ordkortet (D3-1): ordet \(removedText), raden Ångra \(shownText), efter Ångra "
                     + "\(sameText) (\(ids), \(reps)), borttagningen \(forgottenText), till synken \(liveText). "
                     + (ok ? "Rätt" : "FEL"))
        unmount(wrapper)

        UserWords.shared.delete(lemma: entry.lemma, language: lookup.language)
        navigation.popToRootViewController(animated: false)
        await pause(0.3)
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

        // Granskningens fynd 7: Ersätt och börja om byter filen på en gång (replaceItemAt), och den gamla
        // raden markeras som borta först efter bytet.
        try? Data("# Importprov\n\nFjärde versionen, den längsta av dem alla hittills.\n".utf8).write(to: first)
        BookImporter.selfTestAnswer = .replaceStartingOver
        let fresh = await importing(first, move: true).first
        let oldRow = replaced.flatMap { BookRegistry.shared.record(id: $0.id) }
        let text = fresh.flatMap { try? String(contentsOf: $0.url, encoding: .utf8) } ?? ""
        let freshOK = fresh != nil && fresh?.id != replaced?.id && oldRow?.missing == true && text.contains("Fjärde")
        SelfTest.log("Ersätt och börja om (fynd 7): \(fresh?.path ?? "FEL, ingen bok") med "
                     + "\(fresh?.id != replaced?.id ? "nytt id" : "samma id") och den gamla raden "
                     + "\(oldRow?.missing == true ? "borta" : "kvar"), filen har nya texten: \(text.contains("Fjärde")). "
                     + "\(freshOK ? "Rätt" : "FEL")")
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

        // U1: biblioteket i alla fyra bakgrunder. Papper är förvalt.
        let savedTheme = ReaderTheme.current
        SelfTest.log("Bakgrund från början: \(ReaderTheme.effective.title), Följ systemet: \(ReaderTheme.followsSystem)")
        for option in ReaderTheme.allCases {
            ReaderTheme.current = option
            Theme.apply()
            if let list = libraryList {
                list.applyTheme()
                list.reload()
            }
            await pause(0.6)
            SelfTest.saveScreen(library.navigationController?.view ?? library.view, name: "07-bibliotek-\(option.rawValue)")
        }
        ReaderTheme.current = savedTheme
        Theme.apply()
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
        await testBackupPruning()
    }

    /// Granskningens fynd 1 och 2: sju påhittade dagar med kopior och en kopia före uppdateringen. Återställ
    /// från den äldsta ska lyckas och lämna den kvar, kopian före uppdateringen rensas aldrig, och flera kopior
    /// samma dag ersätter varandra. Fynd 3: synken är avstängd efter en återställning tills nästa start.
    private static func testBackupPruning() async {
        let manager = FileManager.default
        guard let latest = Backup.dailyCopies().first else {
            SelfTest.log("FEL: ingen kopia att bygga provet av rensningen på")
            return
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        var made: [URL] = []
        for day in 1...7 {
            let date = Date().addingTimeInterval(-Double(day) * 86_400)
            let url = Backup.directory.appendingPathComponent(formatter.string(from: date), isDirectory: true)
            try? manager.removeItem(at: url)
            try? manager.copyItem(at: latest.url, to: url)
            made.append(url)
        }
        let beforeUpdate = Backup.directory.appendingPathComponent(Backup.beforeUpdatePrefix + "2000-01-01 000000",
                                                                    isDirectory: true)
        try? manager.removeItem(at: beforeUpdate)
        try? manager.copyItem(at: latest.url, to: beforeUpdate)
        defer {
            for url in made + [beforeUpdate] {
                try? manager.removeItem(at: url)
            }
        }
        let daysBefore = Set(Backup.dailyCopies().map { Calendar.current.startOfDay(for: $0.date) }).count
        guard let oldest = Backup.dailyCopies().last else { return }
        do {
            try Backup.restore(oldest)
            let kept = manager.fileExists(atPath: oldest.url.path)
            let beforeKept = manager.fileExists(atPath: beforeUpdate.path)
            let listed = Backup.copies().contains { $0.isBeforeUpdate && $0.url.lastPathComponent == beforeUpdate.lastPathComponent }
            SelfTest.log("Återställ från den äldsta (fynd 1): kopior på \(daysBefore) dagar, återställningen lyckades, "
                         + "den valda kopian \(kept ? "finns kvar" : "är borta"), Före uppdateringen "
                         + "\(beforeKept && listed ? "kvar och i listan" : "borta") (fynd 2). "
                         + "\(kept && beforeKept && listed ? "Rätt" : "FEL")")
        } catch {
            SelfTest.log("FEL: återställningen från den äldsta kopian: \(error.localizedDescription)")
        }

        // N1 (granskning 2): två egna kopior till i dag. Ingen av dagens tidigare kopior tas bort (förut
        // ersatte de varandra), och de sju dagarna räknas per dag.
        let earlierToday = Backup.dailyCopies().filter { $0.date >= Calendar.current.startOfDay(for: Date()) }.map(\.url)
        for _ in 0..<2 {
            let extra: Result<Backup.Copy, Error> = await withCheckedContinuation { continuation in
                Backup.make { continuation.resume(returning: $0) }
            }
            if case .failure(let error) = extra {
                SelfTest.log("FEL: en extra kopia gick inte att spara: \(error.localizedDescription)")
            }
        }
        let daily = Backup.dailyCopies()
        let today = Calendar.current.startOfDay(for: Date())
        let todayCount = daily.filter { $0.date >= today }.count
        let days = Set(daily.map { Calendar.current.startOfDay(for: $0.date) }).count
        let beforeStill = manager.fileExists(atPath: beforeUpdate.path)
        let todaysKept = earlierToday.allSatisfy { manager.fileExists(atPath: $0.path) }
        let kinds = daily.filter { $0.date >= today }.map { SettingsViewController.backupTitle($0) }
        SelfTest.log("Rensningen per dag (fynd 2, N1): \(daily.count) dagliga kopior på \(days) dagar, \(todayCount) i dag "
                     + "(\(kinds.joined(separator: "; "))), dagens \(earlierToday.count) tidigare kopior "
                     + "\(todaysKept ? "kvar" : "FEL, borttagna"), Före uppdateringen \(beforeStill ? "kvar" : "borta"). "
                     + "\(todaysKept && days == 7 && todayCount == earlierToday.count + 2 && beforeStill ? "Rätt" : "FEL")")

        // Fynd 3 (granskning 2): efter en återställning står synken still tills den startas igen, också efter
        // en omstart (pausen är sparad).
        let engine = SyncEngine.shared
        engine.pauseAfterRestore()
        let saved = UserDefaults.standard.bool(forKey: SyncEngine.pausedKey)
        var paused = false
        do {
            _ = try await engine.sync()
        } catch is SyncEngine.PausedError {
            paused = true
        } catch {
            paused = false
        }
        engine.resumeForSelfTest()
        // Återställningen av den påhittade kopian tog tillbaka provets läsposition, som tas bort igen.
        UserDefaults.standard.removeObject(forKey: "position.kopieprov.pdf")
        SelfTest.log("Synken efter återställning (fynd 3): \(paused ? "pausad" : "FEL, körde"), pausen sparad "
                     + "\(saved ? "(gäller efter omstart)" : "FEL, bara i minnet"), startad igen: "
                     + "\(engine.isPaused ? "FEL" : "ja"). \(paused && saved && !engine.isPaused ? "Rätt" : "FEL")")
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
