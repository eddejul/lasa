import XCTest
@testable import Lasa

/// Våg 10b: ramen (P3), förslaget efter var texten ligger och txt-filen från OCR-flödet (P4).
final class PhotoPagesTests: XCTestCase {

    // MARK: P3 Ramen

    func testCropStoreRoundTrip() {
        let saved = PageCropStore.Saved(crop: PageCrop(rect: CGRect(x: 0.1, y: 0.05, width: 0.8, height: 0.9)), isOn: true)
        let text = PageCropStore.format(saved)
        XCTAssertEqual(text, "1;0.1000;0.0500;0.8000;0.9000")
        XCTAssertEqual(PageCropStore.parse(text), saved)
        XCTAssertEqual(PageCropStore.parse("0;0.1;0.05;0.8;0.9")?.isOn, false)
        XCTAssertNil(PageCropStore.parse("1;0.1;0.05;0.8"))
        XCTAssertNil(PageCropStore.parse("2;0.1;0.05;0.8;0.9"))
        XCTAssertNil(PageCropStore.parse("1;x;0.05;0.8;0.9"))
    }

    func testClampKeepsFrameInsidePage() {
        let crop = PageCrop(rect: CGRect(x: 0.9, y: -0.2, width: 0.1, height: 1.5)).clamped()
        XCTAssertEqual(crop.rect.width, PageCrop.minimumSide, accuracy: 0.0001)
        XCTAssertEqual(crop.rect.height, 1, accuracy: 0.0001)
        XCTAssertEqual(crop.rect.maxX, 1, accuracy: 0.0001)
        XCTAssertEqual(crop.rect.minY, 0, accuracy: 0.0001)
        XCTAssertTrue(PageCrop.full.isFull)
        XCTAssertEqual(PageCrop.full.variantSuffix, "")
        XCTAssertEqual(PageCrop(rect: CGRect(x: 0.1, y: 0.05, width: 0.8, height: 0.9)).variantSuffix, "-b100.050.800.900")
    }

    /// Hela sidans plats räknas så att ramens del hamnar exakt på sidbilden, och omvänt.
    func testPageFrameMapsCropOntoImage() {
        let crop = PageCrop(rect: CGRect(x: 0.2, y: 0.1, width: 0.5, height: 0.8))
        let image = CGRect(x: 30, y: 40, width: 300, height: 600)
        let page = crop.pageFrame(for: image)
        XCTAssertEqual(page.width, 600, accuracy: 0.001)
        XCTAssertEqual(page.height, 750, accuracy: 0.001)
        XCTAssertEqual(page.minX + 0.2 * page.width, image.minX, accuracy: 0.001)
        XCTAssertEqual(page.minY + 0.1 * page.height, image.minY, accuracy: 0.001)
        XCTAssertEqual(page.minX + 0.7 * page.width, image.maxX, accuracy: 0.001)
        XCTAssertEqual(page.minY + 0.9 * page.height, image.maxY, accuracy: 0.001)
        XCTAssertEqual(PageCrop.full.pageFrame(for: image), image)
    }

    func testFullPageSizeFillsAreaAndCapsMemory() {
        let page = CGSize(width: 600, height: 800)
        let area = CGSize(width: 500, height: 700)
        let crop = PageCrop(rect: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
        let size = crop.fullPageSize(fitting: area, page: page)
        // Ramens del (80 procent) fyller ytan åt det håll som begränsar.
        let cropWidth = size.width * 0.8
        let cropHeight = size.height * 0.8
        XCTAssertTrue(abs(cropWidth - area.width) < 0.01 || abs(cropHeight - area.height) < 0.01)
        XCTAssertLessThanOrEqual(cropWidth, area.width + 0.01)
        XCTAssertLessThanOrEqual(cropHeight, area.height + 0.01)
        // En liten ram ritar aldrig mer än 2,25 gånger ytan.
        let tiny = PageCrop(rect: CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.3))
        let capped = tiny.fullPageSize(fitting: area, page: page)
        XCTAssertLessThanOrEqual(capped.width * capped.height, area.width * area.height * PageCrop.maxOversize + 1)
        XCTAssertEqual(PageCrop.full.fullPageSize(fitting: area, page: page), area)
    }

