//
//  ZipArchive.swift
//  JobList
//

import Foundation

/// Errors raised while reading or writing ZIP archives.
nonisolated enum ZipError: LocalizedError {
    case notAZipFile
    case corrupt
    case unsupportedCompression(UInt16)
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .notAZipFile: "The file is not a ZIP archive."
        case .corrupt: "The ZIP archive is damaged."
        case .unsupportedCompression(let method): "The ZIP archive uses an unsupported compression method (\(method))."
        case .tooLarge: "The archive is too large to be written."
        }
    }
}

/// Minimal ZIP reader, sufficient for the Office Open XML packages used by `.xlsx` files.
///
/// Supports stored and deflated entries; ZIP64 and encryption are not supported.
nonisolated struct ZipReader {
    private struct Entry {
        let method: UInt16
        let compressedSize: Int
        let localHeaderOffset: Int
    }

    private let data: Data
    private var entries: [String: Entry] = [:]

    init(_ data: Data) throws {
        self.data = data
        let count = data.count
        guard count >= 22 else { throw ZipError.notAZipFile }

        // The end-of-central-directory record is at the end of the file,
        // followed by an optional comment of up to 64 KB.
        var eocd: Int?
        var i = count - 22
        let lowerBound = max(0, count - 22 - 0xFFFF)
        while i >= lowerBound {
            if data.uint32(at: i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard let eocd else { throw ZipError.notAZipFile }

        let entryCount = Int(data.uint16(at: eocd + 10))
        var offset = Int(data.uint32(at: eocd + 16))
        for _ in 0..<entryCount {
            guard offset + 46 <= count, data.uint32(at: offset) == 0x0201_4B50 else { throw ZipError.corrupt }
            let nameLength = Int(data.uint16(at: offset + 28))
            let extraLength = Int(data.uint16(at: offset + 30))
            let commentLength = Int(data.uint16(at: offset + 32))
            guard offset + 46 + nameLength <= count else { throw ZipError.corrupt }

            let nameStart = data.startIndex + offset + 46
            let name = String(decoding: data[nameStart..<nameStart + nameLength], as: UTF8.self)
            entries[name] = Entry(
                method: data.uint16(at: offset + 10),
                compressedSize: Int(data.uint32(at: offset + 20)),
                localHeaderOffset: Int(data.uint32(at: offset + 42))
            )
            offset += 46 + nameLength + extraLength + commentLength
        }
    }

    /// Returns the uncompressed contents of the entry at `path`, or `nil` if there is no such entry.
    func contents(of path: String) throws -> Data? {
        guard let entry = entries[path] else { return nil }
        let header = entry.localHeaderOffset
        guard header + 30 <= data.count, data.uint32(at: header) == 0x0403_4B50 else { throw ZipError.corrupt }

        // Sizes come from the central directory, since the local header may defer them to a data descriptor.
        let start = header + 30 + Int(data.uint16(at: header + 26)) + Int(data.uint16(at: header + 28))
        guard start + entry.compressedSize <= data.count else { throw ZipError.corrupt }
        let payload = data.subdata(in: data.startIndex + start..<data.startIndex + start + entry.compressedSize)

        switch entry.method {
        case 0: return payload
        // `.zlib` here is raw DEFLATE (RFC 1951), which is exactly what ZIP stores.
        case 8: return try (payload as NSData).decompressed(using: .zlib) as Data
        default: throw ZipError.unsupportedCompression(entry.method)
        }
    }
}

/// Minimal ZIP writer that deflates each entry.
nonisolated struct ZipWriter {
    private var body = Data()
    private var centralDirectory = Data()
    private var entryCount = 0

    mutating func add(_ path: String, contents: Data) throws {
        let name = Data(path.utf8)
        var method: UInt16 = 8
        var payload = try (contents as NSData).compressed(using: .zlib) as Data
        if payload.count >= contents.count {
            method = 0
            payload = contents
        }
        let offset = body.count
        guard contents.count <= UInt32.max, offset + payload.count <= UInt32.max, entryCount < UInt16.max else {
            throw ZipError.tooLarge
        }
        let crc = CRC32.checksum(contents)

        // Fields shared by the local header and the central directory record.
        var common = Data()
        common.appendLE(UInt16(20))         // version needed to extract
        common.appendLE(UInt16(0x0800))     // flags: UTF-8 file names
        common.appendLE(method)
        common.appendLE(UInt16(0))          // modification time
        common.appendLE(UInt16(0x21))       // modification date (1980-01-01)
        common.appendLE(crc)
        common.appendLE(UInt32(payload.count))
        common.appendLE(UInt32(contents.count))
        common.appendLE(UInt16(name.count))
        common.appendLE(UInt16(0))          // extra field length

        body.appendLE(UInt32(0x0403_4B50))
        body.append(common)
        body.append(name)
        body.append(payload)

        centralDirectory.appendLE(UInt32(0x0201_4B50))
        centralDirectory.appendLE(UInt16(20)) // version made by
        centralDirectory.append(common)
        centralDirectory.appendLE(UInt16(0))  // comment length
        centralDirectory.appendLE(UInt16(0))  // disk number
        centralDirectory.appendLE(UInt16(0))  // internal attributes
        centralDirectory.appendLE(UInt32(0))  // external attributes
        centralDirectory.appendLE(UInt32(offset))
        centralDirectory.append(name)
        entryCount += 1
    }

    func finish() throws -> Data {
        guard body.count + centralDirectory.count <= UInt32.max else { throw ZipError.tooLarge }
        var archive = body
        archive.append(centralDirectory)
        archive.appendLE(UInt32(0x0605_4B50))
        archive.appendLE(UInt16(0))           // disk number
        archive.appendLE(UInt16(0))           // disk with central directory
        archive.appendLE(UInt16(entryCount))
        archive.appendLE(UInt16(entryCount))
        archive.appendLE(UInt32(centralDirectory.count))
        archive.appendLE(UInt32(body.count))
        archive.appendLE(UInt16(0))           // comment length
        return archive
    }
}

private nonisolated enum CRC32 {
    static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 {
            c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
        }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        table.withUnsafeBufferPointer { table in
            data.withUnsafeBytes { bytes in
                for byte in bytes {
                    crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
                }
            }
        }
        return ~crc
    }
}

private nonisolated extension Data {
    func uint16(at offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }

    mutating func appendLE(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
