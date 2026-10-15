import Foundation

/// A small EPUB 3.4 book exercising navigation, footnotes, and multiple chapters.
/// Used to seed UI tests and as a parser fixture.
nonisolated enum SampleBook {
    static let title = "The Sample Voyage"
    static let author = "Ada Example"
    static let identifier = "urn:uuid:5b1c3c2e-6f0e-4a8d-9c41-2a7b0b6e9f11"

    static func make() throws -> Data {
        var zip = ZipWriter()
        try zip.add("mimetype", "application/epub+zip", compress: false)
        try zip.add("META-INF/container.xml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles>
                <rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/>
              </rootfiles>
            </container>
            """)
        try zip.add("EPUB/package.opf", package)
        try zip.add("EPUB/nav.xhtml", navigation)
        try zip.add("EPUB/style.css", "body { font-family: serif; } h1 { text-align: center; } .note { font-size: 0.9em; }")
        for chapter in 1...3 {
            try zip.add("EPUB/chapter\(chapter).xhtml", self.chapter(chapter))
        }
        return zip.finish()
    }

    private static var package: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid" xml:lang="en">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">\(identifier)</dc:identifier>
            <dc:title id="title">\(title)</dc:title>
            <meta refines="#title" property="title-type">main</meta>
            <dc:creator id="author">\(author)</dc:creator>
            <meta refines="#author" property="role" scheme="marc:relators">aut</meta>
            <meta refines="#author" property="file-as">Example, Ada</meta>
            <dc:language>en</dc:language>
            <dc:publisher>MB Books</dc:publisher>
            <dc:description>&lt;p&gt;A short voyage used to test &lt;b&gt;MB Books&lt;/b&gt;.&lt;/p&gt;</dc:description>
            <dc:subject>Adventure</dc:subject>
            <meta property="dcterms:modified">2026-10-01T00:00:00Z</meta>
            <meta property="belongs-to-collection" id="series">Sample Voyages</meta>
            <meta refines="#series" property="collection-type">series</meta>
            <meta refines="#series" property="group-position">2</meta>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="css" href="style.css" media-type="text/css"/>
            <item id="c1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="chapter2.xhtml" media-type="application/xhtml+xml"/>
            <item id="c3" href="chapter3.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="c1"/>
            <itemref idref="c2"/>
            <itemref idref="c3"/>
          </spine>
        </package>
        """
    }

    private static var navigation: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>Contents</title></head>
        <body>
          <nav epub:type="toc"><ol>
            <li><a href="chapter1.xhtml">Departure</a></li>
            <li><a href="chapter2.xhtml">Open Water</a>
              <ol><li><a href="chapter2.xhtml#storm">The Storm</a></li></ol></li>
            <li><a href="chapter3.xhtml">Landfall</a></li>
          </ol></nav>
          <nav epub:type="landmarks" hidden=""><ol>
            <li><a epub:type="bodymatter" href="chapter1.xhtml">Start</a></li>
          </ol></nav>
        </body>
        </html>
        """
    }

    private static let titles = ["Departure", "Open Water", "Landfall"]

    private static func chapter(_ number: Int) -> String {
        let paragraphs = (1...14).map { index in
            let anchor = number == 2 && index == 8 ? " id=\"storm\"" : ""
            return "<p\(anchor)>Paragraph \(index) of chapter \(number). The ship&nbsp;sailed on beneath a pale sky, "
                + "and the crew kept their logs with careful, steady hands as the miles rolled past the bow. "
                + "Every evening the navigator marked the chart, and every morning the sea looked new again.</p>"
        }.joined(separator: "\n")
        let note = number == 1
            ? """
              <p>The captain checked the compass<a epub:type="noteref" href="#n1">1</a> twice.</p>
              <aside epub:type="footnote" id="n1"><p class="note">A brass compass, older than the ship.</p></aside>
              """
            : ""
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en">
            <head><title>\(titles[number - 1])</title><link rel="stylesheet" href="style.css"/></head>
            <body>
            <section epub:type="chapter">
            <h1>\(titles[number - 1])</h1>
            \(note)
            \(paragraphs)
            </section>
            </body>
            </html>
            """
    }
}
