//
//  Spreadsheet.swift
//  JobList
//

import Foundation

/// Reads and writes single-sheet Excel workbooks (`.xlsx`).
nonisolated enum Spreadsheet {
    /// A cell value to write.
    enum Cell {
        case text(String)
        case number(Double)
        case date(Date)
    }

    enum Error: LocalizedError {
        case missingPart(String)

        var errorDescription: String? {
            switch self {
            case .missingPart(let path): "The workbook is missing “\(path)”."
            }
        }
    }

    // MARK: Reading

    /// The text of every cell in the first worksheet. Rows are padded only as far as their last non-empty cell.
    struct Sheet {
        var rows: [[String]]
        /// Whether date serial numbers count from 1904 rather than 1900.
        var uses1904Dates: Bool

        func date(fromSerial serial: Double) -> Date {
            Spreadsheet.date(fromSerial: serial, uses1904Dates: uses1904Dates)
        }
    }

    static func readFirstSheet(from data: Data) throws -> Sheet {
        let zip = try ZipReader(data)

        // Follow the package relationships: root → workbook → first worksheet and shared strings.
        let rootRelationships = try relationships(for: "", in: zip)
        let workbookPath = rootRelationships.values.first { $0.type.hasSuffix("/officeDocument") }?.target ?? "xl/workbook.xml"
        guard let workbookData = try zip.contents(of: workbookPath) else { throw Error.missingPart(workbookPath) }

        var workbook = WorkbookHandler()
        XMLScanner.scan(workbookData, into: &workbook)

        let workbookRelationships = try relationships(for: workbookPath, in: zip)
        let sheetPath = workbook.firstSheetRelationshipID.flatMap { workbookRelationships[$0]?.target }
            ?? "xl/worksheets/sheet1.xml"
        guard let sheetData = try zip.contents(of: sheetPath) else { throw Error.missingPart(sheetPath) }

        var sharedStrings: [String] = []
        if let path = workbookRelationships.values.first(where: { $0.type.hasSuffix("/sharedStrings") })?.target,
           let stringsData = try zip.contents(of: path) {
            var handler = SharedStringsHandler()
            XMLScanner.scan(stringsData, into: &handler)
            sharedStrings = handler.strings
        }

        var sheet = WorksheetHandler(sharedStrings: sharedStrings)
        XMLScanner.scan(sheetData, into: &sheet)
        return Sheet(rows: sheet.rows, uses1904Dates: workbook.uses1904Dates)
    }

    private struct Relationship {
        var type: String
        var target: String
    }

    /// Reads the relationships of the part at `partPath`, keyed by ID, with targets resolved to archive paths.
    private static func relationships(for partPath: String, in zip: ZipReader) throws -> [String: Relationship] {
        let directory = partPath.split(separator: "/").dropLast().joined(separator: "/")
        let fileName = partPath.split(separator: "/").last.map(String.init) ?? ""
        let relsPath = (directory.isEmpty ? "" : directory + "/") + "_rels/\(fileName).rels"
        guard let data = try zip.contents(of: relsPath) else { return [:] }

        var handler = RelationshipsHandler()
        XMLScanner.scan(data, into: &handler)
        return handler.relationships.mapValues {
            Relationship(type: $0.type, target: resolve($0.target, relativeTo: directory))
        }
    }

    private static func resolve(_ target: String, relativeTo directory: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        var parts = directory.split(separator: "/")
        for component in target.split(separator: "/") {
            switch component {
            case "..": _ = parts.popLast()
            case ".": break
            default: parts.append(component)
            }
        }
        return parts.joined(separator: "/")
    }

    // MARK: Writing

    /// Builds a workbook with one sheet. The first row is the bold, frozen header row with filter buttons.
    static func write(header: [String], rows: [[Cell?]], columnWidths: [Double], sheetName: String) throws -> Data {
        let lastColumn = columnName(max(header.count, 1) - 1)
        let lastRow = rows.count + 1

        var sheet = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
            <dimension ref="A1:\(lastColumn)\(lastRow)"/>\
            <sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/>\
            </sheetView></sheetViews><cols>
            """
        for (index, width) in columnWidths.enumerated() {
            sheet += #"<col min="\#(index + 1)" max="\#(index + 1)" width="\#(width)" customWidth="1"/>"#
        }
        sheet += "</cols><sheetData>"

        let columnNames = (0..<max(header.count, rows.lazy.map(\.count).max() ?? 0)).map(columnName)
        func appendRow(_ cells: [Cell?], number: Int, style: Int?) {
            sheet += #"<row r="\#(number)">"#
            for (index, cell) in cells.enumerated() {
                guard let cell else { continue }
                let ref = "\(columnNames[index])\(number)"
                switch cell {
                case .text(let text):
                    guard !text.isEmpty else { continue }
                    let styleAttribute = style.map { #" s="\#($0)""# } ?? ""
                    let space = text.first?.isWhitespace == true || text.last?.isWhitespace == true
                        ? #" xml:space="preserve""# : ""
                    sheet += #"<c r="\#(ref)"\#(styleAttribute) t="inlineStr"><is><t\#(space)>\#(escape(text))</t></is></c>"#
                case .number(let value) where value.isFinite:
                    sheet += #"<c r="\#(ref)"><v>\#(value)</v></c>"#
                case .number:
                    continue
                case .date(let date):
                    sheet += #"<c r="\#(ref)" s="2"><v>\#(serial(from: date))</v></c>"#
                }
            }
            sheet += "</row>"
        }

        appendRow(header.map(Cell.text), number: 1, style: 1)
        for (index, row) in rows.enumerated() {
            appendRow(row, number: index + 2, style: nil)
        }
        sheet += #"</sheetData><autoFilter ref="A1:\#(lastColumn)\#(lastRow)"/></worksheet>"#

        let name = sanitizedSheetName(sheetName)
        let quotedName = "'" + name.replacingOccurrences(of: "'", with: "''") + "'"
        let workbook = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
            <sheets><sheet name="\(escape(name))" sheetId="1" r:id="rId1"/></sheets>\
            <definedNames><definedName name="_xlnm._FilterDatabase" localSheetId="0" hidden="1">\
            \(escape(quotedName))!$A$1:$\(lastColumn)$\(lastRow)</definedName></definedNames>\
            </workbook>
            """

        var zip = ZipWriter()
        try zip.add("[Content_Types].xml", contents: Data(contentTypesXML.utf8))
        try zip.add("_rels/.rels", contents: Data(rootRelationshipsXML.utf8))
        try zip.add("xl/workbook.xml", contents: Data(workbook.utf8))
        try zip.add("xl/_rels/workbook.xml.rels", contents: Data(workbookRelationshipsXML.utf8))
        try zip.add("xl/styles.xml", contents: Data(stylesXML.utf8))
        try zip.add("xl/worksheets/sheet1.xml", contents: Data(sheet.utf8))
        return try zip.finish()
    }

    /// Converts a zero-based column index to its letter name (0 → "A", 26 → "AA").
    static func columnName(_ index: Int) -> String {
        var index = index + 1
        var name = ""
        while index > 0 {
            let remainder = (index - 1) % 26
            name.insert(Character(Unicode.Scalar(UInt8(65 + remainder))), at: name.startIndex)
            index = (index - 1) / 26
        }
        return name
    }

    /// Excel sheet names are limited to 31 characters and can't contain `[ ] : * ? / \`.
    private static func sanitizedSheetName(_ name: String) -> String {
        let cleaned = String(name.map { "[]:*?/\\".contains($0) ? "_" : $0 }.prefix(31))
            .trimmingCharacters(in: CharacterSet(charactersIn: "' "))
        return cleaned.isEmpty ? "Sheet1" : cleaned
    }

    /// Escapes text for XML. Control characters that XML can't represent use Excel's `_xHHHH_` escape.
    private static func escape(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { "&<>\"".unicodeScalars.contains($0) || $0.value < 0x20 }) else {
            return text
        }
        var result = ""
        result.reserveCapacity(text.utf8.count + 16)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "\t", "\n", "\r": result.unicodeScalars.append(scalar)
            case _ where scalar.value < 0x20:
                result += "_x" + String(format: "%04X", scalar.value) + "_"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    // MARK: Dates

    // Excel stores dates as days since an epoch, with no time zone; UTC is used here.
    // The 1900 system's epoch is 1899-12-30 to account for Excel's fictional 1900-02-29.
    private static let epoch1900 = Date(timeIntervalSince1970: -2_209_161_600)
    private static let epoch1904 = Date(timeIntervalSince1970: -2_082_844_800)

    static func date(fromSerial serial: Double, uses1904Dates: Bool) -> Date {
        (uses1904Dates ? epoch1904 : epoch1900).addingTimeInterval(serial * 86_400)
    }

    static func serial(from date: Date) -> Double {
        date.timeIntervalSince(epoch1900) / 86_400
    }

    // MARK: Package parts

    private static let contentTypesXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
        </Types>
        """

    private static let rootRelationshipsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
        </Relationships>
        """

    private static let workbookRelationshipsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>\
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
        </Relationships>
        """

    /// Cell style 0 is the default, 1 is bold (header), 2 is a date and time.
    private static let stylesXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <numFmts count="1"><numFmt numFmtId="164" formatCode="yyyy-mm-dd hh:mm"/></numFmts>\
        <fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>\
        <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\
        <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
        <cellXfs count="3"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>\
        <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>\
        <xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/></cellXfs>\
        <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>\
        </styleSheet>
        """
}

