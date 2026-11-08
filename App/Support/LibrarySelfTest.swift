import UIKit

/// Självtestet för biblioteket (B1 och framåt), körs i fas 6 när testböckerna redan öppnats en gång:
/// databasen från våg 3 genom trappan, titlar, författare och omslag, hållmenyn, Byt namn, Välj omslag,
/// Markera som läst och bilder av biblioteket i stående, liggande, iPhone-storlek och tomt.
@MainActor
enum LibrarySelfTest {

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    static func run(library: LibraryViewController) async {
        guard let navigation = library.navigationController else { return }
        navigation.popToRootViewController(animated: false)
        testWave3Database()
        await testPlaceholderImport(library: library)

        // Titlar, författare och omslag läses i bakgrunden. Vänta tills alla är klara (högst 20 s).
        library.reload()
        var waited = 0.0
        while library.coverSummary.loading > 0 && waited < 20 {
            await pause(0.5)
            waited += 0.5
        }
        library.reload()
        await pause(0.6)
        let summary = library.coverSummary
        SelfTest.log("Biblioteket (B1): \(library.allItems.count) böcker, \(summary.images) omslag med bild, "
                     + "\(summary.drawn) ritade, \(summary.loading) laddas fortfarande efter \(waited) s "
                     + "(\(CoverStore.shared.rendered) lästa ur filen, \(CoverStore.shared.loaded) från disken)"
                     + (summary.loading > 0 ? " FEL" : ""))
        for item in library.allItems {
            let record = BookRegistry.shared.record(id: item.book.id)
            SelfTest.log("  \(item.book.path): titel \(item.title), författare \(item.author.isEmpty ? "ingen" : item.author), "
                         + "läst \(Int((item.progress * 100).rounded())) %, \(LibraryLogic.statusLine(item)), "
                         + "omslag \(record?.cover ?? "ingen rad")")
        }
        let pdf = library.allItems.first { $0.book.path == "test.pdf" }
        let epub = library.allItems.first { $0.book.path == "test.epub" }
        let roman = library.allItems.first { $0.book.path == "roman.epub" }
        let ok = pdf?.title == "Provbok med textlager" && pdf?.author == "Sensus Testsson"
            && epub?.title == "Testbok för Läsa" && epub?.author == "Sensus Testsson"
            && roman?.title == "Ljuset över hamnen" && roman?.author == "Anna Exempel, Erik Prov"
        SelfTest.log("Titlar och författare ur filerna (PDF, EPUB 3, EPUB 2): \(ok ? "Rätt" : "FEL")")
        let romanCover = roman.flatMap { BookRegistry.shared.record(id: $0.book.id)?.cover } ?? ""
        let epubCover = epub.flatMap { BookRegistry.shared.record(id: $0.book.id)?.cover } ?? ""
        SelfTest.log("Omslag: PNG-omslaget i roman.epub \(romanCover.hasSuffix(".jpg") ? "ritat" : "FEL, \(romanCover)"), "
                     + "SVG-omslaget i test.epub \(epubCover == CoverStore.noImage ? "ritas av biblioteket (rätt)" : "FEL, \(epubCover)")")
        if let continueItem = library.continueItem {
            SelfTest.log("Fortsätt läsa (B2): \(continueItem.title), \(continueItem.chapter.isEmpty ? "inget kapitel" : continueItem.chapter), "
                         + LibraryLogic.statusLine(continueItem))
        } else {
            SelfTest.log("Fortsätt läsa (B2): ingen bok")
        }

        // Hållmenyn.
        if let pdf = pdf {
            let titles = library.menu(for: pdf).children.map(\.title)
            SelfTest.log("Hållmenyn på test.pdf: \(titles.joined(separator: ", "))")
        }

        // Byt namn och tillbaka.
        if let pdf = pdf {
            BookRegistry.shared.rename(id: pdf.book.id, title: "Egen titel", author: "Egen författare")
            library.reload()
            let renamed = library.allItems.first { $0.book.id == pdf.book.id }
            BookRegistry.shared.rename(id: pdf.book.id, title: "", author: "")
            library.reload()
            let back = library.allItems.first { $0.book.id == pdf.book.id }
            SelfTest.log("Byt namn: \(renamed?.title ?? "") av \(renamed?.author ?? ""), tillbaka: \(back?.title ?? ""). "
                         + (renamed?.title == "Egen titel" && back?.title == "Provbok med textlager" ? "Rätt" : "FEL"))
        }

        // Välj omslag: sidan 3 i den fotade PDF:en, sparad som sidnummer i registret.
        if let photo = library.allItems.first(where: { $0.book.path == "foto.pdf" }) {
            BookRegistry.shared.setCoverPage(id: photo.book.id, page: 2)
            library.reload()
            var tries = 0
            while (BookRegistry.shared.record(id: photo.book.id)?.cover ?? "").hasSuffix("-2.jpg") == false && tries < 30 {
                await pause(0.3)
                tries += 1
            }
            let record = BookRegistry.shared.record(id: photo.book.id)
            SelfTest.log("Välj omslag: sidan \((record?.coverPage ?? -9) + 1) sparad, omslaget \(record?.cover ?? "") "
                         + ((record?.cover ?? "").hasSuffix("-2.jpg") ? "Rätt" : "FEL"))
        }

        // Markera som läst, och filtret Utlästa.
        if let epub = epub {
            BookRegistry.shared.setFinished(id: epub.book.id, true)
            library.reload()
            let finished = LibraryLogic.filter(library.allItems, .finished).map(\.book.path)
            BookRegistry.shared.setFinished(id: epub.book.id, false)
            library.reload()
            SelfTest.log("Markera som läst: Utlästa visar \(finished.joined(separator: ", ")). "
                         + (finished.contains("test.epub") ? "Rätt" : "FEL"))
        }

        // B3: kurser. Mappen Kurs blir en kurs av sig själv, en egen kurs får test.pdf och en färg.
        if let folderCourse = CourseStore.shared.courses().first(where: { $0.folder == "Kurs" }) {
            let members = library.allItems.filter { $0.courses.contains(folderCourse.id) }.map(\.book.path)
            SelfTest.log("Kurs ur mappen Kurs (B3): \(folderCourse.name) med \(members.joined(separator: ", ")). "
                         + (members == ["Kurs/Anteckningar.md"] ? "Rätt" : "FEL"))
        } else {
            SelfTest.log("Kurs ur mappen Kurs (B3): FEL, saknas")
        }
        var ownCourse: Course?
        if let pdf = pdf, let course = CourseStore.shared.create(name: "Provkurs", color: HighlightColor.green.rawValue) {
            ownCourse = course
            CourseStore.shared.add(book: pdf.book.id, to: course.id)
            library.reload()
            library.setScope(.course(course.id))
            let shown = library.items.map(\.book.path)
            let menuTitles = (library.menu(for: library.allItems.first { $0.book.id == pdf.book.id } ?? pdf).children
                .compactMap { $0 as? UIMenu }.first?.children.map(\.title)) ?? []
            SelfTest.log("Egen kurs (B3): Provkurs visar \(shown.joined(separator: ", ")), Lägg i kurs: "
                         + "\(menuTitles.joined(separator: ", ")). \(shown == ["test.pdf"] ? "Rätt" : "FEL")")
            library.setScope(.all)
        }
        SelfTest.log("Sidopanelen (B3): \(library.sidebar.rowsForSelfTest.joined(separator: " | "))")

        await testFirstStart(library: library)

        // Bilder: stående, liggande, iPhone-storlek och tomt bibliotek.
        let container = navigation.view!
        let original = container.frame
        library.reload()
        await pause(0.8)
        SelfTest.saveScreen(container, name: "20-bibliotek-staende")
        library.collectionViewForSelfTest.setContentOffset(CGPoint(x: 0, y: 420), animated: false)
        await pause(0.5)
        SelfTest.saveScreen(container, name: "20a-bibliotek-staende-nere")
        library.collectionViewForSelfTest.setContentOffset(.zero, animated: false)

        container.frame = CGRect(x: 0, y: 0, width: original.width, height: (original.width * 0.72).rounded())
        container.layoutIfNeeded()
        library.reload()
        await pause(1.0)
        SelfTest.log("Liggande: sidopanelen \(library.showsSidebar ? "syns" : "FEL, syns inte")")
        SelfTest.saveScreen(container, name: "20b-bibliotek-liggande")
        if let course = ownCourse {
            library.setScope(.course(course.id))
            await pause(0.6)
            SelfTest.saveScreen(container, name: "20e-bibliotek-kurs")
            library.setScope(.all)
        }

        container.frame = CGRect(x: 0, y: 0, width: 390, height: min(844, original.height))
        container.layoutIfNeeded()
        library.reload()
        await pause(1.0)
        SelfTest.saveScreen(container, name: "20c-bibliotek-iphone")

        container.frame = original
        container.layoutIfNeeded()
        library.showsEmptyForSelfTest = true
        library.reload()
        await pause(0.8)
        SelfTest.saveScreen(container, name: "20d-bibliotek-tomt")
        library.showsEmptyForSelfTest = false
        if let course = ownCourse {
            CourseStore.shared.delete(course.id)
        }
        library.reload()
        await pause(0.4)
    }

