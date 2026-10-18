import AVFoundation
import XCTest
@testable import MBBooks

/// What gets read aloud, and how: content extraction, cleanup, OCR layout, and pronunciation.
final class SpeechExtractionTests: XCTestCase {
    private func spine(_ path: String = "OEBPS/chapter.xhtml", linear: Bool = true) -> SpineItem {
        SpineItem(
            item: ManifestItem(id: "c", path: path, mediaType: "application/xhtml+xml", properties: [], fallback: nil,
                               mediaOverlay: nil, remoteURL: nil),
            linear: linear, properties: [], layout: .reflowable)
    }

    private func extract(_ body: String, context: SpeechExtractor.Context = .init(bookTitle: "The Sample Voyage", authors: ["Ada Example"]),
                         head: String = "", linear: Bool = true) -> SpeechChapter {
        let html = """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
            <head><title>Chapter</title>\(head)</head><body>\(body)</body></html>
            """
        return SpeechExtractor(context: context).chapter(spineIndex: 0, item: spine(linear: linear), data: Data(html.utf8))
    }

    private func texts(_ chapter: SpeechChapter) -> [String] { chapter.utterances.map(\.text) }

    func testReadsParagraphsAsSentences() {
        let chapter = extract("<h1>Departure</h1><p>The ship sailed. Mr. Smith waved from the dock!</p><p>Night fell.</p>")
        XCTAssertNil(chapter.skipReason)
        XCTAssertEqual(texts(chapter), ["Departure", "The ship sailed.", "Mr. Smith waved from the dock!", "Night fell."])
        XCTAssertEqual(chapter.utterances[0].kind, .heading)
        XCTAssertGreaterThan(chapter.utterances[0].pauseAfter, chapter.utterances[1].pauseAfter, "Headings get a longer pause")
        XCTAssertGreaterThan(chapter.utterances[2].pauseAfter, 0, "Paragraph ends pause")
        XCTAssertEqual(chapter.title, "Departure")
    }

    func testUtteranceOffsetsMatchTheReaderTextNodes() throws {
        let body = "<h1>One</h1>\n<p>The <i>captain</i> checked the compass<a epub:type=\"noteref\" href=\"#n1\">1</a> twice.</p>"
            + "<aside epub:type=\"footnote\" id=\"n1\"><p>A brass compass.</p></aside><p>Soft\u{00AD}ly, the sea&#160;rolled.</p>"
        let chapter = extract(body)
        let html = Fixtures.xhtml(body)
        let text = try BookSearcher.bodyText(Data(html.utf8)) as NSString
        XCTAssertEqual(texts(chapter), ["One", "The captain checked the compass twice.", "Softly, the sea rolled."])
        for utterance in chapter.utterances {
            let start = try XCTUnwrap(utterance.start)
            let end = try XCTUnwrap(utterance.end)
            let source = text.substring(with: NSRange(location: start, length: end - start))
            // The source range covers the original, including what cleanup removed.
            XCTAssertEqual(source.first, utterance.text.first, source)
            XCTAssertEqual(source.last, utterance.text.last, source)
        }
        // Words map back to their place in the document, past the removed note marker.
        let sentence = chapter.utterances[1]
        let spoken = (sentence.text as NSString).range(of: "twice")
        let offset = try XCTUnwrap(sentence.sourceOffset(forSpoken: spoken.location))
        XCTAssertEqual(text.substring(with: NSRange(location: offset, length: 5)), "twice")
    }

    func testLeavesOutPageNumbersAndNoteMarkers() {
        let chapter = extract("""
            <p>It was a dark<span epub:type="pagebreak" id="page12" title="12">12</span> night.</p>
            <p>She read it<sup><a href="#fn3">3</a></sup> again<a class="noteref" href="notes.xhtml#n4">[4]</a>.</p>
            <div class="pagenum">xiv</div>
            <p>The end<span role="doc-pagebreak" aria-label="13"/> came.</p>
            <p id="fn3">3. A footnote that should not be read.</p>
            <p>— 15 —</p>
            """)
        XCTAssertEqual(texts(chapter), ["It was a dark night.", "She read it again.", "The end came."])
        let reasons = Set(chapter.omissions.map(\.reason))
        XCTAssertTrue(reasons.contains(.pageNumber))
        XCTAssertTrue(reasons.contains(.noteReference))
        XCTAssertTrue(reasons.contains(.notes))
    }

    func testSkipsFootnotesNotesSectionsHiddenTextAndRuby() {
        let chapter = extract("""
            <p>Body text.</p>
            <p hidden="">Hidden by attribute.</p>
            <p style="display: none">Hidden by style.</p>
            <p class="invisible">Hidden by class.</p>
            <p><ruby>漢<rp>(</rp><rt>kan</rt><rp>)</rp></ruby> stays.</p>
            <aside epub:type="pullquote">Body text.</aside>
            <h2>Notes</h2>
            <p>1. A note at the end of the chapter.</p>
            """, head: "<style>.invisible { display:none }</style>")
        XCTAssertEqual(texts(chapter), ["Body text.", "漢 stays."])
    }

