import UIKit

/// Självtestet för AI-frågorna (K6b), sist i `-LasaSelfTest ai` mot låtsas-Gemini (`tools/simtest/mock_gemini.py`
/// svarar på fragor-1 med frågor ur texten i frågan och på jamfor-1 med ett omdöme). Frågefilerna bredvid
/// test.epub och test.pdf läggs undan under provet, så att böckerna får AI-frågor, och läggs tillbaka efteråt.
/// Läsaren öppnas i ett kapitel, frågorna görs i bakgrunden och sparas, prickarna, raden Läs för att ta reda på,
/// rutan före och efter Visa svaret, Jämför, Visa i boken, självtestet efter kapitlet och fliken Frågor prövas.
/// Ingen riktig nyckel används.
@MainActor
enum AIQuestionsSelfTest {

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static let questionFiles = ["test.epub.fragor.json", "test.pdf.fragor.json"]

    /// Flyttar frågefilerna undan (`.av`) eller tillbaka.
    private static func moveQuestionFiles(aside: Bool) {
        let folder = LibraryStore.shared.booksDirectory
        for name in questionFiles {
            let file = folder.appendingPathComponent(name)
            let away = folder.appendingPathComponent(name + ".av")
            let (from, to) = aside ? (file, away) : (away, file)
            guard FileManager.default.fileExists(atPath: from.path) else { continue }
            try? FileManager.default.removeItem(at: to)
            do {
                try FileManager.default.moveItem(at: from, to: to)
            } catch {
                SelfTest.log("FEL: frågefilen \(name) kunde inte flyttas: \(error)")
            }
        }
    }

    static func run(navigation: UINavigationController) async {
        let books = LibraryStore.shared.booksDirectory
        guard let epub = LibraryStore.shared.book(at: books.appendingPathComponent("test.epub")),
              let pdf = LibraryStore.shared.book(at: books.appendingPathComponent("test.pdf")) else {
            SelfTest.log("FEL: test.epub eller test.pdf saknas (AI-frågor)")
            return
        }
        let wasQuestions = QuestionsSetting.isEnabled
        let wasAI = AIQuestionsSetting.isEnabled
        Keychain.set("mock-ok", for: .geminiAPIKey)
        QuestionsSetting.isEnabled = true
        AIQuestionsSetting.isEnabled = true
        AIQuestionMaker.shared.pauseBetweenCalls = 0.3
        moveQuestionFiles(aside: true)
        SelfTest.log("AI-frågor: databasen version \(AnnotationStore.shared.schemaVersion) (ska vara "
                     + "\(AnnotationStore.migrations.count)), Gör frågor med AI \(AIQuestionsSetting.isEnabled), "
                     + "frågefil till test.epub \(BookQuestionFile.url(for: epub) != nil) (ska vara false)")
        await testBook(epub, name: "epub", navigation: navigation)
        await testBook(pdf, name: "pdf", navigation: navigation)
        moveQuestionFiles(aside: false)
        QuestionsSetting.isEnabled = wasQuestions
        AIQuestionsSetting.isEnabled = wasAI
        AIQuestionMaker.shared.pauseBetweenCalls = 4
        SelfTest.log("AI-frågor: frågefilerna tillbaka \(BookQuestionFile.url(for: epub) != nil), "
                     + "\(AIClient.callsToday) anrop i dag")
    }

