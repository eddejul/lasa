import PDFKit
import UIKit

/// Självtestet för Förklara stycket (A1) och guiden för AI-nyckeln (U7), mot en låtsas-Gemini
/// (`tools/simtest/mock_gemini.py`). Körs bara med `-LasaSelfTest ai -LasaGeminiURL http://127.0.0.1:<port>`.
/// Låtsasservern svarar efter nyckeln: mock-ok ger ett svar, mock-bad fel nyckel, mock-quota-day dagens kvot slut
/// och mock-quota-minute minutens kvot slut med 30 sekunders väntan. Ingen riktig nyckel används.
@MainActor
enum AISelfTest {

    static let name = "ai"

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    static func run(from library: UIViewController) async {
        guard let navigation = library.navigationController else {
            SelfTest.finish()
            return
        }
        SelfTest.log("AI: ai-svar.sqlite version \(AIStore.shared.schemaVersion), adress \(AIClient.baseURL), "
                     + "\(AIClient.callsToday) anrop i dag, \(AIStore.shared.answerCount) sparade svar")
        testParagraphs()

        let books = LibraryStore.shared.booksDirectory
        guard let epub = LibraryStore.shared.book(at: books.appendingPathComponent("test.epub")),
              let pdf = LibraryStore.shared.book(at: books.appendingPathComponent("test.pdf")) else {
            SelfTest.log("FEL: test.epub eller test.pdf saknas i biblioteket")
            SelfTest.finish()
            return
        }
        let content = await Task.detached { try? ReflowableBookLoader.load(epub) }.value
        guard let content = content, content.chapters.count > 3 else {
            SelfTest.log("FEL: test.epub gick inte att packa upp")
            SelfTest.finish()
            return
        }

        // Markeringar att förklara: ett svenskt stycke (A), ett engelskt med egen anteckning (B) och en PDF-sida (C).
        guard let a = highlight(in: content.chapters[1].url, book: epub, section: 1, paragraph: 1),
              var b = highlight(in: content.chapters[3].url, book: epub, section: 3, paragraph: 1),
              let c = pdfHighlight(pdf) else {
            SelfTest.log("FEL: kunde inte göra testmarkeringarna")
            SelfTest.finish()
            return
        }
        b.note = "Min egen anteckning."
        AnnotationStore.shared.update(b)
        let chapterA = content.title(ofChapter: 1)

        // Besked: utan nyckel, kvoten slut för dagen och minuten, fel nyckel, inget nät.
        Keychain.set(nil, for: .geminiAPIKey)
        AIClient.resetKeyStatus()
        SelfTest.log("Läget utan nyckel: \(AIClient.keyStatus.title)")
        let none = await explain(a, book: epub, chapter: chapterA, source: .chapter(content.chapters[1].url),
                                 navigation: navigation, photo: "ai-01-utan-nyckel")
        SelfTest.log("Utan nyckel: \(none.stateText), \(none.lastFailure?.errorDescription ?? "inget fel")")
        for key in ["mock-quota-day", "mock-quota-minute", "mock-bad"] {
            Keychain.set(key, for: .geminiAPIKey)
            let box = await explain(a, book: epub, chapter: chapterA, source: .chapter(content.chapters[1].url),
                                    navigation: navigation, photo: key == "mock-quota-day" ? "ai-02-kvot" : nil)
            SelfTest.log("Nyckel \(key): \(box.stateText), \(box.lastFailure?.errorDescription ?? "inget fel")")
        }
        SelfTest.log("Läget efter fel nyckel: \(AIClient.keyStatus.title)")
        Keychain.set("mock-ok", for: .geminiAPIKey)
        AIClient.overrideBaseURL = "http://127.0.0.1:9"
        let offline = await explain(a, book: epub, chapter: chapterA, source: .chapter(content.chapters[1].url),
                                    navigation: navigation, photo: nil)
        SelfTest.log("Utan nät: \(offline.stateText), \(offline.lastFailure?.errorDescription ?? "inget fel")")
        AIClient.overrideBaseURL = nil

        // Svaret: visas, sparas som anteckning och hämtas inte igen.
        let callsBefore = AIClient.callsToday
        let first = await explain(a, book: epub, chapter: chapterA, source: .chapter(content.chapters[1].url),
                                  navigation: navigation, photo: "ai-03-svar")
        if let box = navigation.topViewController as? ExplainViewController {
            box.revealAnswerForSelfTest()
            await pause(0.3)
            SelfTest.saveScreen(navigation.view, name: "ai-04-svar-visat")
        }
        navigation.popToRootViewController(animated: false)
        SelfTest.log("Svar A: \(first.stateText), sparat svar \(first.lastWasCached), anteckning sparad "
                     + "\(first.noteWasSaved), begrepp \(first.lastExplanation?.concepts.count ?? 0), "
                     + "anrop \(callsBefore) till \(AIClient.callsToday)")
        logPrompt(first.lastPrompt, name: "A")
        let callsAfterFirst = AIClient.callsToday
        let again = await explain(a, book: epub, chapter: chapterA, source: .chapter(content.chapters[1].url),
                                  navigation: navigation, photo: "ai-05-sparat-svar")
        navigation.popToRootViewController(animated: false)
        let noteA = AnnotationStore.shared.highlight(id: a.id)?.note ?? ""
        SelfTest.log("Samma fråga igen: sparat svar \(again.lastWasCached), anrop \(callsAfterFirst) till "
                     + "\(AIClient.callsToday), förklaringar i anteckningen \(count(PassageExplain.noteHeading, in: noteA))")
        SelfTest.log("Anteckning A börjar: \(noteA.prefix(120).replacingOccurrences(of: "\n", with: " / "))")

        let english = await explain(b, book: epub, chapter: content.title(ofChapter: 3),
                                    source: .chapter(content.chapters[3].url), navigation: navigation, photo: nil)
        navigation.popToRootViewController(animated: false)
        let noteB = AnnotationStore.shared.highlight(id: b.id)?.note ?? ""
        SelfTest.log("Svar B (engelska, egen anteckning): \(english.stateText), egen text först "
                     + "\(noteB.hasPrefix("Min egen anteckning.")), förklaringar \(count(PassageExplain.noteHeading, in: noteB))")
        logPrompt(english.lastPrompt, name: "B")

        let page = await explain(c, book: pdf, chapter: "Kapitel 1", source: .pdf(pdf.url), navigation: navigation,
                                 photo: nil)
        navigation.popToRootViewController(animated: false)
        SelfTest.log("Svar C (PDF): \(page.stateText), anteckning sparad \(page.noteWasSaved)")
        logPrompt(page.lastPrompt, name: "C")
        SelfTest.log("Läget efter svaren: \(AIClient.keyStatus.title), \(AIClient.callsToday) anrop i dag, "
                     + "\(AIStore.shared.answerCount) sparade svar")

        await testGuide(navigation: navigation)

        // Markeringsraden med Förklara och den riktiga rutan som popover, till skärmbilderna från simctl.
        let menu = HighlightMenuViewController(highlight: a)
        menu.onNote = {}
        menu.onCite = {}
        menu.onConcept = {}
        menu.onLookUp = {}
        menu.onExplain = {}
        HighlightMenuViewController.present(menu, from: library, sourceView: library.view,
                                            sourceRect: CGRect(x: 300, y: 500, width: 200, height: 40))
        await pause(1.0)
        SelfTest.log("Markeringsraden: \(menu.view.subviews.isEmpty ? "tom" : "visas"), storlek "
                     + "\(Int(menu.preferredContentSize.width)) x \(Int(menu.preferredContentSize.height))")
        SelfTest.saveScreen(menu.view, name: "ai-08-raden")
        await pause(7.0)
        menu.dismiss(animated: false)
        await pause(0.5)
        PassageExplain.present(highlight: a, book: epub, chapter: chapterA, source: .chapter(content.chapters[1].url),
                               from: library, sourceView: library.view,
                               sourceRect: CGRect(x: 300, y: 500, width: 200, height: 40), onSaved: {})
        await pause(8.0)
        library.presentedViewController?.dismiss(animated: false)
        await pause(0.5)
        SelfTest.finish()
    }