    func testHiddenClassesComeFromLinkedStylesheets() {
        var context = SpeechExtractor.Context()
        context.stylesheet = { path in path == "OEBPS/style.css" ? "@media print { .print { display: none } } span.calibre_pb { display:none }" : nil }
        let chapter = extract("<p>Read<span class=\"calibre_pb\">this not</span> me. <span class=\"print\">Print hides me.</span></p>",
                              context: context, head: "<link rel=\"stylesheet\" href=\"style.css\"/>")
        XCTAssertEqual(texts(chapter), ["Read me.", "Print hides me."])
    }

    func testSkipsFrontAndBackMatterBySemantics() {
        XCTAssertEqual(extract("<section epub:type=\"copyright-page\"><p>Copyright 2026.</p></section>").skipReason, .copyright)
        XCTAssertEqual(extract("<div><section epub:type=\"index\"><p>Apples, 4</p></section></div>").skipReason, .index)
        XCTAssertEqual(extract("<section epub:type=\"chapter\"><p>Story.</p></section>").skipReason, nil)
        XCTAssertEqual(extract("<p>Appendix text.</p>", linear: false).skipReason, .auxiliary)
        var context = SpeechExtractor.Context()
        context.landmarks = ["OEBPS/chapter.xhtml": "toc"]
        XCTAssertEqual(extract("<p>Contents</p>", context: context).skipReason, .tableOfContents)
        context.navigationDocumentPath = "OEBPS/chapter.xhtml"
        context.landmarks = [:]
        XCTAssertEqual(extract("<p>Contents</p>", context: context).skipReason, .tableOfContents)
    }

    func testRecognizesUnmarkedFrontMatter() {
        let copyright = extract("""
            <p>Copyright © 2026 Ada Example</p><p>All rights reserved.</p><p>ISBN 978-0-00-000000-0</p>
            """)
        XCTAssertEqual(copyright.skipReason, .copyright)
        XCTAssertFalse(copyright.utterances.isEmpty, "Skipped documents keep their text so they can be read on request")

        let links = (1...8).map { "<p><a href=\"c\($0).xhtml\">Chapter \($0): A Long Chapter Title</a></p>" }.joined()
        XCTAssertEqual(extract("<h1>Contents</h1>\(links)").skipReason, .tableOfContents)

        XCTAssertEqual(extract("<h1>The Sample Voyage</h1><p>Ada Example</p>").skipReason, .titlePage)

        let terms = ["Apples", "Boats", "Compass", "Dawn", "Evening", "Fog", "Gulls", "Harbor", "Islands", "Jetty", "Keel", "Lanterns"]
        let index = terms.enumerated().map { "<p>\($1), \($0 + 3), \($0 * 7 + 1)–\($0 * 7 + 3)</p>" }.joined()
        XCTAssertEqual(extract(index).skipReason, .index)
    }

    func testSkipsTablesOfContentsInsideChapters() {
        let links = ["I.", "II.", "III.", "IV.", "V."].enumerated()
            .map { "<a href=\"c\($0.offset).xhtml\">\($0.element)</a>" }.joined(separator: ", ")
        let chapter = extract("""
            <h1>Pride and Prejudice</h1>
            <div class="toc"><p><a href="preface.xhtml">PREFACE.</a><br/>Chapter: \(links)</p></div>
            <p>It is a truth universally acknowledged. See <a href="#n">the note</a>, <a href="#m">this</a>.</p>
            """)
        XCTAssertEqual(texts(chapter), ["Pride and Prejudice", "It is a truth universally acknowledged.", "See the note, this."])
        XCTAssertTrue(chapter.omissions.contains { $0.reason == .tableOfContents })
    }

    func testSkipsIllustrationsAndTheirCaptions() {
        let chapter = extract("""
            <p>Before the picture.</p>
            <div class="figcenter" role="figure"><img src="a.jpg" alt=""/>
              <div class="caption"><p>“No, no; stay where you are”</p><p>[Copyright 1894.]</p></div></div>
            <figure><img src="b.jpg" alt=""/><figcaption>Figure 2: A map.</figcaption></figure>
            <table><tr><td>Ruskin House.</td><td><img src="p.png" alt=""/></td><td>156. Charing Cross Road.</td></tr></table>
            <p class="transnote">Transcriber's note: spelling kept.</p>
            <p>After the picture.</p>
            """)
        XCTAssertEqual(texts(chapter), ["Before the picture.", "After the picture."])
        XCTAssertTrue(chapter.omissions.contains { $0.reason == .illustration })
    }

