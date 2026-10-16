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

final class PronunciationTests: XCTestCase {
    private static let g2p: EnglishG2P = {
        let bundle = Bundle(for: EnglishG2P.self)
        return try! EnglishG2P.load(
            gold: bundle.url(forResource: "us_gold", withExtension: "json")!,
            silver: bundle.url(forResource: "us_silver", withExtension: "json")!,
            fallback: bundle.url(forResource: "g2p-en-us", withExtension: "safetensors"))
    }()

    /// Expected output from misaki (hexgrad/misaki@fba1236) for the same text, except where noted.
    func testMatchesMisaki() throws {
        guard EnglishG2P.hasTagger else { throw XCTSkip("This simulator has no English part-of-speech model") }
        let cases = [
            ("It was the best of times, it was the worst of times.",
             "ˌɪt wʌz ðə bˈɛst ʌv tˈImz, ɪt wʌz ðə wˈɜɹst ʌv tˈImz."),
            ("Mr. Bennet was among the earliest of those who waited on Mr. Bingley.",
             "mˈɪstəɹ bˈɛnət wʌz əmˈʌŋ ði ˈɜɹliᵻst ʌv ðOz hˌu wˈATᵻd ˌɔn mˈɪstəɹ bˈɪŋli."),
            ("\"I don't know,\" she said, \"but I'll find out tomorrow.\"",
             "“ˌI dˈOnt nˈO,” ʃi sˈɛd, “bˌʌt ˌIl fˈInd ˈWt təmˈɑɹO.”"),
            ("The FBI and NASA met in Washington, D.C. on the 21st of June.",
             "ði ˌɛfbˌiˈI ænd nˈæsə mˈɛt ɪn wˈɔʃɪŋtən, dˌisˈi ˌɔn ðə twˈɛnti fˈɜɹst ʌv ʤˈun."),
            ("Hermione looked at Harry, who was reading the letter from Dumbledore.",
             "hˈɜɹmiˌOn lˈʊkt æt hˈɛɹi, hˌu wʌz ɹˈidɪŋ ðə lˈɛTəɹ fɹʌm dˈʌmᵊldˌɔɹ."),
            // Tagger models differ between OS builds, so only unambiguous heteronyms are compared.
            ("The record shows that I will record the song.", "ðə ɹˈɛkəɹd ʃˈOz ðæt ˌI wɪl ɹəkˈɔɹd ðə sˈɔŋ."),
            ("It's a well-known fact that co-operation is key.",
             "ˌɪts ɐ wˌɛlnˈOn fˈækt ðæt kˌOˌɑpəɹˈAʃən ɪz kˈi."),
            // misaki reads years as "nineteen hundred eighty-four"; this reads them as people say them.
            ("In 1984, prices rose by 3.5% a year.",
             "ɪn nˌIntˈin ˈATi fˈɔɹ, pɹˈIsᵻz ɹˈOz bI θɹˈi pYnt fˈIv pəɹsˈɛnt ɐ jˈɪɹ."),
            // misaki reads "10:30" as letters; this reads clock times.
            ("He paid $45.50 at 10:30.", "hˌi pˈAd fˈɔɹTi fˈIv dˈɑləɹz ænd fˈɪfti sˈɛnts æt tˈɛn θˈɜɹTi."),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(Self.g2p.phonemize(text), expected, text)
        }
    }

    /// Without Apple's tagger, closed word classes and context still pick the right pronunciations.
    func testPronouncesFunctionWordsWithoutTheTagger() throws {
        let bundle = Bundle(for: EnglishG2P.self)
        let g2p = try EnglishG2P.load(
            gold: XCTUnwrap(bundle.url(forResource: "us_gold", withExtension: "json")),
            silver: XCTUnwrap(bundle.url(forResource: "us_silver", withExtension: "json")), fallback: nil)
        g2p.usesTagger = false
        XCTAssertEqual(g2p.phonemize("I will record a song in the studio."), "ˌI wɪl ɹəkˈɔɹd ɐ sˈɔŋ ɪn ðə stˈudiO.")
        XCTAssertEqual(g2p.phonemize("The record is in."), "ðə ɹˈɛkəɹd ɪz ˈɪn.")
        XCTAssertTrue(g2p.phonemize("She had read the letter.").contains("ɹˈɛd"))
    }

    func testPastTenseReadFromContext() throws {
        guard EnglishG2P.hasTagger else { throw XCTSkip("This simulator has no English part-of-speech model") }
        XCTAssertTrue(Self.g2p.phonemize("She had read the letter.").contains("ɹˈɛd"))
        XCTAssertTrue(Self.g2p.phonemize("She read the book yesterday.").contains("ɹˈɛd"))
        XCTAssertTrue(Self.g2p.phonemize("She will read the book.").contains("ɹˈid"))
    }

    func testFallbackModelMatchesItsReference() throws {
        let url = try XCTUnwrap(Bundle(for: G2PFallback.self).url(forResource: "g2p-en-us", withExtension: "safetensors"))
        let model = try G2PFallback(url: url)
        // Greedy decoding from the original PyTorch model.
        XCTAssertEqual(model.phonemes(for: "Daenerys"), "dˈAnəɹiz")
        XCTAssertEqual(model.phonemes(for: "Okonkwo"), "ˌOkˈɑŋkwO")
        XCTAssertEqual(model.phonemes(for: "Aragorn"), "ˈɛɹəɡˌɔɹn")
    }

