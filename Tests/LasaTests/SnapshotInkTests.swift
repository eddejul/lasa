import XCTest
import UIKit
@testable import Lasa

/// Kontrollen av tomma sidbilder i EPUB-läsaren (Edvin 8 nov kväll). En sidbild utan text, alltså bara papper
/// eller en enda färg över hela bilden, ska räknas som tom så att sidan tas om. En sida med text får aldrig
/// räknas som tom.
final class SnapshotInkTests: XCTestCase {

    private let dark = ReaderTheme.dark.paperColor
    private let white = ReaderTheme.white.paperColor

    /// En bild som webbvyn kunde lämna: genomskinlig, eller fylld med en färg, eventuellt med en svart ruta (text).
    private func image(fill: UIColor?, text: Bool) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = false
        let size = CGSize(width: 300, height: 400)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            if let fill = fill {
                fill.setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
            if text {
                UIColor(white: 0.85, alpha: 1).setFill()
                for row in 0..<12 {
                    context.fill(CGRect(x: 30, y: 40 + CGFloat(row) * 26, width: 240, height: 9))
                }
            }
        }
    }

    func testTransparentImageIsBlank() {
        // Felet i kväll: en genomskinlig bild skilde sig från papperet i Mörkt och godkändes.
        XCTAssertTrue(SnapshotInk.isBlank(image(fill: nil, text: false), paper: dark))
    }

    func testWhiteImageIsBlankInDark() {
        XCTAssertTrue(SnapshotInk.isBlank(image(fill: .white, text: false), paper: dark))
    }

    func testPaperImageIsBlank() {
        XCTAssertTrue(SnapshotInk.isBlank(image(fill: dark, text: false), paper: dark))
        XCTAssertTrue(SnapshotInk.isBlank(image(fill: white, text: false), paper: white))
    }

    func testPageWithTextIsNotBlank() {
        XCTAssertFalse(SnapshotInk.isBlank(image(fill: dark, text: true), paper: dark))
        XCTAssertFalse(SnapshotInk.isBlank(image(fill: white, text: true), paper: white))
        // Text på genomskinlig botten (webbvyn är inte ogenomskinlig) är inte heller tom.
        XCTAssertFalse(SnapshotInk.isBlank(image(fill: nil, text: true), paper: dark))
    }
}
