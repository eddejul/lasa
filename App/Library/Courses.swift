import UIKit

/// En kurs (B3), till exempel RETA30 eller Högskoleprovet. En undermapp i Böcker blir en kurs av sig själv
/// (`folder`), och böcker kan läggas i kurser med hållmenyn. Färgen är en av markeringsfärgerna och syns som
/// rand på omslagen. Ingen synk än: synken byggs om till iCloud Drive (F1).
struct Course: Equatable {
    let id: String
    var name: String
    /// En av `HighlightColor`, tom för ingen färg.
    var color: String
    /// Undermappen i Böcker som kursen kommer från, tom för en kurs man skapat själv.
    var folder: String
    var added: Double
    var deleted: Bool = false

    var tint: UIColor? {
        HighlightColor(rawValue: color)?.solid
    }
}

/// Kursernas logik utan databas, så att den går att testa (XCTest).
enum CourseLogic {

    /// Den första mappen i en sökväg i Böcker ("RETA30/Kap 1/Bok.pdf" ger "RETA30"), nil direkt i Böcker.
    static func topFolder(of path: String) -> String? {
        let parts = path.split(separator: "/")
        return parts.count > 1 ? String(parts[0]) : nil
    }

    /// Mappar som ska bli kurser: varje översta undermapp med böcker som inte redan har en kurs. En kurs som
    /// tagits bort (`deleted`) skapas inte igen.
    static func newFolderCourses(paths: [String], existing: [Course]) -> [String] {
        let known = Set(existing.map { $0.folder.lowercased() }.filter { !$0.isEmpty })
        var result: [String] = []
        for folder in paths.compactMap(topFolder(of:)) where !known.contains(folder.lowercased())
            && !result.contains(folder) {
            result.append(folder)
        }
        return result.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Kurserna en bok ligger i: kursen för bokens mapp, och de man lagt den i själv.
    static func courses(forPath path: String, bookID: String, courses: [Course],
                        explicit: [String: Set<String>]) -> Set<String> {
        var result = explicit[bookID] ?? []
        if let folder = topFolder(of: path)?.lowercased() {
            for course in courses where !course.deleted && course.folder.lowercased() == folder {
                result.insert(course.id)
            }
        }
        let live = Set(courses.filter { !$0.deleted }.map(\.id))
        return result.intersection(live)
    }
}

/// Kurserna i `markeringar.sqlite` (steg 5 i trappan). Används bara från huvudtråden.
final class CourseStore {

    static let shared = CourseStore()
    static let didChange = Notification.Name("CourseStoreDidChange")

    private var cache: [Course]?
    private var membershipCache: [String: Set<String>]?

    private init() {}

    private var store: AnnotationStore {
        AnnotationStore.shared
    }

    /// Alla kurser, också borttagna (för mapparna), i namnordning.
    func allCourses() -> [Course] {
        if let cache = cache {
            return cache
        }
        var result: [Course] = []
        store.readBooks { db in
            try db.query("SELECT id, name, color, folder, added, deleted FROM courses") { row in
                result.append(Course(id: row.string(0), name: row.string(1), color: row.string(2),
                                     folder: row.string(3), added: row.double(4), deleted: row.int(5) != 0))
            }
        }
        result.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        cache = result
        return result
    }

    /// Kurserna som syns.
    func courses() -> [Course] {
        allCourses().filter { !$0.deleted }
    }

    /// Bok-id till de kurser man lagt boken i själv.
    func membership() -> [String: Set<String>] {
        if let cache = membershipCache {
            return cache
        }
        var result: [String: Set<String>] = [:]
        store.readBooks { db in
            try db.query("SELECT course, book FROM course_books") { row in
                result[row.string(1), default: []].insert(row.string(0))
            }
        }
        membershipCache = result
        return result
    }

    private func changed() {
        cache = nil
        membershipCache = nil
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Undermappar i Böcker blir kurser av sig själva (en gång per mapp).
    func addFolderCourses(for books: [Book]) {
        guard store.database != nil else { return }
        let names = CourseLogic.newFolderCourses(paths: books.map(\.path), existing: allCourses())
        guard !names.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        store.writeBooks("kurserna") { db in
            for name in names {
                try db.execute("INSERT INTO courses (id, name, color, folder, added, deleted) VALUES (?, ?, '', ?, ?, 0)",
                               [UUID().uuidString.lowercased(), name, name, now])
            }
        }
        AppLog.shared.write("Kurser ur mappar i Böcker: \(names.count)")
        changed()
    }

    @discardableResult
    func create(name: String, color: String = "") -> Course? {
        let course = Course(id: UUID().uuidString.lowercased(), name: name, color: color, folder: "",
                            added: Date().timeIntervalSince1970)
        let ok = store.writeBooks("kursen") { db in
            try db.execute("INSERT INTO courses (id, name, color, folder, added, deleted) VALUES (?, ?, ?, '', ?, 0)",
                           [course.id, course.name, course.color, course.added])
        }
        changed()
        return ok ? course : nil
    }

    func rename(_ id: String, to name: String) {
        store.writeBooks("kursens namn") { db in
            try db.execute("UPDATE courses SET name = ? WHERE id = ?", [name, id])
        }
        changed()
    }

    func setColor(_ id: String, color: String) {
        store.writeBooks("kursens färg") { db in
            try db.execute("UPDATE courses SET color = ? WHERE id = ?", [color, id])
        }
        changed()
    }

    /// Tar bort kursen ur listan. Böckerna rörs inte, och en mappkurs skapas inte igen.
    func delete(_ id: String) {
        store.writeBooks("kursen") { db in
            try db.execute("UPDATE courses SET deleted = 1 WHERE id = ?", [id])
        }
        changed()
    }

    func add(book: String, to course: String) {
        store.writeBooks("kursens böcker") { db in
            try db.execute("INSERT OR IGNORE INTO course_books (course, book, added) VALUES (?, ?, ?)",
                           [course, book, Date().timeIntervalSince1970])
        }
        changed()
    }

    func remove(book: String, from course: String) {
        store.writeBooks("kursens böcker") { db in
            try db.execute("DELETE FROM course_books WHERE course = ? AND book = ?", [course, book])
        }
        changed()
    }

    /// Glömmer det som lästs in (efter en återställning).
    func reset() {
        cache = nil
        membershipCache = nil
    }
}
