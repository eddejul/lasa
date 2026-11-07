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
