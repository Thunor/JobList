//
//  JobListTests.swift
//  JobListTests
//
//  Created by Eric Freitas on 11/6/26.
//

import Foundation
import Testing
@testable import JobList

struct JobListTests {

    static let sample = Data("""
    [{
        "title": "Senior Software Engineer, Mobile (Android)",
        "company": "Joinforage",
        "applyUrl": "https://jobs.gem.com/-joinforage/am9icG9zdDoQzZQuSvDKMNwsFFJ3e4g3",
        "source": "Gem",
        "postedAt": "2026-03-02T23:31:07.048+00:00",
        "tags": ["Engineering", "Hybrid"],
        "countries": ["United States"],
        "rawLocation": "New York, United States; New York",
        "compType": "unknown",
        "minAmount": null,
        "maxAmount": null,
        "currency": null,
        "rawSalaryText": null,
        "workMode": "hybrid",
        "categories": []
    }]
    """.utf8)

    @Test func decodesSampleRecord() throws {
        let jobs = try JobPosting.decodeList(from: Self.sample)
        let job = try #require(jobs.first)
        #expect(job.company == "Joinforage")
        #expect(job.tags == ["Engineering", "Hybrid"])
        #expect(job.workMode == "hybrid")
        #expect(job.minAmount == nil)
        #expect(job.applyUrl != nil)
        let posted = try #require(job.postedAt)
        #expect(abs(posted.timeIntervalSince1970 - 1772494267.048) < 0.001)
    }

    @Test(arguments: [
        ("United States", ["United States"]),
        ("U.S.A.", ["United States"]),
        ("Remote (US)", ["United States"]),
        ("USA (Tuscan Village - J.Crew Factory)", ["United States"]),
        ("CO - USA", ["United States"]),
        ("Copenhagen (Denmark)", ["Denmark"]),
        ("Canada_Burnaby_Office", ["Canada"]),
        ("China", ["China"]),
        ("Trinidad and Tobago", ["Trinidad & Tobago"]),
        // State + postal code that belong together.
        ("Texas 75034", ["United States"]),
        ("VA 22603", ["United States"]),
        ("DE 19709-9529", ["United States"]),
        ("Toronto, ON M5V 2T6", ["Canada"]),
        ("Sydney NSW 2000", ["Australia"]),
        ("Perth WA 6000", ["Australia"]),
        ("Bengaluru, Karnataka 560001", ["India"]),
        ("London SW1A 1AA", ["United Kingdom"]),
        // Spelled-out states identify their country.
        ("California", ["United States"]),
        ("Santa Fe, New Mexico", ["United States"]),
        ("Massachusetts (Boston)", ["United States"]),
        // Not enough to determine a country.
        ("TX 12345", []),
        ("Lebanon, PA", []),
        ("Thornhill, ON", []),
        ("Worldwide", []),
    ])
    func normalizesCountry(input: String, expected: [String]) {
        #expect(CountryNormalizer.countries(in: input, isCountryField: true) == expected)
    }

    @Test func countriesFallBackToRawLocation() {
        let job = JobPosting(title: "Nurse", company: "Acme", countries: ["Main Campus"],
                             rawLocation: "Little Rock, AR 72205")
        #expect(job.countries == ["United States"])

        let multi = JobPosting(title: "Engineer", company: "Acme", countries: ["California", "United States", "ON"])
        #expect(multi.countries == ["United States"])
    }

    @Test func exportsValidWorkbook() async throws {
        let jobs = [
            JobPosting(title: "R&D <Lead>", company: "Acme", postedAt: .now, minAmount: 100_000),
            JobPosting(title: "Engineer", company: "Café Corp", countries: ["Canada"]),
        ]
        let url = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try await XLSXWriter.write(jobs, to: url)

        let data = try Data(contentsOf: url)
        #expect(data.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]))
        // The end-of-central-directory record lists the six package parts.
        let eocd = data.suffix(22)
        #expect(eocd.prefix(4) == Data([0x50, 0x4B, 0x05, 0x06]))
        #expect(eocd[eocd.startIndex + 10] == 6)
    }

