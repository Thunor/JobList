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
    @State private var sortOrder = [KeyPathComparator(\JobPosting.postedAtSortKey, order: .reverse)]
    @State private var selection: JobPosting.ID?
    @State private var isInspectorPresented = true

    /// Cached filter/sort result, recomputed only when `query` changes.
    @State private var visibleJobs: [JobPosting] = []
    @State private var appliedQuery: Query?

    /// Everything that affects which rows are shown and in what order.
    private struct Query: Equatable {
        var filter: JobFilter
        var sortOrder: [KeyPathComparator<JobPosting>]
        var version: Int
    }

    var body: some View {
        @Bindable var store = store

        NavigationSplitView {
            FilterSidebar(filter: $filter, options: store.options)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            Group {
                if store.jobs.isEmpty {
                    ContentUnavailableView {
                        Label("No Jobs Loaded", systemImage: "doc.text")
                    } description: {
                        Text("Open a JSON file of job postings, or drop one here.")
                    } actions: {
                        Button("Open…") { store.isImporterPresented = true }
                    }
                } else {
                    jobTable(visibleJobs)
                }
            }
            .overlay {
                if store.isLoading {
                    ProgressView("Loading…")
                        .padding()
                        .background(.regularMaterial, in: .rect(cornerRadius: 12))
                }
            }
            .navigationTitle(store.fileName ?? "JobList")
            .navigationSubtitle(store.jobs.isEmpty ? "" : "\(visibleJobs.count) of \(store.jobs.count) jobs")
            .searchable(text: $filter.searchText, prompt: "Title, company, location, tags")
            .inspector(isPresented: $isInspectorPresented) {
                JobDetailView(job: store.job(withID: selection))
                    .inspectorColumnWidth(min: 260, ideal: 320)
            }
            .toolbar {
                ToolbarItem {
                    Button("Open", systemImage: "folder") { store.isImporterPresented = true }
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
        .fileImporter(isPresented: $store.isImporterPresented, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): open(url)
            case .failure(let error): store.errorMessage = error.localizedDescription
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.pathExtension.lowercased() == "json" }) else { return false }
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
    }

    private func jobTable(_ jobs: [JobPosting]) -> some View {
        Table(jobs, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Title", value: \.title)
                .width(min: 180, ideal: 280)
            TableColumn("Company", value: \.company)
                .width(min: 100, ideal: 140)
            TableColumn("Source", value: \.source)
                .width(min: 60, ideal: 80)
            TableColumn("Posted", value: \.postedAtSortKey) { job in
                Text(job.postedAt?.formatted(date: .abbreviated, time: .omitted) ?? "—")
            }
            .width(min: 80, ideal: 100)
            TableColumn("Work Mode", value: \.workMode) { job in
                Text(job.workMode.capitalized)
            }
            .width(min: 70, ideal: 80)
            TableColumn("Location", value: \.rawLocation)
                .width(min: 100, ideal: 180)
            TableColumn("Countries", value: \.countriesText)
                .width(min: 80, ideal: 120)
            TableColumn("Tags", value: \.tagsText)
                .width(min: 80, ideal: 150)
            TableColumn("Comp Type", value: \.compType)
                .width(min: 70, ideal: 80)
            TableColumn("Salary", value: \.salarySortKey) { job in
                Text(job.salaryText)
            }
            .width(min: 80, ideal: 140)
        }
        .contextMenu(forSelectionType: JobPosting.ID.self) { ids in
            if let url = applyURL(for: ids) {
                Button("Open Apply Link") { openURL(url) }
            }
        } primaryAction: { ids in
            // Double-clicking a row opens its apply link.
            if let url = applyURL(for: ids) { openURL(url) }
        }
    }

    private func applyURL(for ids: Set<JobPosting.ID>) -> URL? {
        store.job(withID: ids.first)?.applyUrl
    }

    private func open(_ url: URL) {
        selection = nil
        Task { await store.load(from: url) }
    }

    /// Recomputes `visibleJobs` in the background. `.task(id:)` cancels the previous
    /// run when the query changes, so stale results are discarded.
    private func refresh(for query: Query) async {
        // While the user is typing, wait briefly so each keystroke doesn't trigger a full pass.
        if let appliedQuery, appliedQuery.filter.searchText != query.filter.searchText,
           appliedQuery.version == query.version {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
        }
        let result = await query.filter.apply(to: store.jobs, sortedBy: query.sortOrder)
        guard !Task.isCancelled else { return }
        visibleJobs = result
        appliedQuery = query
    }
}

#Preview {
    ContentView()
        .environment(JobStore())
}