    /// B5: simulatorn har böcker och ska aldrig få välkomstsidan. Välkomstsidan, kortet Gör mer med Sensus och
    /// exempelboken med stegen fotograferas, och exempelboken tas bort efteråt.
    static func testFirstStart(library: LibraryViewController) async {
        guard let navigation = library.navigationController else { return }
        SelfTest.log("Första start (B5): befintlig data \(Onboarding.hasExistingData() ? "finns" : "FEL, saknas"), "
                     + "välkomstsidan \(Onboarding.shouldShowWelcome ? "FEL, visas" : "visas inte (rätt)")")
        let welcome = WelcomeViewController()
        welcome.modalPresentationStyle = .fullScreen
        library.present(welcome, animated: false)
        await pause(0.8)
        SelfTest.saveScreen(welcome.view, name: "21-forsta-start")
        library.dismiss(animated: false)
        await pause(0.4)

        Onboarding.setNewInstallForSelfTest(true)
        library.reload()
        await pause(0.6)
        SelfTest.saveScreen(navigation.view, name: "21a-gor-mer")
        Onboarding.setNewInstallForSelfTest(false)

        library.openSampleBook()
        await pause(4.0)
        let reader = navigation.topViewController
        SelfTest.log("Exempelboken: \(reader is ReflowReaderViewController ? "öppnad" : "FEL, öppnades inte"), "
                     + "raden: \(OnboardingTips.shared.text)")
        SelfTest.saveScreen(navigation.view, name: "21b-exempelbok")
        if let book = library.books.first(where: { Onboarding.isSample($0) }) {
            for step in OnboardingTips.Step.allCases {
                OnboardingTips.shared.record(step, book: book)
            }
            SelfTest.log("Exempelboken efter de tre stegen: \(OnboardingTips.shared.text)")
            navigation.popToRootViewController(animated: false)
            await pause(0.6)
            let title = library.allItems.first { Onboarding.isSample($0.book) }?.title ?? "saknas"
            SelfTest.log("Exempelboken i biblioteket: \(title)")
            try? LibraryStore.shared.delete(book)
        } else {
            SelfTest.log("FEL: exempelboken finns inte i biblioteket")
            navigation.popToRootViewController(animated: false)
        }
        library.reload()
        await pause(0.4)
    }