    /// Ett grått bord, en ljus boksida och mörk text i mitten: förslaget ramar in texten.
    func testSuggestionFindsTextOnPaper() {
        let width = 200
        let height = 260
        var gray = [UInt8](repeating: 90, count: width * height)
        for y in 10..<250 {
            for x in 20..<180 {
                gray[y * width + x] = 245
            }
        }
        for line in stride(from: 50, to: 170, by: 12) {
            for y in line..<(line + 5) {
                for x in 50..<150 where x % 3 != 0 {
                    gray[y * width + x] = 30
                }
            }
        }
        guard let crop = PageCropSuggestion.suggest(gray: gray, width: width, height: height) else {
            return XCTFail("inget förslag")
        }
        XCTAssertEqual(crop.rect.minX, 0.25, accuracy: 0.05)
        XCTAssertEqual(crop.rect.maxX, 0.75, accuracy: 0.05)
        XCTAssertEqual(crop.rect.minY, 50.0 / 260.0, accuracy: 0.05)
        XCTAssertEqual(crop.rect.maxY, 170.0 / 260.0, accuracy: 0.05)
        // Flera sidor: ramen rymmer texten på alla.
        let wide = PageCrop(rect: CGRect(x: 0.1, y: 0.3, width: 0.8, height: 0.4))
        let union = PageCropSuggestion.union([crop, wide])
        XCTAssertEqual(union?.rect.minX ?? 0, 0.1, accuracy: 0.0001)
        XCTAssertEqual(union?.rect.maxX ?? 0, 0.9, accuracy: 0.0001)
        XCTAssertEqual(union?.rect.minY ?? 0, crop.rect.minY, accuracy: 0.0001)
        XCTAssertNil(PageCropSuggestion.union([]))
        // En sida där texten fyller allt ger inget förslag.
        let full = [UInt8](repeating: 245, count: width * height)
        XCTAssertNil(PageCropSuggestion.suggest(gray: full, width: width, height: height))
    }

    // MARK: P4 Txt-filen från OCR-flödet

    func testParsePagedText() {
        let text = "--- titelsida ---\nBOKEN\n\n--- boksida 12 ---\nRetoriken är reto-\nrikens konst.\n\nRETORIKENS GRUNDER\n\n"
            + "Nytt stycke här.\n\n--- boksida 13 ---\n"
        let pages = OCRPagedText.parse(text)
        XCTAssertEqual(pages?.count, 3)
        XCTAssertEqual(pages?.map(\.heading), ["Titelsida", "Sida 12", "Sida 13"])
        XCTAssertEqual(OCRPagedText.paragraphs(pages?[1].text ?? ""),
                       ["Retoriken är retorikens konst.", "RETORIKENS GRUNDER", "Nytt stycke här."])
        XCTAssertEqual(pages?[2].text.trimmingCharacters(in: .whitespacesAndNewlines), "")
        XCTAssertEqual(OCRPagedText.parse("--- sida 1 ---\r\nEtt\r\n--- sida 2 ---\r\nTvå")?.map(\.heading), ["Sida 1", "Sida 2"])
    }

    func testPlainTextIsNotPaged() {
        XCTAssertNil(OCRPagedText.parse("En vanlig text.\n--- boksida 1 ---\nMer."))
        XCTAssertNil(OCRPagedText.parse("----- 2026-09-22 12:21 | DK1 | Mika\nText"))
        XCTAssertNil(OCRPagedText.marker("--- ---"))
        XCTAssertEqual(OCRPagedText.marker("  --- boksida 222 ---  "), "boksida 222")
        // Ett tankstreck i radslutet före en versal är inget avstavat ord.
        XCTAssertEqual(OCRPagedText.paragraphs("Sverige-\nNorge"), ["Sverige- Norge"])
    }

    func testCompanionTextIsHiddenInLibrary() {
        func book(_ path: String, _ id: String) -> Book {
            Book(url: URL(fileURLWithPath: "/Böcker/" + path), id: id, path: path)
        }
        let books = [book("Kurs/Lindqvist kap 3 (s63-80).pdf", "a"), book("Kurs/Lindqvist kap 3 (s63-80).txt", "b"),
                     book("Anteckningar.txt", "c"), book("Annan/Lindqvist kap 3 (s63-80).txt", "d"),
                     book("Bok.PDF", "e"), book("bok.txt", "f")]
        XCTAssertEqual(PDFTextCompanion.companionTextIDs(in: books), ["b", "f"])
        XCTAssertEqual(PDFTextCompanion.withoutCompanions(books).map(\.id), ["a", "c", "d", "e"])
        // Txt-filen i undermappen txt, där OCR-flödet lägger den.
        let ocr = [book("Kurs/Kap 1 (s15-24).pdf", "p"), book("Kurs/txt/Kap 1 (s15-24).txt", "t"),
                   book("txt/Kap 1 (s15-24).txt", "u"), book("Kurs/txt/Annat.txt", "v")]
        XCTAssertEqual(PDFTextCompanion.companionTextIDs(in: ocr), ["t"])
    }
}
