import UIKit

/// Page geometry for reflowable text on any screen, from iPhone to a 13-inch iPad.
struct ReaderLayout: Equatable {
    /// The longest comfortable line, in points at the default font size and margins (about 70 characters of a serif).
    /// On wide screens the margins grow so lines don't get longer than this.
    static let readableMeasure: CGFloat = 480

    let top: CGFloat
    let bottom: CGFloat
    let side: CGFloat
    let columns: Int
    /// How far each page sits in from the screen's sides, clearing the Dynamic Island and rounded corners.
    /// The page itself is that much narrower, so `side` is just the book's margin.
    let inset: CGFloat

    /// - Parameters:
    ///   - margins: The theme's margin setting, as a multiple of the default.
    ///   - scrolls: Whether the book is in scroll mode rather than paginated.
    init(size: CGSize, safeArea: UIEdgeInsets, margins: Double, fontScale: Double, scrolls: Bool, allowsColumns: Bool) {
        // A large screen, such as an iPad, rather than a phone turned sideways.
        let isWide = min(size.width, size.height) >= 600
        let landscape = size.width > size.height
        columns = allowsColumns && landscape && size.width >= 700 && !scrolls ? 2 : 1
        // `reader.js` pads both sides of every column by `side`, so the safe area is kept out of the page
        // instead; added to the margin, it would also double into the gutter between two columns.
        inset = max(safeArea.left, safeArea.right)
        let margin = (isWide ? 52 : 24) * margins
        // Wider margins narrow the measure too, so the setting still matters where lines are capped.
        let measure = Self.readableMeasure * max(1, fontScale) / max(margins, 0.1)
        let columnWidth = (size.width - 2 * inset) / CGFloat(columns)
        side = max(margin, (columnWidth - measure) / 2)
        // Pages keep their text clear of the controls above and below it (44–52 pt buttons, 4 pt from the safe area).
        // Scroll mode runs text nearly to the edges; the first and last lines still rest clear of the thin fades,
        // and the reader shades the text behind the controls while they're up.
        top = safeArea.top + (scrolls ? 12 : (isWide ? 68 : 56))
        bottom = safeArea.bottom + (scrolls ? 20 : (isWide ? 68 : 56))
    }

    /// Where scroll mode's mask fades text out at the very edges of the screen, so it reads as
    /// running off the page: clear, opaque, opaque, clear, as fractions of the height.
    static func scrollFadeStops(height: CGFloat, safeArea: UIEdgeInsets) -> [CGFloat] {
        guard height > 0 else { return [0, 0, 1, 1] }
        let stops = [
            safeArea.top * 0.5,
            safeArea.top + 4,
            height - safeArea.bottom - 10,
            height - safeArea.bottom * 0.4,
        ]
        return stops.map { min(max($0 / height, 0), 1) }
    }
}
