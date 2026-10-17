import CoreGraphics
import Foundation
import Vision

/// Reads text from page images (scanned books and image-only fixed layouts) with on-device OCR,
/// then puts the lines back together the way a person reads the page.
///
/// OCR returns every mark on the page, so the layout pass does the content work: it drops page numbers and
/// running heads in the top and bottom margins, orders two-column pages, joins words hyphenated across
/// lines, and splits paragraphs by spacing and indentation.
nonisolated enum ScanReader {
    struct Line: Codable, Hashable, Sendable {
        var text: String
        /// Normalized to the page, origin at the bottom left (Vision's convention).
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        var midY: Double { y + height / 2 }
        var maxX: Double { x + width }
        var top: Double { y + height }
    }

    struct Page: Codable, Sendable {
        var paragraphs: [String]
        var omissions: [SpeechOmission]
    }

    /// What the page sits in, to recognize its running heads.
    struct Context: Sendable {
        var bookTitle: String = ""
        var authors: [String] = []
        var chapterTitle: String?
        /// Margin lines seen on other pages of the book, normalized.
        var marginText: [String: Int] = [:]
    }

    static func recognize(imageAt url: URL, language: String?) async throws -> [Line] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if let language {
            let wanted = Locale.Language(identifier: language)
            let supported = request.supportedRecognitionLanguages.filter { $0.languageCode == wanted.languageCode }
            if !supported.isEmpty { request.recognitionLanguages = supported } else { request.automaticallyDetectsLanguage = true }
        } else {
            request.automaticallyDetectsLanguage = true
        }
        let observations = try await request.perform(on: url)
        return observations.compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else { return nil }
            let box = observation.boundingBox
            return Line(text: text, x: box.origin.x, y: box.origin.y, width: box.width, height: box.height)
        }
    }

    /// The share of the page at the top and bottom where headers, footers, and folios live.
    static let marginBand = 0.085

    static func isMargin(_ line: Line) -> Bool {
        line.midY > 1 - marginBand || line.midY < marginBand
    }

    static func marginKey(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter }
    }

    /// Lays out recognized lines as paragraphs, leaving out margin furniture.
    static func layout(_ lines: [Line], context: Context) -> Page {
        var omissions: [SpeechOmission] = []
        let names = ([context.bookTitle, context.chapterTitle ?? ""] + context.authors)
            .map(marginKey).filter { $0.count >= 4 }
        let body = lines.filter { line in
            guard isMargin(line) else { return true }
            let text = line.text.trimmingCharacters(in: .whitespaces)
            if SpeechText.isPageNumber(text) {
                omissions.append(.init(reason: .pageNumber, text: text))
                return false
            }
            let key = marginKey(text)
            let words = text.split(separator: " ").count
            // A page number glued to a running head: "24 THE SEA WOLF" or "Chapter Three 61".
            let stripped = text.replacingOccurrences(of: #"^\d{1,4}\s+|\s+\d{1,4}$"#, with: "", options: .regularExpression)
            let strippedKey = marginKey(stripped)
            if words <= 10, !key.isEmpty,
               names.contains(where: { strippedKey.contains($0) || $0.contains(strippedKey) && strippedKey.count >= 4 })
                || (context.marginText[strippedKey] ?? 0) >= 2 {
                omissions.append(.init(reason: .runningHead, text: text))
                return false
            }
            return true
        }
        return Page(paragraphs: paragraphs(readingOrder(body)), omissions: omissions)
    }

    /// Top to bottom, and for two-column pages the left column before the right.
    static func readingOrder(_ lines: [Line]) -> [Line] {
        let narrow = lines.filter { $0.width < 0.46 }
        let left = narrow.filter { $0.maxX <= 0.52 }
        let right = narrow.filter { $0.x >= 0.48 }
        let isTwoColumn = left.count >= 4 && right.count >= 4 && Double(left.count + right.count) >= Double(lines.count) * 0.7
        let byPosition: (Line, Line) -> Bool = { a, b in
            abs(a.midY - b.midY) < min(a.height, b.height) * 0.5 ? a.x < b.x : a.midY > b.midY
        }
        guard isTwoColumn else { return lines.sorted(by: byPosition) }
        // Full-width lines (titles) above the columns come first.
        let columnsTop = narrow.map(\.top).max() ?? 1
        let header = lines.filter { $0.width >= 0.46 && $0.y >= columnsTop }.sorted(by: byPosition)
        let rest = lines.filter { !($0.width >= 0.46 && $0.y >= columnsTop) }
        let leftColumn = rest.filter { $0.x + $0.width / 2 < 0.5 }.sorted(by: byPosition)
        let rightColumn = rest.filter { $0.x + $0.width / 2 >= 0.5 }.sorted(by: byPosition)
        return header + leftColumn + rightColumn
    }

    /// Joins lines into paragraphs: a larger gap, an indent, or a short line ending a sentence starts a new one.
    static func paragraphs(_ lines: [Line]) -> [String] {
        guard !lines.isEmpty else { return [] }
        let heights = lines.map(\.height).sorted()
        let lineHeight = heights[heights.count / 2]
        let lefts = lines.map(\.x).sorted()
        let leftEdge = lefts[lefts.count / 4]
        let widths = lines.map(\.width).sorted()
        let fullWidth = widths[min(widths.count - 1, widths.count * 3 / 4)]

        var result: [String] = []
        var current = ""
        var previous: Line?
        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if let previous {
                let gap = previous.y - line.top
                let indented = line.x - leftEdge > max(0.02, lineHeight * 0.8)
                let endedShort = previous.width < fullWidth * 0.75 && ".!?\"”’:".contains(previous.text.trimmingCharacters(in: .whitespaces).last ?? " ")
                let sizeChanged = abs(line.height - previous.height) > lineHeight * 0.35
                if gap > lineHeight * 1.1 || indented || endedShort || sizeChanged || gap < -lineHeight * 2 {
                    result.append(current)
                    current = text
                } else if current.hasSuffix("-"), let first = text.first, first.isLowercase {
                    // A word hyphenated across lines.
                    current.removeLast()
                    current += text
                } else {
                    current += " " + text
                }
            } else {
                current = text
            }
            previous = line
        }
        if !current.isEmpty { result.append(current) }
        return result.filter { !SpeechText.isPageNumber($0) }
    }
}
