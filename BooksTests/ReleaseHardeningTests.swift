import SwiftData
import XCTest
@testable import MBBooks

/// Regressions for bugs found while preparing 1.0.
@MainActor
final class ReleaseHardeningTests: XCTestCase {
    private var retainedContainers: [ModelContainer] = []

    private func fixture() throws -> (Book, Publication, DirectoryContainer, ModelContext) {
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
        return (book, publication, container, database.mainContext)
    }

    private func systemVoiceSession(_ book: Book, _ publication: Publication, _ container: DirectoryContainer) -> ListeningSession {
        let session = ListeningSession(book: book, publication: publication, container: container)
        var settings = session.preferences
        settings.voice = .system
        session.preferences = settings
        return session
    }

    func testListenFromSelectionStartsAtTheSelection() async throws {
        let (book, publication, container, context) = try fixture()
        let model = ReaderModel(book: book, publication: publication, container: container, context: context)
        let reader = FakeReader()
        reader.selectedOffset = 1500
        model.navigator = reader
        model.speechFollower = reader
        model.startListening(fromSelection: true)
        for _ in 0..<200 where !reader.didReadSelection { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(reader.offsetRead, 1500, "The selection must be read before it's cleared")
        XCTAssertNil(reader.selectedOffset, "The selection is cleared once listening starts")
        model.stopListening()
    }

    func testStopWhileStartingStaysStopped() async throws {
        let (book, publication, container, _) = try fixture()
        let session = systemVoiceSession(book, publication, container)
        let reader = FakeReader()
        reader.blocksVisibleOffset = true
        session.reader = reader
        let start = Task { await session.start() }
        for _ in 0..<200 where reader.pendingVisibleOffset == nil { try await Task.sleep(for: .milliseconds(10)) }
        session.stop()
        reader.pendingVisibleOffset?.resume(returning: (0, 0))
        await start.value
        XCTAssertEqual(session.state, .idle)
    }

    func testStopDuringChapterSkipStaysStopped() async throws {
        let (book, publication, container, _) = try fixture()
        let session = systemVoiceSession(book, publication, container)
        await session.start()
        session.skipChapter(forward: true)
        session.stop()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(session.state, .idle)
    }

    func testClearingTheSearchStopsTheSpinner() async throws {
        let (book, publication, container, context) = try fixture()
        let model = ReaderModel(book: book, publication: publication, container: container, context: context)
        // A search still running when the field is cleared returns to a stale query and leaves loading on.
        model.isSearching = true
        model.searchQuery = ""
        await model.performSearch()
        XCTAssertFalse(model.isSearching)
    }

    func testLongReadingSessionsCountPastTheIdleCap() throws {
        let (book, publication, container, context) = try fixture()
        let model = ReaderModel(book: book, publication: publication, container: container, context: context)
        let turnEvery = ReaderModel.maxIdleReadingTime * 2 / 3
        model.readingClock = .now.addingTimeInterval(-turnEvery)
        model.didRelocate(to: Locator(spineIndex: 0), page: 1, pageCount: 3)
        model.readingClock = model.readingClock?.addingTimeInterval(-turnEvery)
        model.stopReadingClock()
        let total = try context.fetch(FetchDescriptor<ReadingDay>()).reduce(0) { $0 + $1.seconds }
        XCTAssertEqual(total, turnEvery * 2, accuracy: 5)
    }

    func testVoiceFilesDownloadFromThePublicRelease() {
        let release = "https://github.com/Marginally-Better-Apps/mb-books/releases/download/\(NeuralVoiceCatalog.modelID)/"
        let files = NeuralVoiceCatalog.models + NeuralVoiceCatalog.voices.map(\.file)
        for file in files {
            XCTAssertEqual(file.url.absoluteString, release + file.name)
        }
        XCTAssertEqual(Set(files.map(\.name)).count, files.count, "Release assets share one flat namespace")
    }

    func testImportRejectsBooksWhoseChaptersAreAllMissing() throws {
        let package = Fixtures.package(metadata: "<dc:title>Missing chapter</dc:title>",
                                       manifest: #"<item id="chapter" href="missing.xhtml" media-type="application/xhtml+xml"/>"#,
                                       spine: #"<itemref idref="chapter"/>"#)
        let source = try Fixtures.write(Fixtures.epub(package: package))
        let importer = BookImporter(storage: BookStorage(root: try Fixtures.temporaryDirectory()))
        XCTAssertThrowsError(try importer.importBook(from: source)) { XCTAssertEqual($0 as? EPUBError, .emptySpine) }
    }
}

@MainActor
private final class FakeReader: ReaderNavigator, SpeechFollowing {
    var selectedOffset: Int?
    var didReadSelection = false
    var offsetRead: Int?
    var blocksVisibleOffset = false
    var pendingVisibleOffset: CheckedContinuation<(spineIndex: Int, offset: Int?)?, Never>?

    func visibleTextOffset() async -> (spineIndex: Int, offset: Int?)? {
        if blocksVisibleOffset { return await withCheckedContinuation { pendingVisibleOffset = $0 } }
        return (0, 0)
    }
    func selectionTextOffset() async -> (spineIndex: Int, offset: Int)? {
        didReadSelection = true
        offsetRead = selectedOffset
        return selectedOffset.map { (0, $0) }
    }
    func go(to locator: Locator, animated: Bool) {}
    func turnPage(forward: Bool) {}
    func applyPreferences() {}
    func reloadHighlights() {}
    func currentSelection() async -> TextSelection? { nil }
    func clearSelection() { selectedOffset = nil }
    func show(_ result: BookSearchResult) {}
    func pages(forCFIs cfis: [String]) async -> [Int?] { cfis.map { _ in nil } }
    func markSpeech(spineIndex: Int, start: Int, end: Int, word: Range<Int>?, reveal: Bool) async -> SpeechMark? { nil }
    func showSpeechPage(_ page: Int) {}
    func scrollSpeech(to y: Double) {}
    func showSpineItem(_ spineIndex: Int) {}
    func clearSpeech() {}
}
