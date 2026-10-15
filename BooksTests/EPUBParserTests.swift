import XCTest
@testable import MBBooks

final class EPUBParserTests: XCTestCase {
    private func parse(_ data: Data) throws -> Publication {
        try EPUBParser.parse(ZipArchive(url: Fixtures.write(data)))
    }

    func testParsesSampleBookMetadataAndNavigation() throws {
        let publication = try parse(SampleBook.make())
        let metadata = publication.metadata
        XCTAssertEqual(metadata.title, SampleBook.title)
        XCTAssertEqual(metadata.authors, [SampleBook.author])
        XCTAssertEqual(metadata.sortAuthor, "Example, Ada")
        XCTAssertEqual(metadata.identifier, SampleBook.identifier)
        XCTAssertEqual(metadata.language, "en")
        XCTAssertEqual(metadata.publisher, "MB Books")
        XCTAssertEqual(metadata.summary, "A short voyage used to test MB Books.")
        XCTAssertEqual(metadata.subjects, ["Adventure"])
        XCTAssertEqual(metadata.modified, "2026-10-01T00:00:00Z")
        XCTAssertEqual(metadata.seriesName, "Sample Voyages")
        XCTAssertEqual(metadata.seriesPosition, 2)

        XCTAssertEqual(publication.packagePath, "EPUB/package.opf")
        XCTAssertEqual(publication.layout, .reflowable)
        XCTAssertEqual(publication.spine.map(\.item.path), ["EPUB/chapter1.xhtml", "EPUB/chapter2.xhtml", "EPUB/chapter3.xhtml"])
        XCTAssertEqual(publication.navigationDocumentPath, "EPUB/nav.xhtml")

        XCTAssertEqual(publication.tableOfContents.map(\.title), ["Departure", "Open Water", "Landfall"])
        let storm = try XCTUnwrap(publication.tableOfContents[1].children.first)
        XCTAssertEqual(storm.title, "The Storm")
        XCTAssertEqual(storm.path, "EPUB/chapter2.xhtml")
        XCTAssertEqual(storm.fragment, "storm")
        XCTAssertEqual(publication.landmarks.first?.title, "Start")
        XCTAssertEqual(publication.chapterTitle(forSpineIndex: 1), "The Storm")
        XCTAssertEqual(publication.flattenedTableOfContents.map(\.level), [0, 0, 1, 0])
    }

