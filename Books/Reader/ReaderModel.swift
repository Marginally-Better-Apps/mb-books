import Foundation
import Observation
import SwiftData
import SwiftUI
import UIKit

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
    var bounds: Rect
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
    case contents, themes, search, listen
    var id: String { rawValue }
}

/// A page within a chapter (or, for fixed layouts, a spread in the book), for measuring how far the reader turns.
struct PagePosition: Equatable {
    let spineIndex: Int
    let page: Int
    let pageCount: Int

    /// Pages turned from here to `other`. Chapters further apart than next door count as far away.
    func pagesTurned(to other: PagePosition) -> Int {
        switch other.spineIndex - spineIndex {
        case 0: abs(other.page - page)
        case 1: (pageCount - 1 - page) + other.page + 1
        case -1: page + (other.pageCount - 1 - other.page) + 1
        default: .max
        }
    }
}

/// The way back to search results after jumping to one.
struct SearchReturn: Equatable {
    /// The chapter the result is in.
    let spineIndex: Int
    /// Where the result landed, once the reader reports it.
    var landing: PagePosition?
    /// Scrolls since the jump, in scroll mode, where there are no pages to count.
    var scrolls = 0
}

/// A deleted highlight or bookmark, with enough to put it back as it was, note included.
struct DeletedAnnotation: Equatable {
    let id: UUID
    let kind: Annotation.Kind
    let created: Date
    let locatorData: Data
    let rangeStart: String?
    let rangeEnd: String?
    let text: String
    let note: String?
    let color: HighlightColor
    let chapterTitle: String?

    init(_ annotation: Annotation) {
        id = annotation.id
        kind = annotation.kind
        created = annotation.created
        locatorData = annotation.locatorData
        rangeStart = annotation.rangeStart
        rangeEnd = annotation.rangeEnd
        text = annotation.text
        note = annotation.note
        color = annotation.color
        chapterTitle = annotation.chapterTitle
    }

    @discardableResult
    func restore(to book: Book, in context: ModelContext) -> Annotation {
        let annotation = Annotation(
            kind: kind, locator: Locator(spineIndex: 0), text: text, chapterTitle: chapterTitle,
            rangeStart: rangeStart, rangeEnd: rangeEnd, color: color)
        annotation.id = id
        annotation.created = created
        annotation.locatorData = locatorData
        annotation.note = note
        context.insert(annotation)
        annotation.book = book
        try? context.save()
        return annotation
    }
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
    /// Opening any sheet ends the way back to search results; the reader has moved on.
    var sheet: ReaderSheet? {
        didSet { if sheet != nil { searchReturn = nil } }
    }
    var popover: ReaderPopover?
    var editingNote: Annotation? {
        didSet { if editingNote != nil { searchReturn = nil } }
    }
    var lastHighlightColor: HighlightColor = .yellow
    var searchQuery = ""
    var searchResults: [BookSearchResult] = []
    var isSearching = false
    /// The query `searchResults` answer, so reopening the search doesn't search again and lose them.
    private var searchedQuery: String?
    /// Set after jumping to a search result, while the reader offers a way back to the results.
    private(set) var searchReturn: SearchReturn?
    /// The search result last opened, which the search sheet scrolls back to and marks.
    private(set) var lastShownResult: BookSearchResult.ID?
    /// The highlight or bookmark just deleted, offered back for a few seconds.
    private(set) var recentlyDeleted: DeletedAnnotation?
    private var undoExpiry: Task<Void, Never>?

    weak var navigator: ReaderNavigator?
    /// Shows what's being read aloud; the same view controller as `navigator`.
    weak var speechFollower: SpeechFollowing?
    /// Reading aloud, once started.
    private(set) var listening: ListeningSession?
    var readingClock: Date?

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
    /// The page turn in use: fixed layouts can't scroll, so they slide instead.
    var effectivePageTurn: PageTurnStyle { isFixedLayout && preferences.pageTurn == .scroll ? .slide : preferences.pageTurn }
    var chapterTitle: String? { publication.chapterTitle(forSpineIndex: location.spineIndex) }

    /// Rounded like Home's progress; a book open in the reader counts as started.
    var progressPercent: Int { Book.wholePercent(location.totalProgression, opened: true) }

    /// "12 of 340", estimated from the current chapter's page density for reflowable books.
    var pageLabel: String {
        if publication.layout == .roll || isScrollMode {
            return String(localized: "\(progressPercent)%")
        }
        if isFixedLayout {
            return String(localized: "\(page + 1) of \(pageCount)")
        }
        guard let (current, total) = progressionMap.estimatedPage(
            spineIndex: location.spineIndex, page: page, pageCount: pageCount)
        else { return "" }
        return String(localized: "\(current) of \(total)")
    }

    var pagesLeftLabel: String {
        let left = max(0, pageCount - page - 1)
        if left == 0 { return String(localized: "Last page in chapter") }
        return left == 1 ? String(localized: "1 page left in chapter") : String(localized: "\(left) pages left in chapter")
    }

    // MARK: - Navigation

    func go(to locator: Locator) {
        userDidNavigate()
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
        checkpointReadingClock()
        followSearchReturn(to: PagePosition(
            spineIndex: publication.layout == .prePaginated ? 0 : updated.spineIndex, page: page, pageCount: self.pageCount))
        Task { await refreshBookmarkState() }
    }

