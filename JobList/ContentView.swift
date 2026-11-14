//
//  ContentView.swift
//  JobList
//
//  Created by Eric Freitas on 11/6/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(JobStore.self) private var store
    @Environment(\.openURL) private var openURL

    @State private var filter = JobFilter()
    @State private var sortOrder = [JobSort(column: .posted, order: .reverse)]
    @State private var selection: Set<JobPosting.ID> = []
    @State private var isInspectorPresented = true
    /// The record shown in the inspector, loaded from the database when the selection changes.
    @State private var selectedJob: JobPosting?

    /// The jobs being exported; non-nil while the save dialog or export is in progress.
    @State private var exportItem: JobSpreadsheet?
    @State private var exportError: String?
    @State private var isExporterPresented = false

    /// The matching row IDs plus the loaded records around the scroll position.
    @State private var window = JobWindow()
    @State private var appliedQuery: Query?
    @State private var isFiltering = false

    /// Everything that affects which rows are shown and in what order.
    private struct Query: Equatable {
        var filter: JobFilter
        var sortOrder: [JobSort]
        var version: Int
    }

    var body: some View {
        @Bindable var store = store

        NavigationSplitView {
            FilterSidebar(filter: $filter, options: store.options)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            Group {
                if store.database == nil {
                    ContentUnavailableView {
                        Label("No Jobs Loaded", systemImage: "doc.text")
                    } description: {
                        Text("Open a JSON or Excel file of job postings, or drop one here.")
                    } actions: {
                        Button("Open…") { store.isImporterPresented = true }
                    }
                } else {
                    jobTable
                }
            }
            .overlay {
                if let progress = store.importProgress {
                    VStack {
                        ProgressView("Importing…", value: progress)
                            .frame(width: 240)
                        Button("Cancel") { store.cancelLoading() }
                    }
                    .padding()
                    .background(.regularMaterial, in: .rect(cornerRadius: 12))
                } else if store.isLoading {
                    VStack {
                        ProgressView("Loading…")
                        Button("Cancel") { store.cancelLoading() }
                    }
                    .padding()
                    .background(.regularMaterial, in: .rect(cornerRadius: 12))
                } else if exportItem != nil, !isExporterPresented {
                    ProgressView("Exporting…")
                        .padding()
                        .background(.regularMaterial, in: .rect(cornerRadius: 12))
                }
            }
            .navigationTitle(store.fileName ?? "JobList")
            .navigationSubtitle(subtitle)
            .searchable(text: $filter.searchText, prompt: "Title, company, location, tags")
            .inspector(isPresented: $isInspectorPresented) {
                JobDetailView(job: selection.count == 1 ? selectedJob : nil, selectionCount: selection.count)
                    .inspectorColumnWidth(min: 260, ideal: 320)
            }
            .toolbar {
                ToolbarItem {
                    Button("New Database", systemImage: "doc.badge.plus") { newDatabase() }
                        .help("Discard the current jobs and start with an empty database")
                }
                ToolbarItem {
                    Button("Open", systemImage: "folder") { store.isImporterPresented = true }
                        .disabled(store.isLoading)
                }
                ToolbarItem {
                    Button("Export to Excel", systemImage: "square.and.arrow.up") { export(selection) }
                        .keyboardShortcut("e")
                        .help("Export the selected jobs as an Excel spreadsheet (⌘A selects all)")
                        .disabled(selection.isEmpty || exportItem != nil)
                }
                ToolbarItem {
                    Button("Inspector", systemImage: "sidebar.trailing") { isInspectorPresented.toggle() }
                }
            }
        }
        // Attached to the split view (which never leaves the hierarchy) so the refresh
        // isn't cancelled when the detail content switches between empty state and table.
        .task(id: Query(filter: filter, sortOrder: sortOrder, version: store.version)) {
            await refresh(for: Query(filter: filter, sortOrder: sortOrder, version: store.version))
        }
        .task(id: selection.count == 1 ? selection.first : nil) {
            await loadSelectedJob()
        }
        .task { await store.restore() }
        .fileImporter(isPresented: $store.isImporterPresented, allowedContentTypes: [.json, .xlsx]) { result in
            switch result {
            case .success(let url): open(url)
            case .failure(let error): store.errorMessage = error.localizedDescription
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { ["json", "xlsx"].contains($0.pathExtension.lowercased()) }) else { return false }
            open(url)
            return true
        }
        .alert("Couldn’t Open File", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
        .fileExporter(isPresented: $isExporterPresented, item: exportItem, contentTypes: [.xlsx],
                      defaultFilename: exportFilename) { result in
            exportItem = nil
            if case .failure(let error) = result { exportError = error.localizedDescription }
        } onCancellation: {
            exportItem = nil
        }
        .alert("Couldn’t Export", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    private var subtitle: String {
        guard store.database != nil else { return "" }
        if isFiltering { return "Filtering…" }
        let shown = "\(window.rows.count.formatted()) of \(store.jobCount.formatted()) jobs"
        return selection.isEmpty ? shown : "\(shown), \(selection.count.formatted()) selected"
    }

    private var exportFilename: String {
        let base = store.fileName.map { ($0 as NSString).deletingPathExtension } ?? "Jobs"
        return "\(base) Export"
    }

    /// The selected IDs that are currently visible, in table order. Selections hidden by
    /// a later filter change aren't exported.
    @concurrent
    private nonisolated static func orderedSelection(_ ids: Set<JobPosting.ID>, in rows: [JobPosting.ID]) async -> [JobPosting.ID] {
        rows.filter(ids.contains)
    }

    private func export(_ ids: Set<JobPosting.ID>) {
        guard let database = store.database, !ids.isEmpty else { return }
        let rows = window.rows.ids
        exportItem = JobSpreadsheet(ids: [], database: database)
        Task {
            let ordered = await Self.orderedSelection(ids, in: rows)
            guard !ordered.isEmpty else {
                exportItem = nil
                return
            }
            exportItem = JobSpreadsheet(ids: ordered, database: database, name: exportFilename)
            isExporterPresented = true
        }
    }

    private var jobTable: some View {
        Table(window.rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Title", sortUsing: JobSort(column: .title)) { row in
                cell(row) { Text($0.title) }
                    // Rows report when they scroll into view so the window can slide to them.
                    .onAppear { window.rowAppeared(at: row.index) }
            }
            .width(min: 180, ideal: 280)
            TableColumn("Company", sortUsing: JobSort(column: .company)) { row in
                cell(row) { Text($0.company) }
            }
            .width(min: 100, ideal: 140)
            TableColumn("Source", sortUsing: JobSort(column: .source)) { row in
                cell(row) { Text($0.source) }
            }
            .width(min: 60, ideal: 80)
            TableColumn("Posted", sortUsing: JobSort(column: .posted, order: .reverse)) { row in
                cell(row) { Text($0.postedAt?.formatted(date: .abbreviated, time: .omitted) ?? "—") }
            }
            .width(min: 80, ideal: 100)
            TableColumn("Work Mode", sortUsing: JobSort(column: .workMode)) { row in
                cell(row) { Text($0.workMode.capitalized) }
            }
            .width(min: 70, ideal: 80)
            TableColumn("Location", sortUsing: JobSort(column: .location)) { row in
                cell(row) { Text($0.rawLocation) }
            }
            .width(min: 100, ideal: 180)
            TableColumn("Countries", sortUsing: JobSort(column: .countries)) { row in
                cell(row) { Text($0.countriesText) }
            }
            .width(min: 80, ideal: 120)
            TableColumn("Tags", sortUsing: JobSort(column: .tags)) { row in
                cell(row) { Text($0.tagsText) }
            }
            .width(min: 80, ideal: 150)
            TableColumn("Comp Type", sortUsing: JobSort(column: .compType)) { row in
                cell(row) { Text($0.compType) }
            }
            .width(min: 70, ideal: 80)
            TableColumn("Salary", sortUsing: JobSort(column: .salary, order: .reverse)) { row in
                cell(row) { Text($0.salaryText) }
            }
            .width(min: 80, ideal: 140)
        }
        .contextMenu(forSelectionType: JobPosting.ID.self) { ids in
            if ids.count == 1, let url = applyURL(for: ids) {
                Button("Open Apply Link") { openURL(url) }
            }
            if !ids.isEmpty {
                Button(ids.count == 1 ? "Export to Excel…" : "Export \(ids.count) Jobs to Excel…") { export(ids) }
            }
        } primaryAction: { ids in
            // Double-clicking a row opens its apply link.
            if let url = applyURL(for: ids) { openURL(url) }
        }
    }

    private func cell(_ row: JobRow, @ViewBuilder content: @escaping (JobPosting) -> some View) -> some View {
        JobCell(window: window, row: row, content: content)
    }

    /// The clicked row is on screen, so its record is in the window.
    private func applyURL(for ids: Set<JobPosting.ID>) -> URL? {
        ids.first.flatMap(window.cachedJob(withID:))?.applyUrl
    }

    private func newDatabase() {
        selection = []
        Task { await store.newDatabase() }
    }

    private func open(_ url: URL) {
        selection = []
        Task { await store.load(from: url) }
    }

    /// Re-runs the query in the background. `.task(id:)` cancels the previous run when
    /// the query changes, which interrupts the database query and discards its result.
    private func refresh(for query: Query) async {
        guard let database = store.database else {
            window.reset(ids: [], database: nil)
            appliedQuery = nil
            return
        }
        // While the user is typing, wait briefly so each keystroke doesn't trigger a query.
        if let appliedQuery, appliedQuery.filter.searchText != query.filter.searchText,
           appliedQuery.version == query.version {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
        }

        isFiltering = true
        defer { if !Task.isCancelled { isFiltering = false } }
        do {
            let ids = try await database.matchingIDs(query.filter, sortedBy: query.sortOrder)
            guard !Task.isCancelled else { return }
            if appliedQuery?.version != query.version { selection = [] }
            window.reset(ids: ids, database: database)
            appliedQuery = query
        } catch {
            // Cancellation interrupts the query; anything else is worth reporting.
            if !Task.isCancelled { store.errorMessage = error.localizedDescription }
        }
    }

    private func loadSelectedJob() async {
        guard selection.count == 1, let id = selection.first else {
            selectedJob = nil
            return
        }
        if let job = window.cachedJob(withID: id) {
            selectedJob = job
        } else {
            let job = await store.job(withID: id)
            if !Task.isCancelled { selectedJob = job }
        }
    }
}

/// A table cell that shows its record once the window has loaded it.
private struct JobCell<Content: View>: View {
    let window: JobWindow
    let row: JobRow
    let content: (JobPosting) -> Content

    var body: some View {
        if let job = window.job(for: row) {
            content(job)
        } else {
            // Keeps the row's height while its page loads.
            Text(verbatim: " ")
        }
    }
}

#Preview {
    ContentView()
        .environment(JobStore())
}
