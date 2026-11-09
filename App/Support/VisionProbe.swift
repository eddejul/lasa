import UIKit
import Vision

/// P5, bara provet: vilka språk Apples Vision kan läsa på enheten (en rad i loggen vid varje start, så att en
/// logg från iPaden visar svaret för iPadOS 15), och i självtestet om tyska ger å, ä och ö på svensk text.
/// Ingen textigenkänning i läsaren ännu.
enum VisionProbe {

    static let sample = ["Även små öar får båtar.", "Är det här ändå höstens början?", "Övning ger färdighet, säger Åsa."]

    /// Skriver språken i loggen en stund efter starten, i bakgrunden.
    static func logSupportedLanguagesSoon() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8) {
            AppLog.shared.write("Vision (P5): " + supportedLanguagesSummary())
        }
    }

    static func supportedLanguagesSummary() -> String {
        var parts: [String] = []
        for level in [VNRequestTextRecognitionLevel.accurate, .fast] {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = level
            let languages: [String]
            do {
                languages = try request.supportedRecognitionLanguages()
            } catch {
                parts.append("\(level == .accurate ? "noggrann" : "snabb"): fel \(error.localizedDescription)")
                continue
            }
            parts.append("\(level == .accurate ? "noggrann" : "snabb") (revision \(request.revision)): "
                         + (languages.isEmpty ? "inga" : languages.joined(separator: ", ")))
        }
        return parts.joined(separator: "; ")
    }

    /// Självtestet: läser en bild med svensk text med tyska (och svenska om enheten har det) och räknar å, ä och ö.
    static func swedishProbe() async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runSwedishProbe())
            }
        }
    }

    private static func runSwedishProbe() -> [String] {
        guard let image = sampleImage().cgImage else { return ["FEL: ingen provbild"] }
        let letters = "åäöÅÄÖ"
        let wanted = sample.joined(separator: " ").filter { letters.contains($0) }.count
        let available = Set((try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? [])
        var tries: [(name: String, languages: [String], correction: Bool)] = [
            ("tyska", ["de-DE"], false),
            ("tyska med språkrättning", ["de-DE"], true),
        ]
        if available.contains("sv-SE") {
            tries.append(("svenska", ["sv-SE"], false))
        }
        var lines: [String] = []
        for attempt in tries {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = attempt.languages
            request.usesLanguageCorrection = attempt.correction
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            let started = CACurrentMediaTime()
            do {
                try handler.perform([request])
            } catch {
                lines.append("\(attempt.name): fel \(error.localizedDescription)")
                continue
            }
            let observations = request.results ?? []
            let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            let found = text.filter { letters.contains($0) }.count
            let milliseconds = Int(((CACurrentMediaTime() - started) * 1000).rounded())
            lines.append("\(attempt.name): \(found) av \(wanted) å, ä och ö, \(milliseconds) ms, läst: \(text)")
        }
        return lines
    }

    /// Tre rader svensk text, svart på vitt, ungefär som en fotad boksida i stor stil.
    static func sampleImage() -> UIImage {
        let size = CGSize(width: 1400, height: 420)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let font = UIFont(name: "Georgia", size: 52) ?? UIFont.systemFont(ofSize: 52)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
            for (index, line) in sample.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 40, y: 40 + CGFloat(index) * 120), withAttributes: attributes)
            }
        }
    }
}

/// Självtestet för våg 10b (P3, P4, P5) körs i den första PDF-läsaren. Läsare som öppnas av bytet mellan
/// sidbilden och texten startar inget eget självtest.
enum PhotoPagesSelfTest {
    static let bookName = "foto-text.pdf"
    static var running = false
}
