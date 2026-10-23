import Foundation
import SwiftData

@Model
final class Book {
    @Attribute(.unique) var id: UUID
    var title: String
    var sortTitle: String
    var author: String
    var sortAuthor: String
    var identifier: String?
    var language: String?
    var publisher: String?
    var summary: String?
    var subjects: [String]
    var published: String?
    var seriesName: String?
    var seriesPosition: Double?
    var epubVersion: String
    var layoutRaw: String
    var dateAdded: Date
    var lastOpened: Date?
    /// Whole-book progress from 0 to 1.
    var progress: Double
    var locationData: Data?
    var isFinished: Bool
    var dateFinished: Date?
    var wantToRead: Bool
    var fileSize: Int64
    /// Whether the original `.epub` is kept for sharing (folder imports have none).
    var hasOriginalFile: Bool

    @Relationship(deleteRule: .cascade, inverse: \Annotation.book)
    var annotations: [Annotation] = []

    @Relationship(inverse: \BookCollection.books)
    var collections: [BookCollection] = []

    init(id: UUID = UUID(), metadata: PublicationMetadata, epubVersion: String, layout: Publication.Layout,
         fileSize: Int64, hasOriginalFile: Bool, dateAdded: Date = .now) {
        self.id = id
        let title = metadata.title.isEmpty ? String(localized: "Untitled") : metadata.title
        self.title = title
        self.sortTitle = Self.sortKey(metadata.sortTitle ?? title)
        self.author = metadata.authors.isEmpty
            ? String(localized: "Unknown Author")
            : ListFormatter.localizedString(byJoining: metadata.authors)
        self.sortAuthor = Self.sortKey(metadata.sortAuthor ?? metadata.authors.first ?? "")
        self.identifier = metadata.identifier
        self.language = metadata.language
        self.publisher = metadata.publisher
        self.summary = metadata.summary
        self.subjects = metadata.subjects
        self.published = metadata.published
        self.seriesName = metadata.seriesName
        self.seriesPosition = metadata.seriesPosition
        self.epubVersion = epubVersion
        self.layoutRaw = layout.rawValue
        self.dateAdded = dateAdded
        self.progress = 0
        self.isFinished = false
        self.wantToRead = false
        self.fileSize = fileSize
        self.hasOriginalFile = hasOriginalFile
    }

    var layout: Publication.Layout { Publication.Layout(rawValue: layoutRaw) ?? .reflowable }

    var location: Locator? {
        get { locationData.flatMap { try? JSONDecoder().decode(Locator.self, from: $0) } }
        set { locationData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    var isNew: Bool { lastOpened == nil && !isFinished }
    var isReading: Bool { lastOpened != nil && !isFinished }

    /// Progress rounded to a whole percent, at least 1% once a book has been opened, as Apple Books shows it.
    var percentRead: Double {
        let percent = (progress * 100).rounded()
        return (lastOpened == nil ? percent : max(1, percent)) / 100
    }

    var highlights: [Annotation] {
        annotations.filter { $0.kind == .highlight }.sorted(by: Annotation.readingOrder)
    }

    var bookmarks: [Annotation] {
        annotations.filter { $0.kind == .bookmark }.sorted(by: Annotation.readingOrder)
    }

    /// Ignores leading articles so "The Odyssey" sorts under O, as Apple Books does.
    static func sortKey(_ text: String) -> String {
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for article in ["the ", "a ", "an "] where lowered.hasPrefix(article) {
            return String(lowered.dropFirst(article.count))
        }
        return lowered
    }

    func markFinished(_ finished: Bool) {
        isFinished = finished
        dateFinished = finished ? .now : nil
        if finished { wantToRead = false }
    }
}

@Model
final class BookCollection {
    @Attribute(.unique) var id: UUID
    var name: String
    var created: Date
    var books: [Book] = []

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.created = .now
    }
}

@Model
final class Annotation {
    enum Kind: String, Codable { case highlight, bookmark }

    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var book: Book?
    var created: Date
    var locatorData: Data
    /// Document-local CFIs bounding a highlight.
    var rangeStart: String?
    var rangeEnd: String?
    var text: String
    var note: String?
    var colorRaw: String
    var chapterTitle: String?

    init(kind: Kind, locator: Locator, text: String, chapterTitle: String?,
         rangeStart: String? = nil, rangeEnd: String? = nil, color: HighlightColor = .yellow) {
        self.id = UUID()
        self.kindRaw = kind.rawValue
        self.created = .now
        self.locatorData = (try? JSONEncoder().encode(locator)) ?? Data()
        self.text = text
        self.chapterTitle = chapterTitle
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.colorRaw = color.rawValue
    }

    var kind: Kind { Kind(rawValue: kindRaw) ?? .highlight }

    var locator: Locator {
        (try? JSONDecoder().decode(Locator.self, from: locatorData)) ?? Locator(spineIndex: 0)
    }

    var color: HighlightColor {
        get { HighlightColor(rawValue: colorRaw) ?? .yellow }
        set { colorRaw = newValue.rawValue }
    }

    static func readingOrder(_ lhs: Annotation, _ rhs: Annotation) -> Bool {
        lhs.locator < rhs.locator
    }
}

/// Seconds read on a calendar day, for Reading Goals.
@Model
final class ReadingDay {
    @Attribute(.unique) var day: Date
    var seconds: Double

    init(day: Date, seconds: Double = 0) {
        self.day = day
        self.seconds = seconds
    }
}
