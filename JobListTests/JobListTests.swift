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

    @Test func filterMatchesByFieldsAndSearch() {
        let job = JobPosting(title: "iOS Engineer", company: "Acme", source: "Gem",
                             tags: ["Engineering"], countries: ["Canada"], workMode: "remote")
        var filter = JobFilter()
        #expect(filter.matches(job))

        filter.tag = "Engineering"
        filter.workMode = "remote"
        #expect(filter.matches(job))

        filter.country = "United States"
        #expect(!filter.matches(job))

        filter = JobFilter(searchText: "acme")
        #expect(filter.matches(job))

        filter.minimumSalary = 100_000
        #expect(!filter.matches(job))
    }

    @Test func applyFiltersAndSortsLargeList() async {
        let jobs = (0..<100_000).map { i in
            JobPosting(title: "Engineer \(i)", company: i.isMultiple(of: 2) ? "Café Corp" : "Acme",
                       postedAt: Date(timeIntervalSince1970: Double(i)), workMode: "remote")
        }
        let filter = JobFilter(searchText: "cafe")
        let clock = ContinuousClock()
        var result: [JobPosting] = []
        let elapsed = await clock.measure {
            result = await filter.apply(to: jobs, sortedBy: [KeyPathComparator(\.postedAtSortKey, order: .reverse)])
        }
        print("Filtered and sorted 100k records in \(elapsed)")
        #expect(result.count == 50_000)
        #expect(result.first?.title == "Engineer 99998")
    }
}