// MARK: - XML scanning

/// Receives events from `XMLScanner`. Names are local names, without any namespace prefix.
private nonisolated protocol XMLScanHandler {
    mutating func didOpen(_ tag: XMLTag)
    mutating func didClose(_ name: String)
    /// Raw, still entity-encoded character data between tags.
    mutating func didFindText(_ bytes: UnsafeRawBufferPointer)
}

private nonisolated struct XMLTag {
    let name: String
    let attributes: UnsafeRawBufferPointer

    /// The decoded value of the attribute whose local name is `localName`.
    func attribute(_ localName: String) -> String? {
        let a = attributes
        let n = a.count
        var i = 0
        while i < n {
            while i < n, XMLScanner.isWhitespace(a[i]) { i += 1 }
            let nameStart = i
            while i < n, a[i] != UInt8(ascii: "="), !XMLScanner.isWhitespace(a[i]) { i += 1 }
            let nameEnd = i
            while i < n, a[i] != UInt8(ascii: "\""), a[i] != UInt8(ascii: "'") { i += 1 }
            guard i < n else { return nil }
            let quote = a[i]
            i += 1
            let valueStart = i
            while i < n, a[i] != quote { i += 1 }
            let valueEnd = min(i, n)
            i += 1
            if XMLScanner.localName(UnsafeRawBufferPointer(rebasing: a[nameStart..<nameEnd])).elementsEqual(localName.utf8) {
                return XMLScanner.decode(UnsafeRawBufferPointer(rebasing: a[valueStart..<valueEnd]))
            }
        }
        return nil
    }
}

