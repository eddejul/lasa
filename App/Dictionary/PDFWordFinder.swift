import PDFKit
import UIKit

/// Ett ord som hittats på en PDF-sida, med meningen runt det.
struct FoundWord {
    /// Var ordet börjar i sidans text. Samma värde betyder samma ord, när fingret flyttas.
    let location: Int
    /// Formerna att slå upp, i tur och ordning tills ordboken hittar en. Ett avstavat ord över en
    /// radbrytning kommer först ihopslaget ("kunskap"), sedan med bindestreck ("EU-land"), sist bara
    /// delen man tryckte på.
    let candidates: [String]
    /// Meningen, på en rad och utan avstavning.
    let sentence: String
    /// Var ordet står i meningen (UTF-16, som NSString).
    let rangeInSentence: NSRange
    /// Ordets rutor i sidans koordinater, en per rad.
    let pageRects: [CGRect]
}

/// Tar fram ordet under en punkt på en PDF-sida.
/// Använder läsarens dokument och anropas därför bara från huvudtråden.
enum PDFWordFinder {

    private static let hyphens: Set<unichar> = [0x2D, 0xAD, 0x2010, 0x2011]
    private static let apostrophes: Set<unichar> = [0x27, 0x2019]
    private static let sentenceEnds: Set<unichar> = [0x2E, 0x21, 0x3F, 0x2026]  // . ! ? …
    private static let maxSentenceLength = 320

    /// Om sidan saknar text (en skannad sida utan textlager).
    static func pageHasText(_ page: PDFPage) -> Bool {
        guard let string = page.string else { return false }
        return string.contains { $0.isLetter }
    }

    /// Ordet närmast punkten. `tolerance` är hur långt bort (i sidans enheter) ett ord får ligga,
    /// ungefär en fingertopp. Ordet som innehåller punkten vinner, annars det som ligger närmast.
    /// Förr valdes ordet till vänster när fingret landade i ett mellanrum, det gav fel ord.
    static func word(on page: PDFPage, at point: CGPoint, tolerance: CGFloat) -> FoundWord? {
        guard let string = page.string, !string.isEmpty else { return nil }
        let text = string as NSString
        guard let core = nearestWord(on: page, text: text, at: point, tolerance: tolerance) else {
            return fallback(on: page, at: point)
        }
        let start = core.location
        let end = NSMaxRange(core)
        var parts = [core]

        // Avstavat över radbrytningen: "kun-" på en rad och "skap" på nästa.
        if let next = continuation(after: end, in: text) {
            parts.append(next)
        } else if let previous = beginning(before: start, in: text) {
            parts.insert(previous, at: 0)
        }

        let pieces = parts.map { text.substring(with: $0) }
        let joined = pieces.joined()
        guard joined.contains(where: { $0.isLetter }) else { return nil }
        var candidates = [joined]
        if parts.count > 1 {
            candidates.append(pieces.joined(separator: "-"))
            candidates.append(text.substring(with: core))
        }
        if joined.contains("-") {
            // Ett bindestreck mitt i raden kan vara en avstavning som PDF:en har tappat radbrytningen för.
            candidates.append(joined.replacingOccurrences(of: "-", with: ""))
        }

        let first = parts[0].location
        let last = NSMaxRange(parts[parts.count - 1])
        let sentenceRange = surroundingSentence(of: NSRange(location: first, length: last - first), in: text)
        let before = clean(text.substring(with: NSRange(location: sentenceRange.location,
                                                         length: first - sentenceRange.location)))
        let after = clean(text.substring(with: NSRange(location: last, length: NSMaxRange(sentenceRange) - last)))
        // Ordet börjar med en bokstav, så mellanslag först i meningen kommer bara från texten före.
        let leading = before.prefix(while: { $0 == " " }).count
        let sentence = String((before + joined + after).dropFirst(leading)).trimmingCharacters(in: .whitespaces)
        let range = NSRange(location: (before as NSString).length - leading, length: (joined as NSString).length)

        var rects: [CGRect] = []
        for part in parts {
            guard let selection = page.selection(for: part) else { continue }
            for line in selection.selectionsByLine() {
                let rect = line.bounds(for: page)
                if rect.width > 0, rect.height > 0 {
                    rects.append(rect)
                }
            }
        }

        return FoundWord(location: core.location, candidates: candidates, sentence: sentence,
                         rangeInSentence: range, pageRects: rects)
    }

    // MARK: Internt

