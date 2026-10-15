import XCTest

/// End-to-end flows against a generated EPUB 3.4 sample book in an isolated, in-memory library.
@MainActor
final class LibraryFlowTests: XCTestCase {
    private lazy var app: XCUIApplication = {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-seed-sample-book"]
        app.launch()
        return app
    }()

    func testOpensBookAndUsesReaderMenus() throws {
        app.tabBars.buttons["Library"].tap()
        let book = app.buttons["book.The Sample Voyage"]
        XCTAssertTrue(book.waitForExistence(timeout: 15), "The seeded book should appear in the library")
        book.tap()

        let content = app.otherElements["reader.content"]
        XCTAssertTrue(content.waitForExistence(timeout: 10))
        XCTAssertTrue(app.webViews.staticTexts["Departure"].waitForExistence(timeout: 10), "Chapter 1 should render")

        showChrome()
        let pageLabel = app.buttons["reader.pageLabel"]
        XCTAssertTrue(pageLabel.waitForExistence(timeout: 5))
        XCTAssertTrue(pageLabel.label.contains("of"), "Paginated books show “x of y”, got \(pageLabel.label)")

        // Contents: jump to the nested "The Storm" entry in chapter 2.
        app.buttons["reader.menu"].tap()
        app.buttons["reader.menu.contents"].tap()
        let storm = app.buttons["The Storm"]
        XCTAssertTrue(storm.waitForExistence(timeout: 5))
        storm.tap()
        XCTAssertTrue(app.webViews.staticTexts.containing(NSPredicate(format: "label CONTAINS 'chapter 2'")).firstMatch
            .waitForExistence(timeout: 10), "Navigating to a nested TOC entry should load chapter 2")

        // Themes: switch to Calm and increase the font size.
        showChrome()
        app.buttons["reader.menu"].tap()
        app.buttons["reader.menu.themes"].tap()
        let calm = app.buttons["theme.calm"]
        XCTAssertTrue(calm.waitForExistence(timeout: 5))
        calm.tap()
        XCTAssertTrue(calm.isSelected)
        app.buttons["themes.increaseFont"].tap()
        app.buttons["themes.customize"].tap()
        XCTAssertTrue(app.switches["Bold Text"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Done"].firstMatch.tap()

        // Bookmark the page, then confirm it is listed.
        showChrome()
        app.buttons["reader.menu"].tap()
        app.buttons["reader.bookmark"].tap()
        showChrome()
        app.buttons["reader.menu"].tap()
        app.buttons["reader.menu.contents"].tap()
        app.buttons["Bookmarks"].tap()
        XCTAssertTrue(app.staticTexts["Open Water"].waitForExistence(timeout: 5))
        app.buttons["Done"].firstMatch.tap()

        showChrome()
        app.buttons["reader.close"].tap()
        XCTAssertTrue(book.waitForExistence(timeout: 5))
    }

    func testTurnsPagesAcrossChapters() throws {
        app.tabBars.buttons["Library"].tap()
        let book = app.buttons["book.The Sample Voyage"]
        XCTAssertTrue(book.waitForExistence(timeout: 15))
        book.tap()
        XCTAssertTrue(app.webViews.staticTexts["Departure"].waitForExistence(timeout: 10))

        // Tapping the right edge repeatedly pages through chapter 1 into chapter 2.
        let rightEdge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5))
        var reachedChapterTwo = false
        for _ in 0..<40 {
            rightEdge.tap()
            if app.webViews.staticTexts["Open Water"].waitForExistence(timeout: 0.6) {
                reachedChapterTwo = true
                break
            }
        }
        XCTAssertTrue(reachedChapterTwo, "Paging past the last page should open the next chapter")

        // Reopening the book restores the reading position.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["reader.close"].waitForExistence(timeout: 5))
        app.buttons["reader.close"].tap()
        XCTAssertTrue(book.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["book.The Sample Voyage"].label.isEmpty, false)
        book.tap()
        XCTAssertTrue(app.webViews.staticTexts["Open Water"].waitForExistence(timeout: 10), "The book reopens where it was left")
    }

    func testSettingsShowsAppearanceAndRepositoryLink() throws {
        app.buttons["settings.open"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Dark"].waitForExistence(timeout: 5))
        app.buttons["Dark"].tap()
        XCTAssertTrue(app.buttons["settings.github"].exists)
        app.buttons["settings.done"].tap()
    }

    private func showChrome() {
        if !app.buttons["reader.menu"].exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(app.buttons["reader.menu"].waitForExistence(timeout: 5))
    }
}
