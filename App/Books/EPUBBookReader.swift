import Foundation

/// Läser en EPUB. Första gången packas den upp i appens cache, och kapitlen får en viewport-rad så att
/// webbvyn lägger ut texten i sidans bredd. Sedan läses ryggraden (kapitlen i ordning) och
/// innehållsförteckningen (nav i EPUB 3, NCX i EPUB 2). Körs i bakgrunden.
enum EPUBBookReader {

    static let viewportMeta = "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1, "
        + "minimum-scale=1, maximum-scale=1, user-scalable=no, shrink-to-fit=no\"/>"

    private static let maxEntries = 3000

    private struct Item {
        let url: URL
        let type: String
        let properties: [String]
    }

    static func open(_ book: Book, directory: URL, identifier: String) throws -> ReflowableBook {
        let fileManager = FileManager.default
        let marker = directory.appendingPathComponent(".klar")
        let unpacked = fileManager.fileExists(atPath: marker.path)
        if !unpacked {
            try? fileManager.removeItem(at: directory)
            let archive = try ZipArchive(url: book.url)
            try checkProtection(archive)
            try archive.extractAll(to: directory)
        }

        let containerURL = directory.appendingPathComponent("META-INF/container.xml")
        guard let container = XMLTree.parse(contentsOf: containerURL),
              let rootPath = container.descendants(named: "rootfile").compactMap({ $0["full-path"] }).first,
              let relative = ZipArchive.safeRelativePath(rootPath) else {
            throw BookError.notAnEPUB
        }
        let packageURL = directory.appendingPathComponent(relative)
        guard let package = XMLTree.parse(contentsOf: packageURL) else { throw BookError.notAnEPUB }

        var manifest: [String: Item] = [:]
        for item in package.descendants(named: "item") {
            guard let id = item["id"], let href = item["href"],
                  let target = resolve(href, relativeTo: packageURL) else { continue }
            let properties = (item["properties"] ?? "").split(separator: " ").map(String.init)
            manifest[id] = Item(url: target.url, type: (item["media-type"] ?? "").lowercased(), properties: properties)
        }

        guard let spine = package.descendants(named: "spine").first else { throw BookError.notAnEPUB }
        var chapters: [ReflowableBook.Chapter] = []
        for reference in spine.children where reference.name == "itemref" {
            guard let id = reference["idref"], let item = manifest[id], isDocument(item),
                  let size = fileSize(of: item.url) else { continue }
            chapters.append(ReflowableBook.Chapter(url: item.url, weight: max(size, 1), title: nil))
        }
        guard !chapters.isEmpty else { throw BookError.empty }

        if !unpacked {
            for chapter in chapters {
                insertViewport(into: chapter.url)
            }
            try Data().write(to: marker)
        }

        var indexByPath: [String: Int] = [:]
        for (index, chapter) in chapters.enumerated() where indexByPath[ReflowableBook.pathKey(for: chapter.url)] == nil {
            indexByPath[ReflowableBook.pathKey(for: chapter.url)] = index
        }
        let chapterIndex: (URL) -> Int? = { url in indexByPath[ReflowableBook.pathKey(for: url)] }

        var toc: [ReflowableBook.TOCEntry] = []
        if let nav = manifest.values.first(where: { $0.properties.contains("nav") }) {
            toc = navigationEntries(in: nav.url, chapterIndex: chapterIndex)
        }
        if toc.isEmpty {
            let ncxID = spine["toc"]
            let ncx = ncxID.flatMap { manifest[$0] } ?? manifest.values.first { $0.type == "application/x-dtbncx+xml" }
            if let ncx = ncx {
                toc = ncxEntries(in: ncx.url, chapterIndex: chapterIndex)
            }
        }
        for entry in toc where chapters[entry.chapter].title == nil {
            chapters[entry.chapter].title = entry.title
        }

        let metadataTitle = package.descendants(named: "metadata").first?
            .descendants(named: "title").first?.text ?? ""
        return ReflowableBook(title: metadataTitle.isEmpty ? book.title : metadataTitle,
                              identifier: identifier,
                              rootDirectory: directory,
                              chapters: chapters,
                              toc: toc,
                              isPlainText: false)
    }

    // MARK: Kopieringsskydd

    /// Teckensnitt får vara förvrängda (det är inte DRM), allt annat krypterat går inte att visa.
    private static func checkProtection(_ archive: ZipArchive) throws {
        if archive.entry(named: "META-INF/rights.xml") != nil {
            throw BookError.drm
        }
        guard let entry = archive.entry(named: "META-INF/encryption.xml"),
              let data = try? archive.contents(of: entry),
              let root = XMLTree.parse(data) else {
            return
        }
        let fontObfuscation: Set<String> = ["http://www.idpf.org/2008/embedding", "http://ns.adobe.com/pdf/enc#RC"]
        for method in root.descendants(named: "EncryptionMethod") {
            if let algorithm = method["Algorithm"], !fontObfuscation.contains(algorithm) {
                throw BookError.drm
            }
        }
    }

    // MARK: Sökvägar

