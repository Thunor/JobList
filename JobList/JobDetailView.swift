//
//  JobDetailView.swift
//  JobList
//

import SwiftUI

struct JobDetailView: View {
    let job: JobPosting?

    var body: some View {
        if let job {
            Form {
                Section {
                    Text(job.title).font(.title3.bold())
                    Text(job.company).foregroundStyle(.secondary)
                    if let url = job.applyUrl {
                        Link("Apply…", destination: url)
                    }
                }
                Section("Posting") {
                    row("Source", job.source)
                    row("Posted", job.postedAt?.formatted(date: .abbreviated, time: .shortened) ?? "")
                    row("Work Mode", job.workMode.capitalized)
                }
                Section("Location") {
                    row("Location", job.rawLocation)
                    row("Countries", job.countriesText)
                }
                Section("Classification") {
                    row("Tags", job.tagsText)
                    row("Categories", job.categoriesText)
                }
                Section("Compensation") {
                    row("Type", job.compType)
                    row("Salary", job.salaryText)
                    row("Currency", job.currency ?? "")
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("No Selection", systemImage: "briefcase", description: Text("Select a job to see its details."))
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label, value: value.isEmpty ? "—" : value)
            .textSelection(.enabled)
    }
}
