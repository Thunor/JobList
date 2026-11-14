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

    var body: some View {
        Picker(title, selection: $selection) {
            Text("Any").tag(String?.none)
            if !values.isEmpty {
                Divider()
                ForEach(values, id: \.self) { Text($0).tag(Optional($0)) }
            }
        }
        .disabled(values.isEmpty)
    }
}