/// A fast, forgiving, non-validating XML tokenizer for the well-formed parts inside an `.xlsx`.
/// Worksheets can be tens of megabytes, which makes `XMLParser` noticeably slow.
private nonisolated enum XMLScanner {
    static func scan<Handler: XMLScanHandler>(_ data: Data, into handler: inout Handler) {
        data.withUnsafeBytes { buffer in
            let n = buffer.count
            guard let base = buffer.baseAddress else { return }
            var i = 0

            func find(_ pattern: [UInt8], from start: Int) -> Int {
                var j = start
                while j + pattern.count <= n {
                    if buffer[j] == pattern[0], (1..<pattern.count).allSatisfy({ buffer[j + $0] == pattern[$0] }) {
                        return j
                    }
                    j += 1
                }
                return n
            }

            while i < n {
                // Character data up to the next tag.
                let textStart = i
                if let found = memchr(base + i, Int32(UInt8(ascii: "<")), n - i) {
                    i = base.distance(to: found)
                } else {
                    i = n
                }
                if i > textStart {
                    handler.didFindText(UnsafeRawBufferPointer(rebasing: buffer[textStart..<i]))
                }
                guard i + 1 < n else { break }
                i += 1

                switch buffer[i] {
                case UInt8(ascii: "?"):
                    i = find(Array("?>".utf8), from: i) + 2
                case UInt8(ascii: "!"):
                    if find(Array("![CDATA[".utf8), from: i) == i {
                        let end = find(Array("]]>".utf8), from: i + 8)
                        handler.didFindText(UnsafeRawBufferPointer(rebasing: buffer[(i + 8)..<end]))
                        i = end + 3
                    } else if find(Array("!--".utf8), from: i) == i {
                        i = find(Array("-->".utf8), from: i + 3) + 3
                    } else {
                        i = find([UInt8(ascii: ">")], from: i) + 1
                    }
                case UInt8(ascii: "/"):
                    let nameStart = i + 1
                    i = nameStart
                    while i < n, buffer[i] != UInt8(ascii: ">"), !isWhitespace(buffer[i]) { i += 1 }
                    let name = localName(UnsafeRawBufferPointer(rebasing: buffer[nameStart..<i]))
                    while i < n, buffer[i] != UInt8(ascii: ">") { i += 1 }
                    i += 1
                    handler.didClose(String(decoding: name, as: UTF8.self))
                default:
                    let nameStart = i
                    while i < n, buffer[i] != UInt8(ascii: ">"), buffer[i] != UInt8(ascii: "/"), !isWhitespace(buffer[i]) {
                        i += 1
                    }
                    let name = String(decoding: localName(UnsafeRawBufferPointer(rebasing: buffer[nameStart..<i])), as: UTF8.self)

                    // Find the end of the tag, skipping any `>` inside quoted attribute values.
                    let attributesStart = i
                    var quote: UInt8 = 0
                    while i < n {
                        let byte = buffer[i]
                        if quote != 0 {
                            if byte == quote { quote = 0 }
                        } else if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                            quote = byte
                        } else if byte == UInt8(ascii: ">") {
                            break
                        }
                        i += 1
                    }
                    let isSelfClosing = i > attributesStart && buffer[i - 1] == UInt8(ascii: "/")
                    let attributesEnd = isSelfClosing ? i - 1 : min(i, n)
                    i += 1

                    handler.didOpen(XMLTag(name: name, attributes: UnsafeRawBufferPointer(rebasing: buffer[attributesStart..<attributesEnd])))
                    if isSelfClosing { handler.didClose(name) }
                }
            }
        }
    }

    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
    }

    /// The part of a qualified name after its namespace prefix.
    static func localName(_ name: UnsafeRawBufferPointer) -> UnsafeRawBufferPointer.SubSequence {
        if let colon = name.lastIndex(of: UInt8(ascii: ":")) {
            return name[(colon + 1)...]
        }
        return name[...]
    }

    /// Decodes XML entities and Excel's `_xHHHH_` escapes.
    static func decode(_ bytes: some Collection<UInt8>) -> String {
        guard bytes.contains(UInt8(ascii: "&")) || bytes.contains(UInt8(ascii: "_")) else {
            return String(decoding: bytes, as: UTF8.self)
        }
        let input = Array(bytes)
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        var i = 0

        func appendScalar(_ value: UInt32) {
            if let scalar = Unicode.Scalar(value) {
                output.append(contentsOf: String(Character(scalar)).utf8)
            }
        }

        func isHex(_ byte: UInt8) -> Bool {
            (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
        }

        while i < input.count {
            let byte = input[i]
            if byte == UInt8(ascii: "&"), let semicolon = input[i...].prefix(12).firstIndex(of: UInt8(ascii: ";")) {
                let entity = String(decoding: input[(i + 1)..<semicolon], as: UTF8.self)
                var handled = true
                switch entity {
                case "amp": output.append(UInt8(ascii: "&"))
                case "lt": output.append(UInt8(ascii: "<"))
                case "gt": output.append(UInt8(ascii: ">"))
                case "quot": output.append(UInt8(ascii: "\""))
                case "apos": output.append(UInt8(ascii: "'"))
                default:
                    if entity.hasPrefix("#x") || entity.hasPrefix("#X"), let value = UInt32(entity.dropFirst(2), radix: 16) {
                        appendScalar(value)
                    } else if entity.hasPrefix("#"), let value = UInt32(entity.dropFirst()) {
                        appendScalar(value)
                    } else {
                        handled = false
                    }
                }
                if handled {
                    i = semicolon + 1
                    continue
                }
            } else if byte == UInt8(ascii: "_"), i + 6 < input.count, input[i + 1] == UInt8(ascii: "x"),
                      input[(i + 2)..<(i + 6)].allSatisfy(isHex), input[i + 6] == UInt8(ascii: "_"),
                      let value = UInt32(String(decoding: input[(i + 2)..<(i + 6)], as: UTF8.self), radix: 16) {
                appendScalar(value)
                i += 7
                continue
            }
            output.append(byte)
            i += 1
        }
        return String(decoding: output, as: UTF8.self)
    }
}

