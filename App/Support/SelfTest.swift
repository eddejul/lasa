import UIKit

/// Ett självtest för bygget i molnet. Det körs bara när appen startas med argumentet
/// `-LasaSelfTest <filnamn>`, vilket bara simulatortestet i bygget gör. Då öppnas boken, läsaren bläddrar,
/// slår upp ett ord, byter typsnitt och tema, och sparar bilder och en logg i Documents/selftest,
/// så att läsaren kan kontrolleras utan en iPad. Vanliga användare påverkas inte.
enum SelfTest {

    static let bookName: String? = UserDefaults.standard.string(forKey: "LasaSelfTest")

    static var isActive: Bool {
        bookName != nil
    }

    /// Namnet som startar självtestet för fas 6 (repetition, inställningar, AI-svaret och synken).
    static let fas6Name = "fas6"

    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("selftest", isDirectory: true)
    }

    /// Filnamnet med punkten utbytt, så att test.epub och test.md inte skriver över varandras filer.
    static var stem: String {
        (bookName ?? "test").replacingOccurrences(of: ".", with: "-")
    }

    private static let started = Date()

    static func log(_ text: String) {
        guard isActive else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let line = String(format: "%7.2f  ", Date().timeIntervalSince(started)) + text + "\n"
        let url = directory.appendingPathComponent(stem + ".log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            try? Data(line.utf8).write(to: url)
        }
        print("SELFTEST " + text)
    }

    /// Sparar det som syns i vyn som en bild.
    @MainActor
    static func saveScreen(_ view: UIView, name: String) {
        guard isActive, view.bounds.width > 0, view.bounds.height > 0 else { return }
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        let image = renderer.image { _ in
            _ = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        if let data = image.jpegData(compressionQuality: 0.8) {
            try? data.write(to: directory.appendingPathComponent("\(stem)-\(name).jpg"))
        }
        log("Bild sparad: \(name)")
    }

    /// Andelen punkter (0 till 100) i vyns mittband, utan menyraden och nederkanten, som skiljer sig tydligt
    /// från papperets färg. Under cirka 0,5 är sidan blank. Edvin 8 nov: sidan blev blank efter Aa.
    @MainActor
    static func inkPercent(in view: UIView, paper: UIColor) -> Double {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return -1 }
        let width = 96
        let height = max(Int((Double(width) * Double(bounds.height / bounds.width)).rounded()), 1)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { _ in
            _ = view.drawHierarchy(in: CGRect(x: 0, y: 0, width: width, height: height), afterScreenUpdates: true)
        }
        guard let cg = small.cgImage else { return -1 }
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        paper.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let paperRGB = [Int(red * 255), Int(green * 255), Int(blue * 255)]
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let counted: Int = pixels.withUnsafeMutableBytes { buffer -> Int in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return -1 }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            let bytes = buffer.bindMemory(to: UInt8.self)
            var ink = 0
            // Mittbandet: 15 till 85 procent av höjden, där menyraden och nederkanten inte ligger.
            for row in Int(Double(height) * 0.15)..<Int(Double(height) * 0.85) {
                for column in 0..<width {
                    let index = (row * width + column) * 4
                    let difference = abs(Int(bytes[index]) - paperRGB[0]) + abs(Int(bytes[index + 1]) - paperRGB[1])
                        + abs(Int(bytes[index + 2]) - paperRGB[2])
                    if difference > 40 {
                        ink += 1
                    }
                }
            }
            return ink
        }
        guard counted >= 0 else { return -1 }
        let band = max(Int(Double(height) * 0.85) - Int(Double(height) * 0.15), 1) * width
        return Double(counted) * 100 / Double(band)
    }

    // MARK: Hela skärmen (Edvin 9 nov)

    /// Appens eget fönster i scenen (det SceneDelegate skapar). Alla andra fönster i scenen är systemets,
    /// till exempel tangentbordets textfönster, som ligger över hela skärmen.
    @MainActor
    static func appWindow(in scene: UIWindowScene?) -> UIWindow? {
        (scene?.delegate as? SceneDelegate)?.window
    }

    /// Systemets fönster i scenen som syns och har en egen bakgrundsfärg. De ska alltid vara genomskinliga:
    /// Edvin 9 nov såg hela skärmen i en enda färg efter ett byte av bakgrund, och appen såg fryst ut.
    @MainActor
    static func coveringWindows(in scene: UIWindowScene?) -> [String] {
        guard let scene = scene else { return [] }
        let own = appWindow(in: scene)
        return scene.windows.compactMap { window in
            guard window !== own, !window.isHidden, window.alpha > 0.01 else { return nil }
            let alpha = window.backgroundColor?.cgColor.alpha ?? 0
            guard alpha > 0.01 else { return nil }
            return "\(type(of: window)) (nivå \(Int(window.windowLevel.rawValue)), "
                + "bakgrund \(Int((alpha * 100).rounded())) %)"
        }
    }

    /// Alla fönster i scenen, till loggen: klass, nivå, om det syns, storlek och bakgrundens täckning.
    @MainActor
    static func windowSummary(in scene: UIWindowScene?) -> String {
        guard let scene = scene else { return "ingen scen" }
        let own = appWindow(in: scene)
        return scene.windows.map { window in
            let alpha = window.backgroundColor?.cgColor.alpha ?? 0
            return "\(type(of: window))\(window === own ? " (appens)" : "") nivå \(Int(window.windowLevel.rawValue)), "
                + "\(window.isHidden ? "dolt" : "syns"), \(Int(window.bounds.width)) x \(Int(window.bounds.height)), "
                + "bakgrund \(Int((alpha * 100).rounded())) %"
        }.joined(separator: "; ")
    }

    /// Det som syns på skärmen: alla synliga fönster i scenen ritade i nivåordning, till skillnad från
    /// `inkPercent`, som bara ritar läsarens egen vy och inte ser ett fönster som ligger ovanpå.
    @MainActor
    static func screenImage(of scene: UIWindowScene?, width: Int? = nil) -> UIImage? {
        guard let scene = scene else { return nil }
        let bounds = scene.coordinateSpace.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = width.map { CGFloat($0) / bounds.width } ?? 1
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        let windows = scene.windows.enumerated()
            .filter { !$0.element.isHidden && $0.element.alpha > 0.01 }
            .sorted { ($0.element.windowLevel.rawValue, $0.offset) < ($1.element.windowLevel.rawValue, $1.offset) }
            .map { $0.element }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            for window in windows {
                let frame = window.frame
                let rect = CGRect(x: frame.minX * scale, y: frame.minY * scale,
                                  width: frame.width * scale, height: frame.height * scale)
                _ = window.drawHierarchy(in: rect, afterScreenUpdates: true)
            }
        }
    }

    /// Sparar det som syns på hela skärmen (alla fönster) som en bild.
    @MainActor
    static func saveWholeScreen(_ scene: UIWindowScene?, name: String) {
        guard isActive, let image = screenImage(of: scene) else { return }
        if let data = image.jpegData(compressionQuality: 0.8) {
            try? data.write(to: directory.appendingPathComponent("\(stem)-\(name).jpg"))
        }
        log("Bild sparad: \(name) (hela skärmen, alla fönster)")
    }

    /// Andelen punkter (0 till 100) i skärmens mittband som skiljer sig tydligt från bandets vanligaste färg.
    /// Under cirka 0,5 är hela skärmen en enda färg, som Edvin såg 9 nov.
    @MainActor
    static func screenVariationPercent(in scene: UIWindowScene?) -> Double {
        guard let image = screenImage(of: scene, width: 96), let cg = image.cgImage else { return -1 }
        let width = cg.width
        let height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        return pixels.withUnsafeMutableBytes { buffer -> Double in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return -1 }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            let bytes = buffer.bindMemory(to: UInt8.self)
            let rows = Int(Double(height) * 0.15)..<Int(Double(height) * 0.85)
            // Den vanligaste färgen, i steg om 16 per kanal.
            var counts: [Int: Int] = [:]
            for row in rows {
                for column in 0..<width {
                    let index = (row * width + column) * 4
                    let key = Int(bytes[index] >> 4) << 8 | Int(bytes[index + 1] >> 4) << 4 | Int(bytes[index + 2] >> 4)
                    counts[key, default: 0] += 1
                }
            }
            guard let common = counts.max(by: { $0.value < $1.value })?.key else { return -1 }
            let reference = [((common >> 8) & 0xF) * 16 + 8, ((common >> 4) & 0xF) * 16 + 8, (common & 0xF) * 16 + 8]
            var different = 0
            for row in rows {
                for column in 0..<width {
                    let index = (row * width + column) * 4
                    let difference = abs(Int(bytes[index]) - reference[0]) + abs(Int(bytes[index + 1]) - reference[1])
                        + abs(Int(bytes[index + 2]) - reference[2])
                    if difference > 40 {
                        different += 1
                    }
                }
            }
            return Double(different) * 100 / Double(max(rows.count * width, 1))
        }
    }

    /// Första och sista raden med text i en sidbild, som andel (0 till 1) av bildens höjd. Nil om bilden är tom.
    /// Till kontrollen att menyraden och nederkanten bara ligger över marginalen (Edvin 8 nov).
    static func inkRows(in image: UIImage, paper: UIColor) -> (top: Double, bottom: Double)? {
        guard let cg = image.cgImage, image.size.width > 0, image.size.height > 0 else { return nil }
        let width = 200
        let height = max(Int((Double(width) * Double(image.size.height / image.size.width)).rounded()), 1)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        paper.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let paperRGB = [Int(red * 255), Int(green * 255), Int(blue * 255)]
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rows: [Int] = pixels.withUnsafeMutableBytes { buffer -> [Int] in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            let bytes = buffer.bindMemory(to: UInt8.self)
            var found: [Int] = []
            for row in 0..<height {
                var ink = 0
                for column in 0..<width {
                    let index = (row * width + column) * 4
                    let difference = abs(Int(bytes[index]) - paperRGB[0]) + abs(Int(bytes[index + 1]) - paperRGB[1])
                        + abs(Int(bytes[index + 2]) - paperRGB[2])
                    if difference > 60 {
                        ink += 1
                    }
                }
                if ink >= 2 {
                    found.append(row)
                }
            }
            return found
        }
        guard let first = rows.first, let last = rows.last else { return nil }
        return (Double(first) / Double(height), Double(last + 1) / Double(height))
    }

    static func finish() {
        log("KLART")
        try? Data().write(to: directory.appendingPathComponent(stem + ".klar"))
    }
}

/// Hur mycket minne appens egen process använder (inte webbvyernas processer).
enum MemoryUsage {

    static var megabytes: Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }
}