    /// Provar punkter runt fingret, samlar orden som träffas och tar det som ligger närmast.
    private static func nearestWord(on page: PDFPage, text: NSString, at point: CGPoint,
                                    tolerance: CGFloat) -> NSRange? {
        let steps: [CGFloat] = [0, -1, 1, -2, 2, -3, 3]
        let dx = tolerance / 3
        let dy = tolerance / 4
        var ranges: [Int: NSRange] = [:]
        for row in [0, 1, -1] as [CGFloat] {
            for step in steps {
                let probe = CGPoint(x: point.x + step * dx, y: point.y + row * dy)
                let index = page.characterIndex(at: probe)
                guard index >= 0, index < text.length, isWordCharacter(text.character(at: index)) else { continue }
                let range = wordRange(around: index, in: text)
                ranges[range.location] = range
            }
        }
        var best: (range: NSRange, distance: CGFloat)?
        for range in ranges.values {
            guard let bounds = page.selection(for: range)?.bounds(for: page), bounds.width > 0 else { continue }
            let distance = Self.distance(from: point, to: bounds)
            if let current = best, current.distance <= distance {
                continue
            }
            best = (range, distance)
        }
        guard let found = best, found.distance <= tolerance else { return nil }
        return found.range
    }

    private static func wordRange(around index: Int, in text: NSString) -> NSRange {
        var start = index
        while start > 0, isWordCharacter(text.character(at: start - 1)) || isInnerJoiner(text, at: start - 1) {
            start -= 1
        }
        var end = index + 1
        while end < text.length, isWordCharacter(text.character(at: end)) || isInnerJoiner(text, at: end) {
            end += 1
        }
        return NSRange(location: start, length: end - start)
    }

    /// Avståndet från en punkt till en ruta, 0 om punkten ligger i rutan.
    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    private static func isWordCharacter(_ character: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(character) else { return false }
        return CharacterSet.letters.contains(scalar)
            || CharacterSet.decimalDigits.contains(scalar)
            || CharacterSet.nonBaseCharacters.contains(scalar)
    }

    /// Bindestreck eller apostrof inne i ett ord, med bokstäver på båda sidor (e-post, don't).
    private static func isInnerJoiner(_ text: NSString, at index: Int) -> Bool {
        guard index > 0, index + 1 < text.length else { return false }
        let character = text.character(at: index)
        guard hyphens.contains(character) || apostrophes.contains(character) else { return false }
        return isWordCharacter(text.character(at: index - 1)) && isWordCharacter(text.character(at: index + 1))
    }

    /// Ordets andra halva efter ett avstavningsstreck och en radbrytning. PDF:er skriver ibland
    /// radbrytningen som ett mellanslag, så det räcker med blanktecken. Ordboken avgör sedan om
    /// halvorna hör ihop ("kun- skap") eller inte ("kurs- och studieplan").
    private static func continuation(after end: Int, in text: NSString) -> NSRange? {
        guard end < text.length, hyphens.contains(text.character(at: end)) else { return nil }
        var index = end + 1
        while index < text.length, isSpace(text.character(at: index)) {
            index += 1
        }
        guard index > end + 1 || text.character(at: end) == 0xAD,
              index < text.length, isWordCharacter(text.character(at: index)) else { return nil }
        let start = index
        while index < text.length, isWordCharacter(text.character(at: index)) || isInnerJoiner(text, at: index) {
            index += 1
        }
        return NSRange(location: start, length: index - start)
    }

    /// Ordets första halva före en radbrytning, om ordet man tryckte på är andra halvan.
    private static func beginning(before start: Int, in text: NSString) -> NSRange? {
        var index = start - 1
        while index >= 0, isSpace(text.character(at: index)) {
            index -= 1
        }
        guard index > 0, hyphens.contains(text.character(at: index)),
              index < start - 1 || text.character(at: index) == 0xAD else { return nil }
        let end = index
        index -= 1
        guard index >= 0, isWordCharacter(text.character(at: index)) else { return nil }
        while index > 0, isWordCharacter(text.character(at: index - 1)) || isInnerJoiner(text, at: index - 1) {
            index -= 1
        }
        return NSRange(location: index, length: end - index)
    }

    private static func isSpace(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09 || isLineBreak(character) || character == 0xA0
    }

    private static func isLineBreak(_ character: unichar) -> Bool {
        character == 0x0A || character == 0x0D || character == 0x2028 || character == 0x2029
    }

    /// Meningen runt ordet: bakåt till förra punkten och framåt till nästa, högst 320 tecken.
    private static func surroundingSentence(of word: NSRange, in text: NSString) -> NSRange {
        var start = word.location
        let earliest = max(0, word.location - maxSentenceLength / 2)
        while start > earliest {
            let character = text.character(at: start - 1)
            if sentenceEnds.contains(character), start < text.length, isSpace(text.character(at: start)) {
                break
            }
            if isLineBreak(character), start >= 2, isLineBreak(text.character(at: start - 2)) {
                break
            }
            start -= 1
        }
        var end = NSMaxRange(word)
        let latest = min(text.length, NSMaxRange(word) + maxSentenceLength / 2)
        while end < latest {
            let character = text.character(at: end)
            end += 1
            if sentenceEnds.contains(character), end >= text.length || isSpace(text.character(at: end)) {
                break
            }
            if isLineBreak(character), end < text.length, isLineBreak(text.character(at: end)) {
                break
            }
        }
        return NSRange(location: start, length: end - start)
    }

