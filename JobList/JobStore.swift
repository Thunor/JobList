//
//  JobStore.swift
//  JobList
//

import Foundation
import Observation

/// Owns the job database: imports JSON and Excel files into it and reopens it on launch.
///
/// Records themselves are never held here; views query the database through
/// `JobWindow` and `JobDatabase`.
@Observable
final class JobStore {
    private(set) var database: JobDatabase?
    /// Incremented every time a database is opened so views can tell when the jobs were replaced.
    private(set) var version = 0
    private(set) var isLoading = false
    /// Import progress from 0 to 1, or `nil` when not importing.
    private(set) var importProgress: Double?
    var errorMessage: String?
    var isImporterPresented = false

    var options: FilterOptions { database?.options ?? FilterOptions() }
    var fileName: String? { database?.sourceName }
    var jobCount: Int { database?.totalCount ?? 0 }

    @ObservationIgnored private let databaseURL: URL
    /// The restore or import in progress, kept so it can be cancelled.
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(databaseURL: URL = JobDatabase.defaultURL) {
        self.databaseURL = databaseURL
    }

    /// Reopens the jobs imported in a previous session, if there are any.
    func restore() async {
        guard database == nil, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        await run {
            // A missing database, or one from an incompatible version, just means starting empty.
            guard let opened = try? await JobDatabase.open(self.databaseURL),
                  !Task.isCancelled, self.database == nil else { return }
            self.apply(opened)
        }
    }

    /// Stops the restore or import in progress. A cancelled import leaves the current database as it was.
    func cancelLoading() {
        loadTask?.cancel()
    }

    /// Cancels any restore or import, then discards the current jobs and deletes the
    /// database file, leaving an empty database ready for a new import.
    func newDatabase() async {
        if let loadTask {
            loadTask.cancel()
            await loadTask.value
        }
        try? FileManager.default.removeItem(at: databaseURL)
        database = nil
        version += 1
    }

    func job(withID id: JobPosting.ID?) async -> JobPosting? {
        guard let id, let database else { return nil }
        return try? await database.fetchJobs(withIDs: [id]).first
    }

    /// Imports a JSON or Excel file into a new database, replacing the current one when it succeeds.
    func load(from url: URL) async {
        guard !isLoading else { return }
        isLoading = true
        importProgress = 0
        defer {
            isLoading = false
            importProgress = nil
        }

        await run {
            do {
                let database = try await JobDatabase.importFile(from: url, to: self.databaseURL) { fraction in
                    Task { @MainActor in
                        // Ignore updates that arrive after the import has finished.
                        guard self.importProgress != nil else { return }
                        self.importProgress = fraction
                    }
                }
                guard !Task.isCancelled else { return }
                self.apply(database)
            } catch is CancellationError {
                // Cancelled by the user; nothing to report.
            } catch {
                guard !Task.isCancelled else { return }
                self.errorMessage = "“\(url.lastPathComponent)” could not be imported as a job list.\n\(error.localizedDescription)"
            }
        }
    }

    /// Runs `work` as the cancellable load task and waits for it to finish.
    private func run(_ work: @escaping () async -> Void) async {
        let task = Task { await work() }
        loadTask = task
        await task.value
        loadTask = nil
    }

    private func apply(_ database: JobDatabase) {
        self.database = database
        version += 1
    }
}

/// Sorted, distinct values for each filterable field.
nonisolated struct FilterOptions: Codable, Sendable {
    var sources: [String] = []
    var companies: [String] = []
    var workModes: [String] = []
    var compTypes: [String] = []
    var tags: [String] = []
    var countries: [String] = []
    var categories: [String] = []
    var currencies: [String] = []
}
