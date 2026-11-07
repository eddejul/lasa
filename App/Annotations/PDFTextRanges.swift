import PDFKit
import UIKit

/// Teckenintervall på PDF-sidor: var en markering börjar och slutar under fingret, och var den ligger på sidan.
/// Använder läsarens dokument och anropas därför bara från huvudtråden.
enum PDFTextRanges {

    /// Ordet närmast punkten (i sidans koordinater), som ett teckenintervall i sidans text.
    static func word(on page: PDFPage, at point: CGPoint, tolerance: CGFloat) -> NSRange? {
        guard let string = page.string, !string.isEmpty else { return nil }
        let text = string as NSString
        let steps: [CGFloat] = [0, -1, 1, -2, 2, -3, 3]
        let dx = tolerance / 3
        let dy = tolerance / 4
        var best: (range: NSRange, distance: CGFloat)?
        var seen = Set<Int>()
        for row in [0, 1, -1] as [CGFloat] {
            for step in steps {
                let probe = CGPoint(x: point.x + step * dx, y: point.y + row * dy)
                let index = page.characterIndex(at: probe)
                guard index >= 0, index < text.length, isWordCharacter(text.character(at: index)) else { continue }
                let range = wordRange(around: index, in: text)
                guard seen.insert(range.location).inserted,
                      let bounds = page.selection(for: range)?.bounds(for: page), bounds.width > 0 else { continue }
                let distance = Self.distance(from: point, to: bounds)
                if best == nil || distance < best!.distance {
                    best = (range, distance)
                }
            }
        }
        if let found = best, found.distance <= tolerance {
            return found.range
        }
        // Reserv: PDFKit:s egen ordmarkering, omräknad till ett teckenintervall.
        if let selection = page.selectionForWord(at: point), (selection.string ?? "").contains(where: { $0.isLetter }) {
            let range = selection.range(at: 0, on: page)
            if range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= text.length {
                return range
            }
        }
        return nil
    }

    /// Intervallet från ett ord till ett annat, i vilken ordning de än kom.
    static func span(from first: NSRange, to second: NSRange) -> NSRange {
        let start = min(first.location, second.location)
        let end = max(NSMaxRange(first), NSMaxRange(second))
        return NSRange(location: start, length: end - start)
    }

    /// Markeringens rutor i sidans koordinater, en per rad.
    static func rects(on page: PDFPage, range: NSRange) -> [CGRect] {
        guard let length = page.string.map({ ($0 as NSString).length }),
              range.location >= 0, range.length > 0, NSMaxRange(range) <= length,
              let selection = page.selection(for: range) else {
            return []
        }
        return selection.selectionsByLine().compactMap { line in
            let rect = line.bounds(for: page)
            return rect.width > 0 && rect.height > 0 ? rect : nil
        }
    }

    /// Texten i intervallet, på en rad och utan avstavning.
    static func text(on page: PDFPage, range: NSRange) -> String {
        guard let string = page.string, NSMaxRange(range) <= (string as NSString).length else { return "" }
        return clean((string as NSString).substring(with: range))
    }

    /// Avstavningar ihop, radbrytningar och dubbla mellanslag blir ett mellanslag.
    static func clean(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\u{00AD}", with: "")
        for hyphen in ["-", "\u{2010}", "\u{2011}"] {
            result = result.replacingOccurrences(of: hyphen + "\r\n", with: "")
            result = result.replacingOccurrences(of: hyphen + "\n", with: "")
        }
        return result.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: Internt

    private static func wordRange(around index: Int, in text: NSString) -> NSRange {
        var start = index
        while start > 0, isWordCharacter(text.character(at: start - 1)) || isInnerJoiner(text, at: start - 1) {
            start -= 1
        }
        var end = index + 1
        while end < text.length, isWordCharacter(text.character(at: end)) || isInnerJoiner(text, at: end) {
            end += 1
        }
        // Skiljetecknet direkt efter ordet tas med, som när man markerar med en penna.
        if end < text.length, let scalar = Unicode.Scalar(text.character(at: end)),
           CharacterSet(charactersIn: ".,;:!?…»”\")").contains(scalar) {
            end += 1
        }
        return NSRange(location: start, length: end - start)
    }

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

    private static func isInnerJoiner(_ text: NSString, at index: Int) -> Bool {
        guard index > 0, index + 1 < text.length else { return false }
        let character = text.character(at: index)
        guard [0x2D, 0xAD, 0x2010, 0x2011, 0x27, 0x2019].contains(character) else { return false }
        return isWordCharacter(text.character(at: index - 1)) && isWordCharacter(text.character(at: index + 1))
    }
}
