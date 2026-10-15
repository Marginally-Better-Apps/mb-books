import CoreGraphics
import Foundation
import ImageIO

/// Intrinsic page sizes for fixed-layout documents (EPUB 3.4 §7.3.2: viewport meta or SVG viewBox).
nonisolated enum FixedLayoutGeometry {
    static let fallback = CGSize(width: 1024, height: 1366)

    static func size(of item: ManifestItem, in container: DirectoryContainer) -> CGSize? {
        let url = container.url(for: item.path)
        if item.isImage && !item.isSVG {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
                  let height = properties[kCGImagePropertyPixelHeight] as? CGFloat
            else { return nil }
            return CGSize(width: width, height: height)
        }
        guard let data = try? Data(contentsOf: url), let text = String(data: data.prefix(16_384), encoding: .utf8) else {
            return nil
        }
        return item.isSVG ? svgSize(text) : viewportSize(text)
    }

    static func viewportSize(_ markup: String) -> CGSize? {
        guard let meta = firstMatch(#"<meta\b[^>]*\bname\s*=\s*["']viewport["'][^>]*>"#, in: markup),
              let content = firstMatch(#"\bcontent\s*=\s*(["'])(.*?)\1"#, in: meta, group: 2),
              let width = number(after: "width", in: content),
              let height = number(after: "height", in: content),
              width > 0, height > 0
        else { return nil }
        return CGSize(width: width, height: height)
    }

    static func svgSize(_ markup: String) -> CGSize? {
        guard let root = firstMatch(#"<svg\b[^>]*>"#, in: markup) else { return nil }
        if let viewBox = firstMatch(#"\bviewBox\s*=\s*["']([^"']+)["']"#, in: root, group: 1) {
            let values = viewBox.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
            if values.count == 4, values[2] > 0, values[3] > 0 { return CGSize(width: values[2], height: values[3]) }
        }
        if let width = firstMatch(#"\bwidth\s*=\s*["']([\d.]+)"#, in: root, group: 1).flatMap(Double.init),
           let height = firstMatch(#"\bheight\s*=\s*["']([\d.]+)"#, in: root, group: 1).flatMap(Double.init) {
            return CGSize(width: width, height: height)
        }
        return nil
    }

    private static func number(after key: String, in content: String) -> Double? {
        firstMatch(#"\b"# + key + #"\s*=\s*([\d.]+)"#, in: content, group: 1).flatMap(Double.init)
    }

    private static func firstMatch(_ pattern: String, in text: String, group: Int = 0) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: group), in: text)
        else { return nil }
        return String(text[range])
    }
}

/// Groups pre-paginated spine items into spreads. Landscape shows facing pages, honoring
/// `page-spread-*` properties; portrait shows one page at a time.
nonisolated struct SpreadPlan: Equatable, Sendable {
    let spreads: [[Int]]

    init(spine: [SpineItem], landscape: Bool, rtl: Bool = false) {
        guard landscape else {
            spreads = spine.indices.map { [$0] }
            return
        }
        func has(_ index: Int, _ position: String) -> Bool {
            let properties = spine[index].properties
            return properties.contains("page-spread-\(position)") || properties.contains("rendition:page-spread-\(position)")
        }
        // The page that can't open a spread: a right-hand page in LTR books, a left-hand page in RTL books.
        let trailingSide = rtl ? "left" : "right"
        var result: [[Int]] = []
        var index = 0
        while index < spine.count {
            let standsAlone = index == 0 || index == spine.count - 1
                || has(index, "center") || has(index, trailingSide) || has(index + 1, "center")
            if standsAlone {
                result.append([index])
                index += 1
            } else {
                result.append([index, index + 1])
                index += 2
            }
        }
        spreads = result
    }

    func spreadIndex(containing spineIndex: Int) -> Int {
        spreads.firstIndex { $0.contains(spineIndex) } ?? 0
    }
}

/// Generates wrapper pages that host fixed-layout documents in scaled iframes, so each document
/// lays out at its intended size without fighting the reader's viewport.
nonisolated enum WrapperDocument {
    struct Page {
        let path: String
        let size: CGSize
        let isImage: Bool
    }

    static let directoryName = ".mbbooks"

    static func spread(_ pages: [Page], rtl: Bool) -> String {
        let ordered = rtl ? pages.reversed() : pages
        let body = ordered.map(element).joined(separator: "\n")
        return document(kind: "fixed", body: body)
    }

    static func roll(_ pages: [Page]) -> String {
        let body = pages.enumerated().map { index, page in
            "<div class=\"mb-slot\" data-index=\"\(index)\">\(element(page, lazy: index > 1))</div>"
        }.joined(separator: "\n")
        return document(kind: "roll", body: body)
    }

    private static func element(_ page: Page) -> String { element(page, lazy: false) }

    private static func element(_ page: Page, lazy: Bool) -> String {
        let source = "../" + page.path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        let size = "data-width=\"\(Int(page.size.width))\" data-height=\"\(Int(page.size.height))\""
        let loading = lazy ? " loading=\"lazy\"" : ""
        if page.isImage {
            return "<img class=\"mb-page\" alt=\"\" src=\"\(source)\" \(size)\(loading)>"
        }
        return "<iframe class=\"mb-page\" src=\"\(source)\" \(size)\(loading) scrolling=\"no\"></iframe>"
    }

    private static func document(kind: String, body: String) -> String {
        """
        <!DOCTYPE html>
        <html data-mb-wrapper="\(kind)">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        <style>
        html, body { margin: 0; padding: 0; -webkit-tap-highlight-color: transparent; }
        html[data-mb-wrapper="fixed"], html[data-mb-wrapper="fixed"] body { height: 100%; overflow: hidden; }
        .mb-page { position: absolute; border: 0; transform-origin: 0 0; display: block; background: #fff; }
        .mb-slot { position: relative; overflow: hidden; }
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }
}
