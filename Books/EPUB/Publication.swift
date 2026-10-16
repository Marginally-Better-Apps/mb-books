import Foundation

/// A parsed EPUB publication. All paths are container-relative and percent-decoded,
/// e.g. `OEBPS/text/chapter1.xhtml`.
nonisolated struct Publication: Sendable {
    var version: String
    var packagePath: String
    var metadata: PublicationMetadata
    var manifest: [ManifestItem]
    var spine: [SpineItem]
    var tableOfContents: [NavigationPoint]
    var pageList: [NavigationPoint]
    var landmarks: [NavigationPoint]
    var layout: Layout
    var readingProgression: ReadingProgression
    var coverPath: String?
    var navigationDocumentPath: String?
    var obfuscatedResources: [String: FontObfuscation]

    enum Layout: String, Codable, Sendable {
        /// Text that reflows to the screen and honors reader typography settings.
        case reflowable
        /// One fixed-layout document per page, scaled to fit.
        case prePaginated = "pre-paginated"
        /// Fixed-layout documents fit to width in one continuous vertical scroll (EPUB 3.4).
        case roll
    }

    enum ReadingProgression: String, Codable, Sendable {
        case ltr, rtl, auto
    }

    func manifestItem(id: String) -> ManifestItem? {
        manifest.first { $0.id == id }
    }

    func manifestItem(path: String) -> ManifestItem? {
        manifest.first { $0.path == path }
    }

    func spineIndex(forPath path: String) -> Int? {
        spine.firstIndex { $0.item.path == path }
    }

    /// The table of contents flattened depth-first, with nesting levels.
    var flattenedTableOfContents: [(point: NavigationPoint, level: Int)] {
        var result: [(NavigationPoint, Int)] = []
        func walk(_ points: [NavigationPoint], _ level: Int) {
            for point in points {
                result.append((point, level))
                walk(point.children, level + 1)
            }
        }
        walk(tableOfContents, 0)
        return result
    }

    /// The deepest table-of-contents entry that starts at or before a spine position.
    func chapterTitle(forSpineIndex index: Int) -> String? {
        var best: String?
        for (point, _) in flattenedTableOfContents {
            guard let path = point.path, let position = spineIndex(forPath: path) else { continue }
            if position <= index { best = point.title } else { break }
        }
        return best ?? metadata.title
    }
}

nonisolated struct PublicationMetadata: Sendable, Codable, Equatable {
    var title: String = ""
    var sortTitle: String?
    var authors: [String] = []
    var sortAuthor: String?
    var language: String?
    var identifier: String?
    var publisher: String?
    var summary: String?
    var subjects: [String] = []
    var published: String?
    var modified: String?
    var rights: String?
    var seriesName: String?
    var seriesPosition: Double?
    var accessibilitySummary: String?
    /// The class applied to the active element during media overlay playback.
    var mediaActiveClass: String?
}

nonisolated struct ManifestItem: Sendable, Hashable {
    let id: String
    let path: String
    let mediaType: String
    let properties: Set<String>
    let fallback: String?
    let mediaOverlay: String?
    let remoteURL: URL?

    var isXHTML: Bool { mediaType == "application/xhtml+xml" || mediaType == "text/html" }
    var isSVG: Bool { mediaType == "image/svg+xml" }
    var isImage: Bool { mediaType.hasPrefix("image/") }
    var isScripted: Bool { properties.contains("scripted") }
    /// Content documents a WebKit view can render directly.
    var isRenderable: Bool { isXHTML || isSVG || isImage }
}

nonisolated struct SpineItem: Sendable, Hashable {
    let item: ManifestItem
    let linear: Bool
    let properties: Set<String>
    let layout: Publication.Layout
}

nonisolated struct NavigationPoint: Sendable, Hashable, Identifiable, Codable {
    let id: String
    let title: String
    /// Container path of the target document, if any.
    let path: String?
    let fragment: String?
    let children: [NavigationPoint]
}

nonisolated enum FontObfuscation: String, Sendable {
    case idpf = "http://www.idpf.org/2008/embedding"
    case adobe = "http://ns.adobe.com/pdf/enc#RC"
}
