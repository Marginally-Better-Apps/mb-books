import XCTest

/// End-to-end flows against a generated EPUB 3.4 sample book in an isolated, in-memory library.
@MainActor
final class LibraryFlowTests: XCTestCase {
    /// First launches on a freshly booted simulator (as on CI) can be slow while WebKit warms up.
    private let launchTimeout: TimeInterval = 60

    override func record(_ issue: XCTIssue) {
        // Attach what the screen looked like when an assertion failed.
        var issue = issue
        issue.add(XCTAttachment(screenshot: XCUIScreen.main.screenshot()))
        super.record(issue)
    }

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
        XCTAssertTrue(book.waitForExistence(timeout: launchTimeout), "The seeded book should appear in the library")
        book.tap()

        let content = app.otherElements["reader.content"]
        XCTAssertTrue(content.waitForExistence(timeout: launchTimeout))
        XCTAssertTrue(app.webViews.staticTexts["Departure"].waitForExistence(timeout: launchTimeout), "Chapter 1 should render")

        showChrome()
        let pageLabel = app.buttons["reader.pageLabel"]
        XCTAssertTrue(pageLabel.waitForExistence(timeout: 5))
        XCTAssertTrue(pageLabel.label.contains("of"), "Paginated books show “x of y”, got \(pageLabel.label)")

        // Contents: jump to the nested "The Storm" entry in chapter 2.
        openMenu("reader.menu.contents").tap()
        let storm = app.buttons["The Storm"]
        XCTAssertTrue(storm.waitForExistence(timeout: 5))
        storm.tap()
        XCTAssertTrue(app.webViews.staticTexts.containing(NSPredicate(format: "label CONTAINS 'chapter 2'")).firstMatch
            .waitForExistence(timeout: 10), "Navigating to a nested TOC entry should load chapter 2")

