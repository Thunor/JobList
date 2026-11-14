//
//  JobDatabase.swift
//  JobList
//

import Foundation
import SQLite3
import Synchronization

/// An imported job file, stored in a purpose-built, indexed SQLite database.
///
/// Databases are written once by `importFile(from:to:progress:)` and then opened
/// read-only. Filtering, sorting, and full-text search all run as SQL off the main
/// actor, so the UI only ever holds row IDs plus the handful of records on screen.
nonisolated final class JobDatabase: Sendable {
    /// Where imported jobs are kept between launches.
    static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "JobList/Jobs.sqlite")
    }

    /// Bumped whenever the schema changes, so databases from older versions are rebuilt.
    private static let schemaVersion = "2"

    let url: URL
    /// The name of the JSON or Excel file the database was imported from.
    let sourceName: String
    let totalCount: Int
    let options: FilterOptions

    /// Runs filter queries. Separate from `rowConnection` so a long query can be
    /// interrupted without disturbing the page loads that feed the table.
    private let queryConnection: Mutex<SQLiteConnection>
    private let queryInterrupter: Interrupter
    /// Loads full records by ID for the visible window, the inspector, and exports.
    private let rowConnection: Mutex<SQLiteConnection>

    private init(url: URL) throws {
        let query = try SQLiteConnection(url: url, readOnly: true)
        let rows = try SQLiteConnection(url: url, readOnly: true)

        let meta = try rows.prepare("SELECT key, value FROM meta")
        var values: [String: String] = [:]
        while try meta.step() {
            if let key = meta.string(0), let value = meta.string(1) { values[key] = value }
        }
        guard values["schemaVersion"] == Self.schemaVersion, let count = values["count"].flatMap(Int.init) else {
            throw SQLiteError(code: SQLITE_CORRUPT, message: "The job database was created by a different version of JobList.")
        }

        self.url = url
        sourceName = values["source"] ?? url.lastPathComponent
        totalCount = count
        options = values["options"].flatMap { try? JSONDecoder().decode(FilterOptions.self, from: Data($0.utf8)) }
            ?? FilterOptions()
        queryInterrupter = Interrupter(handle: query.handle)
        queryConnection = Mutex(query)
        rowConnection = Mutex(rows)
    }

    /// Opens a previously imported database.
    @concurrent
    static func open(_ url: URL) async throws -> JobDatabase {
        try JobDatabase(url: url)
    }

    // MARK: Querying

    /// The IDs of all jobs matching `filter`, in display order.
    ///
    /// Cancelling the calling task interrupts the running query.
    @concurrent
    func matchingIDs(_ filter: JobFilter, sortedBy sortOrder: [JobSort], now: Date = .now) async throws -> [Int64] {
        let (whereClause, values) = filter.sqlCondition(now: now)
        let orderBy = (sortOrder.isEmpty ? [JobSort(column: .posted, order: .reverse)] : sortOrder)
            .map { "\($0.column.sqlExpression) \($0.order == .forward ? "ASC" : "DESC")" }
            .joined(separator: ", ")
        let sql = "SELECT j.id FROM jobs j WHERE \(whereClause) ORDER BY \(orderBy), j.id"

        return try await withTaskCancellationHandler {
            try queryConnection.withLock { connection in
                try Task.checkCancellation()
                let statement = try connection.prepare(sql)
                try statement.bind(values)
                var ids: [Int64] = []
                while try statement.step() {
                    ids.append(statement.int64(0))
                }
                return ids
            }
        } onCancel: {
            queryInterrupter.interrupt()
        }
    }

    /// Loads full records for `ids`, returned in the same order. Missing IDs are skipped.
    func jobs(withIDs ids: [Int64]) throws -> [JobPosting] {
        guard !ids.isEmpty else { return [] }
        let found = try rowConnection.withLock { connection in
            let statement = try connection.prepare(Self.selectJobsSQL)
            try statement.bind(.text("[\(ids.map(String.init).joined(separator: ","))]"), at: 1)
            var found: [Int64: JobPosting] = [:]
            found.reserveCapacity(ids.count)
            while try statement.step() {
                let job = Self.job(from: statement)
                found[job.id] = job
            }
            return found
        }
        return ids.compactMap { found[$0] }
    }

    /// Loads full records for `ids` off the main actor.
    @concurrent
    func fetchJobs(withIDs ids: [Int64]) async throws -> [JobPosting] {
        try jobs(withIDs: ids)
    }

    /// Stops a connection's running statement. Unlike the rest of the connection's API,
    /// `sqlite3_interrupt` is safe to call from any thread.
    private struct Interrupter: @unchecked Sendable {
        let handle: OpaquePointer

        func interrupt() {
            sqlite3_interrupt(handle)
        }
    }

    private static let selectJobsSQL = """
        SELECT id, title, company, apply_url, source, posted_at, tags, countries, countries_text,
               raw_location, comp_type, min_amount, max_amount, currency, raw_salary_text,
               work_mode, categories, salary_text
        FROM jobs WHERE id IN (SELECT value FROM json_each(?1))
        """

    private static func job(from row: SQLiteStatement) -> JobPosting {
        JobPosting(
            id: row.int64(0),
            title: row.string(1) ?? "",
            company: row.string(2) ?? "",
            applyUrl: row.string(3).flatMap(URL.init(string:)),
            source: row.string(4) ?? "",
            postedAt: row.double(5).map(Date.init(timeIntervalSince1970:)),
            tags: splitList(row.string(6)),
            countries: splitList(row.string(7)),
            countriesText: row.string(8) ?? "",
            rawLocation: row.string(9) ?? "",
            compType: row.string(10) ?? "",
            minAmount: row.double(11),
            maxAmount: row.double(12),
            currency: row.string(13),
            rawSalaryText: row.string(14),
            workMode: row.string(15) ?? "",
            categories: splitList(row.string(16)),
            salaryText: row.string(17) ?? ""
        )
    }

    // MARK: List columns

    /// Lists are stored in a single column, separated by the ASCII unit separator.
    private static let listSeparator: Character = "\u{1F}"

    private static func joinList(_ values: [String]) -> String {
        values.joined(separator: String(listSeparator))
    }

    private static func splitList(_ text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        return text.split(separator: listSeparator, omittingEmptySubsequences: false).map(String.init)
    }
}

