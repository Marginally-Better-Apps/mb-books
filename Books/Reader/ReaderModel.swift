import Foundation
import Observation
import SwiftData
import SwiftUI

/// What the reader's rendering layer can do. Implemented by `ReaderViewController`.
@MainActor
protocol ReaderNavigator: AnyObject {
    func go(to locator: Locator, animated: Bool)
    func turnPage(forward: Bool)
    func applyPreferences()
    func reloadHighlights()
    func currentSelection() async -> TextSelection?
    func clearSelection()
    func show(_ result: BookSearchResult)
    func pages(forCFIs cfis: [String]) async -> [Int?]
}

/// A text selection reported by `reader.js`.
struct TextSelection: Decodable {
    struct Rect: Decodable {
        let x, y, width, height: Double
    }

    let text: String
    let start: String
    let end: String
    let bounds: Rect
    let progression: Double

    var rect: CGRect { CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height) }

    private enum CodingKeys: String, CodingKey {
        case text, start, end, progression
        case bounds = "rect"
    }
}

/// Popovers anchored to a rect in reader coordinates.
struct ReaderPopover: Identifiable {
    enum Content {
        case footnote(String)
        case highlight(UUID)
    }

    let id = UUID()
    let content: Content
    let rect: CGRect
}

enum ReaderSheet: String, Identifiable {
    case contents, themes, search
    var id: String { rawValue }
}

@Observable
final class ReaderModel {
    let book: Book
    let publication: Publication
    let container: DirectoryContainer
    let progressionMap: ProgressionMap
    private let context: ModelContext

    var preferences: ReaderPreferences {
        didSet {
            guard preferences != oldValue else { return }
            preferences.save()
            navigator?.applyPreferences()
        }
    }

    var isDarkAppearance = false {
        didSet { if isDarkAppearance != oldValue { navigator?.applyPreferences() } }
    }

    private(set) var location: Locator
    /// Page within the current chapter (reflowable) or spread (fixed layout).
    private(set) var page = 0
    private(set) var pageCount = 1
    private(set) var isBookmarked = false
    var isChromeVisible = false
    var showsPagesLeft = false
    var isRotationLocked = false
    var sheet: ReaderSheet?
    var popover: ReaderPopover?
    var editingNote: Annotation?
    var lastHighlightColor: HighlightColor = .yellow
    var searchQuery = ""
    var searchResults: [BookSearchResult] = []
    var isSearching = false

    weak var navigator: ReaderNavigator?
    private var readingClock: Date?

    init(book: Book, publication: Publication, container: DirectoryContainer, context: ModelContext) {
        self.book = book
        self.publication = publication
        self.container = container
        self.context = context
        self.preferences = ReaderPreferences.load()
        self.progressionMap = ProgressionMap(weights: publication.spine.map { item in
            Double((try? container.url(for: item.item.path).resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 1)
        })
        let saved = book.location
        if let saved, publication.spine.indices.contains(saved.spineIndex) {
            self.location = saved
        } else {
            self.location = Locator(spineIndex: 0)
        }
    }

    var palette: ThemePalette { preferences.theme.palette(dark: isDarkAppearance) }
    var isFixedLayout: Bool { publication.layout != .reflowable }
    var isScrollMode: Bool { preferences.pageTurn == .scroll && !isFixedLayout }
    var chapterTitle: String? { publication.chapterTitle(forSpineIndex: location.spineIndex) }

    var progressPercent: Int { Int((location.totalProgression * 100).rounded()) }

    /// "12 of 340", estimated from the current chapter's page density for reflowable books.
    var pageLabel: String {
        if publication.layout == .roll || isScrollMode {
            return String(localized: "\(progressPercent)%")
        }
        if isFixedLayout {
            return String(localized: "\(page + 1) of \(pageCount)")
        }
        let weights = progressionMap.weights
        guard weights.indices.contains(location.spineIndex) else { return "" }
        let pagesPerUnit = Double(pageCount) / weights[location.spineIndex]
        let before = weights[..<location.spineIndex].reduce(0, +)
        let total = max(pageCount, Int((progressionMap.total * pagesPerUnit).rounded()))
        let current = min(total, Int((before * pagesPerUnit).rounded()) + page + 1)
        return String(localized: "\(current) of \(total)")
    }

    var pagesLeftLabel: String {
        let left = max(0, pageCount - page - 1)
        if left == 0 { return String(localized: "Last page in chapter") }
        return left == 1 ? String(localized: "1 page left in chapter") : String(localized: "\(left) pages left in chapter")
    }

    // MARK: - Navigation

    func go(to locator: Locator) {
        navigator?.go(to: locator, animated: false)
    }

    func go(to point: NavigationPoint) {
        guard let path = point.path, let index = publication.spineIndex(forPath: path) else { return }
        go(to: Locator(spineIndex: index, fragment: point.fragment))
    }

    func go(toTotalProgression value: Double) {
        let target = progressionMap.location(forTotalProgression: value)
        go(to: Locator(spineIndex: target.spineIndex, progression: target.progression))
    }

    /// Resolves an in-book link (from content or navigation) to a spine position.
    func open(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let root = container.root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return false }
        let relative = String(path.dropFirst(root.count + 1))
        guard let index = publication.spineIndex(forPath: relative) else { return false }
        go(to: Locator(spineIndex: index, fragment: url.fragment))
        return true
    }

    /// Called by the navigator whenever the visible position changes.
    func didRelocate(to locator: Locator, page: Int, pageCount: Int) {
        var updated = locator
        updated.totalProgression = progressionMap.totalProgression(
            spineIndex: locator.spineIndex, progression: locator.progression)
        if publication.layout == .prePaginated {
            updated.totalProgression = pageCount <= 1 ? 1 : Double(page) / Double(pageCount - 1)
        }
        location = updated
        self.page = page
        self.pageCount = max(1, pageCount)
        book.location = updated
        book.progress = updated.totalProgression
        book.lastOpened = .now
        Task { await refreshBookmarkState() }
    }

