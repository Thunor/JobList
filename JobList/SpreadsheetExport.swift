//
//  SpreadsheetExport.swift
//  JobList
//

import Compression
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// Excel workbook (.xlsx). Declared by the system, so no Info.plist entry is needed.
    nonisolated static let xlsx = UTType(importedAs: "org.openxmlformats.spreadsheetml.sheet")
}

/// A set of jobs that can be saved as an Excel workbook via `fileExporter`.
///
/// Holds only the job IDs; records are read from the database in batches while writing.
nonisolated struct JobSpreadsheet: Transferable {
    let ids: [Int64]
    let database: JobDatabase
    /// File name without extension. The exporter's file wrapper requires a non-empty name.
    var name = "Jobs"

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .xlsx) { spreadsheet in
            let url = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).xlsx")
            let ids = spreadsheet.ids
            let database = spreadsheet.database
            try await XLSXWriter.write(count: ids.count, to: url) { range in
                try database.jobs(withIDs: Array(ids[range]))
            }
            return SentTransferredFile(url)
        }
        .suggestedFileName { $0.name.isEmpty ? "Jobs.xlsx" : "\($0.name).xlsx" }
    }
}

/// Writes jobs to a minimal Office Open XML workbook.
///
/// The worksheet is streamed through a DEFLATE compressor straight to disk, so exporting
/// a million rows never holds the whole sheet in memory. Rows beyond Excel's per-sheet
/// limit continue on additional sheets.
nonisolated enum XLSXWriter {
    /// Excel allows 1,048,576 rows per sheet; one is used by the header.
    static let maxRowsPerSheet = 1_048_575

    private enum Value {
        case text(String)
        case number(Double?)
        case date(Date?)
    }

    private static let columns: [(title: String, width: Int, value: (JobPosting) -> Value)] = [
        ("Title", 45, { .text($0.title) }),
        ("Company", 25, { .text($0.company) }),
        ("Source", 12, { .text($0.source) }),
        ("Posted", 18, { .date($0.postedAt) }),
        ("Work Mode", 12, { .text($0.workMode.capitalized) }),
        ("Location", 35, { .text($0.rawLocation) }),
        ("Countries", 20, { .text($0.countriesText) }),
        ("Tags", 25, { .text($0.tagsText) }),
        ("Categories", 20, { .text($0.categoriesText) }),
        ("Comp Type", 12, { .text($0.compType) }),
        ("Min Salary", 12, { .number($0.minAmount) }),
        ("Max Salary", 12, { .number($0.maxAmount) }),
        ("Currency", 10, { .text($0.currency ?? "") }),
        ("Salary", 25, { .text($0.salaryText) }),
        ("Apply URL", 50, { .text($0.applyUrl?.absoluteString ?? "") }),
    ]

    /// Records requested from `rows` at a time while writing.
    static let batchSize = 1_000

    static func write(_ jobs: [JobPosting], to url: URL) async throws {
        try await write(count: jobs.count, to: url) { Array(jobs[$0]) }
    }

    /// Writes `count` jobs, fetching them in order a batch at a time from `rows`,
    /// so the full set never needs to be in memory.
    @concurrent
    static func write(count: Int, to url: URL, rows: @Sendable (Range<Int>) throws -> [JobPosting]) async throws {
        let sheetCount = max(1, (count + maxRowsPerSheet - 1) / maxRowsPerSheet)
        let sheetNames = (1...sheetCount).map { $0 == 1 ? "Jobs" : "Jobs \($0)" }

        let zip = try ZipWriter(url: url)
        try zip.addFile("[Content_Types].xml", contents: contentTypes(sheetCount: sheetCount))
        try zip.addFile("_rels/.rels", contents: rootRelationships)
        try zip.addFile("xl/workbook.xml", contents: workbook(sheetNames: sheetNames))
        try zip.addFile("xl/_rels/workbook.xml.rels", contents: workbookRelationships(sheetCount: sheetCount))
        try zip.addFile("xl/styles.xml", contents: styles)

        for sheet in 0..<sheetCount {
            try Task.checkCancellation()
            let range = min(count, sheet * maxRowsPerSheet)..<min(count, (sheet + 1) * maxRowsPerSheet)
            try zip.addFile("xl/worksheets/sheet\(sheet + 1).xml") { output in
                try writeSheet(range, rows: rows, to: output)
            }
        }
        try zip.finish()
    }

    // MARK: Worksheet

    private static func writeSheet(
        _ range: Range<Int>,
        rows: (Range<Int>) throws -> [JobPosting],
        to output: ZipWriter.EntryOutput
    ) throws {
        let lastColumn = columnName(columns.count - 1)
        var xml = XMLBuffer()
        xml.append("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <dimension ref="A1:\(lastColumn)\(range.count + 1)"/>\
        <sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>\
        <cols>
        """)
        for (index, column) in columns.enumerated() {
            xml.append("<col min=\"\(index + 1)\" max=\"\(index + 1)\" width=\"\(column.width)\" customWidth=\"1\"/>")
        }
        xml.append("</cols><sheetData><row>")
        for column in columns {
            xml.append("<c t=\"inlineStr\" s=\"2\"><is><t>")
            xml.appendEscaped(column.title)
            xml.append("</t></is></c>")
        }
        xml.append("</row>")

        for batchStart in stride(from: range.lowerBound, to: range.upperBound, by: batchSize) {
            try Task.checkCancellation()
            for job in try rows(batchStart..<min(range.upperBound, batchStart + batchSize)) {
                xml.append("<row>")
                for column in columns {
                    switch column.value(job) {
                    case .text(""), .number(nil), .date(nil):
                        xml.append("<c/>")
                    case .text(let text):
                        xml.append("<c t=\"inlineStr\"><is><t xml:space=\"preserve\">")
                        xml.appendEscaped(text)
                        xml.append("</t></is></c>")
                    case .number(let value?):
                        xml.append("<c><v>\(value)</v></c>")
                    case .date(let date?):
                        // Excel stores dates as days since 1899-12-30.
                        xml.append("<c s=\"1\"><v>\(date.timeIntervalSince1970 / 86_400 + 25_569)</v></c>")
                    }
                }
                xml.append("</row>")
                if xml.bytes.count > 1 << 20 {
                    try output.write(xml.bytes)
                    xml.bytes.removeAll(keepingCapacity: true)
                }
            }
        }
        xml.append("</sheetData><autoFilter ref=\"A1:\(lastColumn)\(range.count + 1)\"/></worksheet>")
        try output.write(xml.bytes)
    }

    /// Spreadsheet column letters: 0 → "A", 25 → "Z", 26 → "AA".
    private static func columnName(_ index: Int) -> String {
        var index = index
        var name = ""
        repeat {
            name.insert(Character(UnicodeScalar(UInt8(65 + index % 26))), at: name.startIndex)
            index = index / 26 - 1
        } while index >= 0
        return name
    }

    // MARK: Package parts

    private static func contentTypes(sheetCount: Int) -> String {
        let sheets = (1...sheetCount).map {
            "<Override PartName=\"/xl/worksheets/sheet\($0).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
        \(sheets)</Types>
        """
    }

    private static let rootRelationships = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
        </Relationships>
        """

    private static func workbook(sheetNames: [String]) -> String {
        let sheets = sheetNames.enumerated().map { index, name in
            "<sheet name=\"\(name)\" sheetId=\"\(index + 1)\" r:id=\"rId\(index + 1)\"/>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <sheets>\(sheets)</sheets></workbook>
        """
    }

    private static func workbookRelationships(sheetCount: Int) -> String {
        let sheets = (1...sheetCount).map {
            "<Relationship Id=\"rId\($0)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0).xml\"/>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        \(sheets)\
        <Relationship Id="rId\(sheetCount + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
        </Relationships>
        """
    }

    /// Style 0 is the default, 1 formats dates, and 2 is the bold header.
    private static let styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <numFmts count="1"><numFmt numFmtId="164" formatCode="yyyy-mm-dd hh:mm"/></numFmts>\
        <fonts count="2"><font><sz val="12"/><name val="Calibri"/></font><font><b/><sz val="12"/><name val="Calibri"/></font></fonts>\
        <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\
        <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
        <cellXfs count="3">\
        <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>\
        <xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>\
        <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>\
        </cellXfs></styleSheet>
        """
}

/// A UTF-8 byte buffer with XML escaping.
private nonisolated struct XMLBuffer {
    var bytes: [UInt8] = []

    init() { bytes.reserveCapacity(1 << 21) }

    mutating func append(_ string: String) {
        bytes.append(contentsOf: string.utf8)
    }

    /// Escapes markup characters and drops control characters, which XML 1.0 forbids.
    /// Text is cut at Excel's 32,767-character cell limit.
    mutating func appendEscaped(_ string: String) {
        var count = 0
        for scalar in string.unicodeScalars {
            count += 1
            if count > 32_767 { break }
            switch scalar {
            case "&": append("&amp;")
            case "<": append("&lt;")
            case ">": append("&gt;")
            case "\"": append("&quot;")
            case "\t", "\n", "\r": bytes.append(UInt8(scalar.value))
            default:
                if scalar.value < 0x20 || scalar.value == 0xFFFE || scalar.value == 0xFFFF { continue }
                bytes.append(contentsOf: String(scalar).utf8)
            }
        }
    }
}

// MARK: - ZIP

/// Writes a ZIP archive with DEFLATE-compressed entries, patching each local header
/// with its CRC and sizes once the entry is complete.
nonisolated final class ZipWriter {
    enum ZipError: LocalizedError {
        case tooLarge
        var errorDescription: String? { "The export is too large for a spreadsheet file (over 4 GB)." }
    }

    private struct Entry {
        let name: [UInt8]
        let offset: UInt32
        let crc: UInt32
        let compressedSize: UInt32
        let size: UInt32
    }

    private let handle: FileHandle
    private var entries: [Entry] = []
    private let dosTime: UInt16
    private let dosDate: UInt16

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: .now)
        dosTime = UInt16((parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | (parts.second ?? 0) / 2)
        dosDate = UInt16(max(0, (parts.year ?? 1980) - 1980) << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1))
    }

    deinit { try? handle.close() }

    /// Receives an entry's uncompressed bytes.
    final class EntryOutput {
        fileprivate var crc = CRC32()
        fileprivate var size: UInt64 = 0
        fileprivate let filter: OutputFilter

        fileprivate init(filter: OutputFilter) { self.filter = filter }

        func write(_ bytes: [UInt8]) throws {
            crc.update(bytes)
            size += UInt64(bytes.count)
            try bytes.withUnsafeBytes { try filter.write($0) }
        }
    }

    func addFile(_ name: String, contents: String) throws {
        try addFile(name) { try $0.write(Array(contents.utf8)) }
    }

    func addFile(_ name: String, body: (EntryOutput) throws -> Void) throws {
        let nameBytes = Array(name.utf8)
        let offset = try handle.offset()
        guard offset <= UInt32.max else { throw ZipError.tooLarge }

        // Local file header; CRC and sizes are filled in after the data is written.
        var header = Data()
        header.appendLE(UInt32(0x0403_4B50))
        header.appendLE(UInt16(20))         // version needed
        header.appendLE(UInt16(0))          // flags
        header.appendLE(UInt16(8))          // DEFLATE
        header.appendLE(dosTime)
        header.appendLE(dosDate)
        header.append(Data(count: 12))      // CRC, compressed size, size
        header.appendLE(UInt16(nameBytes.count))
        header.appendLE(UInt16(0))          // extra field length
        header.append(contentsOf: nameBytes)
        try handle.write(contentsOf: header)

        var compressedSize: UInt64 = 0
        let filter = try OutputFilter(.compress, using: .zlib) { [handle] chunk in
            if let chunk {
                compressedSize += UInt64(chunk.count)
                try handle.write(contentsOf: chunk)
            }
        }
        let output = EntryOutput(filter: filter)
        try body(output)
        try filter.finalize()

        guard compressedSize <= UInt32.max, output.size <= UInt32.max else { throw ZipError.tooLarge }
        let entry = Entry(name: nameBytes, offset: UInt32(offset), crc: output.crc.value,
                          compressedSize: UInt32(compressedSize), size: UInt32(output.size))
        entries.append(entry)

        let end = try handle.offset()
        var sizes = Data()
        sizes.appendLE(entry.crc)
        sizes.appendLE(entry.compressedSize)
        sizes.appendLE(entry.size)
        try handle.seek(toOffset: offset + 14)
        try handle.write(contentsOf: sizes)
        try handle.seek(toOffset: end)
    }

    func finish() throws {
        let directoryOffset = try handle.offset()
        var directory = Data()
        for entry in entries {
            directory.appendLE(UInt32(0x0201_4B50))
            directory.appendLE(UInt16(20))  // version made by
            directory.appendLE(UInt16(20))  // version needed
            directory.appendLE(UInt16(0))   // flags
            directory.appendLE(UInt16(8))   // DEFLATE
            directory.appendLE(dosTime)
            directory.appendLE(dosDate)
            directory.appendLE(entry.crc)
            directory.appendLE(entry.compressedSize)
            directory.appendLE(entry.size)
            directory.appendLE(UInt16(entry.name.count))
            directory.append(Data(count: 12)) // extra, comment, disk, internal & external attributes
            directory.appendLE(entry.offset)
            directory.append(contentsOf: entry.name)
        }
        guard directoryOffset + UInt64(directory.count) <= UInt32.max else { throw ZipError.tooLarge }

        directory.appendLE(UInt32(0x0605_4B50))
        directory.append(Data(count: 4))    // disk numbers
        directory.appendLE(UInt16(entries.count))
        directory.appendLE(UInt16(entries.count))
        directory.appendLE(UInt32(directory.count - 12))
        directory.appendLE(UInt32(directoryOffset))
        directory.appendLE(UInt16(0))       // comment length
        try handle.write(contentsOf: directory)
        try handle.close()
    }
}

/// The CRC-32 checksum used by ZIP.
private nonisolated struct CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    private var state: UInt32 = 0xFFFF_FFFF

    var value: UInt32 { ~state }

    mutating func update(_ bytes: [UInt8]) {
        Self.table.withUnsafeBufferPointer { table in
            var crc = state
            for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
            state = crc
        }
    }
}

private extension Data {
    nonisolated mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