    func testShoutingIsNotSpelledOut() {
        XCTAssertFalse(Self.g2p.phonemize("THE END OF THE WORLD").contains("ˌɛ"))
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

    func testPhonemesStayWithinKokorosVocabulary() {
        let text = "Café owners in São Paulo charged €3.20 — “outrageous!” — for 2 croissants at 9:05; naïve, isn't it?"
        let phonemes = Self.g2p.phonemize(text)
        let unknown = phonemes.unicodeScalars.filter { NeuralVoiceCatalog.vocabulary[Character($0)] == nil }
        XCTAssertTrue(unknown.isEmpty, "Unknown symbols: \(String(String.UnicodeScalarView(unknown)))")
        XCTAssertFalse(phonemes.isEmpty)
    }
}

@MainActor
final class ListeningStorageTests: XCTestCase {
    func testAudiobookStoreRoundTripsAAC() throws {
        let folder = try Fixtures.temporaryDirectory()
        let store = AudiobookStore(bookFolder: folder, voice: NeuralVoiceCatalog.defaultVoice)
        let utterance = SpeechUtterance(spineIndex: 0, text: "Hello there.", start: 0, end: 12)
        XCTAssertFalse(store.contains(utterance))
        let samples = (0..<24_000).map { Float(sin(Double($0) * 2 * .pi * 220 / 24_000) * 0.3) }
        try store.write(samples, for: utterance)
        XCTAssertTrue(store.contains(utterance))
        let read = try store.readSamples(utterance)
        XCTAssertEqual(Double(read.count), Double(samples.count), accuracy: 4096, "AAC adds a little padding at most")
        XCTAssertGreaterThan(read.map(abs).max() ?? 0, 0.1)
        XCTAssertGreaterThan(AudiobookStore.size(bookFolder: folder), 0)

        var other = utterance
        other.text = "Something else."
        XCTAssertNotEqual(store.url(for: utterance), store.url(for: other))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).contains { $0.hasPrefix(".") },
                       "No temporary files are left behind")
        AudiobookStore.remove(bookFolder: folder)
        XCTAssertFalse(store.contains(utterance))
    }

    func testPreferencesPersist() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SpeechTests-\(UUID().uuidString)"))
        var preferences = ListeningPreferences()
        preferences.mode = .studio
        preferences.speed = 1.5
        preferences.neuralVoiceID = "am_michael"
        preferences.setSystemVoice("com.apple.voice.premium.en-US.Zoe", for: "en-GB")
        preferences.save(to: defaults)
        let loaded = ListeningPreferences.load(from: defaults)
        XCTAssertEqual(loaded, preferences)
        XCTAssertEqual(loaded.systemVoice(for: "en"), "com.apple.voice.premium.en-US.Zoe")
        XCTAssertEqual(loaded.neuralVoice.name, "Michael")
    }

    func testStudioSupportsEnglishOnly() {
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

/// Renders speech with the real Kokoro model. Skipped unless `TEST_RUNNER_MB_KOKORO_DIR` points at a folder
/// with `model.onnx` and `af_heart.bin` (the model is 300 MB, so it isn't downloaded in CI).
final class KokoroIntegrationTests: XCTestCase {
    func testSynthesizesIntelligibleSpeech() throws {
        guard let directory = ProcessInfo.processInfo.environment["MB_KOKORO_DIR"].map({ URL(filePath: $0) }) else {
            throw XCTSkip("Set TEST_RUNNER_MB_KOKORO_DIR to run")
        }
        let g2p = try EnglishG2P.bundled()
        let synthesizer = try KokoroSynthesizer(modelURL: directory.appending(path: "model.onnx"), g2p: g2p)
        try synthesizer.loadVoice(id: "af_heart", from: directory.appending(path: "af_heart.bin"))
        let text = "It was the best of times, it was the worst of times. Hermione paid $45.50 for the 21st edition in 1984."
        let started = Date.now
        let samples = try synthesizer.synthesize(text, voice: "af_heart")
        let elapsed = Date.now.timeIntervalSince(started)
        let seconds = Double(samples.count) / NeuralVoiceCatalog.sampleRate
        print("Kokoro rendered \(seconds) s of audio in \(elapsed) s (\(seconds / elapsed)× real time)")
        XCTAssertGreaterThan(seconds, 4)
        XCTAssertLessThan(seconds, 20)
        XCTAssertGreaterThan(samples.map(abs).max() ?? 0, 0.05, "Not silent")
        // Save for listening or transcription.
        if let output = ProcessInfo.processInfo.environment["MB_KOKORO_OUTPUT"] {
            let format = try XCTUnwrap(AudiobookStore.format)
            let file = try AVAudioFile(forWriting: URL(filePath: output), settings: format.settings)
            try file.write(from: XCTUnwrap(AudiobookStore.buffer(samples, format: format)))
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
