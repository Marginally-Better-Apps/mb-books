import Compression
import Foundation

/// A read-only ZIP reader for OCF containers.
///
/// Supports stored and deflated entries, ZIP64 archives (large media-heavy books),
/// UTF-8 and legacy names, and CRC verification. The archive is memory-mapped, so
/// opening a multi-gigabyte book costs only the central directory parse.
nonisolated struct ZipArchive: Sendable {
    struct Entry: Sendable, Hashable {
        let path: String
        let method: UInt16
        let flags: UInt16
        let crc32: UInt32
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64

        var isDirectory: Bool { path.hasSuffix("/") }
        var isEncrypted: Bool { flags & 0x1 != 0 }
    }

    enum Method {
        static let stored: UInt16 = 0
        static let deflated: UInt16 = 8
    }

    let url: URL
    let entries: [Entry]
    private let data: Data
    private let index: [String: Int]

    init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let entries = try Self.readCentralDirectory(data)
        self.url = url
        self.data = data
        self.entries = entries
        var index: [String: Int] = [:]
        for (position, entry) in entries.enumerated() where index[entry.path] == nil {
            index[entry.path] = position
        }
        self.index = index
    }

    func entry(_ path: String) -> Entry? {
        index[path].map { entries[$0] }
    }

    /// Reads an entry fully into memory. Use `extract(_:to:)` for large media.
    func contents(of entry: Entry) throws -> Data {
        var output = Data()
        output.reserveCapacity(Int(clamping: entry.uncompressedSize))
        try stream(entry) { output.append($0) }
        return output
    }

    func contents(of path: String) throws -> Data {
        guard let entry = entry(path) else { throw ZipError.missingEntry(path) }
        return try contents(of: entry)
    }

    /// Streams an entry to a file without holding it in memory.
    func extract(_ entry: Entry, to destination: URL) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try stream(entry) { try handle.write(contentsOf: $0) }
    }

    /// Extracts every entry beneath `directory`, rejecting paths that escape it.
    func extractAll(to directory: URL) throws {
        let fileManager = FileManager.default
        let root = directory.standardizedFileURL
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        for entry in entries {
            let destination = try Self.safeDestination(for: entry.path, in: root)
            if entry.isDirectory {
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                continue
            }
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try extract(entry, to: destination)
        }
    }

    static func safeDestination(for path: String, in root: URL) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !components.contains(where: { $0 == ".." || $0 == "." })
        else { throw ZipError.unsafePath(path) }
        let destination = components.reduce(root) { $0.appending(path: String($1)) }.standardizedFileURL
        guard destination.path.hasPrefix(root.path + "/") else { throw ZipError.unsafePath(path) }
        return destination
    }

    // MARK: - Decompression

    private static let chunkSize = 1 << 20

    private func stream(_ entry: Entry, into sink: @escaping (Data) throws -> Void) throws {
        guard !entry.isEncrypted else { throw ZipError.encrypted(entry.path) }
        let start = try dataOffset(of: entry)
        guard start + entry.compressedSize <= UInt64(data.count) else {
            throw ZipError.corrupt("\(entry.path) extends past the end of the archive")
        }
        var checksum = CRC32()
        var written: UInt64 = 0
        let emit: (Data) throws -> Void = { chunk in
            checksum.update(chunk)
            written += UInt64(chunk.count)
            try sink(chunk)
        }

        switch entry.method {
        case Method.stored:
            var offset = start
            let end = start + entry.compressedSize
            while offset < end {
                let next = min(end, offset + UInt64(Self.chunkSize))
                try emit(data.subdata(in: Int(offset)..<Int(next)))
                offset = next
            }
        case Method.deflated:
            // `.zlib` in the Compression framework is raw DEFLATE (RFC 1951), which is what ZIP stores.
            let filter = try OutputFilter(.decompress, using: .zlib, bufferCapacity: Self.chunkSize) { chunk in
                if let chunk { try emit(chunk) }
            }
            var offset = start
            let end = start + entry.compressedSize
            while offset < end {
                let next = min(end, offset + UInt64(Self.chunkSize))
                try filter.write(data.subdata(in: Int(offset)..<Int(next)))
                offset = next
            }
            try filter.finalize()
        default:
            throw ZipError.unsupportedCompression(entry.path, entry.method)
        }

        guard written == entry.uncompressedSize else {
            throw ZipError.corrupt("\(entry.path) has the wrong size")
        }
        guard checksum.value == entry.crc32 else { throw ZipError.checksumMismatch(entry.path) }
    }

    private func dataOffset(of entry: Entry) throws -> UInt64 {
        let offset = Int(entry.localHeaderOffset)
        guard offset >= 0, offset + 30 <= data.count, data.uint32(at: offset) == 0x0403_4B50 else {
            throw ZipError.corrupt("Missing local header for \(entry.path)")
        }
        let nameLength = UInt64(data.uint16(at: offset + 26))
        let extraLength = UInt64(data.uint16(at: offset + 28))
        return entry.localHeaderOffset + 30 + nameLength + extraLength
    }

    // MARK: - Central directory

    private static func readCentralDirectory(_ data: Data) throws -> [Entry] {
        guard let eocd = findEndOfCentralDirectory(data) else { throw ZipError.notAZip }
        var entryCount = UInt64(data.uint16(at: eocd + 10))
        var directorySize = UInt64(data.uint32(at: eocd + 12))
        var directoryOffset = UInt64(data.uint32(at: eocd + 16))

        let locator = eocd - 20
        if locator >= 0, data.uint32(at: locator) == 0x0706_4B50 {
            let record = Int(clamping: data.uint64(at: locator + 8))
            guard record >= 0, record + 56 <= data.count, data.uint32(at: record) == 0x0606_4B50 else {
                throw ZipError.corrupt("Invalid ZIP64 end record")
            }
            entryCount = data.uint64(at: record + 32)
            directorySize = data.uint64(at: record + 40)
            directoryOffset = data.uint64(at: record + 48)
        }

        guard directoryOffset + directorySize <= UInt64(data.count) else {
            throw ZipError.corrupt("Central directory is out of bounds")
        }

        var entries: [Entry] = []
        entries.reserveCapacity(Int(clamping: entryCount))
        var cursor = Int(directoryOffset)
        let end = Int(directoryOffset + directorySize)
        while cursor + 46 <= end, data.uint32(at: cursor) == 0x0201_4B50 {
            let flags = data.uint16(at: cursor + 8)
            let method = data.uint16(at: cursor + 10)
            let crc = data.uint32(at: cursor + 16)
            var compressed = UInt64(data.uint32(at: cursor + 20))
            var uncompressed = UInt64(data.uint32(at: cursor + 24))
            let nameLength = Int(data.uint16(at: cursor + 28))
            let extraLength = Int(data.uint16(at: cursor + 30))
            let commentLength = Int(data.uint16(at: cursor + 32))
            var localOffset = UInt64(data.uint32(at: cursor + 42))
            let nameStart = cursor + 46
            guard nameStart + nameLength + extraLength <= end else {
                throw ZipError.corrupt("Truncated central directory")
            }
            let nameData = data.subdata(in: nameStart..<(nameStart + nameLength))
            let path = flags & 0x800 != 0
                ? String(decoding: nameData, as: UTF8.self)
                : String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: UTF8.self)

            // ZIP64 extended information only lists the fields that overflowed, in this order.
            var extra = nameStart + nameLength
            let extraEnd = extra + extraLength
            while extra + 4 <= extraEnd {
                let id = data.uint16(at: extra)
                let size = Int(data.uint16(at: extra + 2))
                if id == 0x0001 {
                    var field = extra + 4
                    if uncompressed == 0xFFFF_FFFF, field + 8 <= extraEnd {
                        uncompressed = data.uint64(at: field); field += 8
                    }
                    if compressed == 0xFFFF_FFFF, field + 8 <= extraEnd {
                        compressed = data.uint64(at: field); field += 8
                    }
                    if localOffset == 0xFFFF_FFFF, field + 8 <= extraEnd {
                        localOffset = data.uint64(at: field)
                    }
                }
                extra += 4 + size
            }

            entries.append(Entry(
                path: path, method: method, flags: flags, crc32: crc,
                compressedSize: compressed, uncompressedSize: uncompressed,
                localHeaderOffset: localOffset))
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }

    private static func findEndOfCentralDirectory(_ data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let lowerBound = max(0, data.count - 22 - Int(UInt16.max))
        var position = data.count - 22
        while position >= lowerBound {
            if data.uint32(at: position) == 0x0605_4B50 { return position }
            position -= 1
        }
        return nil
    }
}