    func testSkipsCodeListingsButKeepsInlineCode() {
        let chapter = extract("""
            <p>Call <code>print_line</code> to print.</p>
            <pre><code>fn main() {
                println!("Hello, world!");
            }</code></pre>
            <div class="highlight"><span>x = 1</span></div>
            <p>That prints a greeting.</p>
            """)
        XCTAssertEqual(texts(chapter), ["Call print_line to print.", "That prints a greeting."])
        XCTAssertEqual(chapter.omissions.filter { $0.reason == .code }.count, 2)
    }

    func testHeadingLinesJoinUnlessAfterALabel() {
        XCTAssertEqual(texts(extract("<h1><img src=\"f.png\" alt=\"\"/><br/><br/><i>PRIDE.<br/>and<br/>PREJUDICE</i></h1><p>Text.</p>")).first,
                       "PRIDE. and PREJUDICE")
        XCTAssertEqual(texts(extract("<h2>Part IV<br/>The Return</h2><p>Text.</p>")).first, "Part 4. The Return")
        XCTAssertEqual(texts(extract("<h2>Contents</h2><p>Text.</p>")), ["Text."])
    }

    func testStripsProjectGutenbergWrapper() {
        let chapter = extract("""
            <p>The Project Gutenberg eBook of A Tale</p>
            <p>*** START OF THE PROJECT GUTENBERG EBOOK A TALE ***</p>
            <p>Once upon a time.</p>
            <p>*** END OF THE PROJECT GUTENBERG EBOOK A TALE ***</p>
            <p>Updated editions will replace the previous one.</p>
            """)
        XCTAssertEqual(texts(chapter), ["Once upon a time."])
    }

    func testHeadingsReadNumeralsAndPauseAtLineBreaks() {
        XCTAssertEqual(texts(extract("<h2>Chapter IV</h2><p>Text.</p>")).first, "Chapter 4")
        XCTAssertEqual(texts(extract("<h2>XII.</h2><p>Text.</p>")).first, "12.")
        XCTAssertEqual(texts(extract("<h2>7</h2><p>Text.</p>")).first, "7", "Chapter numbers aren't page numbers")
        XCTAssertEqual(texts(extract("<h2>I Am Legend</h2><p>Text.</p>")).first, "I Am Legend")
        XCTAssertEqual(texts(extract("<h1>Chapter 1<br/>The Beginning</h1>")).first, "Chapter 1. The Beginning")
        XCTAssertEqual(texts(extract("<h1><img src=\"t.png\" alt=\"Chapter One\"/></h1><p>Text.</p>")).first, "Chapter One")
    }

    func testSceneBreaksBecomePauses() {
        let chapter = extract("<p>Before.</p><p class=\"center\">* * *</p><p>After.</p><hr/><p>Later.</p>")
        XCTAssertEqual(texts(chapter), ["Before.", "After.", "Later."])
        XCTAssertGreaterThanOrEqual(chapter.utterances[0].pauseAfter, 1)
        XCTAssertGreaterThanOrEqual(chapter.utterances[1].pauseAfter, 1)
    }

    func testRunningHeadsRepeatedThroughAChapterAreDropped() {
        let pages = (1...4).map { "<p>THE SAMPLE VOYAGE</p><p>Part \($0) of the story goes on.</p>" }.joined()
        XCTAssertEqual(texts(extract(pages)), (1...4).map { "Part \($0) of the story goes on." })
    }

    func testLanguageChangesSplitUtterances() {
        let chapter = extract("<p xml:lang=\"en\">He said <span xml:lang=\"fr\">bonjour, mon ami</span> and left.</p>")
        XCTAssertEqual(chapter.utterances.map(\.language), ["en", "fr", "en"])
    }

    func testCleansURLsLigaturesAndInlineMarkers() {
        let chapter = extract("<p>See https://www.example.com/a/b?c=d for de\u{FB01}nitions¹ and more[2].</p>")
        XCTAssertEqual(texts(chapter), ["See example.com for definitions and more."])
    }

    func testSplitsVeryLongSentencesAtClauses() {
        let clause = "the wind rose over the grey water and the gulls cried above the masts"
        let sentence = Array(repeating: clause, count: 8).joined(separator: ", ") + "."
        let pieces = texts(extract("<p>\(sentence)</p>"))
        XCTAssertGreaterThan(pieces.count, 1)
        XCTAssertTrue(pieces.allSatisfy { $0.count <= SpeechText.maximumUtteranceLength })
        XCTAssertEqual(pieces.joined(separator: " "), sentence)
    }

    func testPageNumberAndSceneBreakPatterns() {
        for text in ["12", "- 12 -", "[xiv]", "Page 7", "p. 12", "— 15 —"] {
            XCTAssertTrue(SpeechText.isPageNumber(text), text)
        }
        for text in ["12 Angry Men", "I", "Chapter 12", "1984 was a year."] {
            XCTAssertFalse(SpeechText.isPageNumber(text) && text.count > 2, text)
        }
        XCTAssertTrue(SpeechText.isSceneBreak("* * *"))
        XCTAssertTrue(SpeechText.isSceneBreak("⁂"))
        XCTAssertFalse(SpeechText.isSceneBreak("1."))
        XCTAssertFalse(SpeechText.isSceneBreak("Yes."))
        XCTAssertEqual(SpeechText.romanValue("XIV"), 14)
        XCTAssertNil(SpeechText.romanValue("IIII"))
        XCTAssertNil(SpeechText.romanValue("DID"))
    }

