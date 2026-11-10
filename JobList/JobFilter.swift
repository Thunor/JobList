//
//  JobFilter.swift
//  JobList
//

import Foundation

/// The user's current filter criteria. A `nil` selection means "Any".
nonisolated struct JobFilter: Equatable, Sendable {
    enum PostedWithin: String, CaseIterable, Identifiable {
        case any = "Any Time"
        case day = "Last 24 Hours"
        case week = "Last 7 Days"
        case month = "Last 30 Days"
        case quarter = "Last 90 Days"

        var id: Self { self }

        var interval: TimeInterval? {
            switch self {
            case .any: nil
            case .day: 86_400
            case .week: 7 * 86_400
            case .month: 30 * 86_400
            case .quarter: 90 * 86_400
            }
        }
    }

    var searchText = ""
    var source: String?
    var company: String?
    var workMode: String?
    var compType: String?
    var tag: String?
    var country: String?
    var category: String?
    var currency: String?
    var postedWithin: PostedWithin = .any
    var salaryListedOnly = false
    var minimumSalary: Double?

    var isActive: Bool { self != JobFilter() }

    func matches(_ job: JobPosting, now: Date = .now) -> Bool {
        if let source, job.source != source { return false }
        if let company, job.company != company { return false }
        if let workMode, job.workMode != workMode { return false }
        if let compType, job.compType != compType { return false }
        if let currency, job.currency != currency { return false }
        if let tag, !job.tags.contains(tag) { return false }
        if let country, !job.countries.contains(country) { return false }
        if let category, !job.categories.contains(category) { return false }

        if let interval = postedWithin.interval {
            guard let posted = job.postedAt, now.timeIntervalSince(posted) <= interval else { return false }
        }

        let topSalary = job.maxAmount ?? job.minAmount
        if salaryListedOnly, topSalary == nil, (job.rawSalaryText ?? "").isEmpty { return false }
        if let minimumSalary {
            guard let topSalary, topSalary >= minimumSalary else { return false }
        }

        let query = foldedQuery
        if !query.isEmpty {
            return job.searchIndex.contains(query)
        }
        return true
    }

    /// The search text normalized the same way as `JobPosting.searchIndex`.
    var foldedQuery: String {
        JobPosting.fold(searchText.trimmingCharacters(in: .whitespaces))
    }

    /// Filters and sorts `jobs` on a background thread.
    @concurrent
    nonisolated func apply(to jobs: [JobPosting], sortedBy sortOrder: [KeyPathComparator<JobPosting>]) async -> [JobPosting] {
        let now = Date.now
        // Fold the query once rather than once per record.
        var filter = self
        filter.searchText = ""
        let query = foldedQuery
        return jobs
            .filter { filter.matches($0, now: now) && (query.isEmpty || $0.searchIndex.contains(query)) }
            .sorted(using: sortOrder)
    }
}
