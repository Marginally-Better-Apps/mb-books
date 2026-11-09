import Foundation

nonisolated struct BookSearchResult: Identifiable, Hashable, Sendable {
    let id = UUID()
    let spineIndex: Int
    let chapterTitle: String?
    let before: String
    let match: String
    let after: String
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
            var searchRange = NSRange(location: 0, length: source.length)
            var occurrence = 0
            while results.count < maxResults {
                let found = source.range(of: needle, options: [.caseInsensitive], range: searchRange)
                guard found.location != NSNotFound else { break }
                let beforeStart = max(0, found.location - contextLength)
                let afterEnd = min(source.length, found.location + found.length + contextLength)
                results.append(BookSearchResult(
                    spineIndex: index,
                    chapterTitle: chapter,
                    before: snippet(source, NSRange(location: beforeStart, length: found.location - beforeStart), skipping: noteMarkers),
                    match: source.substring(with: found),
                    after: snippet(source, NSRange(
                        location: found.location + found.length, length: afterEnd - found.location - found.length),
                        skipping: noteMarkers),
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
    /// leave out. The text itself keeps them, so offsets still match `reader.js`.
    static func indexedBodyText(_ data: Data) throws -> (text: String, noteMarkers: [NSRange]) {
        let root = try MarkupParser.parse(data)
        guard let body = root.firstDescendant(named: "body") else { return ("", []) }
        let skipped: Set<String> = ["script", "style", "noscript", "template", "head", "title"]
        var output = ""
        var length = 0
        var noteMarkers: [NSRange] = []
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
                case .element: continue
                }
            }
        }
        walk(body)
        return (output, noteMarkers.sorted { $0.location < $1.location })
    }

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