    func testSampleBookReadsChaptersAndSkipsTheFootnote() async throws {
        let archive = try ZipArchive(url: Fixtures.write(SampleBook.make()))
        let content = try Fixtures.temporaryDirectory()
        try archive.extractAll(to: content)
        let container = DirectoryContainer(root: content)
        let publication = try EPUBParser.parse(container)
        let provider = SpeechScriptProvider(publication: publication, container: container,
                                            folder: try Fixtures.temporaryDirectory())
        let script = await provider.script()
        XCTAssertEqual(script.readableChapters.count, 3)
        let first = try XCTUnwrap(script.readableChapters.first)
        XCTAssertEqual(first.utterances.first?.text, "Departure")
        XCTAssertTrue(first.utterances.contains { $0.text == "The captain checked the compass twice." })
        XCTAssertFalse(first.utterances.contains { $0.text.contains("brass") }, "The footnote isn't read inline")

        // Overrides persist: skip a chapter, then read it again.
        await provider.setIncluded(1, false)
        let skipping = SpeechScriptProvider(publication: publication, container: container, folder: provider.folder)
        let next = await skipping.readableChapter(from: 1)
        XCTAssertEqual(next?.spineIndex, 2)
        await skipping.setIncluded(1, true)
        let restored = await skipping.readableChapter(from: 1)
        XCTAssertEqual(restored?.spineIndex, 1)
    }

    func testLandmarksComeFromGuideReferences() throws {
        let package = Fixtures.package(
            metadata: "<dc:title>Old Book</dc:title><dc:language>en</dc:language>",
            manifest: """
                <item id="c" href="copyright.xhtml" media-type="application/xhtml+xml"/>
                <item id="t" href="text.xhtml" media-type="application/xhtml+xml"/>
                """,
            spine: "<itemref idref=\"c\"/><itemref idref=\"t\"/>", version: "2.0")
            .replacingOccurrences(of: "</package>", with: "<guide><reference type=\"copyright-page\" title=\"Copyright\" href=\"copyright.xhtml\"/></guide></package>")
        let data = try Fixtures.epub(package: package, files: [
            "copyright.xhtml": Fixtures.xhtml("<p>Published by somebody.</p>"),
            "text.xhtml": Fixtures.xhtml("<p>Story.</p>"),
        ])
        let publication = try EPUBParser.parse(ZipArchive(url: Fixtures.write(data)))
        XCTAssertEqual(publication.landmarks.first?.type, "copyright-page")
        XCTAssertEqual(publication.landmarks.first?.path, "OEBPS/copyright.xhtml")
    }
}

final class ScanLayoutTests: XCTestCase {
    private func line(_ text: String, x: Double = 0.1, top: Double, width: Double = 0.8, height: Double = 0.02) -> ScanReader.Line {
        ScanReader.Line(text: text, x: x, y: top - height, width: width, height: height)
    }

    func testDropsFoliosAndRunningHeadsAndJoinsHyphenation() {
        let lines = [
            line("THE SAMPLE VOYAGE", x: 0.3, top: 0.97, width: 0.4),
            line("The captain looked at the hori-", top: 0.85),
            line("zon and smiled at the crew.", top: 0.82, width: 0.5),
            line("A new paragraph begins here and", x: 0.15, top: 0.76, width: 0.75),
            line("continues on the next line.", top: 0.73, width: 0.6),
            line("42", x: 0.48, top: 0.04, width: 0.04),
        ]
        let page = ScanReader.layout(lines, context: .init(bookTitle: "The Sample Voyage", authors: ["Ada Example"]))
        XCTAssertEqual(page.paragraphs, [
            "The captain looked at the horizon and smiled at the crew.",
            "A new paragraph begins here and continues on the next line.",
        ])
        XCTAssertEqual(Set(page.omissions.map(\.reason)), [.runningHead, .pageNumber])
    }

    func testDropsMarginLinesRepeatedOnOtherPages() {
        let lines = [line("Chapter Three 61", x: 0.3, top: 0.96, width: 0.4), line("Body text.", top: 0.8)]
        let page = ScanReader.layout(lines, context: .init(marginText: ["chapterthree": 3]))
        XCTAssertEqual(page.paragraphs, ["Body text."])
    }

    func testReadsTwoColumnPagesColumnByColumn() {
        var lines: [ScanReader.Line] = []
        for row in 0..<5 {
            let top = 0.8 - Double(row) * 0.03
            lines.append(line("Left \(row)", x: 0.05, top: top, width: 0.4))
            lines.append(line("Right \(row)", x: 0.55, top: top, width: 0.4))
        }
        let ordered = ScanReader.readingOrder(lines).map(\.text)
        XCTAssertEqual(ordered, (0..<5).map { "Left \($0)" } + (0..<5).map { "Right \($0)" })
    }
}

