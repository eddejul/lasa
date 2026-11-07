import Foundation
import SQLite3

/// En liten omslutning av SQLite, för ordboken och för de sparade orden.
/// Används bara från huvudtråden. Frågorna är små och tar några millisekunder.
final class SQLiteDatabase {

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// En rad i ett svar.
    struct Row {
        fileprivate let statement: OpaquePointer

        func string(_ column: Int32) -> String {
            guard let text = sqlite3_column_text(statement, column) else { return "" }
            return String(cString: text)
        }

        func double(_ column: Int32) -> Double {
            sqlite3_column_double(statement, column)
        }

        func int(_ column: Int32) -> Int {
            Int(sqlite3_column_int64(statement, column))
        }

        func isNull(_ column: Int32) -> Bool {
            sqlite3_column_type(statement, column) == SQLITE_NULL
        }
    }

    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    /// Hur många transaktioner som är öppna just nu.
    private var depth = 0

    /// Öppnar en fil. En skrivskyddad fil (ordboken i appen) öppnas som oföränderlig, vilket är snabbast.
    init(path: String, readOnly: Bool) throws {
        let name: String
        let flags: Int32
        if readOnly {
            name = URL(fileURLWithPath: path).absoluteString + "?immutable=1"
            flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        } else {
            name = path
            flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        }
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(name, &opened, flags, nil)
        guard result == SQLITE_OK, let opened = opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "kod \(result)"
            sqlite3_close(opened)
            throw Failure(description: "Kunde inte öppna databasen: \(message)")
        }
        handle = opened
    }

    deinit {
        for statement in statements.values {
            sqlite3_finalize(statement)
        }
        sqlite3_close(handle)
    }

    /// Kör en fråga och anropar `row` för varje rad.
    func query(_ sql: String, _ arguments: [Any?] = [], row: (Row) throws -> Void) throws {
        let statement = try prepared(sql)
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        try bind(arguments, to: statement)
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                try row(Row(statement: statement))
            } else if result == SQLITE_DONE {
                return
            } else {
                throw Failure(description: errorMessage)
            }
        }
    }

    /// Kör en fråga som inte ger några rader (INSERT, UPDATE, DELETE, CREATE).
    func execute(_ sql: String, _ arguments: [Any?] = []) throws {
        try query(sql, arguments) { _ in }
    }

    /// Flera satser utan argument, till exempel att skapa tabeller.
    func executeScript(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw Failure(description: errorMessage)
        }
    }

    /// Databasens version (`PRAGMA user_version`). 0 för en ny databas, eller en som skapades före G8.
    func userVersion() throws -> Int {
        var version = 0
        try query("PRAGMA user_version") { row in version = row.int(0) }
        return version
    }

    /// Tar databasen till den senaste versionen. Steg n (räknat från 1) tar den från version n - 1 till n.
    /// Varje steg körs i en egen transaktion tillsammans med det nya versionsnumret, så ett steg som
    /// misslyckas lämnar databasen som den var. Steg som redan körts hoppas över.
    /// Lägg alltid till nya steg sist, och ändra aldrig ett steg som redan finns i en utgiven version.
    @discardableResult
    func migrate(_ steps: [String]) throws -> (from: Int, to: Int) {
        let start = try userVersion()
        var version = start
        while version < steps.count {
            let sql = steps[version]
            let next = version + 1
            try transaction {
                try executeScript(sql)
                try executeScript("PRAGMA user_version = \(next)")
            }
            version = next
        }
        return (start, version)
    }

    /// Kör `body` i en transaktion: allt sparas, eller inget om något kastar ett fel.
    /// En transaktion inuti en annan blir en del av den yttre.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        if depth > 0 {
            return try body()
        }
        try executeScript("BEGIN IMMEDIATE")
        depth += 1
        defer { depth -= 1 }
        do {
            let result = try body()
            try executeScript("COMMIT")
            return result
        } catch {
            try? executeScript("ROLLBACK")
            throw error
        }
    }

    // MARK: Internt

    private var errorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "okänt fel"
    }

    private func prepared(_ sql: String) throws -> OpaquePointer {
        if let statement = statements[sql] {
            return statement
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement = statement else {
            throw Failure(description: "\(errorMessage) i: \(sql)")
        }
        statements[sql] = statement
        return statement
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(_ arguments: [Any?], to statement: OpaquePointer) throws {
        for (offset, argument) in arguments.enumerated() {
            let index = Int32(offset + 1)
            guard let argument = argument else {
                sqlite3_bind_null(statement, index)
                continue
            }
            let result: Int32
            switch argument {
            case let value as String:
                result = sqlite3_bind_text(statement, index, value, -1, Self.transient)
            case let value as Int:
                result = sqlite3_bind_int64(statement, index, Int64(value))
            case let value as Double:
                result = sqlite3_bind_double(statement, index, value)
            case let value as Bool:
                result = sqlite3_bind_int64(statement, index, value ? 1 : 0)
            default:
                throw Failure(description: "Okänd typ av argument: \(String(describing: argument))")
            }
            guard result == SQLITE_OK else {
                throw Failure(description: errorMessage)
            }
        }
    }
}