    /// Granskning 2, N2: en ny fil med samma namn som en bok som togs bort i gamla appen (en platshållare med
    /// storlek 0 och utan kontrollsumma) tar inte tyst över dess markeringar. Nej ger en ny bok, Behåll ger
    /// platshållarens id och markeringen.
    static func testPlaceholderImport(library: LibraryViewController) async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("platshallarprov", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var results: [String] = []
        var allOK = true
        for (name, keep) in [("PlatshallarprovA.md", false), ("PlatshallarprovB.md", true)] {
            let placeholder = BookRecord(id: UUID().uuidString.lowercased(), sha256: "", file: name,
                                         title: (name as NSString).deletingPathExtension, size: 0, modified: 0,
                                         added: Date().timeIntervalSince1970, missing: true)
            BookRegistry.shared.save([placeholder])
            AnnotationStore.shared.addHighlight(book: placeholder.id, section: 0, start: 2, length: 5,
                                                text: "Platshållare", color: .yellow)
            let source = folder.appendingPathComponent(name)
            try? Data("# \(name)\n\nEn annan bok med samma namn som en borttagen.\n".utf8).write(to: source)
            BookImporter.selfTestKeepVersion = keep
            let book: Book? = await withCheckedContinuation { continuation in
                BookImporter.shared.start([source], move: true, presenter: library) { books in
                    continuation.resume(returning: books.first)
                }
            }
            BookImporter.selfTestKeepVersion = nil
            let marks = AnnotationStore.shared.highlights(book: placeholder.id).count
            let stillMissing = BookRegistry.shared.record(id: placeholder.id)?.missing ?? false
            let ok: Bool
            if keep {
                ok = book?.id == placeholder.id && marks == 1 && !stillMissing
                results.append("Behåll: \(book?.id == placeholder.id ? "platshållarens id" : "FEL, annat id"), "
                               + "\(marks) markering")
            } else {
                ok = book != nil && book?.id != placeholder.id && stillMissing
                results.append("Nej: \(book?.id != placeholder.id ? "ny bok" : "FEL, tog över platshållaren"), "
                               + "platshållaren \(stillMissing ? "kvar som borttagen" : "FEL, används")")
            }
            allOK = allOK && ok
            if let book = book {
                try? LibraryStore.shared.delete(book)
            }
        }
        try? FileManager.default.removeItem(at: folder)
        library.reload()
        SelfTest.log("Platshållare och ny fil med samma namn (N2): \(results.joined(separator: "; ")). "
                     + (allOK ? "Rätt" : "FEL"))
    }