final class PocketTextTests: XCTestCase {
    private static let tokenizer = try! PocketTokenizer(url: Bundle(for: PocketSynthesizer.self).url(forResource: "pocket-tokenizer", withExtension: "json")!)

    /// Token IDs from Hugging Face `tokenizers` for the same tokenizer.json.
    func testTokenizerMatchesTheReference() throws {
        struct Case: Decodable { let text: String; let ids: [Int] }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "pocket-tokenizer-cases", withExtension: "json"))
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
        XCTAssertGreaterThan(cases.count, 30)
        for test in cases {
            XCTAssertEqual(Self.tokenizer.encode(test.text), test.ids, test.text)
        }
    }

    func testDecodingRoundTrips() {
        for text in ["Hello world.", "Café owners in São Paulo.", "Emoji 😀 test.", "naïve, isn't it?"] {
            XCTAssertEqual(Self.tokenizer.decode(Self.tokenizer.encode(text)), text)
        }
    }

    func testCleaningUsesTypographyTheModelKnows() {
        // Curly quotes make the model drop words, so they become straight ones.
        XCTAssertEqual(PocketText.clean("“You can’t stay,” she said…", tokenizer: Self.tokenizer), "\"You can't stay,\" she said...")
        XCTAssertEqual(PocketText.clean("Wait , what ?", tokenizer: Self.tokenizer), "Wait, what?")
        XCTAssertEqual(PocketText.clean("He left (quietly) at dawn.", tokenizer: Self.tokenizer), "He left, quietly, at dawn.")
        XCTAssertEqual(PocketText.clean("A naïve plan.", tokenizer: Self.tokenizer), "A naive plan.")
        XCTAssertEqual(PocketText.clean("See § 4 • now", tokenizer: Self.tokenizer), "See 4 now")
        let cleaned = PocketText.clean("«Ça va?» — “Oui.” [1] and/or ½ 日本", tokenizer: Self.tokenizer)
        let bytes = Set((0...255).map { Self.tokenizer.encode(String(format: "<0x%02X>", $0)) }.compactMap { $0.count == 1 ? $0[0] : nil })
        XCTAssertTrue(Self.tokenizer.encode(cleaned).allSatisfy { !bytes.contains($0) }, cleaned)
    }

    func testPreparesTextLikeKyutai() {
        XCTAssertEqual(PocketText.prepare("hello there").text, "Hello there.")
        XCTAssertEqual(PocketText.prepare("He said, \"wait\"").text, "He said, \"wait\".")
        XCTAssertEqual(PocketText.prepare("And then —").text, "And then.")
        XCTAssertEqual(PocketText.prepare("Really?\"").text, "Really?\"")
        XCTAssertEqual(PocketText.prepare("Go.").framesAfterEnd, 5, "Short phrases keep more frames after the end")
        XCTAssertEqual(PocketText.prepare("This one is long enough.").framesAfterEnd, 3)
    }

    func testLongTextSplitsAtSentencesThenClauses() {
        let sentence = "The rain had not stopped for three days and the river kept rising."
        let chunks = PocketText.chunks(Array(repeating: sentence, count: 6).joined(separator: " "), tokenizer: Self.tokenizer)
        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(Self.tokenizer.encode(chunk).count, PocketText.maximumTokens, chunk)
            XCTAssertTrue(chunk.hasSuffix("."), chunk)
        }
        let clauses = Array(repeating: "one more thing to say about the weather", count: 8).joined(separator: ", ") + "."
        XCTAssertTrue(PocketText.chunks(clauses, tokenizer: Self.tokenizer).allSatisfy {
            Self.tokenizer.encode($0).count <= PocketText.maximumTokens
        })
        XCTAssertEqual(PocketText.chunks("Short.", tokenizer: Self.tokenizer), ["Short."])
    }

    func testNumbersAreReadAsWords() {
        XCTAssertEqual(SpokenEnglish.normalize("In 1984, prices rose by 3.5% a year."),
                       "In nineteen eighty-four, prices rose by three point five percent a year.")
        XCTAssertEqual(SpokenEnglish.normalize("He paid $45.50 at 10:30."), "He paid forty-five dollars and fifty cents at ten thirty.")
        XCTAssertEqual(SpokenEnglish.normalize("The 21st of June, 10:00, 9:05."), "The twenty-first of June, ten o'clock, nine oh five.")
        XCTAssertEqual(SpokenEnglish.normalize("The 1990s and 1,000,000 people."), "The nineteen nineties and one million people.")
        XCTAssertEqual(SpokenEnglish.normalize("Call 5551234567 for £3."), "Call five five five one two three four five six seven for three pounds.")
        XCTAssertEqual(SpokenEnglish.normalize("Salt & pepper"), "Salt and pepper")
        XCTAssertEqual(SpokenEnglish.normalize("THE END OF THE WORLD"), "the end of the world")
        XCTAssertEqual(SpokenEnglish.normalize("NASA and the FBI"), "NASA and the FBI")
    }

    func testTokensKnowWhereTheyStart() {
        let text = "Hi, naïve café 😀 friend."
        let tokens = Self.tokenizer.encodeWithOffsets(text)
        XCTAssertEqual(tokens.map(\.id), Self.tokenizer.encode(text))
        XCTAssertEqual(tokens.map(\.offset), tokens.map(\.offset).sorted())
        let scalars = Array(text.unicodeScalars)
        // Each word's first token starts at the word.
        for word in SpeechWords.words(in: text) {
            XCTAssertTrue(tokens.contains { $0.offset == word.scalarOffset }, word.text)
            XCTAssertEqual(String(scalars[word.scalarOffset]), String(word.text.unicodeScalars.first!))
        }
    }

    func testFindsWords() {
        let words = SpeechWords.words(in: "“Don’t,” she said—well-known café, 1984!")
        XCTAssertEqual(words.map(\.text), ["Don’t", "she", "said", "well", "known", "café", "1984"])
        let text = "“Don’t,” she said—well-known café, 1984!" as NSString
        XCTAssertEqual(words.map { text.substring(with: $0.range) }, words.map(\.text))
        XCTAssertEqual(SpeechWords.words(in: "😀 ok").first?.range, NSRange(location: 3, length: 2), "Ranges count UTF-16")
    }

    func testWordTimesFollowTheSpokenWords() {
        let text = "In 1984, Hermione paid $45.50 — a lot."
        let spoken: [(text: String, time: TimeInterval)] = [
            ("In", 0), ("nineteen", 0.2), ("eighty", 0.5), ("four", 0.7), ("Hermione", 1.0), ("paid", 1.5),
            ("forty", 1.8), ("five", 2.0), ("dollars", 2.2), ("and", 2.5), ("fifty", 2.6), ("cents", 2.9),
            ("a", 3.2), ("lot", 3.3),
        ]
        let timings = SpeechWords.timings(for: text, spoken: spoken)
        let source = text as NSString
        let byWord = Dictionary(timings.map { (source.substring(with: $0.range), $0.time) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(byWord["In"], 0)
        XCTAssertEqual(byWord["1984"], 0.2, "A number starts with its first spoken word")
        XCTAssertEqual(byWord["Hermione"], 1.0)
        XCTAssertEqual(byWord["45"], 1.8)
        XCTAssertEqual(byWord["lot"], 3.3)
        XCTAssertEqual(timings.map(\.time), timings.map(\.time).sorted())
        XCTAssertTrue(SpeechWords.timings(for: text, spoken: []).isEmpty)
    }

    func testWordTimesMatchAcrossTypography() {
        let timings = SpeechWords.timings(for: "“Café,” she said.", spoken: [("Cafe", 0.1), ("she", 0.6), ("said", 0.9)])
        XCTAssertEqual(timings.map(\.time), [0.1, 0.6, 0.9])
    }

    func testNumberWords() {
        XCTAssertEqual(NumberWords.cardinal(0), "zero")
        XCTAssertEqual(NumberWords.cardinal(1_234_567), "one million two hundred thirty-four thousand five hundred sixty-seven")
        XCTAssertEqual(NumberWords.ordinal(21), "twenty-first")
        XCTAssertEqual(NumberWords.ordinal(12), "twelfth")
        XCTAssertEqual(NumberWords.ordinal(40), "fortieth")
        XCTAssertEqual(NumberWords.year(1984), "nineteen eighty-four")
        XCTAssertEqual(NumberWords.year(1905), "nineteen oh five")
        XCTAssertEqual(NumberWords.year(1900), "nineteen hundred")
        XCTAssertEqual(NumberWords.year(2005), "two thousand five")
        XCTAssertEqual(NumberWords.year(2024), "twenty twenty-four")
    }
}

@MainActor
final class ListeningStorageTests: XCTestCase {
    func testEveryNaturalVoiceHasABundledPreviewAndPinnedChecksum() {
        XCTAssertEqual(Set(NeuralVoiceCatalog.voices.map(\.id)).count, NeuralVoiceCatalog.voices.count)
        for voice in NeuralVoiceCatalog.voices {
            XCTAssertNotNil(Bundle(for: PocketSynthesizer.self).url(forResource: "preview-\(voice.id)", withExtension: "m4a"), voice.id)
            XCTAssertEqual(voice.sha256.count, 64)
        }
        XCTAssertEqual(NeuralVoiceCatalog.models.map(\.name), ["FlowLM.mlmodelc.aar", "Mimi.mlmodelc.aar"])
        XCTAssertTrue(NeuralVoiceCatalog.models.allSatisfy { $0.sha256.count == 64 })
        XCTAssertLessThan(NeuralVoiceCatalog.downloadSize, 160_000_000, "The voices download stays under 160 MB")
    }

    func testContentsAreNamedFromTheTableOfContents() {
        func chapter(_ index: Int, title: String? = nil, skip: SpeechSkipReason? = nil, empty: Bool = false) -> SpeechChapter {
            SpeechChapter(spineIndex: index, title: title,
                          utterances: empty ? [] : [SpeechUtterance(spineIndex: index, text: String(repeating: "Words here. ", count: 100))],
                          skipReason: skip)
        }
        func item(_ path: String) -> SpineItem {
            SpineItem(item: ManifestItem(id: path, path: path, mediaType: "application/xhtml+xml", properties: [], fallback: nil,
                                         mediaOverlay: nil, remoteURL: nil), linear: true, properties: [], layout: .reflowable)
        }
        let toc = ["Chapter I", "Chapter II", "Chapter III"].enumerated().map {
            NavigationPoint(id: "\($0.offset)", title: $0.element, path: "book.xhtml", fragment: "c\($0.offset)", children: [])
        } + [NavigationPoint(id: "x", title: "Afterword", path: "after.xhtml", fragment: nil, children: [])]
        let publication = Publication(
            version: "3.0", packagePath: "content.opf", metadata: PublicationMetadata(title: "Book"), manifest: [],
            spine: ["cover.xhtml", "copyright.xhtml", "book.xhtml", "after.xhtml", "extra.xhtml"].map(item),
            tableOfContents: toc, pageList: [], landmarks: [], layout: .reflowable, readingProgression: .ltr,
            coverPath: nil, navigationDocumentPath: nil, obfuscatedResources: [:])
        let script = SpeechScript(chapters: [
            chapter(0, empty: true), chapter(1, skip: .copyright), chapter(2), chapter(3), chapter(4, title: "A Note"),
        ])
        let sections = SpeechSection.sections(script: script, publication: publication, overrides: SpeechOverrides(included: [1]))
        XCTAssertEqual(sections.map(\.spineIndex), [1, 2, 3, 4], "Documents with nothing to read aren't listed")
        XCTAssertEqual(sections.map(\.title), ["Copyright page", "Chapter I – Chapter III", "Afterword", "A Note"])
        XCTAssertTrue(sections[0].isRead, "Overrides show as read")
        XCTAssertTrue(sections[1].summary.hasSuffix("min"), sections[1].summary)
    }

    func testContentsPreferChapterEntriesOverCaptions() {
        let titles = ["PRIDE. and PREJUDICE", "Piling up the fire.", "CHAPTER I.", "“Mrs. Long and her nieces.”", "CHAPTER II.", "CHAPTER XI."]
        XCTAssertEqual(SpeechSection.chapterTitles(titles), ["Chapter I", "Chapter II", "Chapter XI"])
        XCTAssertEqual(SpeechSection.chapterTitles(["Departure", "Open Water"]), ["Departure", "Open Water"])
        XCTAssertEqual(SpeechSection.tidy("THE RED-HEADED LEAGUE."), "The Red-headed League")
    }

    func testPreferencesPersist() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SpeechTests-\(UUID().uuidString)"))
        XCTAssertEqual(ListeningPreferences.load(from: defaults).naturalVoice?.name, "George", "George is the default voice")
        var preferences = ListeningPreferences()
        preferences.speed = 1.5
        preferences.voice = .natural("michael")
        preferences.setSystemVoice("com.apple.voice.premium.en-US.Zoe", for: "en-GB")
        preferences.save(to: defaults)
        var loaded = ListeningPreferences.load(from: defaults)
        XCTAssertEqual(loaded, preferences)
        XCTAssertEqual(loaded.systemVoice(for: "en"), "com.apple.voice.premium.en-US.Zoe")
        XCTAssertEqual(loaded.naturalVoice?.name, "Michael")
        loaded.voice = .natural("af_heart")
        XCTAssertEqual(loaded.naturalVoice?.name, "George", "A Kokoro voice from an earlier version becomes the default")
        loaded.voice = .system
        XCTAssertNil(loaded.naturalVoice)
    }

    func testNaturalVoicesReadEnglishOnly() {
        XCTAssertTrue(NeuralVoiceCatalog.supports(language: "en-GB"))
        XCTAssertTrue(NeuralVoiceCatalog.supports(language: nil))
        XCTAssertFalse(NeuralVoiceCatalog.supports(language: "fr"))
    }

    func testSystemSpeechRatesStayInRange() {
        for speed in ListeningPreferences.speeds {
            let rate = SystemVoices.rate(for: speed)
            XCTAssertGreaterThanOrEqual(rate, AVSpeechUtteranceMinimumSpeechRate)
            XCTAssertLessThanOrEqual(rate, AVSpeechUtteranceMaximumSpeechRate)
        }
        XCTAssertEqual(SystemVoices.rate(for: 1), AVSpeechUtteranceDefaultSpeechRate)
        XCTAssertLessThan(SystemVoices.rate(for: 1), SystemVoices.rate(for: 2))
    }
}