    @Test func importsExportedWorkbook() async throws {
        let posted = Date(timeIntervalSince1970: 1_772_000_000)
        let jobs = [
            JobPosting(
                title: "R&D <Lead>", company: "Acme", applyUrl: URL(string: "https://example.com/apply"),
                source: "Gem", postedAt: posted, tags: ["Engineering", "Remote"], countries: ["Canada"],
                compType: "salary", minAmount: 100_000, maxAmount: 150_000, currency: "USD", workMode: "remote"
            ),
            JobPosting(title: "Engineer", company: "Café Corp"),
        ]
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "jobs.xlsx")
        try await XLSXWriter.write(jobs, to: file)

        let database = try await JobDatabase.importFile(from: file, to: directory.appending(path: "Jobs.sqlite")) { _ in }
        #expect(database.totalCount == 2)
        #expect(database.sourceName == "jobs.xlsx")

        let ids = try await database.matchingIDs(JobFilter(), sortedBy: [JobSort(column: .title)])
        let imported = try database.jobs(withIDs: ids)
        #expect(imported.map(\.title) == ["Engineer", "R&D <Lead>"])
        let lead = try #require(imported.last)
        #expect(lead.company == "Acme")
        #expect(lead.applyUrl == URL(string: "https://example.com/apply"))
        #expect(lead.source == "Gem")
        #expect(abs((lead.postedAt ?? .distantPast).timeIntervalSince(posted)) < 1)
        #expect(lead.tags == ["Engineering", "Remote"])
        #expect(lead.countries == ["Canada"])
        #expect(lead.compType == "salary")
        #expect(lead.minAmount == 100_000)
        #expect(lead.maxAmount == 150_000)
        #expect(lead.currency == "USD")
        #expect(lead.workMode == "remote")
        #expect(imported.first?.postedAt == nil)
    }

    @Test func rejectsInvalidWorkbook() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "notes.xlsx")
        try Data("not a zip".utf8).write(to: file)

        await #expect(throws: XLSXReader.ReadError.self) {
            try await JobDatabase.importFile(from: file, to: directory.appending(path: "Jobs.sqlite")) { _ in }
        }
    }

    @Test func scannerSplitsArrayIntoBatches() throws {
        let json = Data(#"  [ {"title": "a}{[\"", "tags": ["x"]}, {"title": "b"} ,{"title": "c"} ]"#.utf8)
        let batches = try #require(JSONArrayScanner.objectBatches(in: json, batchSize: 2))
        #expect(batches.count == 2)
        let decoded = try batches.flatMap { range in
            try JSONDecoder().decode([JobPosting].self, from: Data("[".utf8) + json[range] + Data("]".utf8))
        }
        #expect(decoded.map(\.title) == ["a}{[\"", "b", "c"])
        #expect(JSONArrayScanner.objectBatches(in: Data(#"{"title": "a"}"#.utf8), batchSize: 2) == nil)
        #expect(JSONArrayScanner.objectBatches(in: Data(#"[{"title": "a"}"#.utf8), batchSize: 2) == nil)
    }

    /// Writes `records` to a JSON file and imports it into a database in a temporary directory.
    private static func importDatabase(_ records: [[String: Any]]) async throws -> (JobDatabase, URL) {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "jobs.json")
        try JSONSerialization.data(withJSONObject: records).write(to: file)
        let database = try await JobDatabase.importFile(from: file, to: directory.appending(path: "Jobs.sqlite")) { _ in }
        return (database, directory)
    }

    @Test func databaseFiltersSearchesAndSorts() async throws {
        // Whole seconds, since the ISO 8601 strings below drop fractional seconds.
        let now = Date(timeIntervalSince1970: Date.now.timeIntervalSince1970.rounded(.down))
        let records: [[String: Any]] = (0..<5_000).map { i in
            [
                "title": "Engineer \(i)",
                "company": i.isMultiple(of: 2) ? "Café Corp" : "Acme",
                "source": "Gem",
                "postedAt": now.addingTimeInterval(-Double(i) * 3_600).formatted(.iso8601),
                "tags": i.isMultiple(of: 5) ? ["Engineering", "Remote"] : ["Sales"],
                "countries": i.isMultiple(of: 3) ? ["Canada"] : ["United States"],
                "rawLocation": "",
                "workMode": "remote",
                "maxAmount": i.isMultiple(of: 10) ? Double(i * 100) : NSNull(),
            ]
        }
        let (database, directory) = try await Self.importDatabase(records)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(database.totalCount == 5_000)
        #expect(database.sourceName == "jobs.json")
        #expect(database.options.companies == ["Acme", "Café Corp"])
        #expect(database.options.tags == ["Engineering", "Remote", "Sales"])

        let newestFirst = [JobSort(column: .posted, order: .reverse)]
        let clock = ContinuousClock()
        var ids: [Int64] = []
        let elapsed = try await clock.measure {
            ids = try await database.matchingIDs(JobFilter(searchText: "cafe"), sortedBy: newestFirst, now: now)
        }
        print("Searched 5k records in \(elapsed)")
        #expect(ids.count == 2_500)
        let first = try database.jobs(withIDs: Array(ids.prefix(2)))
        #expect(first.map(\.title) == ["Engineer 0", "Engineer 2"])

        // Short queries fall back to a scan; longer ones use the trigram index.
        #expect(try await database.matchingIDs(JobFilter(searchText: "co"), sortedBy: newestFirst).count == 2_500)
        #expect(try await database.matchingIDs(JobFilter(searchText: "ENGINEER 49"), sortedBy: newestFirst).count == 111)

        var filter = JobFilter()
        filter.tag = "Engineering"
        filter.country = "Canada"
        #expect(try await database.matchingIDs(filter, sortedBy: newestFirst, now: now).count == 334)

        filter = JobFilter(postedWithin: .day)
        #expect(try await database.matchingIDs(filter, sortedBy: newestFirst, now: now).count == 25)

        filter = JobFilter(minimumSalary: 400_000)
        let bySalary = try await database.matchingIDs(filter, sortedBy: [JobSort(column: .salary, order: .reverse)])
        #expect(bySalary.count == 100)
        #expect(try database.jobs(withIDs: [bySalary[0]]).first?.maxAmount == 499_000)

        filter = JobFilter(salaryListedOnly: true)
        #expect(try await database.matchingIDs(filter, sortedBy: newestFirst).count == 500)
    }

    @MainActor
    @Test func windowLoadsAndEvictsPages() async throws {
        let records: [[String: Any]] = (0..<2_000).map { ["title": "Job \($0)", "company": "Acme"] }
        let (database, directory) = try await Self.importDatabase(records)
        defer { try? FileManager.default.removeItem(at: directory) }

        let ids = try await database.matchingIDs(JobFilter(), sortedBy: [JobSort(column: .title)])
        let window = JobWindow()
        window.reset(ids: ids, database: database)
        #expect(window.rows.count == 2_000)

        func waitForPage(containing index: Int) async throws -> JobPosting {
            for _ in 0..<200 {
                if let job = window.job(for: window.rows[index]) { return job }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw CancellationError()
        }

        #expect(try await waitForPage(containing: 0).id == ids[0])
        // Scrolling far down slides the window: distant pages are discarded.
        window.rowAppeared(at: 1_500)
        #expect(try await waitForPage(containing: 1_500).id == ids[1_500])
        #expect(window.job(for: window.rows[0]) == nil)
        #expect(window.loadedCount <= (2 * JobWindow.margin + 1) * JobWindow.pageSize)
    }
}