    // MARK: Delarna

    /// Ren logik: styckena ur HTML och meningarna runt en markering.
    private static func testParagraphs() {
        let html = "<html><head><title>Titel</title><style>p { color: red }</style></head><body>"
            + "<h1>Rubrik</h1><p>Första stycket. Det har två meningar.</p>\n<p>Andra &amp; stycket med "
            + "<em>markerad\n text</em> i mitten. Mer text h&#228;r.</p><p>Tredje.</p><script>var x = 1;</script></body></html>"
        let paragraphs = PassageText.paragraphs(html: html)
        SelfTest.log("Styckena ur HTML: \(paragraphs.count): \(paragraphs.joined(separator: " | "))")
        let marked = Highlight(id: "t1", book: "t", section: 0, start: 0, length: 13, text: "markerad text",
                               color: .yellow, note: "", created: Date(), updated: Date())
        SelfTest.log("Stycket runt markeringen: \(PassageText.paragraphPassage(marked, paragraphs: paragraphs).context)")
        let sentences = "Ett är först. Två kommer sedan. Tre är mitt. Fyra har markeringen här. Fem följer. "
            + "Sex är näst sist. Sju är sist."
        let start = (sentences as NSString).range(of: "markeringen").location
        let inPDF = Highlight(id: "t2", book: "t", section: 0, start: start, length: 11, text: "markeringen",
                              color: .yellow, note: "", created: Date(), updated: Date())
        SelfTest.log("Meningarna runt markeringen: \(PassageText.sentencePassage(inPDF, in: sentences).context)")
        let long = String(repeating: "Ett långt stycke utan slut. ", count: 200)
        let longStart = (long as NSString).length / 2
        let inLong = Highlight(id: "t3", book: "t", section: 0, start: longStart, length: 10,
                               text: (long as NSString).substring(with: NSRange(location: longStart, length: 10)),
                               color: .yellow, note: "", created: Date(), updated: Date())
        let longPassage = PassageText.sentencePassage(inLong, in: long)
        SelfTest.log("Långt stycke: \(long.count) tecken blev \(longPassage.context.count) (högst \(PassageText.maxLength))")
    }

