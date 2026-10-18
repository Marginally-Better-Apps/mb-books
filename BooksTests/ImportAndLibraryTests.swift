import CryptoKit
import SwiftData
import XCTest
@testable import MBBooks

final class FontDeobfuscatorTests: XCTestCase {
    func testIDPFUsesSHA1OfWhitespaceFreeIdentifierOver1040Bytes() {
        let identifier = " urn:uuid:abc\n 123 "
        let font = Data((0..<2000).map { UInt8($0 % 251) })
        let obfuscated = FontDeobfuscator.deobfuscate(font, algorithm: .idpf, identifier: identifier)
        let key = Array(Insecure.SHA1.hash(data: Data("urn:uuid:abc123".utf8)))
        XCTAssertEqual(obfuscated[0], font[0] ^ key[0])
        XCTAssertEqual(obfuscated[1039], font[1039] ^ key[1039 % 20])
        XCTAssertEqual(obfuscated[1040...], font[1040...], "Bytes after 1040 are untouched")
        XCTAssertEqual(FontDeobfuscator.deobfuscate(obfuscated, algorithm: .idpf, identifier: identifier), font)
    }

    func testAdobeUsesUUIDBytesOver1024Bytes() {
        let identifier = "urn:uuid:00112233-4455-6677-8899-aabbccddeeff"
        let font = Data(repeating: 0xAB, count: 1100)
        let obfuscated = FontDeobfuscator.deobfuscate(font, algorithm: .adobe, identifier: identifier)
        XCTAssertEqual(obfuscated[0], 0xAB ^ 0x00)
        XCTAssertEqual(obfuscated[15], 0xAB ^ 0xFF)
        XCTAssertEqual(obfuscated[1024], 0xAB)
        XCTAssertEqual(FontDeobfuscator.deobfuscate(obfuscated, algorithm: .adobe, identifier: identifier), font)
    }
}

final class BookImporterTests: XCTestCase {
    func testImportsExtractsAndDeobfuscatesFonts() throws {
        let identifier = "urn:uuid:12345678-1234-1234-1234-123456789abc"
        let font = Data((0..<1500).map { UInt8($0 % 256) })
        let obfuscated = FontDeobfuscator.deobfuscate(font, algorithm: .idpf, identifier: identifier)
        let package = Fixtures.package(
            metadata: "<dc:title>Font Book</dc:title><dc:creator>Typesetter</dc:creator>",
            manifest: """
                <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
                <item id="f" href="fonts/a.otf" media-type="font/otf"/>
                """,
            spine: #"<itemref idref="c1"/>"#)
        let encryption = """
            <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
              <enc:EncryptedData><enc:EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/>
              <enc:CipherData><enc:CipherReference URI="OEBPS/fonts/a.otf"/></enc:CipherData></enc:EncryptedData>
            </encryption>
            """
        let epub = try Fixtures.epub(package: package, files: ["c1.xhtml": Fixtures.xhtml("<p>x</p>")], extra: [
            "OEBPS/fonts/a.otf": obfuscated, "META-INF/encryption.xml": Data(encryption.utf8),
        ])
        let storage = BookStorage(root: try Fixtures.temporaryDirectory())
        let imported = try BookImporter(storage: storage).importBook(from: Fixtures.write(epub))

        XCTAssertEqual(imported.metadata.title, "Font Book")
        XCTAssertTrue(imported.hasOriginalFile)
        XCTAssertGreaterThan(imported.fileSize, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.originalFile(for: imported.id).path))
        let extractedFont = try Data(contentsOf: storage.container(for: imported.id).url(for: "OEBPS/fonts/a.otf"))
        XCTAssertEqual(extractedFont, font, "Obfuscated fonts are restored on import")
    }

