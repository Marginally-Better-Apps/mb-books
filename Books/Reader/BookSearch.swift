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
                  let text = try? bodyText(data)
            else { continue }
            let chapter = publication.chapterTitle(forSpineIndex: index)
            let source = text as NSString
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
                    before: collapse(source.substring(with: NSRange(location: beforeStart, length: found.location - beforeStart))),
                    match: source.substring(with: found),
                    after: collapse(source.substring(with: NSRange(
                        location: found.location + found.length, length: afterEnd - found.location - found.length))),
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
        let root = try MarkupParser.parse(data)
        guard let body = root.firstDescendant(named: "body") else { return "" }
        let skipped: Set<String> = ["script", "style", "noscript", "template", "head", "title"]
        var output = ""
        func walk(_ element: MarkupElement) {
            for child in element.children {
                switch child {
                case .text(let text): output += text
                case .element(let element) where !skipped.contains(element.name): walk(element)
                case .element: continue
                }
            }
        }
        walk(body)
        return output
    }

    private static func collapse(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}
