import Foundation

nonisolated struct BookSearchResult: Identifiable, Hashable, Sendable {
    let id = UUID()
    let spineIndex: Int
    let chapterTitle: String?
    let before: String
    let match: String
    let after: String
    /// Whether the snippet is cut short of its paragraph's start or end, so it shows an ellipsis there.
    var continuesBefore = false
    var continuesAfter = false
    /// UTF-16 offset of the match in the document's body text, which matches JavaScript string offsets.
    let offset: Int
    /// Index of this match among case-insensitive matches in the document.
    let occurrence: Int
}

/// Full-text search over a publication's spine, run off the main actor.
nonisolated enum BookSearcher {
    static let maxResults = 500
    private static let contextLength = 40

    static func search(
        _ query: String, in publication: Publication, container: DirectoryContainer
    ) -> [BookSearchResult] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 2 else { return [] }
        var results: [BookSearchResult] = []
        for (index, item) in publication.spine.enumerated() where item.item.isXHTML {
            guard !Task.isCancelled, results.count < maxResults,
                  let data = try? container.data(at: item.item.path),
                  let indexed = try? indexedBodyText(data)
            else { continue }
            let chapter = publication.chapterTitle(forSpineIndex: index)
            let source = indexed.text as NSString
            let noteMarkers = indexed.noteMarkers
            let boundaries = indexed.blockBoundaries
            var searchRange = NSRange(location: 0, length: source.length)
            var occurrence = 0
            while results.count < maxResults {
                let found = source.range(of: needle, options: [.caseInsensitive], range: searchRange)
                guard found.location != NSNotFound else { break }
                let matchEnd = NSMaxRange(found)
                // The context stays inside the match's own heading or paragraph, so a chapter title doesn't run
                // into the sentence after it. Only the snippet is trimmed; the match's offset is untouched.
                let blockStart = boundaries.last { $0 <= found.location } ?? 0
                let blockEnd = boundaries.first { $0 >= matchEnd } ?? source.length
                let beforeStart = max(found.location - contextLength, blockStart)
                let afterEnd = min(matchEnd + contextLength, blockEnd)
                var before = snippet(source, NSRange(location: beforeStart, length: found.location - beforeStart), skipping: noteMarkers)
                var after = snippet(source, NSRange(location: matchEnd, length: afterEnd - matchEnd), skipping: noteMarkers)
                if beforeStart == blockStart { before = String(before.drop { $0.isWhitespace }) }
                if afterEnd == blockEnd { after = String(after.reversed().drop { $0.isWhitespace }.reversed()) }
                results.append(BookSearchResult(
                    spineIndex: index,
                    chapterTitle: chapter,
                    before: before,
                    match: source.substring(with: found),
                    after: after,
                    continuesBefore: beforeStart > blockStart,
                    continuesAfter: afterEnd < blockEnd,
                    offset: found.location,
                    occurrence: occurrence))
                occurrence += 1
                let next = found.location + 1
                searchRange = NSRange(location: next, length: source.length - next)
            }
        }
        return results
    }

    /// Concatenated text nodes under `<body>`, skipping non-rendered elements, mirroring `reader.js`.
    static func bodyText(_ data: Data) throws -> String {
        try indexedBodyText(data).text
    }

    /// The body text, plus the UTF-16 ranges of note reference markers ("compass¹") within it, which snippets
    /// leave out, and the offsets where blocks such as headings and paragraphs start and end, which snippets
    /// don't cross. The text itself keeps everything, so offsets still match `reader.js`.
    static func indexedBodyText(_ data: Data) throws -> (text: String, noteMarkers: [NSRange], blockBoundaries: [Int]) {
        let root = try MarkupParser.parse(data)
        guard let body = root.firstDescendant(named: "body") else { return ("", [], []) }
        let skipped: Set<String> = ["script", "style", "noscript", "template", "head", "title"]
        var output = ""
        var length = 0
        var noteMarkers: [NSRange] = []
        var boundaries: Set<Int> = []
        func walk(_ element: MarkupElement) {
            for child in element.children {
                switch child {
                case .text(let text):
                    output += text
                    length += text.utf16.count
                case .element(let element) where !skipped.contains(element.name):
                    let start = length
                    walk(element)
                    if isNoteMarker(element), length > start {
                        noteMarkers.append(NSRange(location: start, length: length - start))
                    }
                    if blockElements.contains(element.name) {
                        boundaries.insert(start)
                        boundaries.insert(length)
                    }
                case .element: continue
                }
            }
        }
        walk(body)
        return (output, noteMarkers.sorted { $0.location < $1.location }, boundaries.sorted())
    }

    /// Elements set on lines of their own, so the text either side of them doesn't read as one sentence.
    private static let blockElements: Set<String> = [
        "address", "article", "aside", "blockquote", "br", "caption", "dd", "div", "dl", "dt", "figcaption", "figure",
        "footer", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "nav", "ol", "p", "pre", "section",
        "table", "td", "th", "tr", "ul",
    ]

    /// A link to a note: `epub:type="noteref"`, or a linked superscript marker such as "12" or "[3]".
    private static func isNoteMarker(_ element: MarkupElement) -> Bool {
        let types = element.tokens("type", namespace: XMLNamespace.ops).union(element.tokens("role"))
        if types.contains("noteref") || types.contains("doc-noteref") { return true }
        guard element.name == "sup", !element.descendants(named: "a").isEmpty else { return false }
        let text = element.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count <= 6
            && text.range(of: #"^[\[\(]?(?:\d{1,3}|[*†‡§¶#]+|[a-z]|[ivxlc]{1,5})[\]\)]?$"#, options: .regularExpression) != nil
    }

    /// Text in `range`, without note markers, with runs of whitespace collapsed.
    private static func snippet(_ source: NSString, _ range: NSRange, skipping noteMarkers: [NSRange]) -> String {
        var text = ""
        var location = range.location
        for marker in noteMarkers where NSMaxRange(marker) > range.location && marker.location < NSMaxRange(range) {
            if marker.location > location {
                text += source.substring(with: NSRange(location: location, length: marker.location - location))
            }
            location = max(location, NSMaxRange(marker))
        }
        if location < NSMaxRange(range) {
            text += source.substring(with: NSRange(location: location, length: NSMaxRange(range) - location))
        }
        return collapse(text)
    }

    private static func collapse(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}