    /// Edvins riktiga data: en databas i den form våg 3 lämnade (version 3) med en bok, markeringar med rutor,
    /// ett bokmärke och klart-markeringen går genom trappan. Inget får försvinna, och en rad som sparas om
    /// efteråt behåller titel och omslag (ingen `INSERT OR REPLACE`).
    static func testWave3Database() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vag3-prov.sqlite")
        try? FileManager.default.removeItem(at: url)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let db = try SQLiteDatabase(path: url.path, readOnly: false)
            try db.migrate(Array(AnnotationStore.migrations.prefix(3)))
            let record = BookRecord(id: "bok-1", sha256: "abc", file: "RETA30/Retorik.pdf", title: "Retorik", size: 1234,
                                    modified: 99, added: 1_700_000_000, missing: false)
            try BookRegistry.insert(record, into: db)
            try db.execute("""
                INSERT INTO highlights (id, book, section, start, length, text, color, note, created, updated, deleted, rects)
                VALUES ('m1', 'bok-1', 4, 10, 5, 'ethos', 'yellow', 'en anteckning', 1, 2, 0, '[[1,2,3,4]]'),
                       ('m2', 'bok-1', 7, 0, 3, 'logos', 'blue', '', 1, 2, 1, '')
                """)
            try db.execute("""
                INSERT INTO bookmarks (id, book, section, progression, label, created, updated, deleted)
                VALUES ('b1', 'bok-1', 9, 0, 'Sidan 10', 1, 2, 0)
                """)
            try db.execute("INSERT INTO meta (key, value) VALUES ('legacy_book_keys_moved', '1')")
            func snapshot() throws -> String {
                var rows: [String] = []
                try db.query("SELECT id, book, section, start, length, text, color, note, created, updated, deleted, rects "
                              + "FROM highlights ORDER BY id") { row in
                    rows.append((0..<12).map { row.string(Int32($0)) }.joined(separator: "|"))
                }
                try db.query("SELECT id, book, section, progression, label, deleted FROM bookmarks") { row in
                    rows.append((0..<6).map { row.string(Int32($0)) }.joined(separator: "|"))
                }
                try db.query("SELECT id, sha256, file, title, size, modified, added, missing FROM books") { row in
                    rows.append((0..<8).map { row.string(Int32($0)) }.joined(separator: "|"))
                }
                try db.query("SELECT key, value FROM meta") { row in
                    rows.append(row.string(0) + "=" + row.string(1))
                }
                return rows.joined(separator: "\n")
            }
            let before = try snapshot()
            let versions = try db.migrate(AnnotationStore.migrations)
            let after = try snapshot()
            try db.execute("UPDATE books SET book_title = 'Retorikens grunder', cover = 'omslag.jpg' WHERE id = 'bok-1'")
            var saved = record
            saved.file = "Retorik.pdf"
            try BookRegistry.insert(saved, into: db)
            var kept = ""
            try db.query("SELECT book_title, cover, file FROM books WHERE id = 'bok-1'") { row in
                kept = "\(row.string(0)), \(row.string(1)), \(row.string(2))"
            }
            let ok = before == after && kept == "Retorikens grunder, omslag.jpg, Retorik.pdf"
            SelfTest.log("Databasen från våg 3 (version \(versions.from) till \(versions.to)): "
                         + "\(before == after ? "allt kvar" : "FEL, något ändrades") (\(before.split(separator: "\n").count) rader), "
                         + "efter omsparning: \(kept). \(ok ? "Rätt" : "FEL")")
        } catch {
            SelfTest.log("FEL: provet av databasen från våg 3: \(error)")
        }
    }
}
