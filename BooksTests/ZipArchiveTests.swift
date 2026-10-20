import XCTest
@testable import MBBooks

final class ZipArchiveTests: XCTestCase {
    func testRoundTripsStoredAndDeflatedEntries() throws {
        let large = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 7) })
        var writer = ZipWriter()
        try writer.add("mimetype", "application/epub+zip", compress: false)
        try writer.add("text/hello.txt", "Hello, 世界")
        try writer.add("media/blob.bin", large)
        try writer.add("empty.txt", Data())
        let url = try Fixtures.write(writer.finish(), named: "test.zip")

        let archive = try ZipArchive(url: url)
        XCTAssertEqual(archive.entries.map(\.path), ["mimetype", "text/hello.txt", "media/blob.bin", "empty.txt"])
        XCTAssertEqual(archive.entry("mimetype")?.method, ZipArchive.Method.stored)
        XCTAssertEqual(archive.entry("media/blob.bin")?.method, ZipArchive.Method.deflated)
        XCTAssertEqual(String(decoding: try archive.contents(of: "text/hello.txt"), as: UTF8.self), "Hello, 世界")
        XCTAssertEqual(try archive.contents(of: "media/blob.bin"), large)
        XCTAssertEqual(try archive.contents(of: "empty.txt"), Data())
    }

    func testExtractsAllEntriesToDisk() throws {
        var writer = ZipWriter()
        try writer.add("a/b/c.txt", "nested")
        try writer.add("root.txt", "root")
        let archive = try ZipArchive(url: Fixtures.write(writer.finish(), named: "x.zip"))
        let destination = try Fixtures.temporaryDirectory()
        try archive.extractAll(to: destination)
        XCTAssertEqual(try String(contentsOf: destination.appending(path: "a/b/c.txt"), encoding: .utf8), "nested")
        XCTAssertEqual(try String(contentsOf: destination.appending(path: "root.txt"), encoding: .utf8), "root")
    }

    func testRejectsPathsThatEscapeTheDestination() throws {
        let root = try Fixtures.temporaryDirectory()
        for path in ["../evil.txt", "a/../../evil.txt", "/etc/passwd", "a\\..\\b", "./x"] {
            XCTAssertThrowsError(try ZipArchive.safeDestination(for: path, in: root), path) { error in
                XCTAssertEqual(error as? ZipError, .unsafePath(path))
            }
        }
        XCTAssertEqual(
            try ZipArchive.safeDestination(for: "OEBPS/text/ch 1.xhtml", in: root).path,
            root.appending(path: "OEBPS/text/ch 1.xhtml").standardizedFileURL.path)
    }

    func testDetectsCorruptedData() throws {
        var writer = ZipWriter()
        try writer.add("file.txt", String(repeating: "abc", count: 100), compress: false)
        var data = writer.finish()
        data[40] ^= 0xFF // Inside the stored payload.
        let archive = try ZipArchive(url: Fixtures.write(data, named: "bad.zip"))
        XCTAssertThrowsError(try archive.contents(of: "file.txt")) { error in
            XCTAssertEqual(error as? ZipError, .checksumMismatch("file.txt"))
        }
    }

    func testRejectsNonZipFiles() throws {
        let url = try Fixtures.write(Data("not a zip file at all".utf8), named: "plain.epub")
        XCTAssertThrowsError(try ZipArchive(url: url)) { XCTAssertEqual($0 as? ZipError, .notAZip) }
    }

    func testRejectsZIP64SizesThatOverflow() throws {
        // A ZIP64 end record whose central directory offset plus size wraps past UInt64.max.
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        append(UInt32(0x0606_4B50)); append(UInt64(44)); append(UInt16(45)); append(UInt16(45))
        append(UInt32(0)); append(UInt32(0)); append(UInt64(0)); append(UInt64(0))
        append(UInt64(1)); append(UInt64.max)
        append(UInt32(0x0706_4B50)); append(UInt32(0)); append(UInt64(0)); append(UInt32(1))
        append(UInt32(0x0605_4B50)); for _ in 0..<4 { append(UInt16(0)) }; append(UInt32(0)); append(UInt32(0)); append(UInt16(0))
        let url = try Fixtures.write(data, named: "overflow.epub")
        XCTAssertThrowsError(try ZipArchive(url: url)) { error in
            XCTAssertEqual(error as? ZipError, .corrupt("Central directory is out of bounds"))
        }
    }

    func testCRC32MatchesKnownVector() {
        var crc = CRC32()
        crc.update(Data("123456789".utf8))
        XCTAssertEqual(crc.value, 0xCBF4_3926)
    }
}