// MARK: - Importing

extension JobDatabase {
    /// Records decoded and inserted per batch.
    private static let batchSize = 2_000

    /// Imports a JSON file or Excel workbook of job postings into a new database at `url`,
    /// replacing any existing one.
    ///
    /// JSON files are memory-mapped and split into batches of records that are decoded in
    /// parallel. Workbooks are parsed a row at a time and inserted in batches. Either way,
    /// all records are inserted in a single transaction, and indexes are built after the
    /// data is loaded, which is much faster than maintaining them row by row.
    ///
    /// The database is built in a separate file and moved into place once complete, so a
    /// failed import leaves the previous database intact. Connections still open on the
    /// previous file keep reading it until they're released.
    @concurrent
    static func importFile(
        from source: URL,
        to url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> JobDatabase {
        // Files chosen through the open panel or dropped on the window are security scoped.
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appending(path: "\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: staging) }

        let isWorkbook = source.pathExtension.lowercased() == "xlsx"
        try await build(at: staging, sourceName: source.lastPathComponent, progress: progress) { inserter in
            if isWorkbook {
                try XLSXReader.readJobs(from: data, batchSize: batchSize, progress: progress, insert: inserter.insert)
            } else if let batches = JSONArrayScanner.objectBatches(in: data, batchSize: batchSize) {
                try await insertBatches(batches, of: data, using: inserter, progress: progress)
            } else {
                // Not an array: a file holding a single record.
                try inserter.insert(JobPosting.decodeList(from: data))
            }
        }
        // Don't replace the existing database if the import was cancelled while finishing up.
        try Task.checkCancellation()
        guard rename(staging.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return try JobDatabase(url: url)
    }

    /// Creates the database at `url`, filling it with the records `insertRecords` passes to the inserter.
    private static func build(
        at url: URL,
        sourceName: String,
        progress: @escaping @Sendable (Double) -> Void,
        insertRecords: (Inserter) async throws -> Void
    ) async throws {
        let connection = try SQLiteConnection(url: url, readOnly: false)
        // The file isn't used until it's complete, so durability isn't needed while building it.
        try connection.execute("""
            PRAGMA journal_mode = OFF;
            PRAGMA synchronous = OFF;
            PRAGMA locking_mode = EXCLUSIVE;
            PRAGMA temp_store = MEMORY;
            PRAGMA cache_size = -262144;
            """)
        try connection.execute(schema)
        try connection.execute("BEGIN")

        let inserter = try Inserter(connection: connection)
        try await insertRecords(inserter)

        progress(1)
        try Task.checkCancellation()
        try connection.execute(indexes)
        let options = try FilterOptions(connection: connection)
        let meta = try connection.prepare("INSERT INTO meta (key, value) VALUES (?, ?)")
        for (key, value) in [
            ("schemaVersion", schemaVersion),
            ("source", sourceName),
            ("count", String(inserter.count)),
            ("options", String(decoding: try JSONEncoder().encode(options), as: UTF8.self)),
        ] {
            try meta.bind([.text(key), .text(value)])
            try meta.run()
        }
        try connection.execute("COMMIT")
        // Merge the full-text index into one segment and gather statistics for the query planner.
        try connection.execute("INSERT INTO job_search (job_search) VALUES ('optimize'); ANALYZE;")
    }

    /// Decodes batches concurrently, keeping a bounded number in flight, and inserts
    /// each as it finishes.
    private static func insertBatches(
        _ batches: [Range<Int>],
        of data: Data,
        using inserter: Inserter,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let width = max(2, ProcessInfo.processInfo.activeProcessorCount)
        try await withThrowingTaskGroup(of: [JobPosting].self) { group in
            var next = 0
            func addNext() {
                guard next < batches.count else { return }
                let range = batches[next]
                next += 1
                group.addTask {
                    try Task.checkCancellation()
                    // The range spans comma-separated objects; wrap it to form an array.
                    var json = Data("[".utf8)
                    json.append(data[range])
                    json.append(contentsOf: "]".utf8)
                    return try JSONDecoder().decode([JobPosting].self, from: json)
                }
            }

            for _ in 0..<width { addNext() }
            var finished = 0
            while let jobs = try await group.next() {
                try inserter.insert(jobs)
                finished += 1
                progress(Double(finished) / Double(batches.count))
                addNext()
            }
        }
    }

    private static let schema = """
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE jobs (
            id INTEGER PRIMARY KEY,
            title TEXT NOT NULL,
            company TEXT NOT NULL,
            apply_url TEXT,
            source TEXT NOT NULL,
            posted_at REAL,
            posted_sort REAL NOT NULL,
            tags TEXT NOT NULL,
            tags_text TEXT NOT NULL,
            countries TEXT NOT NULL,
            countries_text TEXT NOT NULL,
            raw_location TEXT NOT NULL,
            comp_type TEXT NOT NULL,
            min_amount REAL,
            max_amount REAL,
            salary_sort REAL NOT NULL,
            has_salary INTEGER NOT NULL,
            currency TEXT,
            raw_salary_text TEXT,
            salary_text TEXT NOT NULL,
            work_mode TEXT NOT NULL,
            categories TEXT NOT NULL
        );
        -- Multi-valued fields, keyed by value so a filter finds its jobs with one index range scan.
        CREATE TABLE job_tags (value TEXT NOT NULL, job_id INTEGER NOT NULL, PRIMARY KEY (value, job_id)) WITHOUT ROWID;
        CREATE TABLE job_countries (value TEXT NOT NULL, job_id INTEGER NOT NULL, PRIMARY KEY (value, job_id)) WITHOUT ROWID;
        CREATE TABLE job_categories (value TEXT NOT NULL, job_id INTEGER NOT NULL, PRIMARY KEY (value, job_id)) WITHOUT ROWID;
        -- Trigram index over the folded search text, for fast substring search. Rowid = jobs.id.
        CREATE VIRTUAL TABLE job_search USING fts5 (text, tokenize = 'trigram');
        """

    /// Indexes for each filter (paired with the default sort) and each sortable column.
    /// Every index implicitly ends with the row ID, which breaks ties in the sort order.
    private static let indexes = """
        CREATE INDEX jobs_posted ON jobs (posted_sort);
        CREATE INDEX jobs_salary ON jobs (salary_sort);
        CREATE INDEX jobs_has_salary ON jobs (has_salary, posted_sort);
        CREATE INDEX jobs_title ON jobs (title COLLATE NOCASE);
        CREATE INDEX jobs_company_sort ON jobs (company COLLATE NOCASE);
        CREATE INDEX jobs_company ON jobs (company, posted_sort);
        CREATE INDEX jobs_source ON jobs (source, posted_sort);
        CREATE INDEX jobs_work_mode ON jobs (work_mode, posted_sort);
        CREATE INDEX jobs_comp_type ON jobs (comp_type, posted_sort);
        CREATE INDEX jobs_currency ON jobs (currency, posted_sort);
        CREATE INDEX jobs_location ON jobs (raw_location COLLATE NOCASE);
        """

    /// Prepared insert statements, reused for every record.
    nonisolated private final class Inserter {
        private let connection: SQLiteConnection
        private let job: SQLiteStatement
        private let search: SQLiteStatement
        private let tag: SQLiteStatement
        private let country: SQLiteStatement
        private let category: SQLiteStatement
        private(set) var count = 0

        init(connection: SQLiteConnection) throws {
            self.connection = connection
            job = try connection.prepare("""
                INSERT INTO jobs (title, company, apply_url, source, posted_at, posted_sort, tags, tags_text,
                                  countries, countries_text, raw_location, comp_type, min_amount, max_amount,
                                  salary_sort, has_salary, currency, raw_salary_text, salary_text, work_mode,
                                  categories)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            search = try connection.prepare("INSERT INTO job_search (rowid, text) VALUES (?, ?)")
            tag = try connection.prepare("INSERT OR IGNORE INTO job_tags (value, job_id) VALUES (?, ?)")
            country = try connection.prepare("INSERT OR IGNORE INTO job_countries (value, job_id) VALUES (?, ?)")
            category = try connection.prepare("INSERT OR IGNORE INTO job_categories (value, job_id) VALUES (?, ?)")
        }

        func insert(_ jobs: [JobPosting]) throws {
            for posting in jobs {
                let hasSalary = posting.maxAmount != nil || posting.minAmount != nil
                    || !(posting.rawSalaryText ?? "").isEmpty
                try job.bind([
                    .text(posting.title),
                    .text(posting.company),
                    posting.applyUrl.map { .text($0.absoluteString) } ?? .null,
                    .text(posting.source),
                    posting.postedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                    .double(posting.postedAtSortKey.timeIntervalSince1970),
                    .text(joinList(posting.tags)),
                    .text(posting.tagsText),
                    .text(joinList(posting.countries)),
                    .text(posting.countriesText),
                    .text(posting.rawLocation),
                    .text(posting.compType),
                    posting.minAmount.map(SQLiteStatement.Value.double) ?? .null,
                    posting.maxAmount.map(SQLiteStatement.Value.double) ?? .null,
                    .double(posting.salarySortKey),
                    .int(hasSalary ? 1 : 0),
                    posting.currency.map(SQLiteStatement.Value.text) ?? .null,
                    posting.rawSalaryText.map(SQLiteStatement.Value.text) ?? .null,
                    .text(posting.salaryText),
                    .text(posting.workMode),
                    .text(joinList(posting.categories)),
                ])
                try job.run()
                let id = sqlite3_last_insert_rowid(connection.handle)

                try search.bind([.int(id), .text(posting.searchIndex)])
                try search.run()
                for (statement, values) in [(tag, posting.tags), (country, posting.countries), (category, posting.categories)] {
                    for value in values where !value.isEmpty {
                        try statement.bind([.text(value), .int(id)])
                        try statement.run()
                    }
                }
                count += 1
            }
        }
    }
}

// MARK: - Filter options

extension FilterOptions {
    /// Reads the distinct values of each filterable field from a freshly built database.
    nonisolated fileprivate init(connection: SQLiteConnection) throws {
        func distinct(_ sql: String) throws -> [String] {
            let statement = try connection.prepare(sql)
            var values: [String] = []
            while try statement.step() {
                if let value = statement.string(0), !value.isEmpty { values.append(value) }
            }
            return values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        self.init()
        sources = try distinct("SELECT DISTINCT source FROM jobs")
        companies = try distinct("SELECT DISTINCT company FROM jobs")
        workModes = try distinct("SELECT DISTINCT work_mode FROM jobs")
        compTypes = try distinct("SELECT DISTINCT comp_type FROM jobs")
        currencies = try distinct("SELECT DISTINCT currency FROM jobs WHERE currency IS NOT NULL")
        tags = try distinct("SELECT DISTINCT value FROM job_tags")
        countries = try distinct("SELECT DISTINCT value FROM job_countries")
        categories = try distinct("SELECT DISTINCT value FROM job_categories")
    }
}

// MARK: - SQL generation

extension JobSort.Column {
    /// The expression the column sorts by. Text sorts ignore ASCII case, matching the indexes.
    nonisolated fileprivate var sqlExpression: String {
        switch self {
        case .title: "j.title COLLATE NOCASE"
        case .company: "j.company COLLATE NOCASE"
        case .source: "j.source COLLATE NOCASE"
        case .posted: "j.posted_sort"
        case .workMode: "j.work_mode COLLATE NOCASE"
        case .location: "j.raw_location COLLATE NOCASE"
        case .countries: "j.countries_text COLLATE NOCASE"
        case .tags: "j.tags_text COLLATE NOCASE"
        case .compType: "j.comp_type COLLATE NOCASE"
        case .salary: "j.salary_sort"
        }
    }
}

extension JobFilter {
    /// A `WHERE` condition over `jobs j` and its parameter values.
    nonisolated fileprivate func sqlCondition(now: Date) -> (String, [SQLiteStatement.Value]) {
        var clauses = ["1"]
        var values: [SQLiteStatement.Value] = []

        func equals(_ column: String, _ value: String?) {
            guard let value else { return }
            clauses.append("j.\(column) = ?")
            values.append(.text(value))
        }
        func contains(_ table: String, _ value: String?) {
            guard let value else { return }
            clauses.append("j.id IN (SELECT job_id FROM \(table) WHERE value = ?)")
            values.append(.text(value))
        }

        equals("source", source)
        equals("company", company)
        equals("work_mode", workMode)
        equals("comp_type", compType)
        equals("currency", currency)
        contains("job_tags", tag)
        contains("job_countries", country)
        contains("job_categories", category)

        if let interval = postedWithin.interval {
            clauses.append("j.posted_at >= ?")
            values.append(.double(now.timeIntervalSince1970 - interval))
        }
        if salaryListedOnly {
            clauses.append("j.has_salary = 1")
        }
        if let minimumSalary {
            clauses.append("(j.max_amount IS NOT NULL OR j.min_amount IS NOT NULL) AND j.salary_sort >= ?")
            values.append(.double(minimumSalary))
        }

        let query = foldedQuery
        if query.unicodeScalars.count >= 3 {
            // The trigram tokenizer treats a quoted phrase as a substring match.
            clauses.append("j.id IN (SELECT rowid FROM job_search WHERE job_search MATCH ?)")
            values.append(.text("\"\(query.replacing("\"", with: "\"\""))\""))
        } else if !query.isEmpty {
            // Trigrams can't match fewer than three characters, so scan the stored text instead.
            clauses.append("j.id IN (SELECT rowid FROM job_search WHERE instr(text, ?) > 0)")
            values.append(.text(query))
        }

        return (clauses.joined(separator: " AND "), values)
    }
}

// MARK: - JSON scanning

/// Finds record boundaries in a JSON array without decoding it, so a very large
/// file can be decoded in independent batches.
nonisolated enum JSONArrayScanner {
    /// Byte ranges of the data, each spanning up to `batchSize` consecutive objects of
    /// the top-level array. Returns `nil` if the data isn't a complete JSON array.
    static func objectBatches(in data: Data, batchSize: Int) -> [Range<Int>]? {
        let openBrace = UInt8(ascii: "{"), closeBrace = UInt8(ascii: "}")
        let openBracket = UInt8(ascii: "["), closeBracket = UInt8(ascii: "]")
        let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\")
        let base = data.startIndex

        return data.withUnsafeBytes { bytes -> [Range<Int>]? in
            var i = 0
            while i < bytes.count, bytes[i] != openBracket {
                // Only whitespace (or a UTF-8 byte order mark) may precede the array.
                guard [0x20, 0x09, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF].contains(bytes[i]) else { return nil }
                i += 1
            }
            i += 1

            var batches: [Range<Int>] = []
            var depth = 0
            var inString = false
            var escaped = false
            var batchStart: Int?
            var lastEnd = 0
            var count = 0

            while i < bytes.count {
                let byte = bytes[i]
                if inString {
                    if escaped {
                        escaped = false
                    } else if byte == backslash {
                        escaped = true
                    } else if byte == quote {
                        inString = false
                    }
                } else if byte == quote {
                    inString = true
                } else if byte == openBrace || byte == openBracket {
                    if depth == 0, batchStart == nil { batchStart = i }
                    depth += 1
                } else if byte == closeBrace || byte == closeBracket {
                    if depth == 0 {
                        // The end of the top-level array.
                        if let start = batchStart { batches.append(base + start..<base + lastEnd) }
                        return batches
                    }
                    depth -= 1
                    if depth == 0 {
                        lastEnd = i + 1
                        count += 1
                        if count == batchSize, let start = batchStart {
                            batches.append(base + start..<base + lastEnd)
                            batchStart = nil
                            count = 0
                        }
                    }
                }
                i += 1
            }
            return nil
        }
    }
}