    /// En länk i boken (relativ till filen den står i) som fil plus ankare.
    static func resolve(_ href: String, relativeTo base: URL) -> (url: URL, fragment: String?)? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var path = trimmed
        var fragment: String?
        if let hash = trimmed.firstIndex(of: "#") {
            path = String(trimmed[..<hash])
            let raw = String(trimmed[trimmed.index(after: hash)...])
            fragment = raw.removingPercentEncoding ?? raw
        }
        if fragment?.isEmpty == true {
            fragment = nil
        }
        if path.isEmpty {
            return (base.standardizedFileURL, fragment)
        }
        let resolved = URL(string: path, relativeTo: base)
            ?? path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed).flatMap { URL(string: $0, relativeTo: base) }
        guard let url = resolved?.absoluteURL.standardizedFileURL, url.isFileURL else { return nil }
        return (url, fragment)
    }

    private static func isDocument(_ item: Item) -> Bool {
        if item.type == "application/xhtml+xml" || item.type == "text/html" {
            return true
        }
        return ["xhtml", "html", "htm"].contains(item.url.pathExtension.lowercased())
    }

    private static func fileSize(of url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    // MARK: Innehållsförteckning

    /// EPUB 3: listan i nav-elementet med typen toc.
    private static func navigationEntries(in url: URL, chapterIndex: @escaping (URL) -> Int?) -> [ReflowableBook.TOCEntry] {
        guard let document = XMLTree.parse(contentsOf: url) else { return [] }
        let navs = document.descendants(named: "nav")
        let tocNav = navs.first { ($0["type"] ?? "").split(separator: " ").contains("toc") } ?? navs.first
        guard let nav = tocNav, let list = nav.descendants(named: "ol").first else { return [] }

        var entries: [ReflowableBook.TOCEntry] = []
        func visit(_ ol: XMLNode, level: Int) {
            for item in ol.children where item.name == "li" {
                guard entries.count < maxEntries else { return }
                if let label = item.children.first(where: { $0.name == "a" || $0.name == "span" }) {
                    let title = label.text
                    if !title.isEmpty, let href = label["href"],
                       let target = resolve(href, relativeTo: url),
                       let chapter = chapterIndex(target.url) {
                        entries.append(ReflowableBook.TOCEntry(title: title, level: level,
                                                               chapter: chapter, fragment: target.fragment))
                    }
                }
                for nested in item.children where nested.name == "ol" {
                    visit(nested, level: level + 1)
                }
            }
        }
        visit(list, level: 0)
        return entries
    }

    /// EPUB 2: navMap i NCX-filen.
    private static func ncxEntries(in url: URL, chapterIndex: @escaping (URL) -> Int?) -> [ReflowableBook.TOCEntry] {
        guard let document = XMLTree.parse(contentsOf: url),
              let map = document.descendants(named: "navMap").first else { return [] }

        var entries: [ReflowableBook.TOCEntry] = []
        func visit(_ node: XMLNode, level: Int) {
            for point in node.children where point.name == "navPoint" {
                guard entries.count < maxEntries else { return }
                let title = point.children.first { $0.name == "navLabel" }?.text ?? ""
                let source = point.children.first { $0.name == "content" }?["src"]
                if !title.isEmpty, let source = source,
                   let target = resolve(source, relativeTo: url),
                   let chapter = chapterIndex(target.url) {
                    entries.append(ReflowableBook.TOCEntry(title: title, level: level,
                                                           chapter: chapter, fragment: target.fragment))
                }
                visit(point, level: level + 1)
            }
        }
        visit(map, level: 0)
        return entries
    }

    // MARK: Viewport

    /// Lägger in en viewport-rad först i head. Utan den lägger webbvyn ut sidan 980 punkter bred och krymper den.
    /// Ändringen görs på bytenivå, så att filens teckenkodning inte påverkas. Filer som redan har en
    /// viewport (fast layout) och UTF-16-filer lämnas orörda.
    static func insertViewport(into url: URL) {
        guard var data = try? Data(contentsOf: url) else { return }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return
        }
        let searchLength = min(data.count, 65_536)
        let lower = data.prefix(searchLength).map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }
        if index(of: Array("name=\"viewport\"".utf8), in: lower) != nil
            || index(of: Array("name='viewport'".utf8), in: lower) != nil {
            return
        }
        let position = tagEnd(named: "head", in: lower) ?? tagEnd(named: "html", in: lower)
        guard let insertAt = position else { return }
        data.insert(contentsOf: Data(viewportMeta.utf8), at: insertAt)
        try? data.write(to: url)
    }

    /// Positionen direkt efter starttaggen (till exempel efter "<head>"), eller nil.
    private static func tagEnd(named name: String, in bytes: [UInt8]) -> Int? {
        let pattern = Array("<\(name)".utf8)
        var from = 0
        while let start = index(of: pattern, in: bytes, from: from) {
            let next = start + pattern.count
            guard next < bytes.count else { return nil }
            let character = bytes[next]
            // "<head" ska följas av ">" eller ett blanktecken, så att "<header" inte räknas.
            if character == 0x3E || character == 0x20 || character == 0x09 || character == 0x0A || character == 0x0D {
                var end = next
                while end < bytes.count, bytes[end] != 0x3E {
                    end += 1
                }
                return end < bytes.count ? end + 1 : nil
            }
            from = next
        }
        return nil
    }

    private static func index(of pattern: [UInt8], in bytes: [UInt8], from: Int = 0) -> Int? {
        guard !pattern.isEmpty, bytes.count >= pattern.count, from <= bytes.count - pattern.count else { return nil }
        var position = from
        let last = bytes.count - pattern.count
        while position <= last {
            if bytes[position] == pattern[0] {
                var matches = true
                for offset in 1..<pattern.count where bytes[position + offset] != pattern[offset] {
                    matches = false
                    break
                }
                if matches {
                    return position
                }
            }
            position += 1
        }
        return nil
    }
}
