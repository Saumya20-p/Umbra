import Foundation
import SQLite3

nonisolated enum DailyCounterStoreError: Error, Equatable, Sendable {
    case sqlite(code: Int32, message: String)
    case readOnly
}

actor DailyCounterStore {
    private let database: OpaquePointer
    private let readOnly: Bool

    init(url: URL, readOnly: Bool = false) throws {
        var handle: OpaquePointer?
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = url.path.withCString { path in
            sqlite3_open_v2(path, &handle, flags, nil)
        }

        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) }
                ?? String(cString: sqlite3_errstr(result))
            if let handle { sqlite3_close_v2(handle) }
            throw DailyCounterStoreError.sqlite(code: result, message: message)
        }

        do {
            if !readOnly {
                try Self.execute("PRAGMA journal_mode = WAL", on: handle)
                try Self.execute("PRAGMA synchronous = FULL", on: handle)
                try Self.execute("CREATE TABLE IF NOT EXISTS daily_counts (day TEXT PRIMARY KEY NOT NULL, count INTEGER NOT NULL CHECK (count >= 0))", on: handle)
            }
        } catch {
            sqlite3_close_v2(handle)
            throw error
        }

        database = handle
        self.readOnly = readOnly
    }

    isolated deinit {
        sqlite3_close_v2(database)
    }

    func recordDenial(at date: Date = .now, calendar: Calendar = .autoupdatingCurrent) throws -> Int64 {
        guard !readOnly else { throw DailyCounterStoreError.readOnly }

        let day = Self.dayKey(for: date, calendar: calendar)
        try Self.execute("BEGIN IMMEDIATE", on: database)
        do {
            let count = try increment(day: day)
            try Self.execute("COMMIT", on: database)
            return count
        } catch {
            try? Self.execute("ROLLBACK", on: database)
            throw error
        }
    }

    func total(at date: Date = .now, calendar: Calendar = .autoupdatingCurrent) throws -> Int64 {
        let statement = try prepare("SELECT count FROM daily_counts WHERE day = ?1")
        defer { sqlite3_finalize(statement) }

        try bind(Self.dayKey(for: date, calendar: calendar), to: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return 0 }
        guard result == SQLITE_ROW else { throw sqliteError(result) }
        return sqlite3_column_int64(statement, 0)
    }

    private func increment(day: String) throws -> Int64 {
        let statement = try prepare("INSERT INTO daily_counts (day, count) VALUES (?1, 1) ON CONFLICT(day) DO UPDATE SET count = count + 1 RETURNING count")
        defer { sqlite3_finalize(statement) }

        try bind(day, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else { throw sqliteError(result) }
        let count = sqlite3_column_int64(statement, 0)
        let completion = sqlite3_step(statement)
        guard completion == SQLITE_DONE else { throw sqliteError(completion) }
        return count
    }

    private func bind(_ value: String, to statement: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let result = value.withCString { text in
            sqlite3_bind_text(statement, 1, text, -1, transient)
        }
        guard result == SQLITE_OK else { throw sqliteError(result) }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw sqliteError(result) }
        return statement
    }

    private nonisolated static func execute(_ sql: String, on database: OpaquePointer) throws {
        let result = sql.withCString { text in
            sqlite3_exec(database, text, nil, nil, nil)
        }
        guard result == SQLITE_OK else {
            throw DailyCounterStoreError.sqlite(
                code: result,
                message: String(cString: sqlite3_errmsg(database))
            )
        }
    }

    private func sqliteError(_ code: Int32) -> DailyCounterStoreError {
        .sqlite(code: code, message: String(cString: sqlite3_errmsg(database)))
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            locale: Locale(identifier: "en_US_POSIX"),
            components.year!, components.month!, components.day!
        )
    }
}