    func testFailedImportLeavesNothingBehind() throws {
        let root = try Fixtures.temporaryDirectory()
        let importer = BookImporter(storage: BookStorage(root: root))
        XCTAssertThrowsError(try importer.importBook(from: Fixtures.write(Data("junk".utf8))))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testImportsExtractedFolders() throws {
        let archive = try ZipArchive(url: Fixtures.write(SampleBook.make()))
        let folder = try Fixtures.temporaryDirectory().appending(path: "Sample.epub")
        try archive.extractAll(to: folder)
        let storage = BookStorage(root: try Fixtures.temporaryDirectory())
        let imported = try BookImporter(storage: storage).importBook(from: folder)
        XCTAssertFalse(imported.hasOriginalFile)
        XCTAssertEqual(imported.metadata.title, SampleBook.title)
        let chapter = try String(contentsOf: storage.container(for: imported.id).url(for: "EPUB/chapter1.xhtml"), encoding: .utf8)
        XCTAssertFalse(chapter.contains("&nbsp;"), "Named HTML entities are rewritten so strict XHTML parsing succeeds")
        XCTAssertTrue(chapter.contains("&#160;"))
    }

    func testExpandsSelfClosingTagsInXHTMLSavedAsHTML() throws {
        // Kobo-style books ship XHTML as `.html` with `<script/>` in the head, which WebKit's HTML
        // parser leaves open, swallowing the whole chapter.
        let chapter = Fixtures.xhtml(#"<p><a id="i1"/>Text<br/></p>"#)
            .replacingOccurrences(of: "</title></head>", with: #"</title><script src="../js/kobo.js"/></head>"#)
        let package = Fixtures.package(
            metadata: "<dc:title>Kobo</dc:title>",
            manifest: """
                <item id="c1" href="c1.html" media-type="application/xhtml+xml"/>
                <item id="c2" href="c2.xhtml" media-type="application/xhtml+xml"/>
                """,
            spine: #"<itemref idref="c1"/><itemref idref="c2"/>"#)
        let epub = try Fixtures.epub(package: package, files: ["c1.html": chapter, "c2.xhtml": chapter])
        let storage = BookStorage(root: try Fixtures.temporaryDirectory())
        let imported = try BookImporter(storage: storage).importBook(from: Fixtures.write(epub))
        let content = storage.container(for: imported.id)

        let html = try String(contentsOf: content.url(for: "OEBPS/c1.html"), encoding: .utf8)
        XCTAssertTrue(html.contains(#"<script src="../js/kobo.js"></script>"#))
        XCTAssertTrue(html.contains(#"<a id="i1"></a>Text<br/>"#), "Void elements stay self-closing")
        XCTAssertNoThrow(try MarkupParser.parse(Data(html.utf8)), "The rewrite is still well-formed XML")
        let xhtml = try String(contentsOf: content.url(for: "OEBPS/c2.xhtml"), encoding: .utf8)
        XCTAssertEqual(xhtml, chapter, ".xhtml files are parsed as XML, so they're left alone")
    }

    func testSelfClosingTagExpansionSkipsCommentsScriptsAndQuotedValues() {
        let source = #"<p title="a/>b"/><!-- <c/> --><script>if (a <b/>) {}</script><svg:rect x='1'/>"#
        let expanded = String(decoding: SelfClosingTags.expanded(Data(source.utf8)), as: UTF8.self)
        XCTAssertEqual(expanded, #"<p title="a/>b"></p><!-- <c/> --><script>if (a <b/>) {}</script><svg:rect x='1'></svg:rect>"#)
        XCTAssertEqual(SelfClosingTags.expanded(Data(expanded.utf8)), Data(expanded.utf8), "Expansion is idempotent")
    }

    func testOpeningRepairsBooksImportedByOlderBuilds() throws {
        let package = Fixtures.package(
            metadata: "<dc:title>Old</dc:title>",
            manifest: #"<item id="c1" href="c1.htm" media-type="application/xhtml+xml"/>"#,
            spine: #"<itemref idref="c1"/>"#)
        let folder = try Fixtures.temporaryDirectory()
        try ZipArchive(url: Fixtures.write(try Fixtures.epub(
            package: package, files: ["c1.htm": Fixtures.xhtml("<p>&nbsp;<span/></p>")]))).extractAll(to: folder)
        let container = DirectoryContainer(root: folder)
        let publication = try EPUBParser.parse(container)

        ContentNormalizer.normalizeIfNeeded(publication, in: folder)
        let chapter = try String(contentsOf: container.url(for: "OEBPS/c1.htm"), encoding: .utf8)
        XCTAssertTrue(chapter.contains("<p>&#160;<span></span></p>"))
        XCTAssertEqual(try String(contentsOf: folder.appending(path: ContentNormalizer.markerName), encoding: .utf8),
                       String(ContentNormalizer.version))

        try Data(Fixtures.xhtml("<p>&nbsp;</p>").utf8).write(to: container.url(for: "OEBPS/c1.htm"))
        ContentNormalizer.normalizeIfNeeded(publication, in: folder)
        XCTAssertTrue(try String(contentsOf: container.url(for: "OEBPS/c1.htm"), encoding: .utf8).contains("&nbsp;"),
                      "Books already at the current version aren't rewritten again")
    }

    @MainActor
    func testLibraryStoreDeduplicatesAndDeletesBooks() async throws {
        let container = try ModelContainer(
            for: Book.self, BookCollection.self, Annotation.self, ReadingDay.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let storage = BookStorage(root: try Fixtures.temporaryDirectory())
        let store = LibraryStore(storage: storage)
        let url = try Fixtures.write(SampleBook.make())

        let first = await store.importBooks(from: [url], into: context)
        let second = await store.importBooks(from: [url], into: context)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?.id, second.first?.id, "Re-importing returns the existing book")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Book>()), 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: storage.root.path).count, 1)

        let book = try XCTUnwrap(first.first)
        XCTAssertEqual(book.sortAuthor, "example, ada")
        XCTAssertNotNil(store.shareURL(for: book))
        store.delete([book], from: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Book>()), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.folder(for: book.id).path))
    }
}
