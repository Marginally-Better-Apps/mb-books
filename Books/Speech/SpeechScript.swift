import Foundation

/// One thing to say: usually a sentence, with where it came from so the reader can highlight it.
nonisolated struct SpeechUtterance: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case heading, text, caption
        /// Recognized from a page image, so it has no text range to highlight.
        case scan
    }

    /// Maps a position in `text` back to the document. Positions are UTF-16 offsets.
    struct Anchor: Codable, Hashable, Sendable {
        let spoken: Int
        let source: Int
    }

    var spineIndex: Int
    /// What the voice says, after cleanup.
    var text: String
    /// UTF-16 offsets into the document's body text (the same offsets `BookSearcher.bodyText` and `reader.js`
    /// use). `nil` when the text came from a page image.
    var start: Int?
    var end: Int?
    var anchors: [Anchor] = []
    var kind: Kind = .text
    /// BCP 47 language of the text, when the book marks it.
    var language: String?
    /// Silence after this utterance, in seconds: longer after headings and paragraphs than between sentences.
    var pauseAfter: Double = 0

    /// The source offset for a position in `text`, for following along word by word.
    func sourceOffset(forSpoken spoken: Int) -> Int? {
        guard let start else { return nil }
        guard let anchor = anchors.last(where: { $0.spoken <= spoken }) else { return start + spoken }
        return anchor.source + (spoken - anchor.spoken)
    }

    /// Stable identity for caching rendered audio.
    var cacheKey: String { "\(kind.rawValue)|\(language ?? "")|\(text)" }
}

/// What will be read from one spine item, and what was left out.
nonisolated struct SpeechChapter: Codable, Hashable, Sendable {
    var spineIndex: Int
    var title: String?
    var utterances: [SpeechUtterance] = []
    /// Why the whole document is skipped, if it is.
    var skipReason: SpeechSkipReason?
    /// Passages left out of an otherwise read document, for review.
    var omissions: [SpeechOmission] = []

    var isSkipped: Bool { skipReason != nil }
    var characterCount: Int { utterances.reduce(0) { $0 + $1.text.count } }
}

nonisolated struct SpeechOmission: Codable, Hashable, Sendable {
    var reason: SpeechSkipReason
    var text: String
}

/// Why text isn't read aloud. The raw values are stable; they're stored with per-book overrides.
nonisolated enum SpeechSkipReason: String, Codable, Hashable, Sendable, CaseIterable {
    case auxiliary
    case cover
    case titlePage
    case copyright
    case tableOfContents
    case index
    case notes
    case bibliography
    case colophon
    case boilerplate
    case pageNumber
    case noteReference
    case hidden
    case navigation
    case pullQuote
    case runningHead
    case annotation
    case illustration
    case code
    case empty

    var title: String {
        switch self {
        case .auxiliary: String(localized: "Supplementary content")
        case .cover: String(localized: "Cover")
        case .titlePage: String(localized: "Title page")
        case .copyright: String(localized: "Copyright page")
        case .tableOfContents: String(localized: "Table of contents")
        case .index: String(localized: "Index")
        case .notes: String(localized: "Notes")
        case .bibliography: String(localized: "Bibliography")
        case .colophon: String(localized: "Colophon")
        case .boilerplate: String(localized: "License text")
        case .pageNumber: String(localized: "Page number")
        case .noteReference: String(localized: "Note reference")
        case .hidden: String(localized: "Hidden text")
        case .navigation: String(localized: "Navigation")
        case .pullQuote: String(localized: "Pull quote")
        case .runningHead: String(localized: "Running head")
        case .annotation: String(localized: "Pronunciation guide")
        case .illustration: String(localized: "Illustration caption")
        case .code: String(localized: "Code listing")
        case .empty: String(localized: "No text")
        }
    }

    /// Document-level reasons a reader might reasonably want to override.
    var isOverridable: Bool {
        switch self {
        case .auxiliary, .titlePage, .copyright, .tableOfContents, .index, .notes, .bibliography, .colophon,
             .boilerplate: true
        default: false
        }
    }
}

/// A book's speech script: every spine item, in reading order.
nonisolated struct SpeechScript: Codable, Sendable {
    /// Bump when extraction changes, so cached scripts are rebuilt.
    static let version = 1

    var version = SpeechScript.version
    var chapters: [SpeechChapter]

    var readableChapters: [SpeechChapter] { chapters.filter { !$0.isSkipped && !$0.utterances.isEmpty } }
    var characterCount: Int { readableChapters.reduce(0) { $0 + $1.characterCount } }
    var utteranceCount: Int { readableChapters.reduce(0) { $0 + $1.utterances.count } }
}
