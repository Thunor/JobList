//
//  SpreadsheetImport.swift
//  JobList
//

import Foundation

/// Reads job postings from the first worksheet of an Excel workbook (.xlsx).
///
/// The first non-empty row holds the column headers, which are matched by name to job
/// fields. Both the JSON field names (`minAmount`) and the titles written by Export to
/// Excel (`Min Salary`) are recognized, so exported spreadsheets can be imported again.
/// Columns that don't match a field are ignored.
nonisolated enum XLSXReader {
    enum ReadError: LocalizedError {
        case notWorkbook
        case unsupportedCompression
        case noTitleColumn

        var errorDescription: String? {
            switch self {
            case .notWorkbook: "The file isn’t a valid Excel workbook."
            case .unsupportedCompression: "The workbook uses an unsupported compression method."
            case .noTitleColumn: "The first worksheet has no “title” column."
            }
        }
    }

    /// Parses the first worksheet in `data`, passing records to `insert` in batches of
    /// `batchSize` so the whole sheet is never held as records at once.
    static func readJobs(
        from data: Data,
        batchSize: Int,
        progress: @escaping (Double) -> Void,
        insert: @escaping ([JobPosting]) throws -> Void
    ) throws {
        let archive = try ZipReader(data: data)
        let workbook = try WorkbookInfo(archive: archive)
        let sharedStrings = try archive.contents(of: "xl/sharedStrings.xml").map(SharedStringsParser.parse) ?? []
        guard let sheet = try archive.contents(of: workbook.firstSheetPath) else { throw ReadError.notWorkbook }

        let parser = SheetParser(
            sharedStrings: sharedStrings, uses1904Dates: workbook.uses1904Dates,
            batchSize: batchSize, progress: progress, insert: insert
        )
        try parser.parse(sheet)
    }
}

// MARK: - Columns

/// The job field a spreadsheet column holds.
private nonisolated enum Field {
    case title, company, applyUrl, source, postedAt, tags, countries, rawLocation
    case compType, minAmount, maxAmount, currency, rawSalaryText, workMode, categories

    /// Header names, lowercased with spaces and punctuation removed.
    private static let byHeader: [String: Field] = [
        "title": .title, "jobtitle": .title,
        "company": .company,
        "applyurl": .applyUrl, "applylink": .applyUrl, "url": .applyUrl,
        "source": .source,
        "postedat": .postedAt, "posted": .postedAt, "dateposted": .postedAt,
        "tags": .tags,
        "countries": .countries, "country": .countries,
        "rawlocation": .rawLocation, "location": .rawLocation,
        "comptype": .compType,
        "minamount": .minAmount, "minsalary": .minAmount,
        "maxamount": .maxAmount, "maxsalary": .maxAmount,
        "currency": .currency,
        "rawsalarytext": .rawSalaryText, "salary": .rawSalaryText,
        "workmode": .workMode,
        "categories": .categories, "category": .categories,
    ]

    static func matching(_ header: String) -> Field? {
        byHeader[header.lowercased().filter { $0.isLetter || $0.isNumber }]
    }
}

private nonisolated enum CellValue {
    case text(String)
    case number(Double)

    var text: String {
        switch self {
        case .text(let text):
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .number(let value):
            // Whole numbers such as IDs or years shouldn't gain a trailing ".0".
            if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
            return String(value)
        }
    }

    var number: Double? {
        switch self {
        case .number(let value): value
        case .text(let text): Double(text.trimmingCharacters(in: .whitespaces).replacing(",", with: ""))
        }
    }
}

// MARK: - Worksheet

