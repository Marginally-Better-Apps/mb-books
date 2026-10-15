import Foundation

/// Builds small ZIP archives in memory (OCF-conformant when `mimetype` is added first, stored).
nonisolated struct ZipWriter {
    private var archive = Data()
    private var directory = Data()
    private var count: UInt16 = 0

    /// Adds a file. Entries are deflated unless `compress` is false.
    mutating func add(_ path: String, _ contents: Data, compress: Bool = true) throws {
        let name = Data(path.utf8)
        var checksum = CRC32()
        checksum.update(contents)
        let payload: Data
        let method: UInt16
        if compress, !contents.isEmpty {
            payload = try (contents as NSData).compressed(using: .zlib) as Data
            method = ZipArchive.Method.deflated
        } else {
            payload = contents
            method = ZipArchive.Method.stored
        }
        let offset = UInt32(archive.count)
        let dosDate: UInt16 = (0 << 9) | (1 << 5) | 1

        var local = Data()
        local.append(le: UInt32(0x0403_4B50))
        local.append(le: UInt16(20))
        local.append(le: UInt16(0x0800))
        local.append(le: method)
        local.append(le: UInt16(0))
        local.append(le: dosDate)
        local.append(le: checksum.value)
        local.append(le: UInt32(payload.count))
        local.append(le: UInt32(contents.count))
        local.append(le: UInt16(name.count))
        local.append(le: UInt16(0))
        local.append(name)
        archive.append(local)
        archive.append(payload)

        directory.append(le: UInt32(0x0201_4B50))
        directory.append(le: UInt16(20))
        directory.append(le: UInt16(20))
        directory.append(le: UInt16(0x0800))
        directory.append(le: method)
        directory.append(le: UInt16(0))
        directory.append(le: dosDate)
        directory.append(le: checksum.value)
        directory.append(le: UInt32(payload.count))
        directory.append(le: UInt32(contents.count))
        directory.append(le: UInt16(name.count))
        directory.append(le: UInt16(0))
        directory.append(le: UInt16(0))
        directory.append(le: UInt16(0))
        directory.append(le: UInt16(0))
        directory.append(le: UInt32(0))
        directory.append(le: offset)
        directory.append(name)
        count += 1
    }

    mutating func add(_ path: String, _ text: String, compress: Bool = true) throws {
        try add(path, Data(text.utf8), compress: compress)
    }

    func finish() -> Data {
        var output = archive
        output.append(directory)
        output.append(le: UInt32(0x0605_4B50))
        output.append(le: UInt16(0))
        output.append(le: UInt16(0))
        output.append(le: count)
        output.append(le: count)
        output.append(le: UInt32(directory.count))
        output.append(le: UInt32(archive.count))
        output.append(le: UInt16(0))
        return output
    }
}

nonisolated extension Data {
    mutating func append<T: FixedWidthInteger>(le value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