    func testParsesEPUB2PackageWithNCXAndLegacyCover() throws {
        let package = Fixtures.package(
            metadata: """
                <dc:title>Old Book</dc:title>
                <dc:creator opf:role="aut" opf:file-as="Writer, Old">Old Writer</dc:creator>
                <dc:creator opf:role="ill">An Illustrator</dc:creator>
                <meta name="cover" content="cover-img"/>
                <meta name="calibre:series" content="Classics"/>
                <meta name="calibre:series_index" content="3"/>
                """,
            manifest: """
                <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
                <item id="cover-img" href="images/front.jpg" media-type="image/jpeg"/>
                <item id="c1" href="Text/ch1.html" media-type="application/xhtml+xml"/>
                """,
            spine: #"<itemref idref="c1"/>"#, version: "2.0", spineAttributes: #"toc="ncx""#)
        let ncx = """
            <?xml version="1.0"?>
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
              <navMap>
                <navPoint id="p1"><navLabel><text>Chapter One</text></navLabel><content src="Text/ch1.html#start"/>
                  <navPoint id="p2"><navLabel><text>Part A</text></navLabel><content src="Text/ch1.html#a"/></navPoint>
                </navPoint>
              </navMap>
            </ncx>
            """
        let publication = try parse(Fixtures.epub(package: package, files: [
            "toc.ncx": ncx, "Text/ch1.html": Fixtures.xhtml("<p>Hi</p>"),
        ]))
        XCTAssertEqual(publication.version, "2.0")
        XCTAssertEqual(publication.metadata.authors, ["Old Writer"])
        XCTAssertEqual(publication.metadata.sortAuthor, "Writer, Old")
        XCTAssertEqual(publication.metadata.seriesName, "Classics")
        XCTAssertEqual(publication.metadata.seriesPosition, 3)
        XCTAssertEqual(publication.coverPath, "OEBPS/images/front.jpg")
        XCTAssertEqual(publication.tableOfContents.first?.title, "Chapter One")
        XCTAssertEqual(publication.tableOfContents.first?.fragment, "start")
        XCTAssertEqual(publication.tableOfContents.first?.children.first?.title, "Part A")
    }

    func testDetectsFixedLayoutsRollsAndSpineOverrides() throws {
        func layoutOf(_ meta: String, spine: String = #"<itemref idref="c1"/><itemref idref="c2" properties="rendition:layout-reflowable"/>"#) throws -> Publication {
            try parse(Fixtures.epub(package: Fixtures.package(
                metadata: "<dc:title>T</dc:title>\(meta)",
                manifest: """
                    <item id="c1" href="p1.xhtml" media-type="application/xhtml+xml"/>
                    <item id="c2" href="p2.xhtml" media-type="application/xhtml+xml"/>
                    """,
                spine: spine, spineAttributes: #"page-progression-direction="rtl""#),
                files: ["p1.xhtml": Fixtures.xhtml(""), "p2.xhtml": Fixtures.xhtml("")]))
        }

        let fixed = try layoutOf(#"<meta property="rendition:layout">pre-paginated</meta>"#)
        XCTAssertEqual(fixed.layout, .prePaginated)
        XCTAssertEqual(fixed.spine.map(\.layout), [.prePaginated, .reflowable])
        XCTAssertEqual(fixed.readingProgression, .rtl)

        // EPUB 3.4 roll layouts ignore spine overrides.
        let roll = try layoutOf(#"<meta property="rendition:layout">roll</meta>"#)
        XCTAssertEqual(roll.layout, .roll)
        XCTAssertEqual(roll.spine.map(\.layout), [.roll, .roll])

        // Pre-3.4 rolls: pre-paginated with scrolled-continuous flow.
        let legacyRoll = try layoutOf("""
            <meta property="rendition:layout">pre-paginated</meta>
            <meta property="rendition:flow">scrolled-continuous</meta>
            """)
        XCTAssertEqual(legacyRoll.layout, .roll)

        let reflowable = try layoutOf("", spine: #"<itemref idref="c1" properties="rendition:layout-pre-paginated"/><itemref idref="c2" linear="no"/>"#)
        XCTAssertEqual(reflowable.spine.map(\.layout), [.prePaginated, .reflowable])
        XCTAssertEqual(reflowable.spine.map(\.linear), [true, false])
    }

    func testFollowsManifestFallbacksAndResolvesPaths() throws {
        let publication = try parse(Fixtures.epub(package: Fixtures.package(
            metadata: "<dc:title>T</dc:title>",
            manifest: """
                <item id="exotic" href="data/page.xyz" media-type="application/x-custom" fallback="html"/>
                <item id="html" href="Text/My%20Chapter.xhtml" media-type="application/xhtml+xml"/>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="remote" href="https://example.com/a.mp4" media-type="video/mp4"/>
                """,
            spine: #"<itemref idref="exotic"/>"#),
            files: [
                "Text/My Chapter.xhtml": Fixtures.xhtml("<p>x</p>"),
                "nav.xhtml": Fixtures.xhtml("""
                    <nav epub:type="toc"><ol>
                      <li><a href="Text/My%20Chapter.xhtml#s&#160;1">Chapter&nbsp;One</a></li>
                      <li><span>Part Heading</span><ol><li><a href="../OEBPS/Text/My%20Chapter.xhtml">Sub</a></li></ol></li>
                    </ol></nav>
                    """),
            ]))
        XCTAssertEqual(publication.spine.first?.item.id, "html")
        XCTAssertEqual(publication.spine.first?.item.path, "OEBPS/Text/My Chapter.xhtml")
        XCTAssertEqual(publication.manifestItem(id: "remote")?.remoteURL?.host(), "example.com")
        XCTAssertEqual(publication.tableOfContents.first?.title, "Chapter One", "Labels collapse whitespace, including NBSP")
        XCTAssertEqual(publication.tableOfContents.first?.fragment, "s\u{00A0}1")
        XCTAssertNil(publication.tableOfContents[1].path, "A span heading has no target")
        XCTAssertEqual(publication.tableOfContents[1].children.first?.path, "OEBPS/Text/My Chapter.xhtml")
    }

    func testRecognizesFontObfuscationAndRejectsDRM() throws {
        func encryption(_ algorithm: String) -> Data {
            Data("""
                <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
                  <enc:EncryptedData>
                    <enc:EncryptionMethod Algorithm="\(algorithm)"/>
                    <enc:CipherData><enc:CipherReference URI="OEBPS/fonts/a.otf"/></enc:CipherData>
                  </enc:EncryptedData>
                </encryption>
                """.utf8)
        }
        let package = Fixtures.package(
            metadata: "<dc:title>T</dc:title>",
            manifest: #"<item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>"#,
            spine: #"<itemref idref="c1"/>"#)
        let files = ["c1.xhtml": Fixtures.xhtml("")]

        let obfuscated = try parse(Fixtures.epub(package: package, files: files, extra: [
            "META-INF/encryption.xml": encryption(FontObfuscation.idpf.rawValue),
        ]))
        XCTAssertEqual(obfuscated.obfuscatedResources, ["OEBPS/fonts/a.otf": .idpf])

        XCTAssertThrowsError(try parse(Fixtures.epub(package: package, files: files, extra: [
            "META-INF/encryption.xml": encryption("http://www.w3.org/2001/04/xmlenc#aes128-cbc"),
        ]))) { XCTAssertEqual($0 as? EPUBError, .drmProtected) }
    }

    func testRejectsArchivesWithoutAContainer() throws {
        var writer = ZipWriter()
        try writer.add("readme.txt", "hello")
        XCTAssertThrowsError(try parse(writer.finish())) { XCTAssertEqual($0 as? EPUBError, .missingContainer) }
    }

    func testResolvesContainerRelativePaths() {
        XCTAssertEqual(EPUBPath.resolve("../Images/a b.png", relativeTo: "OEBPS/Text/ch.xhtml")?.path, "OEBPS/Images/a b.png")
        XCTAssertEqual(EPUBPath.resolve("ch%202.xhtml#x%20y", relativeTo: "OEBPS/ch.xhtml")?.fragment, "x y")
        XCTAssertEqual(EPUBPath.resolve("#note", relativeTo: "OEBPS/ch.xhtml")?.path, "OEBPS/ch.xhtml")
        XCTAssertEqual(EPUBPath.resolve("/OEBPS/a.xhtml?query=1", relativeTo: "X/y.xhtml")?.path, "OEBPS/a.xhtml")
        XCTAssertNil(EPUBPath.resolve("https://example.com/x", relativeTo: "a.xhtml"))
        XCTAssertNil(EPUBPath.resolve("mailto:me@example.com", relativeTo: "a.xhtml"))
    }
}
