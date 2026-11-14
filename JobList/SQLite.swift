//
//  SQLite.swift
//  JobList
//

import Foundation
import SQLite3

/// SQLite's sentinel telling it to copy bound text before the call returns.
nonisolated private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

nonisolated struct SQLiteError: LocalizedError {
    let code: Int32
    let message: String

    var isInterrupt: Bool { code == SQLITE_INTERRUPT }
    var errorDescription: String? { message }
}

/// A thin wrapper around a single `sqlite3` connection.
///
/// A connection is not thread-safe; callers must use it from one thread at a time
/// (see `JobDatabase`, which guards each connection with a mutex).
nonisolated final class SQLiteConnection {
    let handle: OpaquePointer

    init(url: URL, readOnly: Bool) throws {
        var handle: OpaquePointer?
        let flags: Int32
        let path: String
        if readOnly {
            // `immutable=1` skips file locking and change detection: imported databases are never modified.
            var components = URLComponents()
            components.scheme = "file"
            components.path = url.path(percentEncoded: false)
            components.queryItems = [URLQueryItem(name: "immutable", value: "1")]
            path = components.string ?? url.absoluteString
            flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        } else {
            path = url.path(percentEncoded: false)
            flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        }
        let result = sqlite3_open_v2(path, &handle, flags, nil)
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database"
            sqlite3_close_v2(handle)
            throw SQLiteError(code: result, message: message)
        }
        self.handle = handle
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    func execute(_ sql: String) throws {
        try check(sqlite3_exec(handle, sql, nil, nil, nil))
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &statement, nil))
        guard let statement else { throw SQLiteError(code: SQLITE_MISUSE, message: "Empty statement: \(sql)") }
        return SQLiteStatement(statement, connection: self)
    }

    func check(_ result: Int32) throws {
        guard result == SQLITE_OK || result == SQLITE_ROW || result == SQLITE_DONE else {
            throw SQLiteError(code: result, message: String(cString: sqlite3_errmsg(handle)))
        }
    }
}

/// A prepared statement. Parameters are 1-based; columns are 0-based.
nonisolated final class SQLiteStatement {
    private let statement: OpaquePointer
    private let connection: SQLiteConnection

    fileprivate init(_ statement: OpaquePointer, connection: SQLiteConnection) {
        self.statement = statement
        self.connection = connection
    }

    deinit {
        sqlite3_finalize(statement)
    }

    // MARK: Binding

    enum Value {
        case int(Int64)
        case double(Double)
        case text(String)
        case null
    }

    func bind(_ values: [Value]) throws {
        for (offset, value) in values.enumerated() {
            try bind(value, at: Int32(offset + 1))
        }
    }

    func bind(_ value: Value, at index: Int32) throws {
        switch value {
        case .int(let value): try connection.check(sqlite3_bind_int64(statement, index, value))
        case .double(let value): try connection.check(sqlite3_bind_double(statement, index, value))
        case .text(let value): try connection.check(sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT))
        case .null: try connection.check(sqlite3_bind_null(statement, index))
        }
    }

    func bind(_ value: String?, at index: Int32) throws {
        try bind(value.map(Value.text) ?? .null, at: index)
    }

    func bind(_ value: Double?, at index: Int32) throws {
        try bind(value.map(Value.double) ?? .null, at: index)
    }

    // MARK: Stepping

    /// Advances to the next row. Returns `false` when the statement is done.
    func step() throws -> Bool {
        let result = sqlite3_step(statement)
        try connection.check(result)
        return result == SQLITE_ROW
    }

    /// Runs a statement that returns no rows, then resets it for reuse.
    func run() throws {
        defer { reset() }
        while try step() {}
    }

    func reset() {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    // MARK: Columns

    func int64(_ column: Int32) -> Int64 {
        sqlite3_column_int64(statement, column)
    }

    func double(_ column: Int32) -> Double? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_double(statement, column)
    }

    func string(_ column: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: text)
    }
}
