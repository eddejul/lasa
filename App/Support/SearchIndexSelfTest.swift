import Foundation

/// Självtestet för sökregistret (G11). Körs i båda läsarna efter sökningen, för varje testbok: ett gammalt
/// register ger en sökning direkt i boken och byggs om i bakgrunden, och sedan jämförs registrets träffar med
/// den gamla sökningens för samma ord, både med FTS5 och med den vanliga tabellen.
enum SearchIndexSelfTest {

    /// Ord som provas i alla böcker. Två tecken letas med `instr` även när FTS5 finns.
    private static let fixedWords = ["kunskap", "och", "att", "en s", "er", "det är", "Kun-skap"]

    static func run(source: BookSearch.Source, key: SearchIndex.Key) async {
        let index = SearchIndex.shared
        let info = index.info
        SelfTest.log("Sökregistret: SQLite \(info.sqliteVersion), FTS5 \(info.fts5 ? "finns" : "saknas"), "
                     + "trigram \(info.trigram ? "finns" : "saknas"), söker med \(info.mode.rawValue)")

        // Ett gammalt register (som efter en ny version av boken): sökningen går direkt i boken och
        // registret byggs om i bakgrunden.
        index.invalidate(book: key.book)
        let search = BookSearch(source: source, index: key)
        let fallback = await search.hits("och", path: .automatic)
        SelfTest.log("Sökregistret gammalt: klart \(index.isReady(key) ? "FEL, ja" : "nej"), "
                     + "sökningen gick \(fallback.usedIndex ? "FEL, i registret" : "direkt i boken") "
                     + "(\(fallback.hits.count) träffar), bokens text släppt efteråt: "
                     + (holdsDocument(search, source) ? "FEL, nej" : "ja"))
        let started = CFAbsoluteTimeGetCurrent()
        var ready = false
        for _ in 0..<600 {
            if index.isReady(key) {
                ready = true
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let stored = index.storedSections(key)
        SelfTest.log("Sökregistret byggdes om i bakgrunden: \(ready ? "ja" : "FEL, nej") efter "
                     + "\(Int(((CFAbsoluteTimeGetCurrent() - started) * 1000).rounded())) ms, \(stored.count) avsnitt med text")
        guard ready else { return }

        // Samma ord i den gamla sökningen och i registret, med FTS5 och med den vanliga tabellen.
        let words = fixedWords + sampleWords(index: index, key: key, sections: stored)
        var total = 0
        var allSame = true
        var times = (direct: 0.0, index: 0.0, plain: 0.0)
        var lines: [String] = []
        for word in words {
            let direct = await search.hits(word, path: .direct)
            let viaIndex = await search.hits(word, path: .index)
            let viaPlain = await search.hits(word, path: .indexPlain)
            times.direct += direct.milliseconds
            times.index += viaIndex.milliseconds
            times.plain += viaPlain.milliseconds
            total += direct.hits.count
            var problems: [String] = []
            if !viaIndex.usedIndex || !viaPlain.usedIndex {
                problems.append("registret användes inte")
            }
            if viaIndex.hits != direct.hits {
                problems.append("FTS-vägen gav \(viaIndex.hits.count) " + firstDifference(direct.hits, viaIndex.hits))
            }
            if viaPlain.hits != direct.hits {
                problems.append("vanliga tabellen gav \(viaPlain.hits.count) " + firstDifference(direct.hits, viaPlain.hits))
            }
            if !problems.isEmpty {
                allSame = false
            }
            lines.append("  \(word): \(direct.hits.count) träffar \(places(direct.hits))"
                         + (problems.isEmpty ? ", lika" : ", FEL: " + problems.joined(separator: "; ")))
        }
        SelfTest.log("Sökregistret mot gamla sökningen: \(words.count) ord, \(total) träffar, samma antal och platser: "
                     + (allSame ? "ja" : "FEL, nej")
                     + String(format: ". Tid direkt i boken %.0f ms, registret %.0f ms, vanliga tabellen %.0f ms",
                              times.direct, times.index, times.plain))
        for line in lines {
            SelfTest.log(line)
        }

        // Nu när registret är klart går läsarens sökning dit.
        let automatic = await search.hits("kunskap", path: .automatic)
        SelfTest.log("Sökningen efter kunskap går nu \(automatic.usedIndex ? "i registret" : "FEL, direkt i boken")")

        // Minnesvarningen släpper sökningens egen text.
        _ = await search.hits("kunskap", path: .direct)
        search.releaseMemory()
        try? await Task.sleep(nanoseconds: 300_000_000)
        SelfTest.log("Sökningens text efter minnesvarningen: \(search.holdsBookText ? "FEL, kvar" : "släppt")")
    }

    /// För PDF ska dokumentet vara släppt direkt efter sökningen. Kapiteltexter får sparas till nästa sökning.
    private static func holdsDocument(_ search: BookSearch, _ source: BookSearch.Source) -> Bool {
        if case .pdf = source {
            return search.holdsBookText
        }
        return false
    }

    /// Några ord och ett ordpar ur bokens egen text, jämnt fördelade, så att alla avsnitt provas.
    private static func sampleWords(index: SearchIndex, key: SearchIndex.Key, sections: [Int]) -> [String] {
        guard !sections.isEmpty else { return [] }
        var words: [String] = []
        let picks = Set([0, sections.count / 2, sections.count - 1].map { sections[$0] })
        for section in picks.sorted() {
            guard let original = index.original(key, section: section) else { continue }
            let text = original as String
            let tokens = text.components(separatedBy: CharacterSet.letters.inverted).filter { $0.count >= 5 }
            if let first = tokens.first {
                words.append(first)
            }
            if tokens.count > 2 {
                words.append(tokens[tokens.count / 2])
            }
            if let pairStart = text.range(of: " ", range: text.index(text.startIndex, offsetBy: min(40, text.count))..<text.endIndex) {
                // Två ord i följd, med blanktecknen som de står (kan vara en radbrytning).
                let rest = text[pairStart.upperBound...]
                let pair = rest.prefix(24)
                if pair.count >= 6 {
                    words.append(String(pair))
                }
            }
        }
        var seen = Set<String>()
        return words.filter { seen.insert($0).inserted }
    }

    /// Var träffarna står: avsnitt:start+längd, högst 40 stycken.
    private static func places(_ hits: [SearchHit]) -> String {
        guard !hits.isEmpty else { return "" }
        let shown = hits.prefix(40).map { "\($0.section):\($0.start)+\($0.length)" }.joined(separator: " ")
        return "[" + shown + (hits.count > 40 ? " och \(hits.count - 40) till" : "") + "]"
    }

    private static func firstDifference(_ expected: [SearchHit], _ actual: [SearchHit]) -> String {
        for (offset, pair) in zip(expected, actual).enumerated() where pair.0 != pair.1 {
            return "(nr \(offset): väntat \(pair.0.section):\(pair.0.start)+\(pair.0.length), fick \(pair.1.section):\(pair.1.start)+\(pair.1.length))"
        }
        return "(väntat \(expected.count))"
    }
}