// MARK: - Part handlers

private nonisolated struct RelationshipsHandler: XMLScanHandler {
    var relationships: [String: (type: String, target: String)] = [:]

    mutating func didOpen(_ tag: XMLTag) {
        guard tag.name == "Relationship", let id = tag.attribute("Id"), let target = tag.attribute("Target") else { return }
        relationships[id] = (tag.attribute("Type") ?? "", target)
    }

    mutating func didClose(_ name: String) {}
    mutating func didFindText(_ bytes: UnsafeRawBufferPointer) {}
}

private nonisolated struct WorkbookHandler: XMLScanHandler {
    var firstSheetRelationshipID: String?
    var uses1904Dates = false

    mutating func didOpen(_ tag: XMLTag) {
        switch tag.name {
        case "workbookPr":
            let value = tag.attribute("date1904")
            uses1904Dates = value == "1" || value == "true"
        case "sheet" where firstSheetRelationshipID == nil:
            // The relationship ID is the namespaced `r:id` attribute.
            firstSheetRelationshipID = tag.attribute("id")
        default:
            break
        }
    }

    mutating func didClose(_ name: String) {}
    mutating func didFindText(_ bytes: UnsafeRawBufferPointer) {}
}

private nonisolated struct SharedStringsHandler: XMLScanHandler {
    var strings: [String] = []
    private var text: [UInt8] = []
    private var isCapturing = false
    private var isInPhonetic = false

    mutating func didOpen(_ tag: XMLTag) {
        switch tag.name {
        case "si": text.removeAll(keepingCapacity: true)
        case "t": isCapturing = !isInPhonetic
        case "rPh": isInPhonetic = true
        default: break
        }
    }

    mutating func didClose(_ name: String) {
        switch name {
        case "si": strings.append(XMLScanner.decode(text))
        case "t": isCapturing = false
        case "rPh": isInPhonetic = false
        default: break
        }
    }

    mutating func didFindText(_ bytes: UnsafeRawBufferPointer) {
        if isCapturing { text.append(contentsOf: bytes) }
    }
}

