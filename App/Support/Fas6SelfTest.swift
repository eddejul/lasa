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
        navigation.popToRootViewController(animated: false)
        SelfTest.finish()
    }

    /// G8: databasernas versioner, trappan av uppdateringar och att en avbruten transaktion inte sparar något.
    /// Trappan provas i en databas i minnet, så att användarens filer inte rörs.
    private static func testDatabases() {
        SelfTest.log("Databasernas versioner: markeringar \(AnnotationStore.shared.schemaVersion), "
                     + "sparade ord \(UserWords.shared.schemaVersion) (ska vara 1 och 1)")
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
