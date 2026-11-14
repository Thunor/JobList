//
//  JobSpreadsheet.swift
//  JobList
//

import CoreTransferable
import Foundation
import UniformTypeIdentifiers

nonisolated extension UTType {
    /// Excel workbook (`.xlsx`).
    static let xlsx = UTType("org.openxmlformats.spreadsheetml.sheet")
        ?? UTType(importedAs: "org.openxmlformats.spreadsheetml.sheet")
}

/// Jobs exported as an `.xlsx` workbook, generated only when the file is actually saved.
nonisolated struct JobSpreadsheet: Transferable {
    let jobs: [JobPosting]

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .xlsx) { spreadsheet in
            try await spreadsheet.data()
        }
    }

    @concurrent
    func data() async throws -> Data {
        try JobPosting.spreadsheetData(for: jobs)
    }
}

nonisolated extension JobPosting {
    enum SpreadsheetError: LocalizedError {
        case missingHeader

        var errorDescription: String? {
            "The first row of the first sheet must contain column headers such as “title” and “company”."
        }
    }

    /// Spreadsheet columns, named after the JSON keys so files convert cleanly between formats.
    private enum Column: String, CaseIterable {
        case title, company, applyUrl, source, postedAt, tags, countries, rawLocation
        case compType, minAmount, maxAmount, currency, rawSalaryText, workMode, categories

        var width: Double {
            switch self {
            case .title: 45
            case .applyUrl: 50
            case .rawLocation: 35
            case .tags, .rawSalaryText: 30
            case .company, .countries: 22
            default: 14
            }
        }
    }

    /// Separator for list fields (tags, countries, categories), which share a single cell.
    private static let listSeparator = ", "

    /// Reads jobs from the first sheet of an `.xlsx` workbook whose first row holds the column names.
    /// Columns may appear in any order; unknown columns are ignored.
    static func decodeSpreadsheet(from data: Data) throws -> [JobPosting] {
        let sheet = try Spreadsheet.readFirstSheet(from: data)
        guard let header = sheet.rows.first else { throw SpreadsheetError.missingHeader }

        var columnIndex: [Column: Int] = [:]
        for (index, name) in header.enumerated() {
            let name = name.trimmingCharacters(in: .whitespaces)
            if let column = Column.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(name) == .orderedSame }),
               columnIndex[column] == nil {
                columnIndex[column] = index
            }
        }
        guard columnIndex[.title] != nil || columnIndex[.company] != nil else { throw SpreadsheetError.missingHeader }

        return sheet.rows.dropFirst().compactMap { row in
            func text(_ column: Column) -> String {
                guard let index = columnIndex[column], index < row.count else { return "" }
                return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            func optionalText(_ column: Column) -> String? {
                let value = text(column)
                return value.isEmpty ? nil : value
            }
            func list(_ column: Column) -> [String] {
                text(column).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            func number(_ column: Column) -> Double? {
                Double(text(column))
            }
            // Dates may be stored as date cells (serial numbers) or as ISO 8601 text.
            func date(_ column: Column) -> Date? {
                let value = text(column)
                if let serial = Double(value) { return sheet.date(fromSerial: serial) }
                return parseDate(value)
            }

            let title = text(.title)
            let company = text(.company)
            guard !title.isEmpty || !company.isEmpty else { return nil }

            return JobPosting(
                title: title,
                company: company,
                applyUrl: optionalText(.applyUrl).flatMap(URL.init(string:)),
                source: text(.source),
                postedAt: date(.postedAt),
                tags: list(.tags),
                countries: list(.countries),
                rawLocation: text(.rawLocation),
                compType: optionalText(.compType) ?? "unknown",
                minAmount: number(.minAmount),
                maxAmount: number(.maxAmount),
                currency: optionalText(.currency),
                rawSalaryText: optionalText(.rawSalaryText),
                workMode: text(.workMode),
                categories: list(.categories)
            )
        }
    }

    /// Writes jobs to an `.xlsx` workbook using the same columns `decodeSpreadsheet` reads.
    static func spreadsheetData(for jobs: [JobPosting]) throws -> Data {
        let rows: [[Spreadsheet.Cell?]] = jobs.map { job in
            Column.allCases.map { column in
                switch column {
                case .title: .text(job.title)
                case .company: .text(job.company)
                case .applyUrl: job.applyUrl.map { .text($0.absoluteString) }
                case .source: .text(job.source)
                case .postedAt: job.postedAt.map { .date($0) }
                case .tags: .text(job.tags.joined(separator: listSeparator))
                case .countries: .text(job.countries.joined(separator: listSeparator))
                case .rawLocation: .text(job.rawLocation)
                case .compType: .text(job.compType)
                case .minAmount: job.minAmount.map { .number($0) }
                case .maxAmount: job.maxAmount.map { .number($0) }
                case .currency: job.currency.map { .text($0) }
                case .rawSalaryText: job.rawSalaryText.map { .text($0) }
                case .workMode: .text(job.workMode)
                case .categories: .text(job.categories.joined(separator: listSeparator))
                }
            }
        }
        return try Spreadsheet.write(
            header: Column.allCases.map(\.rawValue),
            rows: rows,
            columnWidths: Column.allCases.map(\.width),
            sheetName: "Jobs"
        )
    }
}
