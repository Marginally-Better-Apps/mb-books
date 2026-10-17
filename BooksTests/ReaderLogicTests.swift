import SwiftData
import XCTest
@testable import MBBooks

@MainActor
final class ReaderLogicTests: XCTestCase {
    func testProgressionMapIsWeightedAndInvertible() {
        let map = ProgressionMap(weights: [100, 300, 600])
        XCTAssertEqual(map.totalProgression(spineIndex: 0, progression: 0), 0)
        XCTAssertEqual(map.totalProgression(spineIndex: 1, progression: 0.5), 0.25, accuracy: 1e-9)
        XCTAssertEqual(map.totalProgression(spineIndex: 2, progression: 1), 1)
        let location = map.location(forTotalProgression: 0.25)
        XCTAssertEqual(location.spineIndex, 1)
        XCTAssertEqual(location.progression, 0.5, accuracy: 1e-9)
        XCTAssertEqual(map.location(forTotalProgression: 1).spineIndex, 2)
    }

    func testPageEstimatesSurviveNonsensePageCounts() throws {
        let map = ProgressionMap(weights: [100, 300, 600])
        let estimate = try XCTUnwrap(map.estimatedPage(spineIndex: 1, page: 2, pageCount: 6))
        XCTAssertEqual(estimate.total, 20, "6 pages for 300 units means 20 for the book's 1000")
        XCTAssertEqual(estimate.current, 5, "2 pages before chapter 2, then its third page")
        XCTAssertNil(map.estimatedPage(spineIndex: 1, page: 0, pageCount: .max), "A web view mid-layout can report Infinity")
        XCTAssertNil(map.estimatedPage(spineIndex: 1, page: 0, pageCount: 0))
        XCTAssertNil(map.estimatedPage(spineIndex: 9, page: 0, pageCount: 3))
    }

    func testLocatorsSortInReadingOrderAndFormatCFI() {
        let a = Locator(spineIndex: 1, progression: 0.9)
        let b = Locator(spineIndex: 2, progression: 0.1)
        XCTAssertLessThan(a, b)
        XCTAssertEqual(Locator(spineIndex: 2, cfi: "/4/2/1:10").epubCFI(), "epubcfi(/6/6!/4/2/1:10)")
    }

    func testSpreadPlanPairsFacingPages() {
        func spine(_ properties: [Set<String>]) -> [SpineItem] {
            properties.enumerated().map { index, properties in
                let item = ManifestItem(id: "p\(index)", path: "p\(index).xhtml", mediaType: "application/xhtml+xml",
                                        properties: [], fallback: nil, mediaOverlay: nil, remoteURL: nil)
                return SpineItem(item: item, linear: true, properties: properties, layout: .prePaginated)
            }
        }
        let plain = spine(Array(repeating: [], count: 6))
        XCTAssertEqual(SpreadPlan(spine: plain, landscape: false).spreads, [[0], [1], [2], [3], [4], [5]])
        XCTAssertEqual(SpreadPlan(spine: plain, landscape: true).spreads, [[0], [1, 2], [3, 4], [5]])

        let centered = spine([[], [], ["rendition:page-spread-center"], [], [], []])
        XCTAssertEqual(SpreadPlan(spine: centered, landscape: true).spreads, [[0], [1], [2], [3, 4], [5]])
        XCTAssertEqual(SpreadPlan(spine: plain, landscape: true).spreadIndex(containing: 4), 2)
    }