nonisolated enum ZipError: LocalizedError, Equatable {
    case notAZip
    case corrupt(String)
    case missingEntry(String)
    case unsupportedCompression(String, UInt16)
    case encrypted(String)
    case checksumMismatch(String)
    case unsafePath(String)

    var errorDescription: String? {
        switch self {
        case .notAZip: "The file is not a valid EPUB archive."
        case .corrupt(let detail): "The archive is damaged: \(detail)."
        case .missingEntry(let path): "The archive is missing \(path)."
        case .unsupportedCompression(let path, let method): "\(path) uses unsupported compression (\(method))."
        case .encrypted: "This book is protected by DRM and can't be opened."
        case .checksumMismatch(let path): "\(path) failed its integrity check."
        case .unsafePath(let path): "The archive contains an unsafe path: \(path)."
        }
    }
}

/// CRC-32 (IEEE 802.3), as used by ZIP.
nonisolated struct CRC32 {
    private(set) var value: UInt32 = 0

    private static let table: [UInt32] = (0..<256).map { index in
        (0..<8).reduce(UInt32(index)) { crc, _ in crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
    }

    mutating func update(_ data: Data) {
        var crc = ~value
        Self.table.withUnsafeBufferPointer { table in
            data.withUnsafeBytes { bytes in
                for byte in bytes {
                    crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
                }
            }
        }
        value = ~crc
    }
}

nonisolated extension Data {
    func uint16(at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        return withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) }
    }

    func uint32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        return withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    func uint64(at offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= count else { return 0 }
        return withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
    }
}