/// Streams a worksheet's XML, turning each row after the header into a job posting.
private nonisolated final class SheetParser: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    /// Excel serial day number of 1970-01-01 in the workbook's date system.
    private let unixEpochSerial: Double
    private let batchSize: Int
    private let progress: (Double) -> Void
    private let insert: ([JobPosting]) throws -> Void

    /// Fields by zero-based column index, set once the header row has been read.
    private var columns: [Int: Field]?
    private var batch: [JobPosting] = []
    private var rowsRead = 0
    /// The sheet's row count from its `<dimension>` element, for progress reporting.
    private var expectedRows = 0
    private var failure: Error?

    private var cells: [Int: CellValue] = [:]
    private var nextColumn = 0
    private var cellColumn = 0
    private var cellType: String?
    private var text = ""
    private var isCollectingText = false
    /// Phonetic guides (`<rPh>`) contain `<t>` elements that aren't part of the value.
    private var isInPhonetic = false

    init(
        sharedStrings: [String],
        uses1904Dates: Bool,
        batchSize: Int,
        progress: @escaping (Double) -> Void,
        insert: @escaping ([JobPosting]) throws -> Void
    ) {
        self.sharedStrings = sharedStrings
        unixEpochSerial = uses1904Dates ? 24_107 : 25_569
        self.batchSize = batchSize
        self.progress = progress
        self.insert = insert
    }

    func parse(_ data: Data) throws {
        let parser = XMLParser(data: data)
        parser.delegate = self
        let succeeded = parser.parse()
        if let failure { throw failure }
        guard succeeded else { throw parser.parserError ?? XLSXReader.ReadError.notWorkbook }
        guard columns != nil else { throw XLSXReader.ReadError.noTitleColumn }
        try insert(batch)
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String] = [:]
    ) {
        switch localName(elementName) {
        case "row":
            cells = [:]
            nextColumn = 0
        case "c":
            cellColumn = attributes["r"].flatMap(Self.columnIndex) ?? nextColumn
            cellType = attributes["t"]
            text = ""
        case "v":
            isCollectingText = true
        case "t":
            isCollectingText = !isInPhonetic
        case "rPh":
            isInPhonetic = true
        case "dimension":
            // "A1:O61947" → 61947.
            if let ref = attributes["ref"], let end = ref.split(separator: ":").last {
                expectedRows = Int(end.drop(while: \.isLetter)) ?? 0
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isCollectingText { text += string }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?
    ) {
        switch localName(elementName) {
        case "v", "t":
            isCollectingText = false
        case "rPh":
            isInPhonetic = false
        case "c":
            if let value = cellValue() { cells[cellColumn] = value }
            nextColumn = cellColumn + 1
        case "row":
            do {
                try finishRow()
            } catch {
                failure = error
                parser.abortParsing()
            }
        default:
            break
        }
    }

    private func cellValue() -> CellValue? {
        switch cellType {
        case "s":
            guard let index = Int(text), sharedStrings.indices.contains(index) else { return nil }
            return .text(sharedStrings[index])
        case "b":
            return .text(text == "1" ? "TRUE" : "FALSE")
        case "e":
            // Formula errors such as #N/A.
            return nil
        case "inlineStr", "str", "d":
            return text.isEmpty ? nil : .text(text)
        default:
            if let number = Double(text) { return .number(number) }
            return text.isEmpty ? nil : .text(text)
        }
    }

    private func finishRow() throws {
        rowsRead += 1
        guard let columns else {
            // Leading blank rows are skipped; the first row with content is the header.
            guard !cells.isEmpty else { return }
            let fields = cells.compactMapValues { Field.matching($0.text) }
            guard fields.values.contains(.title) else { throw XLSXReader.ReadError.noTitleColumn }
            self.columns = fields
            return
        }

        if let job = job(from: columns) { batch.append(job) }
        if batch.count >= batchSize {
            try Task.checkCancellation()
            try insert(batch)
            batch.removeAll(keepingCapacity: true)
            if expectedRows > 0 { progress(min(1, Double(rowsRead) / Double(expectedRows))) }
        }
    }

    private func job(from columns: [Int: Field]) -> JobPosting? {
        var values: [Field: CellValue] = [:]
        for (column, value) in cells {
            if let field = columns[column] { values[field] = value }
        }
        guard !values.isEmpty else { return nil }

        func text(_ field: Field) -> String { values[field]?.text ?? "" }
        func optionalText(_ field: Field) -> String? {
            let value = text(field)
            return value.isEmpty ? nil : value
        }
        func list(_ field: Field) -> [String] {
            text(field).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }

        return JobPosting(
            title: text(.title),
            company: text(.company),
            applyUrl: optionalText(.applyUrl).flatMap(URL.init(string:)),
            source: text(.source),
            postedAt: values[.postedAt].flatMap { date(from: $0) },
            tags: list(.tags),
            countries: list(.countries),
            rawLocation: text(.rawLocation),
            compType: optionalText(.compType) ?? "unknown",
            minAmount: values[.minAmount]?.number,
            maxAmount: values[.maxAmount]?.number,
            currency: optionalText(.currency),
            rawSalaryText: optionalText(.rawSalaryText),
            // Exports capitalize work modes; the JSON files use lowercase.
            workMode: text(.workMode).lowercased(),
            categories: list(.categories)
        )
    }

    /// Dates are usually Excel serial day numbers, but may also be ISO 8601 text.
    private func date(from value: CellValue) -> Date? {
        switch value {
        case .number(let serial):
            return Date(timeIntervalSince1970: (serial - unixEpochSerial) * 86_400)
        case .text:
            let text = value.text
            return JobPosting.parseDate(text) ?? (try? Date(text, strategy: .iso8601.year().month().day()))
        }
    }

    /// Zero-based column index from a cell reference: "A1" → 0, "AB12" → 27.
    private static func columnIndex(_ reference: String) -> Int? {
        var index = 0
        for scalar in reference.unicodeScalars {
            guard (65...90).contains(scalar.value) else { break }
            index = index * 26 + Int(scalar.value - 64)
        }
        return index > 0 ? index - 1 : nil
    }
}

/// An element name without its namespace prefix: "x:row" → "row".
private nonisolated func localName(_ name: String) -> Substring {
    name.split(separator: ":").last ?? Substring(name)
}

// MARK: - Workbook structure

/// Locates the first worksheet and reads workbook-wide settings.
private nonisolated struct WorkbookInfo {
    let firstSheetPath: String
    let uses1904Dates: Bool

    init(archive: ZipReader) throws {
        guard let workbook = try archive.contents(of: "xl/workbook.xml") else {
            throw XLSXReader.ReadError.notWorkbook
        }
        var uses1904Dates = false
        var sheetRelationship: String?
        StartElementParser.parse(workbook) { name, attributes in
            if name == "workbookPr", let value = attributes["date1904"] {
                uses1904Dates = value == "1" || value == "true"
            } else if name == "sheet", sheetRelationship == nil {
                sheetRelationship = attributes.first { $0.key.hasSuffix(":id") }?.value
            }
        }

        var sheetPath = "xl/worksheets/sheet1.xml"
        if let sheetRelationship, let rels = try archive.contents(of: "xl/_rels/workbook.xml.rels") {
            StartElementParser.parse(rels) { name, attributes in
                guard name == "Relationship", attributes["Id"] == sheetRelationship,
                      let target = attributes["Target"] else { return }
                // Targets are relative to xl/ unless absolute within the package.
                sheetPath = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            }
        }
        firstSheetPath = sheetPath
        self.uses1904Dates = uses1904Dates
    }
}

/// Collects the text of each `<si>` in the shared string table.
private nonisolated final class SharedStringsParser: NSObject, XMLParserDelegate {
    private var strings: [String] = []
    private var current = ""
    private var isCollectingText = false
    private var isInPhonetic = false

    static func parse(_ data: Data) throws -> [String] {
        let delegate = SharedStringsParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw parser.parserError ?? XLSXReader.ReadError.notWorkbook }
        return delegate.strings
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String] = [:]
    ) {
        switch localName(elementName) {
        case "si": current = ""
        case "t": isCollectingText = !isInPhonetic
        case "rPh": isInPhonetic = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isCollectingText { current += string }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?
    ) {
        switch localName(elementName) {
        case "si": strings.append(current)
        case "t": isCollectingText = false
        case "rPh": isInPhonetic = false
        default: break
        }
    }
}

