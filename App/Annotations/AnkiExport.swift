import UIKit

/// Anki-filernas form (K5): Ankis textimport med rubrikrader (`#separator:tab`, `#html:true`, `#guid column:1`,
/// `#deck`, `#tags column:4`), se docs.ankiweb.net/importing/text-files.html. Första kolumnen är ett fast id per
/// kort, så att en ny export uppdaterar korten i stället för att skapa dubbletter. Ren logik (G13).
enum AnkiFormat {

    /// En cell: HTML-tecken skyddade, tabbar bort och radbrytningar som `<br>`.
    static func field(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    /// En tagg: mellanslag blir understreck, eftersom Anki skiljer taggar med mellanslag.
    static func tag(_ text: String) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: "_")
        return cleaned.replacingOccurrences(of: "\"", with: "")
    }

    static func header(deck: String) -> String {
        ["#separator:tab", "#html:true", "#guid column:1", "#deck:\(deck)", "#tags column:4"].joined(separator: "\n")
    }

    /// Ordet som blir luckan: det längsta ordet med bokstäver, det senare vid lika långa.
    static func clozeWord(in text: String) -> String? {
        var best: String?
        (text as NSString).enumerateSubstrings(in: NSRange(location: 0, length: (text as NSString).length),
                                               options: .byWords) { word, _, _, _ in
            guard let word = word, word.rangeOfCharacter(from: .letters) != nil else { return }
            // Vid lika långa ord vinner det senare: begreppet står ofta sist i meningen.
            if word.count >= (best?.count ?? 0) {
                best = word
            }
        }
        return best
    }

    /// Markeringen som lucktext: `{{c1::ordet}}` i stället för det valda ordet (första förekomsten).
    static func cloze(_ text: String) -> String {
        let clean = Citation.cleanQuote(text)
        let escaped = field(clean)
        guard let word = clozeWord(in: clean) else { return escaped }
        let target = field(word)
        guard let range = escaped.range(of: target) else { return escaped }
        return escaped.replacingCharacters(in: range, with: "{{c1::\(target)}}")
    }

    /// Filen med markeringarna, för anteckningstypen Lucktext (Cloze): id, text, extra (anteckning och källa), taggar.
    static func highlightsFile(_ entries: [NotebookEntry], colorNames: [HighlightColor: String]) -> String {
        var lines = [header(deck: "Sensus::Markeringar")]
        for entry in entries {
            let highlight = entry.highlight
            var extra: [String] = []
            if highlight.hasNote {
                extra.append(field(highlight.note))
            }
            let source = entry.page.map { "\(entry.bookTitle), s. \($0)" } ?? entry.bookTitle
            extra.append("<i>\(field(source))</i>")
            let tags = ["Sensus", tag(entry.bookTitle), tag(colorNames[highlight.color] ?? highlight.color.title)]
                .filter { !$0.isEmpty }.joined(separator: " ")
            lines.append(["sensus-m-\(highlight.id)", cloze(highlight.text), extra.joined(separator: "<br><br>"), tags]
                .joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Ett sparat ord som rad för anteckningstypen Grundläggande (Basic): id, ordet, svaret och meningen, taggar.
    static func wordLine(id: String, word: String, language: String, answer: String, sentence: String,
                         book: String) -> String {
        var back = field(answer)
        if !sentence.isEmpty {
            back += "<br><br><i>\(field(Citation.cleanQuote(sentence)))</i>"
        }
        let tags = ["Sensus", "ord", tag(language), tag(book)].filter { !$0.isEmpty }.joined(separator: " ")
        return [id, field(word), back, tags].joined(separator: "\t")
    }
}

/// Exporten via delningsmenyn (K5). Bara filen, ingen knapp till AnkiMobile än.
@MainActor
enum AnkiExport {

    static func share(highlights: [NotebookEntry], includeWords: Bool, from presenter: UIViewController,
                      sourceItem: UIBarButtonItem?) {
        var urls: [URL] = []
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Anki", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if !highlights.isEmpty {
            let url = folder.appendingPathComponent("Sensus markeringar (Lucktext).txt")
            let text = AnkiFormat.highlightsFile(highlights, colorNames: HighlightColorNames.all())
            if (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil {
                urls.append(url)
            }
        }
        var wordCount = 0
        if includeWords {
            let words = UserWords.shared.savedWords()
            wordCount = words.count
            if !words.isEmpty {
                var lines = [AnkiFormat.header(deck: "Sensus::Ord")]
                let titles = Dictionary(BookRegistry.shared.records().map { ($0.id, $0.displayTitle) },
                                        uniquingKeysWith: { first, _ in first })
                for word in words {
                    let language = word.language == .english ? "engelska" : "svenska"
                    lines.append(AnkiFormat.wordLine(id: "sensus-o-\(word.language == .english ? "en" : "sv")-\(word.lemma)",
                                                     word: word.word, language: language,
                                                     answer: WordReviewViewController.answer(for: word),
                                                     sentence: word.sentence, book: titles[word.book] ?? ""))
                }
                let url = folder.appendingPathComponent("Sensus ord (Grundläggande).txt")
                if (try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)) != nil {
                    urls.append(url)
                }
            }
        }
        AppLog.shared.write("K5: Anki-export med \(highlights.count) markeringar och \(wordCount) ord")
        guard !urls.isEmpty else {
            let alert = UIAlertController(title: "Inget att exportera",
                                          message: "Det finns inga markeringar eller sparade ord att exportera.",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            presenter.present(alert, animated: true)
            return
        }
        let share = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        share.popoverPresentationController?.barButtonItem = sourceItem
        if sourceItem == nil {
            share.popoverPresentationController?.sourceView = presenter.view
            share.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX,
                                                                     y: presenter.view.bounds.midY, width: 1, height: 1)
        }
        presenter.present(share, animated: true)
    }
}
