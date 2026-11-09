import SwiftData
import XCTest
@testable import MBBooks

/// The reader's state that the controls show: the way back to search results, and Undo after deleting.
@MainActor
final class ReaderModelTests: XCTestCase {
    private var retainedContainers: [ModelContainer] = []

    private func makeModel() throws -> (ReaderModel, ModelContext) {
        let root = try Fixtures.temporaryDirectory()
        let archive = try ZipArchive(url: Fixtures.write(SampleBook.make()))
        try archive.extractAll(to: root)
        let container = DirectoryContainer(root: root)
        let publication = try EPUBParser.parse(container)
        let database = try ModelContainer(for: Book.self, BookCollection.self, Annotation.self, ReadingDay.self,
                                          configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        retainedContainers.append(database)
        let book = Book(metadata: publication.metadata, epubVersion: publication.version, layout: publication.layout,
                        fileSize: 0, hasOriginalFile: false)
        database.mainContext.insert(book)
        let model = ReaderModel(book: book, publication: publication, container: container, context: database.mainContext)
        return (model, database.mainContext)
    }

    private func result(spineIndex: Int) -> BookSearchResult {
        BookSearchResult(spineIndex: spineIndex, chapterTitle: nil, before: "", match: "sky", after: "", offset: 0, occurrence: 0)
    }

    func testPagesTurnedCountsAcrossNeighboringChapters() {
        let landing = PagePosition(spineIndex: 1, page: 8, pageCount: 10)
        XCTAssertEqual(landing.pagesTurned(to: PagePosition(spineIndex: 1, page: 6, pageCount: 10)), 2)
        XCTAssertEqual(landing.pagesTurned(to: PagePosition(spineIndex: 2, page: 0, pageCount: 4)), 2)
        XCTAssertEqual(PagePosition(spineIndex: 1, page: 0, pageCount: 10)
            .pagesTurned(to: PagePosition(spineIndex: 0, page: 5, pageCount: 6)), 1)
        XCTAssertEqual(landing.pagesTurned(to: PagePosition(spineIndex: 3, page: 0, pageCount: 4)), .max)
    }

    func testBackToResultsLastsUntilTwoPagesAway() throws {
        let (model, _) = try makeModel()
        model.show(result(spineIndex: 1))
        XCTAssertNotNil(model.searchReturn)
        // A report from the page being left doesn't count as where the result landed.
        model.didRelocate(to: Locator(spineIndex: 0), page: 0, pageCount: 5)
        model.didRelocate(to: Locator(spineIndex: 1), page: 3, pageCount: 9)
        model.didRelocate(to: Locator(spineIndex: 1), page: 4, pageCount: 9)
        model.didRelocate(to: Locator(spineIndex: 1), page: 3, pageCount: 9)
        XCTAssertNotNil(model.searchReturn, "One page on and back again is still near the result")
        model.didRelocate(to: Locator(spineIndex: 1), page: 5, pageCount: 9)
        XCTAssertNil(model.searchReturn)
    }

    func testBackToResultsReopensTheSearchAndEndsWithAnySheet() throws {
        let (model, _) = try makeModel()
        model.show(result(spineIndex: 0))
        model.returnToSearchResults()
        XCTAssertEqual(model.sheet, .search)
        XCTAssertNil(model.searchReturn)

        model.show(result(spineIndex: 0))
        XCTAssertNil(model.sheet)
        model.sheet = .themes
        XCTAssertNil(model.searchReturn, "Opening another sheet ends the way back")
    }

    func testReopeningTheSearchKeepsItsResults() async throws {
        let (model, _) = try makeModel()
        model.searchQuery = "pale sky"
        await model.performSearch()
        let first = model.searchResults.map(\.id)
        XCTAssertFalse(first.isEmpty)
        await model.performSearch()
        XCTAssertEqual(model.searchResults.map(\.id), first, "The same query keeps the same results")
        model.searchQuery = ""
        await model.performSearch()
        model.searchQuery = "pale sky"
        await model.performSearch()
        XCTAssertFalse(model.searchResults.isEmpty, "Clearing the field doesn't leave the next search empty")
    }

    func testDeletingAHighlightOrBookmarkCanBeUndone() throws {
        let (model, context) = try makeModel()
        let highlight = Annotation(kind: .highlight, locator: Locator(spineIndex: 1, progression: 0.5), text: "pale sky",
                                   chapterTitle: "Open Water", rangeStart: "/4/2:3", rangeEnd: "/4/2:11", color: .green)
        highlight.note = "Lovely"
        highlight.book = model.book
        context.insert(highlight)
        let id = highlight.id

        model.delete(highlight)
        XCTAssertTrue(model.book.highlights.isEmpty)
        XCTAssertEqual(model.recentlyDeleted?.kind, .highlight)
        model.undoDelete()
        XCTAssertNil(model.recentlyDeleted)
        let restored = try XCTUnwrap(model.book.highlights.first)
        XCTAssertEqual(restored.id, id)
        XCTAssertEqual(restored.note, "Lovely")
        XCTAssertEqual(restored.color, .green)
        XCTAssertEqual(restored.locator.spineIndex, 1)

        let bookmark = Annotation(kind: .bookmark, locator: Locator(spineIndex: 2), text: "", chapterTitle: "Landfall")
        bookmark.book = model.book
        context.insert(bookmark)
        model.delete(bookmark)
        XCTAssertTrue(model.book.bookmarks.isEmpty)
        XCTAssertEqual(model.recentlyDeleted?.kind, .bookmark)
        model.undoDelete()
        XCTAssertEqual(model.book.bookmarks.first?.locator.spineIndex, 2)
    }

    func testUndoExpires() async throws {
        let (model, context) = try makeModel()
        let bookmark = Annotation(kind: .bookmark, locator: Locator(spineIndex: 0), text: "", chapterTitle: nil)
        bookmark.book = model.book
        context.insert(bookmark)
        model.delete(bookmark)
        XCTAssertNotNil(model.recentlyDeleted)
        try await Task.sleep(for: ReaderModel.undoDuration + .milliseconds(500))
        XCTAssertNil(model.recentlyDeleted)
    }
}
