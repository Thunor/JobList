//
//  FilterSidebar.swift
//  JobList
//

import SwiftUI

struct FilterSidebar: View {
    @Binding var filter: JobFilter
    let options: FilterOptions

    var body: some View {
        Form {
            Section("Posting") {
                OptionPicker(title: "Source", selection: $filter.source, values: options.sources)
                OptionPicker(title: "Company", selection: $filter.company, values: options.companies)
                Picker("Posted", selection: $filter.postedWithin) {
                    ForEach(JobFilter.PostedWithin.allCases) { Text($0.rawValue).tag($0) }
                }
            }

            Section("Location") {
                OptionPicker(title: "Work Mode", selection: $filter.workMode, values: options.workModes)
                OptionPicker(title: "Country", selection: $filter.country, values: options.countries)
            }

            Section("Classification") {
                OptionPicker(title: "Tag", selection: $filter.tag, values: options.tags)
                OptionPicker(title: "Category", selection: $filter.category, values: options.categories)
            }

            Section("Compensation") {
                OptionPicker(title: "Comp Type", selection: $filter.compType, values: options.compTypes)
                OptionPicker(title: "Currency", selection: $filter.currency, values: options.currencies)
                TextField("Minimum", value: $filter.minimumSalary, format: .number, prompt: Text("Any"))
                Toggle("Salary listed", isOn: $filter.salaryListedOnly)
            }

            Section {
                Button("Reset Filters") { filter = JobFilter() }
                    .disabled(!filter.isActive)
            }
        }
        .formStyle(.grouped)
    }
}

/// A picker over a field's distinct values, with "Any" mapped to `nil`.
private struct OptionPicker: View {
    let title: String
    @Binding var selection: String?
    let values: [String]

    /// Menus build every item eagerly, so a field with thousands of distinct values
    /// (e.g. companies) exhausts SwiftUI's attribute graph and crashes. Above this
    /// count, a searchable popover backed by a lazy `List` is used instead.
    private static let menuLimit = 100

    @State private var isPopoverPresented = false

    var body: some View {
        if values.count <= Self.menuLimit {
            Picker(title, selection: $selection) {
                Text("Any").tag(String?.none)
                if !values.isEmpty {
                    Divider()
                    ForEach(values, id: \.self) { Text($0).tag(Optional($0)) }
                }
            }
            .disabled(values.isEmpty)
        } else {
            LabeledContent(title) {
                Button(selection ?? "Any") { isPopoverPresented = true }
                    .popover(isPresented: $isPopoverPresented, arrowEdge: .trailing) {
                        OptionSearchList(selection: $selection, values: values) {
                            isPopoverPresented = false
                        }
                    }
            }
        }
    }
}

/// A searchable, lazily rendered list of values for fields with too many options for a menu.
private struct OptionSearchList: View {
    @Binding var selection: String?
    let values: [String]
    let dismiss: () -> Void

    @State private var searchText = ""

    private var matches: [String] {
        searchText.isEmpty ? values : values.filter { $0.localizedStandardContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search", text: $searchText, prompt: Text("Search \(values.count) values"))
                .textFieldStyle(.roundedBorder)
                .padding(8)
            List {
                Button("Any") { choose(nil) }
                ForEach(matches, id: \.self) { value in
                    Button(value) { choose(value) }
                }
            }
            .buttonStyle(.plain)
        }
        .frame(width: 280, height: 360)
    }

    private func choose(_ value: String?) {
        selection = value
        dismiss()
    }
}
