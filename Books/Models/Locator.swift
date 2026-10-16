import Foundation
import SwiftUI

/// A position in a publication.
nonisolated struct Locator: Codable, Hashable, Sendable, Comparable {
    var spineIndex: Int
    /// Progress through the spine item, from 0 to 1.
    var progression: Double = 0
    /// A document-local EPUB CFI path such as `/4/2/1:10`. Survives font and layout changes.
    var cfi: String?
    /// An element ID to scroll to, from navigation links.
    var fragment: String?
    /// Progress through the whole publication, from 0 to 1.
    var totalProgression: Double = 0

    static func < (lhs: Locator, rhs: Locator) -> Bool {
        (lhs.spineIndex, lhs.progression) < (rhs.spineIndex, rhs.progression)
    }

    /// The EPUB CFI with a spine step, for interchange with other reading systems.
    func epubCFI() -> String? {
        guard let cfi else { return nil }
        return "epubcfi(/6/\((spineIndex + 1) * 2)!\(cfi))"
    }
}

/// Spine-weighted progress across a publication, using document sizes as a length proxy.
nonisolated struct ProgressionMap: Sendable {
    let weights: [Double]
    let total: Double

    init(weights: [Double]) {
        let sanitized = weights.map { max($0, 1) }
        self.weights = sanitized
        self.total = sanitized.reduce(0, +)
    }

    func totalProgression(spineIndex: Int, progression: Double) -> Double {
        guard total > 0, weights.indices.contains(spineIndex) else { return 0 }
        let before = weights[..<spineIndex].reduce(0, +)
        return min(1, max(0, (before + weights[spineIndex] * min(1, max(0, progression))) / total))
    }

    /// "Page x of y" across the whole book, estimated from the current chapter's page density.
    func estimatedPage(spineIndex: Int, page: Int, pageCount: Int) -> (current: Int, total: Int)? {
        guard weights.indices.contains(spineIndex), pageCount > 0 else { return nil }
        let pagesPerUnit = Double(pageCount) / weights[spineIndex]
        let before = weights[..<spineIndex].reduce(0, +)
        let estimatedTotal = (total * pagesPerUnit).rounded()
        let estimatedBefore = (before * pagesPerUnit).rounded()
        // Page counts come from a web view; refuse anything that isn't a sensible number.
        guard estimatedTotal.isFinite, estimatedTotal < 10_000_000 else { return nil }
        let bookTotal = max(pageCount, Int(estimatedTotal))
        return (min(bookTotal, Int(estimatedBefore) + min(max(page, 0), pageCount - 1) + 1), bookTotal)
    }

    /// Inverse of `totalProgression`, for the progress scrubber.
    func location(forTotalProgression value: Double) -> (spineIndex: Int, progression: Double) {
        guard !weights.isEmpty else { return (0, 0) }
        var remaining = min(1, max(0, value)) * total
        for (index, weight) in weights.enumerated() {
            if remaining <= weight || index == weights.count - 1 {
                return (index, min(1, max(0, remaining / weight)))
            }
            remaining -= weight
        }
        return (weights.count - 1, 1)
    }
}

enum HighlightColor: String, CaseIterable, Codable, Identifiable {
    case yellow, green, blue, pink, purple, underline

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .yellow: Color(red: 1.0, green: 0.84, blue: 0.2)
        case .green: Color(red: 0.45, green: 0.85, blue: 0.4)
        case .blue: Color(red: 0.4, green: 0.7, blue: 1.0)
        case .pink: Color(red: 1.0, green: 0.5, blue: 0.65)
        case .purple: Color(red: 0.72, green: 0.55, blue: 1.0)
        case .underline: .red
        }
    }

    var name: LocalizedStringKey {
        switch self {
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .pink: "Pink"
        case .purple: "Purple"
        case .underline: "Underline"
        }
    }
}