/// Reports each element's name (without namespace prefix) and attributes.
private nonisolated final class StartElementParser: NSObject, XMLParserDelegate {
    private let handler: (String, [String: String]) -> Void

    private init(handler: @escaping (String, [String: String]) -> Void) {
        self.handler = handler
    }

    static func parse(_ data: Data, handler: @escaping (String, [String: String]) -> Void) {
        let delegate = StartElementParser(handler: handler)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String] = [:]
    ) {
        handler(String(localName(elementName)), attributes)
    }
}

// MARK: - ZIP

/// Reads entries from a ZIP archive held in memory (or memory-mapped).
///
/// Supports stored and DEFLATE-compressed entries, which is all Office files use.
/// ZIP64 archives (over 4 GB) aren't supported.
nonisolated struct ZipReader {
    private struct Entry {
        let method: UInt16
        let compressedSize: Int
        let localHeaderOffset: Int
    }

    private let data: Data
    private var entries: [String: Entry] = [:]

    init(data: Data) throws {
        self.data = data
        guard data.count >= 22 else { throw XLSXReader.ReadError.notWorkbook }

        // The end-of-central-directory record is the last 22 bytes plus an optional comment.
        var end = data.count - 22
        let lowest = max(0, end - 65_535)
        while end >= lowest, u32(at: end) != 0x0605_4B50 { end -= 1 }
        guard end >= lowest else { throw XLSXReader.ReadError.notWorkbook }

        let count = Int(u16(at: end + 10))
        var offset = Int(u32(at: end + 16))
        for _ in 0..<count {
            guard offset + 46 <= data.count, u32(at: offset) == 0x0201_4B50 else {
                throw XLSXReader.ReadError.notWorkbook
            }
            let nameLength = Int(u16(at: offset + 28))
            let extraLength = Int(u16(at: offset + 30))
            let commentLength = Int(u16(at: offset + 32))
            let nameStart = data.startIndex + offset + 46
            guard nameStart + nameLength <= data.endIndex else { throw XLSXReader.ReadError.notWorkbook }
            let name = String(decoding: data[nameStart..<nameStart + nameLength], as: UTF8.self)
            entries[name] = Entry(
                method: u16(at: offset + 10),
                compressedSize: Int(u32(at: offset + 20)),
                localHeaderOffset: Int(u32(at: offset + 42))
            )
            offset += 46 + nameLength + extraLength + commentLength
        }
    }

    /// The decompressed contents of the entry at `path`, or `nil` if there is none.
    func contents(of path: String) throws -> Data? {
        guard let entry = entries[path] else { return nil }
        let header = entry.localHeaderOffset
        guard header + 30 <= data.count, u32(at: header) == 0x0403_4B50 else {
            throw XLSXReader.ReadError.notWorkbook
        }
        let start = header + 30 + Int(u16(at: header + 26)) + Int(u16(at: header + 28))
        guard start + entry.compressedSize <= data.count else { throw XLSXReader.ReadError.notWorkbook }
        let raw = data.subdata(in: data.startIndex + start..<data.startIndex + start + entry.compressedSize)

        switch entry.method {
        case 0:
            return raw
        case 8:
            // Apple's zlib algorithm is raw DEFLATE, exactly what ZIP entries contain.
            return try (raw as NSData).decompressed(using: .zlib) as Data
        default:
            throw XLSXReader.ReadError.unsupportedCompression
        }
    }

    private func u16(at offset: Int) -> UInt16 {
        let i = data.startIndex + offset
        return UInt16(data[i]) | UInt16(data[i + 1]) << 8
    }

    private func u32(at offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        return UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24
    }
}
