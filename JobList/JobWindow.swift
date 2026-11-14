//
//  JobWindow.swift
//  JobList
//

import Foundation
import Observation

/// A table row: a job's position in the current results and its database ID.
/// The full record is loaded separately, and only while the row is near the screen.
nonisolated struct JobRow: Identifiable, Hashable, Sendable {
    let index: Int
    let id: Int64
}

/// The current query's rows, built on demand from the ordered list of matching IDs.
nonisolated struct JobRows: RandomAccessCollection, Sendable {
    let ids: [Int64]

    var startIndex: Int { 0 }
    var endIndex: Int { ids.count }

    subscript(index: Int) -> JobRow {
        JobRow(index: index, id: ids[index])
    }
}

/// A sliding window of fully loaded records over the current query's results.
///
/// The table is given every matching row ID (eight bytes each) so its scroll bar,
/// selection, and Select All work across all results, but full records are only
/// loaded a page at a time as rows scroll into view. Pages that scroll out of the
/// window are discarded, so memory use stays constant however far the user scrolls.
@Observable
final class JobWindow {
    /// Records loaded per database fetch.
    static let pageSize = 100
    /// Pages kept loaded on each side of the page being viewed.
    static let margin = 2

    private(set) var rows = JobRows(ids: [])
    /// Loaded pages, keyed by page number.
    private var pages: [Int: [JobPosting]] = [:]

    @ObservationIgnored private var database: JobDatabase?
    @ObservationIgnored private var loading: Set<Int> = []
    /// The pages that should currently be loaded.
    @ObservationIgnored private var window: ClosedRange<Int> = 0...0
    /// Bumped on every reset so loads for a previous query are discarded.
    @ObservationIgnored private var generation = 0

    /// The number of loaded records, for diagnostics and tests.
    var loadedCount: Int { pages.values.reduce(0) { $0 + $1.count } }

    /// Replaces the results, dropping all loaded records.
    func reset(ids: [Int64], database: JobDatabase?) {
        generation += 1
        self.database = database
        rows = JobRows(ids: ids)
        pages = [:]
        loading = []
        window = 0...0
        if !ids.isEmpty { rowAppeared(at: 0) }
    }

    /// The record for `row`, or `nil` while it's loading.
    func job(for row: JobRow) -> JobPosting? {
        guard let page = pages[row.index / Self.pageSize] else { return nil }
        let offset = row.index % Self.pageSize
        guard offset < page.count, page[offset].id == row.id else { return nil }
        return page[offset]
    }

    /// A loaded record with the given ID, if it's in the window.
    func cachedJob(withID id: Int64) -> JobPosting? {
        for page in pages.values {
            if let job = page.first(where: { $0.id == id }) { return job }
        }
        return nil
    }

    /// Slides the window to the page containing `index`, discarding pages that are now
    /// out of range and loading any that are missing.
    func rowAppeared(at index: Int) {
        guard !rows.isEmpty else { return }
        let page = index / Self.pageSize
        let lastPage = (rows.count - 1) / Self.pageSize
        window = max(0, page - Self.margin)...min(lastPage, page + Self.margin)

        if pages.keys.contains(where: { !window.contains($0) }) {
            pages = pages.filter { window.contains($0.key) }
        }
        for page in window where pages[page] == nil && !loading.contains(page) {
            load(page)
        }
    }

    private func load(_ page: Int) {
        guard let database else { return }
        loading.insert(page)
        let start = page * Self.pageSize
        let ids = Array(rows.ids[start..<min(rows.count, start + Self.pageSize)])
        let generation = generation

        Task {
            let jobs = try? await database.fetchJobs(withIDs: ids)
            // Discard results for an earlier query or for a page that has since scrolled away.
            guard generation == self.generation else { return }
            loading.remove(page)
            guard let jobs, window.contains(page) else { return }
            pages[page] = jobs
        }
    }
}