    /// En markering mitt i ett stycke i kapitlet, sparad i markeringarna.
    private static func highlight(in chapter: URL, book: Book, section: Int, paragraph: Int) -> Highlight? {
        guard let html = try? String(contentsOf: chapter, encoding: .utf8) else { return nil }
        let paragraphs = PassageText.paragraphs(html: html).filter { $0.split(separator: " ").count >= 8 }
        guard !paragraphs.isEmpty else { return nil }
        let words = paragraphs[min(paragraph, paragraphs.count - 1)].split(separator: " ")
        let text = words[2..<min(8, words.count)].joined(separator: " ")
        return AnnotationStore.shared.addHighlight(book: AnnotationStore.key(for: book), section: section,
                                                   start: 500_000 + 1_000 * section, length: (text as NSString).length,
                                                   text: text, color: .yellow)
    }

    /// En markering av en mening mitt på andra sidan i test.pdf.
    private static func pdfHighlight(_ book: Book) -> Highlight? {
        guard let document = PDFDocument(url: book.url), let string = document.page(at: 1)?.string else { return nil }
        let text = string as NSString
        var sentences: [NSRange] = []
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length),
                                 options: [.bySentences, .substringNotRequired]) { _, range, _, _ in
            sentences.append(range)
        }
        guard sentences.count > 6 else { return nil }
        let range = sentences[sentences.count / 2]
        let marked = text.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        let local = text.range(of: marked, options: [], range: range)
        SelfTest.log("PDF-sidan: \(text.length) tecken, \(sentences.count) meningar, markerar mening \(sentences.count / 2)")
        return AnnotationStore.shared.addHighlight(book: AnnotationStore.key(for: book), section: 1,
                                                   start: local.location, length: local.length, text: marked,
                                                   color: .yellow)
    }

    /// Visar rutan i bibliotekets navigering (så att den kommer med på appens egen bild) och väntar på svaret.
    private static func explain(_ highlight: Highlight, book: Book, chapter: String?, source: PassageExplain.Source,
                                navigation: UINavigationController, photo: String?) async -> ExplainViewController {
        navigation.popToRootViewController(animated: false)
        let box = ExplainViewController(highlight: highlight, bookTitle: PassageExplain.title(of: book),
                                        chapter: chapter, source: source)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var resumed = false
            box.onFinished = {
                guard !resumed else { return }
                resumed = true
                continuation.resume()
            }
            navigation.pushViewController(box, animated: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
                guard !resumed else { return }
                resumed = true
                SelfTest.log("FEL: rutan blev inte klar inom 25 sekunder")
                continuation.resume()
            }
        }
        box.onFinished = nil
        await pause(0.4)
        if let photo = photo {
            SelfTest.saveScreen(navigation.view, name: photo)
        }
        return box
    }

    private static func logPrompt(_ prompt: String?, name: String) {
        guard let prompt = prompt else {
            SelfTest.log("Fråga \(name): ingen")
            return
        }
        let passage = prompt.components(separatedBy: "\"\"\"").dropFirst().first ?? ""
        SelfTest.log("Fråga \(name): \(prompt.count) tecken, stycket \(passage.count) tecken: "
                     + passage.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
    }

    private static func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    /// Guiden (U7): fel nyckel sparas inte, en nyckel som fungerar ger grön bock.
    private static func testGuide(navigation: UINavigationController) async {
        navigation.pushViewController(SettingsViewController(), animated: false)
        await pause(0.8)
        SelfTest.saveScreen(navigation.view, name: "ai-06-installningar")
        let guide = AIKeyGuideViewController()
        navigation.pushViewController(guide, animated: false)
        await pause(0.5)
        SelfTest.log("Guiden: \(AIKeyGuideViewController.keyCandidate("  AIzaSyTestTestTestTestTest123  ") ?? "ingen") ur "
                     + "urklipp med mellanslag runt, \(AIKeyGuideViewController.keyCandidate("två ord") ?? "ingen nyckel") "
                     + "ur en mening")
        guide.test("mock-bad", saving: true)
        await waitForGuide(guide)
        SelfTest.log("Guiden efter fel nyckel: nyckeln i nyckelringen är \(Keychain.string(.geminiAPIKey) ?? "ingen")")
        guide.test("mock-ok", saving: true)
        await waitForGuide(guide)
        SelfTest.log("Guiden efter rätt nyckel: \(guide.statusText), läget \(AIClient.keyStatus.title)")
        SelfTest.saveScreen(navigation.view, name: "ai-07-guiden")
        navigation.popViewController(animated: false)
        await pause(0.6)
        SelfTest.saveScreen(navigation.view, name: "ai-06b-installningar-fungerar")
        navigation.popToRootViewController(animated: false)
    }

    private static func waitForGuide(_ guide: AIKeyGuideViewController) async {
        for _ in 0..<40 {
            await pause(0.25)
            if guide.statusText != "Provar nyckeln …" {
                return
            }
        }
        SelfTest.log("FEL: guiden blev inte klar")
    }
}