    // MARK: - Chrome

    func toggleChrome() {
        withAnimation(.smooth(duration: 0.25)) { isChromeVisible.toggle() }
    }

    func hideChrome() {
        guard isChromeVisible else { return }
        withAnimation(.smooth(duration: 0.25)) { isChromeVisible = false }
    }

    // MARK: - Typography shortcuts

    func increaseFontSize() {
        preferences.fontScaleIndex = min(preferences.fontScaleIndex + 1, ReaderPreferences.fontScales.count - 1)
    }

    func decreaseFontSize() {
        preferences.fontScaleIndex = max(preferences.fontScaleIndex - 1, 0)
    }

    // MARK: - Bookmarks

    func toggleBookmark() {
        if isBookmarked {
            Task {
                for bookmark in await bookmarksOnCurrentPage() { delete(bookmark) }
                await refreshBookmarkState()
            }
        } else {
            let bookmark = Annotation(
                kind: .bookmark, locator: location, text: "", chapterTitle: chapterTitle)
            bookmark.book = book
            context.insert(bookmark)
            isBookmarked = true
        }
    }

    private func bookmarksOnCurrentPage() async -> [Annotation] {
        let candidates = book.bookmarks.filter { $0.locator.spineIndex == location.spineIndex }
        guard !candidates.isEmpty else { return [] }
        if isFixedLayout { return candidates }
        let currentPage = page
        let pages = await navigator?.pages(forCFIs: candidates.map { $0.locator.cfi ?? "" }) ?? []
        return zip(candidates, pages).filter { $0.1 == currentPage }.map(\.0)
    }

    private func refreshBookmarkState() async {
        isBookmarked = await !bookmarksOnCurrentPage().isEmpty
    }

    // MARK: - Highlights and notes

    func highlights(forSpineIndex index: Int) -> [Annotation] {
        book.highlights.filter { $0.locator.spineIndex == index }
    }

    @discardableResult
    func highlightSelection(color: HighlightColor? = nil) async -> Annotation? {
        guard let selection = await navigator?.currentSelection() else { return nil }
        var locator = location
        locator.cfi = selection.start
        locator.progression = selection.progression
        let annotation = Annotation(
            kind: .highlight, locator: locator, text: selection.text, chapterTitle: chapterTitle,
            rangeStart: selection.start, rangeEnd: selection.end, color: color ?? lastHighlightColor)
        annotation.book = book
        context.insert(annotation)
        navigator?.clearSelection()
        navigator?.reloadHighlights()
        popover = ReaderPopover(content: .highlight(annotation.id), rect: selection.rect)
        return annotation
    }

    func addNoteToSelection() async {
        guard let annotation = await highlightSelection() else { return }
        popover = nil
        editingNote = annotation
    }

    func annotation(id: UUID) -> Annotation? {
        book.annotations.first { $0.id == id }
    }

    func setColor(_ color: HighlightColor, for annotation: Annotation) {
        annotation.color = color
        lastHighlightColor = color
        navigator?.reloadHighlights()
    }

    func delete(_ annotation: Annotation) {
        if popover.map({ if case .highlight(annotation.id) = $0.content { true } else { false } }) == true {
            popover = nil
        }
        context.delete(annotation)
        try? context.save()
        navigator?.reloadHighlights()
    }

    // MARK: - Search

    func performSearch() async {
        let query = searchQuery
        guard query.trimmingCharacters(in: .whitespaces).count >= 2 else {
            searchResults = []
            return
        }
        isSearching = true
        let publication = publication
        let container = container
        let results = await Task.detached(priority: .userInitiated) {
            BookSearcher.search(query, in: publication, container: container)
        }.value
        guard query == searchQuery else { return }
        searchResults = results
        isSearching = false
    }

    func show(_ result: BookSearchResult) {
        sheet = nil
        navigator?.show(result)
    }

    // MARK: - Reading time

    func startReadingClock() {
        readingClock = .now
    }

    /// Credits time since the clock started to today's reading total.
    func stopReadingClock() {
        guard let start = readingClock else { return }
        readingClock = nil
        // Ignore long idle stretches, such as leaving the book open overnight.
        let seconds = min(Date.now.timeIntervalSince(start), 30 * 60)
        guard seconds >= 1 else { return }
        ReadingStats.record(seconds: seconds, in: context)
    }

    func close() {
        stopReadingClock()
        try? context.save()
    }
}

enum ReadingStats {
    static func record(seconds: Double, on date: Date = .now, in context: ModelContext) {
        let day = Calendar.current.startOfDay(for: date)
        let descriptor = FetchDescriptor<ReadingDay>(predicate: #Predicate { $0.day == day })
        if let existing = try? context.fetch(descriptor).first {
            existing.seconds += seconds
        } else {
            context.insert(ReadingDay(day: day, seconds: seconds))
        }
        try? context.save()
    }

    /// Consecutive days, ending today or yesterday, with any reading.
    static func streak(from days: [ReadingDay], today: Date = .now, minimumSeconds: Double = 60) -> Int {
        let calendar = Calendar.current
        let readDays = Set(days.filter { $0.seconds >= minimumSeconds }.map { calendar.startOfDay(for: $0.day) })
        var cursor = calendar.startOfDay(for: today)
        if !readDays.contains(cursor) {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        var count = 0
        while readDays.contains(cursor) {
            count += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        return count
    }
}
