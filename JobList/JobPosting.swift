//
//  JobPosting.swift
//  JobList
//

import Foundation

/// A single job record as stored in the JSON files and the job database.
///
/// Display text and sort keys are computed once at import time rather than on
/// every row render.
nonisolated struct JobPosting: Identifiable, Hashable, Sendable, Decodable {
    /// The database row ID; zero for records that haven't been imported.
    let id: Int64
    let title: String
    let company: String
    let applyUrl: URL?
    let source: String
    let postedAt: Date?
    let tags: [String]
    let countries: [String]
    let rawLocation: String
    let compType: String
    let minAmount: Double?
    let maxAmount: Double?
    let currency: String?
    let rawSalaryText: String?
    let workMode: String
    let categories: [String]

    // MARK: Precomputed values

    /// Non-optional keys so columns with missing values can still be sorted.
    let postedAtSortKey: Date
    let salarySortKey: Double
    let tagsText: String
    let countriesText: String
    let categoriesText: String
    let salaryText: String

    /// Case- and diacritic-folded text of all searchable fields, stored in the database's search index.
    var searchIndex: String {
        Self.fold([title, company, rawLocation, source, tagsText, countriesText, categoriesText].joined(separator: "\n"))
    }

    private enum CodingKeys: String, CodingKey {
        case title, company, applyUrl, source, postedAt, tags, countries, rawLocation
        case compType, minAmount, maxAmount, currency, rawSalaryText, workMode, categories
    }

    init(
        id: Int64 = 0,
        title: String,
        company: String,
        applyUrl: URL? = nil,
        source: String = "",
        postedAt: Date? = nil,
        tags: [String] = [],
        countries: [String] = [],
        rawLocation: String = "",
        compType: String = "unknown",
        minAmount: Double? = nil,
        maxAmount: Double? = nil,
        currency: String? = nil,
        rawSalaryText: String? = nil,
        workMode: String = "",
        categories: [String] = []
    ) {
        self.init(
            id: id, title: title, company: company, applyUrl: applyUrl, source: source, postedAt: postedAt,
            tags: tags,
            // The source data mixes cities, states, and addresses into `countries`.
            countries: CountryNormalizer.countries(from: countries, rawLocation: rawLocation),
            countriesText: countries.joined(separator: ", "),
            rawLocation: rawLocation, compType: compType, minAmount: minAmount, maxAmount: maxAmount,
            currency: currency, rawSalaryText: rawSalaryText, workMode: workMode, categories: categories,
            salaryText: Self.makeSalaryText(raw: rawSalaryText, min: minAmount, max: maxAmount, currency: currency)
        )
    }

    /// Recreates a record read back from the database, whose countries are already
    /// normalized and whose display text is already computed.
    init(
        id: Int64,
        title: String,
        company: String,
        applyUrl: URL?,
        source: String,
        postedAt: Date?,
        tags: [String],
        countries: [String],
        countriesText: String,
        rawLocation: String,
        compType: String,
        minAmount: Double?,
        maxAmount: Double?,
        currency: String?,
        rawSalaryText: String?,
        workMode: String,
        categories: [String],
        salaryText: String
    ) {
        self.id = id
        self.title = title
        self.company = company
        self.applyUrl = applyUrl
        self.source = source
        self.postedAt = postedAt
        self.tags = tags
        self.countries = countries
        self.rawLocation = rawLocation
        self.compType = compType
        self.minAmount = minAmount
        self.maxAmount = maxAmount
        self.currency = currency
        self.rawSalaryText = rawSalaryText
        self.workMode = workMode
        self.categories = categories

        postedAtSortKey = postedAt ?? .distantPast
        salarySortKey = maxAmount ?? minAmount ?? -1
        tagsText = tags.joined(separator: ", ")
        self.countriesText = countriesText
        categoriesText = categories.joined(separator: ", ")
        self.salaryText = salaryText
    }

    /// Lenient decoding: missing or null fields fall back to sensible defaults
    /// so one incomplete record doesn't prevent the whole file from loading.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            title: try c.decodeIfPresent(String.self, forKey: .title) ?? "",
            company: try c.decodeIfPresent(String.self, forKey: .company) ?? "",
            applyUrl: try c.decodeIfPresent(String.self, forKey: .applyUrl).flatMap(URL.init(string:)),
            source: try c.decodeIfPresent(String.self, forKey: .source) ?? "",
            postedAt: try c.decodeIfPresent(String.self, forKey: .postedAt).flatMap(Self.parseDate),
            tags: try c.decodeIfPresent([String].self, forKey: .tags) ?? [],
            countries: try c.decodeIfPresent([String].self, forKey: .countries) ?? [],
            rawLocation: try c.decodeIfPresent(String.self, forKey: .rawLocation) ?? "",
            compType: try c.decodeIfPresent(String.self, forKey: .compType) ?? "unknown",
            minAmount: try c.decodeIfPresent(Double.self, forKey: .minAmount),
            maxAmount: try c.decodeIfPresent(Double.self, forKey: .maxAmount),
            currency: try c.decodeIfPresent(String.self, forKey: .currency),
            rawSalaryText: try c.decodeIfPresent(String.self, forKey: .rawSalaryText),
            workMode: try c.decodeIfPresent(String.self, forKey: .workMode) ?? "",
            categories: try c.decodeIfPresent([String].self, forKey: .categories) ?? []
        )
    }

    // Identity is the database row ID, which keeps hashing and equality cheap.
    static func == (lhs: JobPosting, rhs: JobPosting) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    // MARK: Helpers

    private static let fractionalDateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plainDateStyle = Date.ISO8601FormatStyle()

    /// Parses ISO 8601 timestamps such as `2026-03-02T23:31:07.048+00:00`,
    /// with or without fractional seconds.
    static func parseDate(_ string: String) -> Date? {
        if let date = try? Date(string, strategy: fractionalDateStyle) {
            return date
        }
        return try? Date(string, strategy: plainDateStyle)
    }

    /// Normalizes text for case- and diacritic-insensitive searching.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Decodes a file containing either an array of records or a single record.
    static func decodeList(from data: Data) throws -> [JobPosting] {
        let decoder = JSONDecoder()
        if let list = try? decoder.decode([JobPosting].self, from: data) {
            return list
        }
        return [try decoder.decode(JobPosting.self, from: data)]
    }

    private static func makeSalaryText(raw: String?, min: Double?, max: Double?, currency: String?) -> String {
        if let raw, !raw.isEmpty { return raw }
        func format(_ value: Double) -> String {
            if let currency {
                return value.formatted(.currency(code: currency).precision(.fractionLength(0)))
            }
            return value.formatted(.number.precision(.fractionLength(0)))
        }
        switch (min, max) {
        case let (min?, max?) where min != max: return "\(format(min)) – \(format(max))"
        case let (min?, _): return format(min)
        case let (nil, max?): return format(max)
        default: return ""
        }
    }
}
