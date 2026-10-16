import XCTest

/// A development aid that opens every book in a folder and saves screenshots.
/// Skipped unless `MB_TOUR_DIR` (books) and `MB_TOUR_OUTPUT` (screenshots) are set, e.g. via
/// `TEST_RUNNER_MB_TOUR_DIR=… TEST_RUNNER_MB_TOUR_OUTPUT=… xcodebuild test …`.
@MainActor
final class ScreenshotTour: XCTestCase {
    func testTour() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let books = environment["MB_TOUR_DIR"], let output = environment["MB_TOUR_OUTPUT"] else {
            throw XCTSkip("Set MB_TOUR_DIR and MB_TOUR_OUTPUT to run the screenshot tour.")
        }
        let outputURL = URL(filePath: output)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-import-directory", books]
        if let appearance = environment["MB_TOUR_APPEARANCE"] { app.launchArguments += ["-appearance", appearance] }
        app.launch()

        func save(_ name: String) {
            let data = XCUIScreen.main.screenshot().pngRepresentation
            try? data.write(to: outputURL.appending(path: "\(name).png"))
        }

        sleep(8)
        save("00-home")
        app.tabBars.buttons["Library"].tap()
        sleep(1)
        save("01-library")

        let filter = environment["MB_TOUR_ONLY"]
        let titles = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'book.'")).allElementsBoundByIndex
            .map(\.identifier)
        for (index, identifier) in titles.enumerated() {
            if let filter, !identifier.localizedCaseInsensitiveContains(filter) { continue }
            let button = app.buttons[identifier].firstMatch
            for _ in 0..<12 where !button.isHittable { app.swipeUp() }
            button.tap()
            sleep(3)
            let name = String(format: "%02d", index + 2) + "-" + identifier.replacingOccurrences(of: "/", with: "-")
            save("\(name)-a")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            sleep(2)
            save("\(name)-b")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            sleep(1)
            save("\(name)-c-chrome")
            if app.buttons["reader.menu"].exists {
                app.buttons["reader.menu"].tap()
                sleep(1)
                save("\(name)-d-menu")
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)).tap()
            }
            if !app.buttons["reader.close"].exists {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            if app.buttons["reader.close"].waitForExistence(timeout: 3) {
                app.buttons["reader.close"].tap()
            }
            sleep(1)
        }
    }

    /// Captures the reader's sheets and themes using the generated sample book.
    func testReaderTour() throws {
        let app = XCUIApplication()
        guard let output = ProcessInfo.processInfo.environment["MB_TOUR_OUTPUT"] else {
            throw XCTSkip("Set MB_TOUR_OUTPUT to run the screenshot tour.")
        }
        let outputURL = URL(filePath: output)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        func showChrome() {
            if !app.buttons["reader.menu"].exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
            _ = app.buttons["reader.menu"].waitForExistence(timeout: 3)
        }
        func save(_ name: String) {
            sleep(1)
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: outputURL.appending(path: "r-\(name).png"))
        }
        app.launchArguments = ["-ui-testing", "-seed-sample-book"]
        app.launch()
        app.tabBars.buttons["Library"].tap()
        let book = app.buttons["book.The Sample Voyage"]
        XCTAssertTrue(book.waitForExistence(timeout: 15))
        book.tap()
        sleep(2)
        save("01-page")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        save("02-chrome")
        app.buttons["reader.menu"].tap()
        app.buttons["reader.menu.themes"].tap()
        save("03-themes")
        app.buttons["theme.calm"].tap()
        save("04-calm")
        app.buttons["themes.customize"].tap()
        save("05-customize")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["theme.quiet"].tap()
        app.buttons["Done"].firstMatch.tap()
        save("06-quiet")
        showChrome()
        app.buttons["reader.menu"].tap()
        app.buttons["reader.menu.contents"].tap()
        save("07-contents")
        app.buttons["Done"].firstMatch.tap()
        showChrome()
        app.buttons["reader.menu"].tap()
        app.buttons["reader.menu.search"].tap()
        app.textFields["bookSearch.field"].typeText("compass")
        sleep(1)
        save("08-search")
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'compass'")).firstMatch.tap()
        save("09-search-result")
        // Footnote popover.
        app.webViews.links["1"].firstMatch.tap()
        save("10-footnote")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).tap()
        // Highlight: select a word and choose Highlight.
        app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Paragraph 2'")).firstMatch.press(forDuration: 1.2)
        save("11-selection")
        if app.menuItems["Highlight"].waitForExistence(timeout: 3) {
            app.menuItems["Highlight"].tap()
            save("12-highlight")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
            sleep(1)
        }
        showChrome()
        app.buttons["reader.close"].tap()
        sleep(1)
        app.tabBars.buttons["Home"].tap()
        save("13-home")
        app.buttons["settings.open"].firstMatch.tap()
        save("14-settings")
        app.buttons["Dark"].tap()
        app.buttons["settings.done"].tap()
        save("15-home-dark")
        app.tabBars.buttons["Library"].tap()
        book.tap()
        sleep(2)
        save("16-reader-dark")
    }

    /// Captures listening: the controls, the highlight following along, and the listening options.
    func testListenTour() throws {
        let app = XCUIApplication()
        guard let output = ProcessInfo.processInfo.environment["MB_TOUR_OUTPUT"] else {
            throw XCTSkip("Set MB_TOUR_OUTPUT to run the screenshot tour.")
        }
        let outputURL = URL(filePath: output)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        func save(_ name: String) {
            sleep(1)
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: outputURL.appending(path: "l-\(name).png"))
        }
        app.launchArguments = ["-ui-testing", "-seed-sample-book"]
        app.launch()
        app.tabBars.buttons["Library"].tap()
        let book = app.buttons["book.The Sample Voyage"]
        XCTAssertTrue(book.waitForExistence(timeout: 15))
        book.tap()
        sleep(2)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        save("01-chrome")
        app.buttons["reader.listen"].tap()
        sleep(3)
        save("02-listening")
        sleep(4)
        save("03-following")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        save("04-pill")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        _ = app.buttons["listen.options"].waitForExistence(timeout: 3)
        app.buttons["listen.options"].tap()
        save("05-options")
        app.buttons["listen.contents"].tap()
        sleep(2)
        save("06-whats-read")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Studio"].tap()
        save("07-studio")
        app.swipeUp()
        save("08-studio-more")
        app.buttons["listen.done"].tap()
        app.swipeLeft()
        sleep(2)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        save("09-return")
    }

    /// Starts listening to real books (with covers, front matter, and notes) and checks the app keeps running.
    /// Needs `MB_LISTEN_DIR`, a folder of `.epub` files.
    func testListenToImportedBooks() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let books = environment["MB_LISTEN_DIR"] else { throw XCTSkip("Set MB_LISTEN_DIR to run.") }
        let output = environment["MB_TOUR_OUTPUT"].map { URL(filePath: $0) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-import-directory", books]
        if let models = environment["MB_VOICE_MODEL_DIR"] { app.launchEnvironment["MB_VOICE_MODEL_DIR"] = models }
        app.launch()
        app.tabBars.buttons["Library"].tap()
        let book = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'book.'")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 60))
        book.tap()
        sleep(3)
        for _ in 0..<3 where !app.buttons["reader.listen"].exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            _ = app.buttons["reader.listen"].waitForExistence(timeout: 3)
        }
        app.buttons["reader.listen"].tap()
        for second in 0..<5 {
            sleep(2)
            XCTAssertEqual(app.state, .runningForeground, "The app keeps running while listening")
            if let output {
                try? XCUIScreen.main.screenshot().pngRepresentation.write(to: output.appending(path: "i-\(second).png"))
            }
        }
        XCTAssertTrue(app.buttons["listen.playPause"].exists || app.buttons["listen.pill"].exists)
        // Back home, the Continue shelf shows the book with progress as wide as its cover.
        if !app.buttons["reader.close"].exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        app.buttons["reader.close"].tap()
        app.tabBars.buttons["Home"].tap()
        sleep(2)
        if let output { try? XCUIScreen.main.screenshot().pngRepresentation.write(to: output.appending(path: "i-home.png")) }
    }

    /// Listens with the Studio voice. Needs `MB_VOICE_MODEL_DIR`: a folder with `model.onnx` and `voices/af_heart.bin`.
    func testStudioTour() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let output = environment["MB_TOUR_OUTPUT"], let models = environment["MB_VOICE_MODEL_DIR"] else {
            throw XCTSkip("Set MB_TOUR_OUTPUT and MB_VOICE_MODEL_DIR to run the Studio tour.")
        }
        let outputURL = URL(filePath: output)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        func save(_ name: String) {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: outputURL.appending(path: "s-\(name).png"))
        }
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-seed-sample-book"]
        app.launchEnvironment["MB_VOICE_MODEL_DIR"] = models
        app.launch()
        app.tabBars.buttons["Library"].tap()
        let book = app.buttons["book.The Sample Voyage"]
        XCTAssertTrue(book.waitForExistence(timeout: 15))
        book.tap()
        XCTAssertTrue(app.webViews.staticTexts["Departure"].waitForExistence(timeout: 30))
        for _ in 0..<3 where !app.buttons["reader.listen"].exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            _ = app.buttons["reader.listen"].waitForExistence(timeout: 3)
        }
        app.buttons["reader.listen"].tap()
        XCTAssertTrue(app.buttons["listen.options"].waitForExistence(timeout: 10))
        app.buttons["listen.options"].tap()
        app.buttons["Studio"].tap()
        sleep(1)
        save("01-studio-options")
        app.buttons["listen.done"].tap()
        for second in 0..<8 {
            sleep(2)
            save(String(format: "02-playing-%02d", second))
        }
    }

    /// Drags pages slowly, cancels a turn, and flicks, in each style, for screen recordings of page turns.
    func testPageTurnTour() throws {
        guard ProcessInfo.processInfo.environment["MB_TOUR_OUTPUT"] != nil else {
            throw XCTSkip("Set MB_TOUR_OUTPUT to run the screenshot tour.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-seed-sample-book"]
        app.launch()
        app.tabBars.buttons["Library"].tap()
        let book = app.buttons["book.The Sample Voyage"]
        XCTAssertTrue(book.waitForExistence(timeout: 15))
        book.tap()
        sleep(2)
        func point(_ x: CGFloat) -> XCUICoordinate { app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.5)) }
        for style in ["Slide", "Curl", "Fast Fade"] {
            if !app.buttons["reader.menu"].exists { point(0.5).tap() }
            app.buttons["reader.menu"].tap()
            app.buttons["reader.menu.themes"].tap()
            app.buttons["themes.pageTurn"].tap()
            app.buttons[style].firstMatch.tap()
            app.buttons["Done"].firstMatch.tap()
            sleep(1)
            // A slow drag held at the middle of the page, then released.
            point(0.9).press(forDuration: 0.1, thenDragTo: point(0.45), withVelocity: 300, thenHoldForDuration: 1)
            sleep(1)
            // A short drag released slowly: the page should fall back.
            point(0.9).press(forDuration: 0.1, thenDragTo: point(0.75), withVelocity: 200, thenHoldForDuration: 0.5)
            sleep(1)
            // Quick flicks forward and back.
            for _ in 0..<3 { app.swipeLeft(velocity: .fast) }
            sleep(1)
            app.swipeRight(velocity: .fast)
            sleep(1)
            // Taps on the edge.
            point(0.95).tap()
            sleep(1)
            point(0.05).tap()
            sleep(1)
        }
    }

    /// Captures the main screens in portrait and landscape, for checking layouts across iPhone and iPad sizes.
    func testLayoutTour() throws {
        guard let output = ProcessInfo.processInfo.environment["MB_TOUR_OUTPUT"] else {
            throw XCTSkip("Set MB_TOUR_OUTPUT to run the screenshot tour.")
        }
        let outputURL = URL(filePath: output)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-seed-sample-book"]
        app.launch()
        func save(_ name: String) {
            sleep(1)
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: outputURL.appending(path: "l-\(name).png"))
        }
        func showChrome() {
            if !app.buttons["reader.menu"].exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
            _ = app.buttons["reader.menu"].waitForExistence(timeout: 3)
        }
        func closeSheet() {
            app.buttons["Done"].firstMatch.tap()
            sleep(1)
        }
        /// Highlights a word, so the highlight menu appears anchored to it.
        func highlight(_ text: String, _ name: String) {
            app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.press(forDuration: 1.2)
            if app.menuItems["Highlight"].waitForExistence(timeout: 3) {
                app.menuItems["Highlight"].tap()
                save(name)
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
                sleep(1)
            }
        }
        for (label, orientation) in [("portrait", UIDeviceOrientation.portrait), ("landscape", .landscapeLeft)] {
            XCUIDevice.shared.orientation = orientation
            app.buttons["Home"].firstMatch.tap()
            save("\(label)-01-home")
            app.buttons["settings.open"].firstMatch.tap()
            save("\(label)-02-settings")
            app.buttons["settings.done"].tap()
            app.buttons["Library"].firstMatch.tap()
            save("\(label)-03-library")
            let book = app.buttons["book.The Sample Voyage"]
            XCTAssertTrue(book.waitForExistence(timeout: 15))
            book.tap()
            XCTAssertTrue(app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "of chapter")).firstMatch.waitForExistence(timeout: 30), "\(label): the book should open")
            save("\(label)-04-page")
            highlight("Paragraph 2", "\(label)-04b-highlight")
            showChrome()
            app.buttons["reader.menu"].tap()
            save("\(label)-05-menu")
            app.buttons["reader.menu.themes"].tap()
            save("\(label)-06-themes")
            app.buttons["themes.pageTurn"].tap()
            app.buttons["Scroll"].firstMatch.tap()
            closeSheet()
            app.swipeUp()
            sleep(1)
            save("\(label)-07-scroll")
            highlight("Paragraph 6", "\(label)-07b-scroll-highlight")
            showChrome()
            app.buttons["reader.menu"].tap()
            app.buttons["reader.menu.contents"].tap()
            save("\(label)-08-contents")
            closeSheet()
            showChrome()
            app.buttons["reader.menu"].tap()
            app.buttons["reader.menu.themes"].tap()
            app.buttons["themes.pageTurn"].tap()
            app.buttons["Slide"].firstMatch.tap()
            closeSheet()
            showChrome()
            app.buttons["reader.close"].tap()
            sleep(1)
        }
        XCUIDevice.shared.orientation = .portrait
    }
}
