//
//  JobFilter.swift
//  JobList
//

import Foundation

/// The user's current filter criteria. A `nil` selection means "Any".
///
/// Filters are applied by `JobDatabase`, which translates them into SQL.
nonisolated struct JobFilter: Equatable, Sendable {
    enum PostedWithin: String, CaseIterable, Identifiable, Sendable {
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

    /// The search text normalized the same way as `JobPosting.searchIndex`.
    var foldedQuery: String {
        JobPosting.fold(searchText.trimmingCharacters(in: .whitespaces))
    }
}

/// A table sort column and direction. Sorting is performed by `JobDatabase` in SQL;
/// the table only uses this to record which column header the user clicked.
nonisolated struct JobSort: SortComparator, Hashable, Sendable {
    enum Column: Hashable, Sendable {
        case title, company, source, posted, workMode, location, countries, tags, compType, salary
    }

    var column: Column
    var order: SortOrder = .forward

    func compare(_ lhs: JobRow, _ rhs: JobRow) -> ComparisonResult {
        // Rows only carry IDs, so they can't be compared here; the database sorts them.
        .orderedSame
    }
}