    /// Texten på en rad: avstavningar ihop, radbrytningar och dubbla mellanslag blir ett mellanslag.
    private static func clean(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\u{00AD}", with: "")
        for hyphen in ["-", "\u{2010}", "\u{2011}"] {
            result = result.replacingOccurrences(of: hyphen + "\r\n", with: "")
            result = result.replacingOccurrences(of: hyphen + "\n", with: "")
        }
        result = result.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        if text.first.map({ $0.isWhitespace }) == true { result = " " + result }
        if text.last.map({ $0.isWhitespace }) == true, !result.hasSuffix(" ") { result += " " }
        return result
    }

    /// Om sidans textindex inte räcker: PDFKit:s egen ordmarkering, utan avstavning och mening.
    private static func fallback(on page: PDFPage, at point: CGPoint) -> FoundWord? {
        guard let selection = page.selectionForWord(at: point),
              let word = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              word.contains(where: { $0.isLetter }) else {
            return nil
        }
        let rects = selection.selectionsByLine().map { $0.bounds(for: page) }.filter { $0.width > 0 }
        return FoundWord(location: -1, candidates: [word], sentence: word,
                         rangeInSentence: NSRange(location: 0, length: (word as NSString).length),
                         pageRects: rects)
    }
}

/// Omräkning mellan punkter i sidbilden och PDF-sidans egna koordinater.
///
/// Sidbilden ritas av `PDFPage.thumbnail(of:for: .mediaBox)`, som tar hänsyn till sidans rotation.
/// `transform(for:)` ger samma rotation, så att ett tryck hamnar på rätt ställe även på roterade sidor.
enum PDFPageGeometry {

    /// Sidans synliga yta (rotationen inräknad) och omvandlingen dit från sidans koordinater.
    private static func displayed(_ page: PDFPage) -> (rect: CGRect, transform: CGAffineTransform) {
        let box = page.bounds(for: .mediaBox)
        let transform = page.transform(for: .mediaBox)
        return (box.applying(transform).standardized, transform)
    }

    /// Var sidan ligger i bildrutan. Bilden kan vara lite större än sidan, sidan ligger då centrerad.
    private static func content(in imageFrame: CGRect, aspect: CGSize) -> CGRect {
        guard aspect.width > 0, aspect.height > 0, imageFrame.width > 0, imageFrame.height > 0 else { return imageFrame }
        let scale = min(imageFrame.width / aspect.width, imageFrame.height / aspect.height)
        let size = CGSize(width: aspect.width * scale, height: aspect.height * scale)
        return CGRect(x: imageFrame.midX - size.width / 2, y: imageFrame.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// Hur många av sidans enheter en punkt på skärmen motsvarar.
    static func pageUnitsPerPoint(imageFrame: CGRect, page: PDFPage) -> CGFloat {
        let (shown, _) = displayed(page)
        let area = content(in: imageFrame, aspect: shown.size)
        guard area.width > 0 else { return 1 }
        return shown.width / area.width
    }

    /// En punkt i bladets vy (y nedåt) till sidans koordinater (y uppåt).
    static func pagePoint(for viewPoint: CGPoint, imageFrame: CGRect, page: PDFPage) -> CGPoint? {
        let (shown, transform) = displayed(page)
        let area = content(in: imageFrame, aspect: shown.size)
        guard area.width > 0, area.height > 0, area.insetBy(dx: -8, dy: -8).contains(viewPoint) else { return nil }
        let u = (viewPoint.x - area.minX) / area.width
        let v = (viewPoint.y - area.minY) / area.height
        let point = CGPoint(x: shown.minX + u * shown.width, y: shown.maxY - v * shown.height)
        return point.applying(transform.inverted())
    }

    /// En ruta i sidans koordinater till bladets vy.
    static func viewRect(for pageRect: CGRect, imageFrame: CGRect, page: PDFPage) -> CGRect {
        let (shown, transform) = displayed(page)
        let area = content(in: imageFrame, aspect: shown.size)
        let rect = pageRect.applying(transform).standardized
        guard shown.width > 0, shown.height > 0 else { return .zero }
        let sx = area.width / shown.width
        let sy = area.height / shown.height
        return CGRect(x: area.minX + (rect.minX - shown.minX) * sx,
                      y: area.minY + (shown.maxY - rect.maxY) * sy,
                      width: rect.width * sx,
                      height: rect.height * sy)
    }
}