/// Renders speech with the real Pocket TTS models. Skipped unless `TEST_RUNNER_MB_VOICE_MODEL_DIR` points at a folder
/// with `FlowLM.mlmodelc`, `Mimi.mlmodelc`, and `voices/george.bin` (the models aren't downloaded in CI).
final class PocketIntegrationTests: XCTestCase {
    func testSynthesizesSpeech() throws {
        if ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil {
            throw XCTSkip("The Simulator can't load multifunction Core ML models; run on a device")
        }
        guard let directory = ProcessInfo.processInfo.environment["MB_VOICE_MODEL_DIR"].map({ URL(filePath: $0) }) else {
            throw XCTSkip("Set TEST_RUNNER_MB_VOICE_MODEL_DIR to run")
        }
        let tokenizer = try PocketTokenizer(url: XCTUnwrap(Bundle(for: PocketSynthesizer.self).url(forResource: "pocket-tokenizer", withExtension: "json")))
        let synthesizer = try PocketSynthesizer(directory: directory, tokenizer: tokenizer)
        try synthesizer.loadVoice(id: "george", from: directory.appending(path: "voices/george.bin"))
        let text = "“It was the best of times,” he said, “it was the worst of times.” Hermione paid $45.50 for the 21st edition in 1984."
        _ = try synthesizer.synthesize("Warming up.", voice: "george")
        let started = Date.now
        let speech = try synthesizer.synthesize(text, voice: "george")
        let samples = speech.samples
        let elapsed = Date.now.timeIntervalSince(started)
        let seconds = Double(samples.count) / NeuralVoiceCatalog.sampleRate
        print("Pocket TTS rendered \(seconds) s of audio in \(elapsed) s (\(seconds / elapsed)× real time)")
        XCTAssertGreaterThan(seconds, 5)
        XCTAssertLessThan(seconds, 25)
        XCTAssertGreaterThan(samples.map(abs).max() ?? 0, 0.05, "Not silent")
        XCTAssertThrowsError(try synthesizer.synthesize(text, voice: "george", isCancelled: { true }))
        // Every word on the page gets a time, in order, within the audio.
        let timings = SpeechWords.timings(for: text, spoken: speech.words)
        XCTAssertEqual(timings.count, SpeechWords.words(in: text).count)
        XCTAssertEqual(timings.map(\.time), timings.map(\.time).sorted())
        XCTAssertLessThan(timings.last?.time ?? .infinity, seconds)
        // Save for listening or transcription.
        if let output = ProcessInfo.processInfo.environment["MB_VOICE_OUTPUT"] {
            let format = try XCTUnwrap(NeuralSpeechBackend.format)
            let file = try AVAudioFile(forWriting: URL(filePath: output), settings: format.settings)
            try file.write(from: XCTUnwrap(NeuralSpeechBackend.buffer(samples, format: format)))
        }
    }
}

