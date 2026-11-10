//
//  JobStore.swift
//  JobList
//

import Foundation
import Observation

/// Holds the currently loaded job file and the distinct values used by the filter pickers.
@Observable
final class JobStore {
    private(set) var jobs: [JobPosting] = []
    private(set) var options = FilterOptions()
    private(set) var fileName: String?
    /// Incremented on every successful load so views can tell when `jobs` was replaced.
    private(set) var version = 0
    private(set) var isLoading = false
    var errorMessage: String?
    var isImporterPresented = false

    private var jobsByID: [JobPosting.ID: JobPosting] = [:]

    func job(withID id: JobPosting.ID?) -> JobPosting? {
        id.flatMap { jobsByID[$0] }
    }

    func load(from url: URL) async {
        isLoading = true
        defer { isLoading = false }

        do {
            let file = try await Self.read(url)
            jobs = file.jobs
            jobsByID = file.jobsByID
            options = file.options
            fileName = url.lastPathComponent
            version += 1
        } catch {
            errorMessage = "“\(url.lastPathComponent)” could not be read as a job list.\n\(error.localizedDescription)"
        }
    }

    private struct LoadedFile: Sendable {
        let jobs: [JobPosting]
        let jobsByID: [JobPosting.ID: JobPosting]
        let options: FilterOptions
    }

    /// Reads, decodes, and indexes the file off the main actor so the UI stays responsive.
    @concurrent
    private nonisolated static func read(_ url: URL) async throws -> LoadedFile {
        // Files chosen through the open panel or dropped on the window are security scoped.
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let jobs = try JobPosting.decodeList(from: data)
        return LoadedFile(
            jobs: jobs,
            jobsByID: Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0) }),
            options: FilterOptions(jobs: jobs)
        )
    }
}

/// Sorted, distinct values for each filterable field.
nonisolated struct FilterOptions: Sendable {
    var sources: [String] = []
    var companies: [String] = []
    var workModes: [String] = []
    var compTypes: [String] = []
    var tags: [String] = []
    var countries: [String] = []
    var categories: [String] = []
    var currencies: [String] = []

    init() {}

    init(jobs: [JobPosting]) {
        func distinct(_ values: some Sequence<String>) -> [String] {
            Set(values.filter { !$0.isEmpty }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        sources = distinct(jobs.lazy.map(\.source))
        companies = distinct(jobs.lazy.map(\.company))
        workModes = distinct(jobs.lazy.map(\.workMode))
        compTypes = distinct(jobs.lazy.map(\.compType))
        tags = distinct(jobs.lazy.flatMap(\.tags))
        countries = distinct(jobs.lazy.flatMap(\.countries))
        categories = distinct(jobs.lazy.flatMap(\.categories))
        currencies = distinct(jobs.lazy.compactMap(\.currency))
    }
}