    private static func testBook(_ book: Book, name: String, navigation: UINavigationController) async {
        let defaults = UserDefaults.standard
        let reader: UIViewController
        if book.kind == .pdf {
            defaults.set(0, forKey: "bookPosition.\(book.id)")
            guard let pdfReader = PDFCurlReaderViewController(book: book) else {
                SelfTest.log("FEL: \(name) gick inte att öppna (AI-frågor)")
                return
            }
            reader = pdfReader
        } else {
            // Kapitel 2 i läsordningen (plats 1), från början.
            defaults.set("1|0.0", forKey: "bookLocation.\(book.id)")
            reader = ReflowReaderViewController(book: book)
        }
        navigation.pushViewController(reader, animated: false)
        let started = Date()
        // Kapitlet som visas och nästa kapitel görs i bakgrunden, när läsaren har visat sidan.
        var ready = false
        for _ in 0..<150 {
            await pause(0.4)
            if let questions = ReaderQuestions.current, questions.book.id == book.id, questions.isLocated,
               !questions.places.isEmpty {
                ready = true
                break
            }
        }
        guard let questions = ReaderQuestions.current, questions.book.id == book.id else {
            SelfTest.log("FEL: läsaren för \(name) fick inga frågor (AI-frågor)")
            navigation.popToRootViewController(animated: false)
            return
        }
        let records = AIQuestionStore.shared.records(book: book.id)
        let byTiming = Dictionary(grouping: questions.questions, by: \.timing).mapValues(\.count)
        SelfTest.log("AI-frågor (\(name)): klara \(ready) efter \(Int(Date().timeIntervalSince(started))) s, "
                     + "\(records.count) delar sparade (" + records.map { "\($0.chapter): \($0.questions.count)" }
                        .joined(separator: ", ") + "), frågor \(byTiming), \(questions.places.count) placerade i texten, "
                     + "kapitel \(questions.aiChapterCount.done) av \(questions.aiChapterCount.total)")
        if let record = records.first(where: { !$0.questions.isEmpty }) {
            SelfTest.log("AI-frågor (\(name)): \(record.chapter) \"\(record.chapterTitle)\", sammanfattning "
                         + "\(record.summary.count) tecken, begrepp \(record.concepts), id "
                         + "\(record.questions.first?.id ?? "inget"), avsnitt \(record.questions.compactMap(\.avsnitt))")
        }
        await pause(1.5)
        SelfTest.saveScreen(reader.view, name: "aifragor-\(name)-01-prickar")

        // Läs för att ta reda på: kapitlet öppnades på första sidan.
        if let banner = BeforeReadingBanner.current, banner.superview != nil {
            SelfTest.log("AI-frågor (\(name)): raden Läs för att ta reda på visas")
            SelfTest.saveScreen(reader.view, name: "aifragor-\(name)-02-fore")
            banner.showTapped()
            await pause(0.9)
            if let shown = reader.presentedViewController as? UINavigationController {
                SelfTest.saveScreen(shown.view, name: "aifragor-\(name)-03-fore-fragor")
                SelfTest.log("AI-frågor (\(name)): Visa öppnade \(shown.viewControllers.first?.title ?? "inget")")
            } else {
                SelfTest.log("FEL: Visa öppnade inga frågor före läsningen")
            }
            reader.presentedViewController?.dismiss(animated: false)
            await pause(0.5)
        } else {
            SelfTest.log("AI-frågor (\(name)): raden Läs för att ta reda på visas inte (fore-frågor "
                         + "\(questions.questions.filter { $0.timing == "fore" }.count))")
        }

        // Rutan med en fråga i texten, före och efter Visa svaret, Jämför och Visa i boken.
        if let first = questions.questions.first(where: { $0.timing == "efter" && questions.place(of: $0.id) != nil }) {
            questions.presentCard(for: first.id, from: reader, sourceView: reader.view,
                                  sourceRect: CGRect(x: reader.view.bounds.midX, y: 200, width: 2, height: 2))
            await pause(1.0)
            if let shown = reader.presentedViewController as? UINavigationController,
               let card = shown.viewControllers.first as? AIQuestionCardViewController {
                let before = card.visibleText
                SelfTest.log("AI-frågor (\(name)): rutan före svaret: \(before)")
                SelfTest.log("AI-frågor (\(name)): källan syns före svaret \(before.contains(first.source)) (ska vara false), "
                             + "Jämför syns utan svar \(card.showsCompare) (ska vara false)")
                SelfTest.saveScreen(shown.view, name: "aifragor-\(name)-04-ruta")
                card.setAnswerForSelfTest("Författaren vill visa avsnittets huvudtanke.")
                SelfTest.log("AI-frågor (\(name)): Jämför syns med svar \(card.showsCompare)")
                card.compare()
                for _ in 0..<60 where card.lastFeedback == nil {
                    await pause(0.25)
                }
                SelfTest.log("AI-frågor (\(name)): Jämför gav \(card.lastFeedback?["omdome"] as? String ?? "inget"), "
                             + "förslaget \(card.suggestedStatus?.title ?? "inget")")
                card.revealAnswer()
                await pause(0.5)
                SelfTest.log("AI-frågor (\(name)): rutan efter svaret: \(card.visibleText)")
                SelfTest.saveScreen(shown.view, name: "aifragor-\(name)-05-svar")
                card.choose(.unsure)
                await pause(0.4)
            } else {
                SelfTest.log("FEL: rutan med AI-frågan öppnades inte")
            }
            reader.presentedViewController?.dismiss(animated: false)
            await pause(0.6)
            let saved = QuestionStore.shared.myAnswer(question: first.id, book: book.id)
            SelfTest.log("AI-frågor (\(name)): svaret sparat \(saved.text.count) tecken, bedömning sparad "
                         + "\(!saved.feedback.isEmpty), läget \(QuestionStore.shared.statuses(book: book.id)[first.id]?.title ?? "inget")")
            questions.showInBook(first)
            for _ in 0..<24 where questions.lastJump == nil {
                await pause(0.25)
            }
            SelfTest.log("AI-frågor (\(name)): Visa i boken hoppade till "
                         + (questions.lastJump.map { "avsnitt \($0.section), tecken \($0.start)" } ?? "ingenstans"))
            await pause(1.5)
            SelfTest.saveScreen(reader.view, name: "aifragor-\(name)-06-visa-i-boken")
        } else {
            SelfTest.log("FEL: ingen AI-fråga i texten placerad (\(name))")
        }

        // Självtestet efter kapitlet (K7): kapitlets frågor före, i texten och efter.
        if let chapter = questions.aiContext?.chapters.first(where: { chapter in
            records.contains { $0.chapter == chapter.key && !$0.questions.isEmpty }
        }) {
            let list = questions.chapterQuestions(sections: chapter.sections)
            let cards = ChapterTestLogic.cards(highlights: [], allHighlights: [], questions: list, terms: [],
                                               book: book.id, source: chapter.title)
            SelfTest.log("AI-frågor (\(name)): K7 i \(chapter.key) har \(list.count) frågor och \(cards.count) kort "
                         + "(\(Dictionary(grouping: list, by: \.timing).mapValues(\.count)))")
        }

        // Fliken Frågor.
        let tab = questions.makeList(placeLabel: { "avsnitt \($0.section + 1)" }, onSelect: { _, _ in })
        let holder = UINavigationController(rootViewController: tab)
        holder.modalPresentationStyle = .formSheet
        reader.present(holder, animated: false)
        await pause(1.0)
        SelfTest.log("AI-frågor (\(name)): fliken Frågor \(tab.count) frågor, \"\(tab.aiStatusText)\", knappar "
                     + "\(tab.actionTitles)")
        SelfTest.saveScreen(holder.view, name: "aifragor-\(name)-07-flik")
        if name == "epub" {
            tab.runAction("Gör frågor till hela boken")
            await pause(0.5)
            SelfTest.log("AI-frågor (\(name)): hela boken startad, \"\(tab.aiStatusText)\"")
            for _ in 0..<240 {
                await pause(0.5)
                if AIQuestionMaker.shared.progress(book: book.id) == nil,
                   !AIQuestionMaker.shared.isWorking(book: book.id) {
                    break
                }
            }
            await pause(1.0)
            let all = AIQuestionStore.shared.records(book: book.id)
            let synthesis = all.flatMap(\.questions).filter { $0.typ == "syntes" }.count
            SelfTest.log("AI-frågor (\(name)): hela boken klar, \"\(tab.aiStatusText)\", \(all.count) delar, "
                         + "syntes \(synthesis) (ska vara 1), anrop i dag \(AIClient.callsToday)")
            SelfTest.saveScreen(holder.view, name: "aifragor-\(name)-08-hela-boken")
        }
        holder.dismiss(animated: false)
        await pause(0.5)
        navigation.popToRootViewController(animated: false)
        await pause(1.0)
    }
}