    func testFixedLayoutGeometryReadsViewportAndViewBox() {
        XCTAssertEqual(FixedLayoutGeometry.viewportSize(#"<meta content="width=1200, height = 1600" name="viewport"/>"#),
                       CGSize(width: 1200, height: 1600))
        XCTAssertNil(FixedLayoutGeometry.viewportSize(#"<meta name="viewport" content="width=device-width"/>"#))
        XCTAssertEqual(FixedLayoutGeometry.svgSize(#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 800">"#),
                       CGSize(width: 600, height: 800))
        XCTAssertEqual(FixedLayoutGeometry.svgSize(#"<svg width="300" height="400">"#), CGSize(width: 300, height: 400))
    }

    func testSearchFindsMatchesWithUTF16OffsetsMatchingBodyText() throws {
        let archive = try ZipArchive(url: Fixtures.write(SampleBook.make()))
        let content = try Fixtures.temporaryDirectory()
        try archive.extractAll(to: content)
        let container = DirectoryContainer(root: content)
        let publication = try EPUBParser.parse(container)

        let results = BookSearcher.search("BRASS compass", in: publication, container: container)
        XCTAssertEqual(results.count, 1)
        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(result.spineIndex, 0)
        XCTAssertEqual(result.match, "brass compass")
        XCTAssertEqual(result.chapterTitle, "Departure")

        let text = try BookSearcher.bodyText(container.data(at: publication.spine[0].item.path)) as NSString
        XCTAssertEqual(text.substring(with: NSRange(location: result.offset, length: result.match.utf16.count)), "brass compass")
        XCTAssertFalse(text.contains("Departure</title>"))

        XCTAssertEqual(BookSearcher.search("paragraph 3 of", in: publication, container: container).count, 3)
        XCTAssertTrue(BookSearcher.search("x", in: publication, container: container).isEmpty, "Single characters are ignored")
    }

    func testBodyTextSkipsScriptsAndStyles() throws {
        let html = Fixtures.xhtml("<style>p{}</style><p>Hello <b>world</b></p><script>var x = 1;</script>&amp; more")
        XCTAssertEqual(try BookSearcher.bodyText(Data(html.utf8)), "Hello world& more")
    }

    func testReadingStreakCountsConsecutiveDays() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        func day(_ offset: Int, _ seconds: Double) -> ReadingDay {
            ReadingDay(day: calendar.date(byAdding: .day, value: -offset, to: today)!, seconds: seconds)
        }
        XCTAssertEqual(ReadingStats.streak(from: [day(0, 120), day(1, 300), day(2, 90), day(4, 600)]), 3)
        XCTAssertEqual(ReadingStats.streak(from: [day(1, 120), day(2, 120)]), 2, "A streak survives until today ends")
        XCTAssertEqual(ReadingStats.streak(from: [day(0, 10)]), 0, "Less than a minute doesn't count")
    }

    func testReaderPreferencesPersistPerThemeStyles() throws {
        var preferences = ReaderPreferences()
        XCTAssertEqual(preferences.style, ReaderThemeID.original.defaultStyle)
        preferences.theme = .calm
        preferences.style.justify = true
        preferences.fontScaleIndex = 5
        XCTAssertTrue(preferences.isStyleCustomized)

        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ReaderPreferencesTests"))
        preferences.save(to: defaults)
        let loaded = ReaderPreferences.load(from: defaults)
        XCTAssertEqual(loaded, preferences)
        XCTAssertTrue(loaded.style(for: .calm).justify)
        XCTAssertFalse(loaded.style(for: .paper).justify)

        preferences.resetTheme()
        XCTAssertFalse(preferences.isStyleCustomized)
        defaults.removePersistentDomain(forName: "ReaderPreferencesTests")
    }

    func testThemesRespectPublisherColorsOnlyInOriginalLight() {
        XCTAssertFalse(ReaderThemeID.original.overridesPublisherColors(dark: false))
        XCTAssertTrue(ReaderThemeID.original.overridesPublisherColors(dark: true))
        XCTAssertTrue(ReaderThemeID.calm.overridesPublisherColors(dark: false))
        XCTAssertTrue(ReaderThemeID.original.palette(dark: true).isDark)
        XCTAssertFalse(ReaderThemeID.paper.palette(dark: false).isDark)
        for theme in ReaderThemeID.allCases {
            XCTAssertTrue(theme.palette(dark: true).isDark, "\(theme) dark palette should be dark")
        }
    }

    func testPageTurnsCompleteOnFlicksOrPastHalfway() {
        XCTAssertTrue(PageTurnPhysics.shouldComplete(progress: 0.05, velocity: 2), "A quick flick turns even a barely moved page")
        XCTAssertFalse(PageTurnPhysics.shouldComplete(progress: 0.9, velocity: -2), "Flicking back cancels")
        XCTAssertTrue(PageTurnPhysics.shouldComplete(progress: 0.6, velocity: 0))
        XCTAssertFalse(PageTurnPhysics.shouldComplete(progress: 0.3, velocity: 0))
        XCTAssertTrue(PageTurnPhysics.shouldComplete(progress: 0.45, velocity: 0.5), "A slow release is projected forward")
        XCTAssertFalse(PageTurnPhysics.shouldComplete(progress: 0.55, velocity: -0.5))
    }

    func testRubberBandResistsAndKeepsDirection() {
        XCTAssertEqual(PageTurnPhysics.rubberBand(0, dimension: 400), 0)
        let pulled = PageTurnPhysics.rubberBand(200, dimension: 400)
        XCTAssertGreaterThan(pulled, 0)
        XCTAssertLessThan(pulled, 100, "Pulling past the last page moves the page much less than the finger")
        XCTAssertEqual(PageTurnPhysics.rubberBand(-200, dimension: 400), -pulled, accuracy: 1e-9)
        XCTAssertLessThan(PageTurnPhysics.rubberBand(10_000, dimension: 400), 400)
    }

    func testSettleSpringCarriesTheFingersSpeed() {
        let flick = PageTurnPhysics.settleTiming(distance: 0.5, velocity: 3)
        XCTAssertEqual(flick.initialVelocity.dx, 6, accuracy: 1e-9, "Velocity is relative to the distance left")
        XCTAssertEqual(PageTurnPhysics.settleTiming(distance: 0.5, velocity: 100).initialVelocity.dx, 30, "Extreme flicks are capped")
        XCTAssertEqual(PageTurnPhysics.settleTiming(distance: 0, velocity: 3).initialVelocity.dx, 0)
    }

    func testPageTurnStylesFollowAppleBooksOrderAndPersist() throws {
        XCTAssertEqual(PageTurnStyle.allCases, [.slide, .curl, .fade, .scroll])
        var preferences = ReaderPreferences()
        XCTAssertEqual(preferences.pageTurn, .slide)
        preferences.pageTurn = .curl
        let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(decoded.pageTurn, .curl)
    }

    func testLayoutKeepsLinesReadableOnEveryScreen() {
        let phone = ReaderLayout(size: CGSize(width: 402, height: 874), safeArea: UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0),
                                 margins: 1, fontScale: 1, scrolls: false, allowsColumns: true)
        XCTAssertEqual(phone.columns, 1)
        XCTAssertEqual(phone.side, 24, "Phones use the plain margin")

        let padPortrait = ReaderLayout(size: CGSize(width: 1032, height: 1376), safeArea: UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0),
                                       margins: 1, fontScale: 1, scrolls: false, allowsColumns: true)
        XCTAssertEqual(padPortrait.columns, 1)
        XCTAssertEqual(1032 - 2 * padPortrait.side, ReaderLayout.readableMeasure, accuracy: 0.5, "A 13-inch iPad in portrait caps the line length")

        let padLandscape = ReaderLayout(size: CGSize(width: 1376, height: 1032), safeArea: .zero,
                                        margins: 1, fontScale: 1, scrolls: false, allowsColumns: true)
        XCTAssertEqual(padLandscape.columns, 2, "Landscape iPads show two pages")
        XCTAssertLessThanOrEqual(688 - 2 * padLandscape.side, ReaderLayout.readableMeasure)

        let padScrolling = ReaderLayout(size: CGSize(width: 1376, height: 1032), safeArea: .zero,
                                        margins: 1, fontScale: 1, scrolls: true, allowsColumns: true)
        XCTAssertEqual(padScrolling.columns, 1, "Scroll mode is a single column")
        XCTAssertEqual(1376 - 2 * padScrolling.side, ReaderLayout.readableMeasure, accuracy: 0.5)

        let wideMargins = ReaderLayout(size: CGSize(width: 1032, height: 1376), safeArea: .zero,
                                       margins: 2, fontScale: 1, scrolls: false, allowsColumns: true)
        XCTAssertGreaterThan(wideMargins.side, padPortrait.side, "The margin setting still widens capped margins")
    }

    func testScrollFadesHugTheEdges() {
        let stops = ReaderLayout.scrollFadeStops(height: 1000, safeArea: UIEdgeInsets(top: 60, left: 0, bottom: 30, right: 0))
        XCTAssertEqual(stops.count, 4)
        XCTAssertEqual(stops[0], 0.03, accuracy: 1e-9, "Text fades out only at the very top")
        XCTAssertEqual(stops[3], 0.988, accuracy: 1e-9, "…and the very bottom")
        XCTAssertGreaterThan(stops[2] - stops[1], 0.85, "Most of the screen shows the book")
        XCTAssertEqual(stops, stops.sorted())
        let layout = ReaderLayout(size: CGSize(width: 402, height: 1000), safeArea: UIEdgeInsets(top: 60, left: 0, bottom: 30, right: 0),
                                  margins: 1, fontScale: 1, scrolls: true, allowsColumns: true)
        XCTAssertLessThan(1 - layout.bottom / 1000, stops[2], "The last line scrolls clear of the bottom fade")
        XCTAssertGreaterThan(layout.top / 1000, stops[1], "The first line starts below the top fade")
    }

    func testSortKeysIgnoreLeadingArticles() {
        XCTAssertEqual(Book.sortKey("The Odyssey"), "odyssey")
        XCTAssertEqual(Book.sortKey("An Answer"), "answer")
        XCTAssertEqual(Book.sortKey("Theory"), "theory")
    }
}