private nonisolated struct WorksheetHandler: XMLScanHandler {
    let sharedStrings: [String]
    var rows: [[String]] = []

    private var row: [String] = []
    private var nextColumn = 0
    private var cellColumn = 0
    private var cellType = ""
    private var value: [UInt8] = []
    private var isInCell = false
    private var isCapturing = false
    private var isInPhonetic = false

    init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
    }

    mutating func didOpen(_ tag: XMLTag) {
        switch tag.name {
        case "row":
            row = []
            nextColumn = 0
        case "c":
            isInCell = true
            cellType = tag.attribute("t") ?? "n"
            cellColumn = tag.attribute("r").flatMap(Self.columnIndex) ?? nextColumn
            value.removeAll(keepingCapacity: true)
        case "v", "t":
            isCapturing = isInCell && !isInPhonetic
        case "rPh":
            isInPhonetic = true
        default:
            break
        }
    }

    mutating func didClose(_ name: String) {
        switch name {
        case "v", "t":
            isCapturing = false
        case "rPh":
            isInPhonetic = false
        case "c":
            let raw = XMLScanner.decode(value)
            let text = switch cellType {
            case "s": Int(raw).flatMap { sharedStrings.indices.contains($0) ? sharedStrings[$0] : nil } ?? ""
            case "b": raw == "1" ? "TRUE" : "FALSE"
            default: raw
            }
            if !text.isEmpty {
                if row.count <= cellColumn {
                    row.append(contentsOf: repeatElement("", count: cellColumn - row.count + 1))
                }
                row[cellColumn] = text
            }
            nextColumn = cellColumn + 1
            isInCell = false
        case "row":
            rows.append(row)
        default:
            break
        }
    }

    mutating func didFindText(_ bytes: UnsafeRawBufferPointer) {
        if isCapturing { value.append(contentsOf: bytes) }
    }

    /// The zero-based column of a cell reference such as "AB12".
    private static func columnIndex(_ reference: String) -> Int? {
        var index = 0
        var hasLetters = false
        for byte in reference.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"): index = index * 26 + Int(byte - UInt8(ascii: "A")) + 1
            case UInt8(ascii: "a")...UInt8(ascii: "z"): index = index * 26 + Int(byte - UInt8(ascii: "a")) + 1
            default:
                return hasLetters ? index - 1 : nil
            }
            hasLetters = true
        }
        return hasLetters ? index - 1 : nil
    }
}
