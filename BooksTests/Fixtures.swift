import Foundation
@testable import MBBooks

/// Builds EPUB fixtures in memory so tests don't depend on binary files.
enum Fixtures {
    static let container = """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """

    static func xhtml(_ body: String, title: String = "Chapter") -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>\(title)</title></head><body>\(body)</body></html>
        """
    }

    /// An EPUB with the given package document and files under `OEBPS/`.
    static func epub(package: String, files: [String: String] = [:], extra: [String: Data] = [:]) throws -> Data {
        var zip = ZipWriter()
        try zip.add("mimetype", "application/epub+zip", compress: false)
        try zip.add("META-INF/container.xml", container)
        try zip.add("OEBPS/content.opf", package)
        for (path, contents) in files.sorted(by: { $0.key < $1.key }) {
            try zip.add("OEBPS/\(path)", contents)
        }
        for (path, contents) in extra.sorted(by: { $0.key < $1.key }) {
            try zip.add(path, contents)
        }
        return zip.finish()
    }

    static func package(metadata: String, manifest: String, spine: String, version: String = "3.0",
                        spineAttributes: String = "") -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" xmlns:opf="http://www.idpf.org/2007/opf"
                 version="\(version)" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">urn:uuid:12345678-1234-1234-1234-123456789abc</dc:identifier>
            \(metadata)
          </metadata>
          <manifest>\(manifest)</manifest>
          <spine \(spineAttributes)>\(spine)</spine>
        </package>
        """
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "MBBooksTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write(_ data: Data, named name: String = "book.epub") throws -> URL {
        let url = try temporaryDirectory().appending(path: name)
        try data.write(to: url)
        return url
    }
}
