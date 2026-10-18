import Foundation

/// Decides what in a content document is the book, and turns it into utterances.
///
/// Books carry a lot of text nobody wants read aloud: page numbers from print editions, footnote
/// markers in the middle of sentences, running heads, copyright pages, tables of contents, and indexes.
/// The extractor uses the publisher's semantics first (`epub:type`, ARIA roles, landmarks, `linear="no"`),
/// then falls back to heuristics for books that don't mark them up. Everything it leaves out is recorded
/// with a reason, so the choices can be reviewed and overridden.
///
/// Text positions are UTF-16 offsets into the document's text nodes, counted exactly as `reader.js` counts
/// them, so the reader can highlight what's being said.
nonisolated struct SpeechExtractor {
    struct Context: Sendable {
        var bookTitle: String = ""
        var authors: [String] = []
        var language: String?
        /// Landmark types by container path, from the navigation document or OPF guide.
        var landmarks: [String: String] = [:]
        var navigationDocumentPath: String?
        /// Loads a stylesheet by container path, to find classes the book hides.
        var stylesheet: @Sendable (String) -> String? = { _ in nil }
    }

    let context: Context

    init(context: Context) {
        self.context = context
    }

    init(publication: Publication, container: some PublicationContainer & Sendable) {
        var landmarks: [String: String] = [:]
        for landmark in publication.landmarks {
            guard let path = landmark.path, let type = landmark.type else { continue }
            // A landmark for a fragment marks part of a document, not all of it.
            if landmark.fragment == nil || landmarks[path] == nil { landmarks[path] = type }
        }
        context = Context(
            bookTitle: publication.metadata.title, authors: publication.metadata.authors,
            language: publication.metadata.language, landmarks: landmarks,
            navigationDocumentPath: publication.navigationDocumentPath,
            stylesheet: { path in (try? container.data(at: path)).map { String(decoding: $0, as: UTF8.self) } })
    }

    // MARK: - Documents

    /// Document types that aren't read: front and back matter a narrator would skip.
    static let skippedTypes: [String: SpeechSkipReason] = [
        "cover": .cover, "titlepage": .titlePage, "halftitlepage": .titlePage, "fulltitle": .titlePage,
        "title-page": .titlePage, "copyright-page": .copyright, "copyright": .copyright, "imprint": .copyright,
        "toc": .tableOfContents, "landmarks": .navigation, "loi": .tableOfContents, "lot": .tableOfContents,
        "lov": .tableOfContents, "page-list": .navigation, "index": .index, "colophon": .colophon,
        "endnotes": .notes, "footnotes": .notes, "rearnotes": .notes, "bibliography": .bibliography,
        "errata": .auxiliary, "seriespage": .auxiliary, "other-credits": .colophon, "frontispiece": .cover,
        "doc-toc": .tableOfContents, "doc-index": .index, "doc-endnotes": .notes, "doc-colophon": .colophon,
        "doc-bibliography": .bibliography, "doc-errata": .auxiliary, "doc-credits": .colophon,
        // EPUB 2 guide types.
        "title page": .titlePage, "copyright page": .copyright, "notes": .notes,
    ]

    func chapter(spineIndex: Int, item: SpineItem, data: Data) -> SpeechChapter {
        var chapter = SpeechChapter(spineIndex: spineIndex)
        if !item.linear {
            chapter.skipReason = .auxiliary
            return chapter
        }
        if item.item.path == context.navigationDocumentPath {
            chapter.skipReason = .tableOfContents
            return chapter
        }
        if let type = context.landmarks[item.item.path], let reason = Self.skippedTypes[type.lowercased()] {
            chapter.skipReason = reason
        }
        guard item.item.isXHTML, let root = try? MarkupParser.parse(data),
              let body = root.firstDescendant(named: "body")
        else {
            chapter.skipReason = chapter.skipReason ?? .empty
            return chapter
        }
        if chapter.skipReason == nil, let reason = documentSkipReason(root: root, body: body) {
            chapter.skipReason = reason
        }
        var walker = Walker(
            context: context, hiddenClasses: hiddenClasses(root: root, documentPath: item.item.path),
            noteTargets: noteTargets(body: body, documentPath: item.item.path), documentPath: item.item.path)
        walker.walk(body, language: language(of: root) ?? context.language)
        walker.flush()
        chapter.title = walker.firstHeading
        chapter.omissions = walker.omissions
        let blocks = postProcess(walker.blocks, omissions: &chapter.omissions)
        chapter.utterances = utterances(from: blocks, spineIndex: spineIndex)
        if chapter.skipReason == nil, let reason = contentSkipReason(blocks: blocks, walker: walker) {
            chapter.skipReason = reason
        }
        if chapter.skipReason == nil, chapter.utterances.isEmpty {
            // Nothing left to read: say why, if one reason accounts for most of what was left out.
            let reasons = Dictionary(grouping: chapter.omissions, by: \.reason).mapValues(\.count)
            let main = reasons.max { $0.value < $1.value }
            chapter.skipReason = main.flatMap { $0.key.isOverridable || $0.key == .navigation ? $0.key : nil } ?? .empty
        }
        return chapter
    }

    private func language(of root: MarkupElement) -> String? {
        let body = root.firstDescendant(named: "body")
        return body?.attribute("lang", namespace: XMLNamespace.xml) ?? body?.attribute("lang")
            ?? root.attribute("lang", namespace: XMLNamespace.xml) ?? root.attribute("lang")
    }

    /// Structural semantics on the body or its top-level sections.
    private func documentSkipReason(root: MarkupElement, body: MarkupElement) -> SpeechSkipReason? {
        var candidates = [body]
        var level = body.elements
        // Look through wrappers such as <div class="main"><section epub:type="copyright-page">.
        for _ in 0..<3 {
            let meaningful = level.filter { !["script", "style"].contains($0.name) }
            guard meaningful.count <= 3 else { break }
            candidates += meaningful
            level = meaningful.flatMap(\.elements)
        }
        for element in candidates {
            let types = element.tokens("type", namespace: XMLNamespace.ops).union(element.tokens("role"))
            if types.contains(where: { ["bodymatter", "chapter", "part", "doc-chapter", "doc-part"].contains($0) }) {
                return nil
            }
            for type in types.sorted() {
                if let reason = Self.skippedTypes[type] { return reason }
            }
        }
        if let title = root.firstDescendant(named: "title")?.normalizedText.lowercased() {
            if Self.boilerplateTitles.contains(where: { title.contains($0) }) { return .boilerplate }
        }
        return nil
    }

    private static let boilerplateTitles = ["project gutenberg license", "full project gutenberg"]

    /// Heuristics for books without semantics, applied to what would otherwise be read.
    private func contentSkipReason(blocks: [Block], walker: Walker) -> SpeechSkipReason? {
        let text = blocks.map(\.text.string).joined(separator: "\n")
        let lowered = text.lowercased()
        let characters = text.count
        // Mostly links: a table of contents.
        if walker.linkCount >= 5, walker.totalCharacters > 0,
           Double(walker.linkCharacters) / Double(walker.totalCharacters) > 0.6 {
            return .tableOfContents
        }
        // Short documents dominated by rights and publishing details.
        let rightsSignals = ["copyright", "©", "all rights reserved", "isbn", "library of congress",
                             "first published", "printed in", "cataloging-in-publication", "no part of this publication"]
            .filter { lowered.contains($0) }.count
        if characters < 4000, rightsSignals >= 2 { return .copyright }
        // Lines of terms followed by page references: an index.
        let indexLines = blocks.filter {
            $0.text.string.range(of: #"^[^\d]{2,60},\s*\d+(?:[-–]\d+)?(?:,\s*\d+(?:[-–]\d+)?)*\.?$"#, options: .regularExpression) != nil
        }
        if blocks.count >= 10, Double(indexLines.count) / Double(blocks.count) > 0.5 { return .index }
        // Just the title and author: a title page.
        if characters < 300, !context.bookTitle.isEmpty, lowered.contains(context.bookTitle.lowercased()) {
            let remainder = context.authors.reduce(lowered.replacingOccurrences(of: context.bookTitle.lowercased(), with: "")) {
                $0.replacingOccurrences(of: $1.lowercased(), with: "")
            }
            if remainder.filter(\.isLetter).count < 60 { return .titlePage }
        }
        if lowered.contains("project gutenberg") && lowered.contains("license") && lowered.contains("trademark") {
            return .boilerplate
        }
        return nil
    }

    // MARK: - Blocks

    struct Block {
        enum Kind { case heading, text, caption, sceneBreak }
        var kind: Kind
        var text: MappedText
        var language: String?
    }

    /// Drops page numbers, repeated running heads, and Project Gutenberg wrappers; turns ornaments into pauses.
    private func postProcess(_ blocks: [Block], omissions: inout [SpeechOmission]) -> [Block] {
        var result: [Block] = []
        var counts: [String: Int] = [:]
        for block in blocks where block.kind != .sceneBreak {
            let key = block.text.string.lowercased()
            if key.count <= 80 { counts[key, default: 0] += 1 }
        }
        let names = ([context.bookTitle] + context.authors).map { $0.lowercased() }.filter { !$0.isEmpty }
        var inGutenbergHeader = blocks.contains { $0.text.string.uppercased().contains("*** START OF") }
        for block in blocks {
            let text = block.text.string
            let upper = text.uppercased()
            if upper.contains("*** START OF") {
                inGutenbergHeader = false
                omissions.append(.init(reason: .boilerplate, text: String(text.prefix(80))))
                continue
            }
            if upper.contains("*** END OF") { break }
            if text.range(of: #"(?i)\bebook\s*\[?\s*#\s*\d+|gutenberg\.org"#, options: .regularExpression) != nil {
                omissions.append(.init(reason: .boilerplate, text: String(text.prefix(80))))
                continue
            }
            if inGutenbergHeader {
                omissions.append(.init(reason: .boilerplate, text: String(text.prefix(80))))
                continue
            }
            if block.kind == .sceneBreak || SpeechText.isSceneBreak(text) {
                if result.last?.kind != .sceneBreak, !result.isEmpty {
                    result.append(Block(kind: .sceneBreak, text: MappedText(), language: nil))
                }
                continue
            }
            // Headings that are just a number ("12", "XII") are chapter numbers, not page numbers.
            if block.kind != .heading, SpeechText.isPageNumber(text) {
                omissions.append(.init(reason: .pageNumber, text: text))
                continue
            }
            // A short line repeated through the chapter that names the book or its author is a running head.
            let key = text.lowercased()
            if block.kind != .heading, key.count <= 80, (counts[key] ?? 0) >= 3, names.contains(where: { key.contains($0) }) {
                omissions.append(.init(reason: .runningHead, text: text))
                continue
            }
            result.append(block)
        }
        while result.last?.kind == .sceneBreak { result.removeLast() }
        return result
    }

    private func utterances(from blocks: [Block], spineIndex: Int) -> [SpeechUtterance] {
        var result: [SpeechUtterance] = []
        for block in blocks {
            if block.kind == .sceneBreak {
                if !result.isEmpty { result[result.count - 1].pauseAfter = max(result[result.count - 1].pauseAfter, 1.2) }
                continue
            }
            var text = block.text
            if block.kind == .heading { text = SpeechText.headingText(text) }
            let string = text.string
            let ranges = block.kind == .heading
                ? [string.startIndex..<string.endIndex]
                : SpeechText.sentences(in: string, language: block.language)
            for (position, range) in ranges.enumerated() {
                var lower = string.distance(from: string.startIndex, to: range.lowerBound)
                var upper = string.distance(from: string.startIndex, to: range.upperBound)
                let characters = text.characters
                while lower < upper, characters[lower].isWhitespace { lower += 1 }
                while upper > lower, characters[upper - 1].isWhitespace { upper -= 1 }
                guard lower < upper else { continue }
                let piece = text.slice(lower..<upper)
                guard piece.characters.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
                let source = text.sourceRange(lower..<upper)
                let isLast = position == ranges.count - 1
                result.append(SpeechUtterance(
                    spineIndex: spineIndex, text: piece.string, start: source?.start, end: source?.end,
                    anchors: text.anchors(lower..<upper),
                    kind: block.kind == .heading ? .heading : block.kind == .caption ? .caption : .text,
                    language: block.language,
                    pauseAfter: block.kind == .heading ? 0.8 : isLast ? 0.35 : 0))
            }
        }
        return result
    }

    // MARK: - Stylesheets and notes

    /// Classes that the book's CSS hides with `display: none` or `visibility: hidden`.
    private func hiddenClasses(root: MarkupElement, documentPath: String) -> Set<String> {
        var sheets = root.descendants(named: "style").map(\.textContent)
        for link in root.descendants(named: "link") where link.attribute("rel")?.lowercased().contains("stylesheet") == true {
            guard let href = link.attribute("href"), let target = EPUBPath.resolve(href, relativeTo: documentPath),
                  let css = context.stylesheet(target.path)
            else { continue }
            sheets.append(css)
        }
        return Set(sheets.flatMap(CSSHiddenRules.hiddenClasses))
    }

    /// IDs that note references in this document point to, so the notes themselves aren't read inline.
    private func noteTargets(body: MarkupElement, documentPath: String) -> Set<String> {
        var targets: Set<String> = []
        for link in body.descendants(named: "a") {
            guard let href = link.attribute("href"), Walker.isNoteReference(link),
                  let target = EPUBPath.resolve(href, relativeTo: documentPath),
                  target.path == documentPath, let fragment = target.fragment
            else { continue }
            targets.insert(fragment)
        }
        return targets
    }
}

// MARK: - Walking the document

private nonisolated struct Walker {
    let context: SpeechExtractor.Context
    let hiddenClasses: Set<String>
    let noteTargets: Set<String>
    let documentPath: String

    private(set) var blocks: [SpeechExtractor.Block] = []
    private(set) var omissions: [SpeechOmission] = []
    private(set) var firstHeading: String?
    private(set) var linkCount = 0
    private(set) var linkCharacters = 0
    private(set) var totalCharacters = 0

    /// UTF-16 offset of the next text node, counted as `reader.js` counts.
    private var offset = 0
    private var current = MappedText()
    private var currentKind: SpeechExtractor.Block.Kind = .text
    private var currentLanguage: String?
    private var headingDepth = 0
    private var captionDepth = 0
    private var linkDepth = 0
    /// Set while inside a "Notes" section at the end of a chapter.
    private var notesHeadingLevel: Int?

    init(context: SpeechExtractor.Context, hiddenClasses: Set<String>, noteTargets: Set<String>, documentPath: String) {
        self.context = context
        self.hiddenClasses = hiddenClasses
        self.noteTargets = noteTargets
        self.documentPath = documentPath
    }

    /// Elements whose text `reader.js` never sees.
    static let unrendered: Set<String> = ["script", "style", "noscript", "template", "head", "title"]

    static let blockElements: Set<String> = [
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "ul", "ol", "dl", "dt", "dd", "blockquote", "section",
        "article", "aside", "header", "footer", "main", "figure", "figcaption", "pre", "table", "thead", "tbody",
        "tfoot", "tr", "td", "th", "caption", "address", "hgroup", "details", "summary", "nav", "body", "center",
        "fieldset", "legend", "form", "hr",
    ]

    private static let noteTypes: Set<String> = [
        "footnote", "endnote", "rearnote", "footnotes", "endnotes", "rearnotes", "note",
        "doc-footnote", "doc-endnote", "doc-endnotes",
    ]
    private static let navigationTypes: Set<String> = [
        "toc", "landmarks", "page-list", "index", "loi", "lot", "doc-toc", "doc-index", "doc-pagelist",
    ]
    private static let notesHeadings: Set<String> = ["notes", "footnotes", "endnotes", "references"]

    /// A short marker such as "12", "*", "[3]", or "iv" that links to a note.
    static func isNoteMarker(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 6 else { return false }
        return trimmed.range(of: #"^[\[\(]?(?:\d{1,3}|[*†‡§¶#]+|[a-z]|[ivxlc]{1,5})[\]\)]?$"#, options: .regularExpression) != nil
    }

    static func isNoteReference(_ element: MarkupElement) -> Bool {
        let types = element.tokens("type", namespace: XMLNamespace.ops).union(element.tokens("role"))
        if types.contains("noteref") || types.contains("doc-noteref") { return true }
        guard element.name == "a", let href = element.attribute("href"), href.contains("#"),
              !EPUBPath.isExternal(href)
        else { return false }
        let classes = (element.attribute("class") ?? "").lowercased()
        if ["noteref", "footnote", "fnref", "endnote", "note-ref", "footnote-ref"].contains(where: classes.contains) { return true }
        return isNoteMarker(element.textContent)
    }

    // MARK: Walking

    mutating func walk(_ element: MarkupElement, language: String?) {
        let name = element.name.lowercased()
        if Self.unrendered.contains(name) { return }
        let language = element.attribute("lang", namespace: XMLNamespace.xml) ?? element.attribute("lang") ?? language

        if let reason = skipReason(element, name: name) {
            skip(element, reason: reason, isBlock: Self.blockElements.contains(name))
            return
        }
        let isBlock = Self.blockElements.contains(name)
        let headingLevel = Self.headingLevel(element, name: name)

        if let notesLevel = notesHeadingLevel {
            if let level = headingLevel, level <= notesLevel {
                notesHeadingLevel = nil
            } else {
                skip(element, reason: .notes, isBlock: isBlock)
                return
            }
        }
        if let level = headingLevel, Self.notesHeadings.contains(element.normalizedText.lowercased()) {
            notesHeadingLevel = level
            skip(element, reason: .notes, isBlock: true)
            return
        }

        switch name {
        case "br":
            // A break after a label in a heading ("Chapter 1<br/>The Beginning") is a pause; a heading set on
            // several lines ("PRIDE<br/>and<br/>PREJUDICE") just continues.
            if headingDepth > 0, Self.endsWithHeadingLabel(current.string) {
                current.appendSynthetic(". ", at: offset)
            } else {
                current.appendSynthetic(" ", at: offset)
            }
            return
        case "hr":
            flush()
            blocks.append(.init(kind: .sceneBreak, text: MappedText(), language: nil))
            return
        case "img", "image":
            // Pictures aren't described, but a heading set as an image of text is read from its alt text.
            if headingDepth > 0, let alt = element.attribute("alt")?.trimmingCharacters(in: .whitespaces), !alt.isEmpty {
                current.appendSynthetic(" \(alt) ", at: offset)
            }
            return
        case "math":
            let count = Self.textLength(element)
            if let alt = element.attribute("alttext"), !alt.isEmpty {
                current.appendSynthetic(" \(alt) ", at: offset)
            }
            offset += count
            return
        case "svg":
            offset += Self.textLength(element)
            return
        default:
            break
        }

        if isBlock {
            flush()
            currentLanguage = language
        }
        if headingLevel != nil { headingDepth += 1 }
        if name == "figcaption" || name == "caption" { captionDepth += 1 }
        let isLink = name == "a" && element.attribute("href") != nil
        if isLink {
            linkDepth += 1
            linkCount += 1
        }
        if headingDepth > 0 { currentKind = .heading } else if captionDepth > 0, currentKind != .heading { currentKind = .caption }

        for child in element.children {
            switch child {
            case .text(let text):
                appendText(text, language: language)
            case .element(let child):
                walk(child, language: language)
            }
        }

        if isLink { linkDepth -= 1 }
        if name == "figcaption" || name == "caption" { captionDepth -= 1 }
        if headingLevel != nil {
            headingDepth -= 1
            if firstHeading == nil {
                let title = element.normalizedText
                if !title.isEmpty { firstHeading = title }
            }
        }
        if isBlock { flush() }
    }

    private mutating func appendText(_ text: String, language: String?) {
        let count = text.utf16.count
        if currentLanguage == nil { currentLanguage = language }
        // A language change inside a paragraph starts a new utterance, so each part gets the right voice.
        if let language, let currentLanguage, !current.characters.allSatisfy(\.isWhitespace),
           Self.primaryLanguage(language) != Self.primaryLanguage(currentLanguage),
           text.contains(where: \.isLetter) {
            flush()
            self.currentLanguage = language
        }
        current.append(text, at: offset)
        let letters = text.filter { !$0.isWhitespace }.count
        totalCharacters += letters
        if linkDepth > 0 { linkCharacters += letters }
        offset += count
    }

    mutating func flush() {
        defer {
            current = MappedText()
            currentKind = headingDepth > 0 ? .heading : captionDepth > 0 ? .caption : .text
            currentLanguage = nil
        }
        let cleaned = SpeechText.clean(current)
        guard cleaned.characters.contains(where: { $0.isLetter || $0.isNumber || !$0.isWhitespace }) else { return }
        blocks.append(.init(kind: currentKind, text: cleaned, language: currentLanguage))
    }

    private mutating func skip(_ element: MarkupElement, reason: SpeechSkipReason, isBlock: Bool) {
        if isBlock { flush() }
        let count = Self.textLength(element)
        let text = element.normalizedText
        if !text.isEmpty {
            omissions.append(.init(reason: reason, text: String(text.prefix(120))))
        }
        offset += count
    }

    // MARK: Rules

    private func skipReason(_ element: MarkupElement, name: String) -> SpeechSkipReason? {
        let types = element.tokens("type", namespace: XMLNamespace.ops).union(element.tokens("role"))
        let classes = element.tokens("class")
        let classText = classes.joined(separator: " ").lowercased()
        let id = element.attribute("id") ?? ""

        // Hidden from everyone.
        if element.attribute("hidden") != nil || element.attribute("aria-hidden") == "true" { return .hidden }
        if let style = element.attribute("style")?.lowercased().replacingOccurrences(of: " ", with: ""),
           style.contains("display:none") || style.contains("visibility:hidden") {
            return .hidden
        }
        if !classes.isDisjoint(with: hiddenClasses) { return .hidden }

        // Print page numbers.
        if types.contains("pagebreak") || types.contains("doc-pagebreak") || types.contains("page-break") { return .pageNumber }
        // Only short elements can be page numbers or note markers; avoid flattening whole sections.
        let text = Self.shortText(element, limit: 24)
        if let text, classText.range(
            of: #"\b(?:page-?num(?:ber)?|pagenum|page_?num|page-?break|pagebreak|pageno|pg-?num|folio|page-?marker)\b"#,
            options: .regularExpression) != nil,
           text.isEmpty || SpeechText.isPageNumber(text) {
            return .pageNumber
        }
        if let text, ["span", "a", "div", "p"].contains(name), !text.isEmpty, SpeechText.isPageNumber(text),
           id.range(of: #"^(?:page|pg|p)[-_]?\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .pageNumber
        }

        // Note references and the notes themselves.
        if Self.isNoteReference(element) { return .noteReference }
        if name == "sup", let text, Self.isNoteMarker(text),
           !element.descendants(named: "a").isEmpty || text.contains(where: { "*†‡§¶".contains($0) })
            || classText.contains("note") || classText.contains("fn") {
            return .noteReference
        }
        if !types.isDisjoint(with: Self.noteTypes) { return .notes }
        if Self.blockElements.contains(name), !id.isEmpty, noteTargets.contains(id) { return .notes }
        if Self.blockElements.contains(name), let anchor = Self.leadingAnchorID(element), noteTargets.contains(anchor) {
            return .notes
        }

        // Navigation, indexes, and duplicated text.
        if name == "nav" { return .navigation }
        // A block that is mostly links is a table of contents inside a chapter, as Project Gutenberg books have.
        if Self.listBlocks.contains(name), Self.isLinkList(element) { return .tableOfContents }
        if let level = Self.headingLevel(element, name: name), level > 0,
           ["contents", "table of contents", "list of illustrations", "illustrations"].contains(
               element.normalizedText.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
            return .tableOfContents
        }

        // Illustrations: figures and their captions, which would otherwise interrupt the text.
        if name == "figure" || name == "figcaption" || types.contains("figure") || types.contains("doc-figure") {
            return .illustration
        }
        if ["div", "table", "aside", "p", "span"].contains(name),
           classText.range(of: #"\b(?:fig[a-z]*|illus[a-z]*|caption|image|img|picture|plate)\b"#, options: .regularExpression) != nil,
           Self.shortText(element, limit: 600) != nil {
            return .illustration
        }
        if ["div", "table"].contains(name), Self.containsImage(element), Self.shortText(element, limit: 300) != nil,
           element.firstDescendant(named: "h1") == nil, element.firstDescendant(named: "h2") == nil {
            return .illustration
        }
        // Code listings don't make sense read aloud; inline code like `Vec` stays in its sentence.
        if name == "pre" || (name == "div" && classText.range(of: #"\b(?:code|listing|highlight|sourcecode|programlisting)\b"#,
                                                               options: .regularExpression) != nil) {
            return .code
        }
        // Notes from whoever digitized the book.
        if classText.range(of: #"\b(?:transnote|tnote|transcriber[a-z-]*|pg-boilerplate)\b"#, options: .regularExpression) != nil {
            return .boilerplate
        }
        if !types.isDisjoint(with: Self.navigationTypes) { return types.contains("index") || types.contains("doc-index") ? .index : .navigation }
        if types.contains("pullquote") || types.contains("doc-pullquote") || classText.contains("pullquote")
            || classText.contains("pull-quote") {
            return .pullQuote
        }
        if name == "rt" || name == "rp" { return .annotation }
        return nil
    }

    static func containsImage(_ element: MarkupElement) -> Bool {
        element.firstDescendant(named: "img") != nil || element.firstDescendant(named: "image") != nil
            || element.firstDescendant(named: "svg") != nil
    }

    /// Whether the heading text so far ends in a label like "Chapter 1", "Part IV", or "12".
    static func endsWithHeadingLabel(_ text: String) -> Bool {
        let line = text.trimmingCharacters(in: .whitespaces)
        guard let last = line.last, !".:!?—,;".contains(last) else { return false }
        return line.range(of: #"(?:^|\s)(?:chapter|part|book|section|act|scene|canto|volume|letter|stave)\s+[\divxlcdm]+$|^[\divxlcdm]+$"#,
                          options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static let listBlocks: Set<String> = ["p", "div", "ul", "ol", "dl", "table", "section", "blockquote", "li"]

    /// Four or more links that make up most of the block's text.
    static func isLinkList(_ element: MarkupElement) -> Bool {
        var links = 0
        var linked = 0
        var total = 0
        func walk(_ element: MarkupElement, inLink: Bool) {
            let isLink = element.name == "a" && element.attribute("href") != nil
            if isLink { links += 1 }
            for child in element.children {
                switch child {
                case .text(let text):
                    let letters = text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
                    total += letters
                    if inLink || isLink { linked += letters }
                case .element(let child):
                    if !unrendered.contains(child.name) { walk(child, inLink: inLink || isLink) }
                }
            }
        }
        walk(element, inLink: false)
        return links >= 4 && total > 0 && Double(linked) / Double(total) >= 0.65
    }

    /// The ID of an anchor at the very start of a block, as in `<p><a id="fn1"/>1. A note.</p>`.
    private static func leadingAnchorID(_ element: MarkupElement) -> String? {
        for child in element.children {
            switch child {
            case .text(let text):
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            case .element(let child):
                if child.name == "a" || child.name == "span" || child.name == "sup" {
                    if let id = child.attribute("id") { return id }
                    return leadingAnchorID(child)
                }
                return nil
            }
        }
        return nil
    }

    private static func headingLevel(_ element: MarkupElement, name: String) -> Int? {
        if name.count == 2, name.hasPrefix("h"), let level = Int(String(name.last!)), (1...6).contains(level) { return level }
        if element.attribute("role") == "heading" {
            return Int(element.attribute("aria-level") ?? "") ?? 2
        }
        return nil
    }

    /// The element's text with whitespace collapsed, or `nil` if it's longer than `limit` characters.
    static func shortText(_ element: MarkupElement, limit: Int) -> String? {
        var raw = ""
        func collect(_ element: MarkupElement) -> Bool {
            for child in element.children {
                switch child {
                case .text(let text):
                    raw += text
                    if raw.count > limit * 4 { return false }
                case .element(let child):
                    if unrendered.contains(child.name.lowercased()) { continue }
                    if !collect(child) { return false }
                }
            }
            return true
        }
        guard collect(element) else { return nil }
        let text = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return text.count <= limit ? text : nil
    }

    /// UTF-16 length of an element's rendered text nodes.
    static func textLength(_ element: MarkupElement) -> Int {
        if unrendered.contains(element.name.lowercased()) { return 0 }
        var total = 0
        for child in element.children {
            switch child {
            case .text(let text): total += text.utf16.count
            case .element(let child): total += textLength(child)
            }
        }
        return total
    }

    static func primaryLanguage(_ tag: String) -> String {
        String(tag.lowercased().split(separator: "-").first ?? "")
    }
}

/// A small reader for CSS rules that hide elements by class.
nonisolated enum CSSHiddenRules {
    static func hiddenClasses(in css: String) -> [String] {
        var classes: [String] = []
        let stripped = css.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        scan(Substring(stripped), into: &classes)
        return classes
    }

    private static func scan(_ css: Substring, into classes: inout [String]) {
        var index = css.startIndex
        while index < css.endIndex {
            guard let open = css[index...].firstIndex(of: "{") else { return }
            let prelude = css[index..<open].trimmingCharacters(in: .whitespacesAndNewlines)
            // Find the matching close brace.
            var depth = 0
            var close = open
            for position in css[open...].indices {
                if css[position] == "{" { depth += 1 }
                if css[position] == "}" {
                    depth -= 1
                    if depth == 0 { close = position; break }
                }
            }
            guard depth == 0 else { return }
            let body = css[css.index(after: open)..<close]
            if prelude.hasPrefix("@") {
                // Print-only rules don't affect the screen; other media and supports blocks might.
                if prelude.hasPrefix("@media"), !prelude.lowercased().contains("print") || prelude.lowercased().contains("screen") {
                    scan(body, into: &classes)
                }
            } else {
                let declarations = body.lowercased().replacingOccurrences(of: " ", with: "")
                if declarations.contains("display:none") || declarations.contains("visibility:hidden") {
                    for selector in prelude.split(separator: ",") {
                        let trimmed = selector.trimmingCharacters(in: .whitespaces)
                        // Only simple selectors like ".x" or "span.x"; anything contextual is too risky.
                        if let match = trimmed.range(of: #"^[a-zA-Z0-9]*\.([A-Za-z0-9_-]+)$"#, options: .regularExpression) {
                            let selectorText = String(trimmed[match])
                            if let dot = selectorText.lastIndex(of: ".") {
                                classes.append(String(selectorText[selectorText.index(after: dot)...]))
                            }
                        }
                    }
                }
            }
            index = css.index(after: close)
        }
    }
}