    // MARK: - Listening

    /// Reads aloud from the page on screen, or from the start of the selection.
    func startListening(fromSelection: Bool = false) {
        let session = listening ?? ListeningSession(book: book, publication: publication, container: container)
        session.reader = speechFollower
        if session.coverImage == nil {
            let cover = container.root.deletingLastPathComponent().appending(path: "cover.jpg")
            session.coverImage = UIImage(contentsOfFile: cover.path)
        }
        listening = session
        session.prewarm()
        let follower = speechFollower
        let navigator = navigator
        Task {
            // Read the selection before clearing it; clearing first would start from the page instead.
            let selection = fromSelection ? await follower?.selectionTextOffset() : nil
            navigator?.clearSelection()
            await session.start(at: selection.map { ($0.spineIndex, $0.offset) })
        }
    }

    /// The reader moved to another page themselves (not the narration following along).
    func userDidNavigate() {
        listening?.readerWasNavigated()
        // Without pages to count, two scrolls stand in for two page turns.
        if !hasPages, var trip = searchReturn {
            trip.scrolls += 1
            searchReturn = trip.scrolls >= 2 ? nil : trip
        }
    }

    func stopListening() {
        listening?.stop()
    }

    var isListening: Bool { listening?.isActive == true }

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
            // The button itself puts a removed bookmark back, so this doesn't offer Undo.
            Task {
                for bookmark in await bookmarksOnCurrentPage() { remove(bookmark) }
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

    /// Deletes a highlight (with its note) or a bookmark straight away, and offers it back for a few seconds.
    func delete(_ annotation: Annotation) {
        let deleted = DeletedAnnotation(annotation)
        remove(annotation)
        if deleted.kind == .bookmark { Task { await refreshBookmarkState() } }
        recentlyDeleted = deleted
        AccessibilityNotification.Announcement(deleted.kind == .highlight
            ? String(localized: "Highlight deleted. Undo is available.")
            : String(localized: "Bookmark deleted. Undo is available.")).post()
        undoExpiry?.cancel()
        // VoiceOver users need longer to reach the Undo button.
        let duration = UIAccessibility.isVoiceOverRunning ? Self.voiceOverUndoDuration : Self.undoDuration
        undoExpiry = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, self?.recentlyDeleted == deleted else { return }
            self?.recentlyDeleted = nil
        }
    }

    /// Puts back what was just deleted, as it was.
    func undoDelete() {
        guard let deleted = recentlyDeleted else { return }
        undoExpiry?.cancel()
        recentlyDeleted = nil
        deleted.restore(to: book, in: context)
        navigator?.reloadHighlights()
        if deleted.kind == .bookmark { Task { await refreshBookmarkState() } }
    }

    static let undoDuration: Duration = .seconds(6)
    static let voiceOverUndoDuration: Duration = .seconds(20)

    private func remove(_ annotation: Annotation) {
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
            searchedQuery = nil
            isSearching = false
            return
        }
        // Reopened on the same query: the results are already here.
        guard query != searchedQuery else {
            isSearching = false
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
        searchedQuery = query
        isSearching = false
    }

    func show(_ result: BookSearchResult) {
        sheet = nil
        userDidNavigate()
        lastShownResult = result.id
        searchReturn = SearchReturn(spineIndex: result.spineIndex)
        navigator?.show(result)
    }

    /// Back to the search sheet, with the query and results as they were.
    func returnToSearchResults() {
        sheet = .search
    }

    /// Whether the reader turns pages that can be counted, rather than scrolling.
    private var hasPages: Bool { !isScrollMode && publication.layout != .roll }

    /// Remembers the page a search result landed on, then lets the way back go once the reader is two pages away.
    private func followSearchReturn(to position: PagePosition) {
        guard var trip = searchReturn, hasPages else { return }
        if let landing = trip.landing {
            if landing.pagesTurned(to: position) >= 2 { searchReturn = nil }
        } else if publication.layout != .reflowable || position.spineIndex == trip.spineIndex {
            trip.landing = position
            searchReturn = trip
        }
    }

    // MARK: - Reading time

    func startReadingClock() {
        readingClock = .now
    }

    /// Credits time since the clock started to today's reading total.
    func stopReadingClock() {
        guard let start = readingClock else { return }
        readingClock = nil
        creditReading(since: start)
    }

    /// Turning a page shows the reader is still there: credit the time so far and restart the clock, so the idle
    /// cap applies to the time since the last page rather than to the whole session.
    private func checkpointReadingClock(now: Date = .now) {
        guard let start = readingClock, now.timeIntervalSince(start) >= 60 else { return }
        readingClock = now
        creditReading(since: start, until: now)
    }

    private func creditReading(since start: Date, until end: Date = .now) {
        // Ignore long idle stretches, such as leaving the book open overnight.
        let seconds = min(end.timeIntervalSince(start), Self.maxIdleReadingTime)
        guard seconds >= 1 else { return }
        ReadingStats.record(seconds: seconds, in: context)
    }

    static let maxIdleReadingTime: TimeInterval = 30 * 60

    func close() {
        searchReturn = nil
        undoExpiry?.cancel()
        stopListening()
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