/// Writes what would be read from real books, for reviewing the extraction rules. Skipped unless
/// `TEST_RUNNER_MB_LISTEN_DIR` is a folder of `.epub` files; the report goes to `TEST_RUNNER_MB_SPEECH_REPORT`.
final class SpeechReportTests: XCTestCase {
    func testReportWhatIsRead() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["MB_LISTEN_DIR"], let report = environment["MB_SPEECH_REPORT"] else {
            throw XCTSkip("Set TEST_RUNNER_MB_LISTEN_DIR and TEST_RUNNER_MB_SPEECH_REPORT to run")
        }
        var lines: [String] = []
        for file in try FileManager.default.contentsOfDirectory(atPath: directory).sorted() where file.hasSuffix(".epub") {
            let archive = try ZipArchive(url: URL(filePath: directory).appending(path: file))
            let content = try Fixtures.temporaryDirectory()
            try archive.extractAll(to: content)
            let container = DirectoryContainer(root: content)
            let publication = try EPUBParser.parse(container)
            let provider = SpeechScriptProvider(publication: publication, container: container, folder: try Fixtures.temporaryDirectory())
            let script = await provider.script()
            lines.append("# \(file): \(publication.metadata.title)")
            for chapter in script.chapters {
                let omitted = Dictionary(grouping: chapter.omissions, by: \.reason).map { "\($0.key.rawValue)×\($0.value.count)" }.sorted()
                lines.append("## [\(chapter.spineIndex)] \(chapter.skipReason.map { "SKIP \($0.rawValue)" } ?? "READ") "
                             + "\(chapter.utterances.count) utterances; omitted \(omitted.joined(separator: " "))")
                for utterance in chapter.utterances.prefix(4) { lines.append("    \(utterance.text.prefix(110))") }
                for omission in chapter.omissions.prefix(3) { lines.append("    - \(omission.reason.rawValue): \(omission.text.prefix(80))") }
            }
        }
        try lines.joined(separator: "\n").write(toFile: report, atomically: true, encoding: .utf8)
    }
}