        // Themes: switch to Calm and increase the font size.
        openMenu("reader.menu.themes").tap()
        let calm = app.buttons["theme.calm"]
        XCTAssertTrue(calm.waitForExistence(timeout: 5))
        // Slow simulators can still be sliding the sheet up; a tap then lands nowhere.
        XCTAssertTrue(wait(for: calm, toMatch: "isHittable == true"))
        calm.tap()
        XCTAssertTrue(wait(for: calm, toMatch: "isSelected == true"), "Tapping a theme should select it")
        app.buttons["themes.increaseFont"].tap()
        app.buttons["themes.customize"].tap()
        XCTAssertTrue(app.switches["Bold Text"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Done"].firstMatch.tap()

        // Bookmark the page, then confirm it is listed.
        openMenu("reader.bookmark").tap()
        openMenu("reader.menu.contents").tap()
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
        XCTAssertTrue(book.waitForExistence(timeout: launchTimeout))
        book.tap()
        XCTAssertTrue(app.webViews.staticTexts["Departure"].waitForExistence(timeout: launchTimeout))

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

    func testSwipesPagesInEveryStyle() throws {
        app.tabBars.buttons["Library"].tap()
        let book = app.buttons["book.The Sample Voyage"]
        XCTAssertTrue(book.waitForExistence(timeout: launchTimeout))
        book.tap()
        XCTAssertTrue(app.webViews.staticTexts["Departure"].waitForExistence(timeout: launchTimeout))

        // Each style pages back to the book's first page, then forward across the chapter boundary.
        for style in ["Slide", "Curl", "Fast Fade"] {
            choosePageTurn(style)
            XCTAssertTrue(swipe(right: true, untilShowing: "Departure"), "\(style): swiping right returns to the first page")
            XCTAssertTrue(swipe(right: false, untilShowing: "Open Water"), "\(style): swiping left pages into chapter 2")
        }

        // Scroll mode: pulling past the end of chapter 2 moves on to chapter 3.
        choosePageTurn("Scroll")
        var reachedChapterThree = false
        for _ in 0..<20 where !reachedChapterThree {
            app.swipeUp()
            reachedChapterThree = app.webViews.staticTexts["Landfall"].waitForExistence(timeout: 1)
        }
        XCTAssertTrue(reachedChapterThree, "Scrolling past the end of a chapter should open the next one")
    }

    func testListensFollowsAlongAndShowsWhatIsRead() throws {
        app.tabBars.buttons["Library"].tap()
        let book = app.buttons["book.The Sample Voyage"]
        XCTAssertTrue(book.waitForExistence(timeout: launchTimeout))
        book.tap()
        XCTAssertTrue(app.webViews.staticTexts["Departure"].waitForExistence(timeout: launchTimeout))

        showChrome()
        app.buttons["reader.listen"].tap()
        let playPause = app.buttons["listen.playPause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 10), "Listening shows its controls")
        XCTAssertTrue(app.buttons["listen.speed"].exists)

        // What's read: every chapter, with the footnote and its marker left out.
        app.buttons["listen.options"].tap()
        let contents = app.buttons["listen.contents"]
        XCTAssertTrue(app.buttons["listen.done"].waitForExistence(timeout: 5))
        for _ in 0..<8 where !(contents.exists && contents.isHittable) { app.swipeUp() }
        contents.tap()
        XCTAssertTrue(app.staticTexts["Departure"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Landfall"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'note reference'")).firstMatch.exists,
                      "The footnote marker is listed as left out")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["listen.done"].tap()

        // Turning the page by hand stops following until the reader asks to return.
        // The button sits in the controls, which hide by themselves while listening.
        let returnButton = app.buttons["listen.return"]
        for _ in 0..<3 where !returnButton.exists {
            app.swipeLeft()
            if returnButton.waitForExistence(timeout: 2) { break }
            showChrome()
            _ = returnButton.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(returnButton.exists, "Paging away offers a way back to the narration")
        returnButton.tap()
        XCTAssertTrue(wait(for: returnButton, toMatch: "exists == false"))

        showChrome()
        app.buttons["listen.stop"].tap()
        XCTAssertTrue(wait(for: playPause, toMatch: "exists == false"), "Stopping hides the controls")
    }

    func testPreviewingAndChoosingAVoiceNeverStartsTheBook() throws {
        app.tabBars.buttons["Library"].tap()
        let book = app.buttons["book.The Sample Voyage"]
        XCTAssertTrue(book.waitForExistence(timeout: launchTimeout))
        book.tap()
        XCTAssertTrue(app.webViews.staticTexts["Departure"].waitForExistence(timeout: launchTimeout))
        showChrome()
        app.buttons["reader.listen"].tap()
        let playPause = app.buttons["listen.playPause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(for: playPause, toMatch: "label == 'Pause'"), "Listening starts playing")
        playPause.tap()
        XCTAssertTrue(wait(for: playPause, toMatch: "label == 'Play'"))

        app.buttons["listen.options"].tap()
        // Natural voices can be heard before they're downloaded.
        let naturalPreview = app.buttons["voice.preview.george"]
        XCTAssertTrue(naturalPreview.waitForExistence(timeout: 5))
        naturalPreview.tap()
        XCTAssertTrue(wait(for: naturalPreview, toMatch: "label == 'Stop Sample'"), "The sample plays")
        naturalPreview.tap()
        XCTAssertTrue(wait(for: naturalPreview, toMatch: "label BEGINSWITH 'Play Sample'"))

        // Choose a different Apple voice while paused.
        let systemVoices = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'voice.select.com.apple'"))
        var identifier: String?
        for _ in 0..<6 where identifier == nil {
            // Let the list stop coasting, or the tap only stops the scroll.
            sleep(1)
            // Rows under the sheet's translucent header still count as hittable; take one well inside the list.
            let top = app.buttons["listen.done"].frame.maxY + 60
            identifier = systemVoices.allElementsBoundByIndex
                .first { $0.isHittable && !$0.isSelected && $0.frame.minY > top }?.identifier
            if identifier == nil { app.swipeUp() }
        }
        let choice = app.buttons[try XCTUnwrap(identifier, "An Apple voice to choose")]
        choice.tap()
        XCTAssertTrue(wait(for: choice, toMatch: "isSelected == true"), "The voice is chosen")
        app.buttons["listen.done"].tap()

        showChrome()
        XCTAssertTrue(playPause.waitForExistence(timeout: 5))
        sleep(2)
        XCTAssertEqual(playPause.label, "Play", "Choosing a voice leaves the book paused")
        playPause.tap()
        XCTAssertTrue(wait(for: playPause, toMatch: "label == 'Pause'"), "Resuming reads with the new voice")
        app.buttons["listen.stop"].tap()
    }

    func testSettingsShowsAppearanceAndRepositoryLink() throws {
        XCTAssertTrue(app.buttons["settings.open"].firstMatch.waitForExistence(timeout: launchTimeout))
        app.buttons["settings.open"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Dark"].waitForExistence(timeout: launchTimeout))
        app.buttons["Dark"].tap()
        // The About section sits below Listening and Library.
        let github = app.buttons["settings.github"]
        for _ in 0..<4 where !github.isHittable { app.swipeUp() }
        XCTAssertTrue(github.exists)
        XCTAssertTrue(app.buttons["Download Natural Voices"].exists || app.staticTexts["Listening"].exists)
        app.buttons["settings.done"].tap()
    }

    private func choosePageTurn(_ style: String) {
        openMenu("reader.menu.themes").tap()
        let menu = app.buttons["themes.pageTurn"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        let option = app.buttons[style].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), "The Page Turn menu should offer \(style)")
        option.tap()
        app.buttons["Done"].firstMatch.tap()
    }

    /// Swipes until the heading `title` is on screen (not just somewhere in the chapter's columns).
    private func swipe(right: Bool, untilShowing title: String) -> Bool {
        let screen = app.windows.firstMatch.frame
        for _ in 0..<30 {
            let heading = app.webViews.staticTexts[title].firstMatch
            if heading.exists, screen.contains(CGPoint(x: heading.frame.midX, y: heading.frame.midY)) { return true }
            if right { app.swipeRight() } else { app.swipeLeft() }
            Thread.sleep(forTimeInterval: 0.7)
        }
        return false
    }

    private func wait(for element: XCUIElement, toMatch format: String, timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Shows the reader's controls. They can fade mid-animation or, while listening, hide on their own
    /// after a few seconds, so a single tap isn't enough.
    private func showChrome() {
        let menu = app.buttons["reader.menu"]
        for _ in 0..<3 where !menu.waitForExistence(timeout: 1) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            if menu.waitForExistence(timeout: 2) { break }
        }
        XCTAssertTrue(menu.exists)
    }

    /// Opens the reading menu and returns its `item` button, retrying if the controls hid meanwhile.
    private func openMenu(_ item: String) -> XCUIElement {
        let button = app.buttons[item]
        for _ in 0..<3 {
            showChrome()
            app.buttons["reader.menu"].tap()
            if button.waitForExistence(timeout: 3) { break }
        }
        XCTAssertTrue(button.exists, "The reading menu should offer \(item)")
        return button
    }
}
