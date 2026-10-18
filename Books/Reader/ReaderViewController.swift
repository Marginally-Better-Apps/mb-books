import OSLog
import SwiftUI
import UIKit
import WebKit

/// Renders a publication and turns its pages.
///
/// Each document loads into a `ChapterView` (one `WKWebView`). Reflowable chapters paginate with CSS
/// columns (`reader.js`); fixed-layout spreads and rolls load generated wrapper pages that scale each
/// document inside an iframe. Spare chapter views preload the documents on either side of the current
/// one, so turning across a chapter boundary is as quick as turning within one. A `PageTurnPresenter`
/// animates turns in the reader's chosen style.
final class ReaderViewController: UIViewController {
    private static let logger = Logger(subsystem: "com.mbbooks.MBBooks", category: "Reader")

    /// Where a document should be once it has loaded.
    private enum Target {
        case locator(Locator)
        case start
        case end
        case search(BookSearchResult, query: String)
        /// A text offset, as the read-aloud script counts them.
        case textOffset(Int)

        init(_ placement: ChapterView.Placement) {
            self = placement == .start ? .start : .end
        }

        var placement: ChapterView.Placement? {
            switch self {
            case .start: .start
            case .end: .end
            case .locator, .search, .textOffset: nil
            }
        }
    }

    private enum PresenterKind: Equatable {
        case slide, fade, push
        case curl(mirrored: Bool)
    }

    private let model: ReaderModel
    private let world = WKContentWorld.world(name: "MBReader")
    private let messageProxy = ScriptMessageProxy()
    private let userContentController = WKUserContentController()
    /// Keeps spare chapters in the window, behind the page, so WebKit lays them out and paints them.
    private let parkingView = UIView()
    /// Covers the parked chapters, so scroll mode's faded edges show the page color rather than them.
    private let backdropView = UIView()
    private let touchTracker = TouchStartRecognizer()
    /// Fades text out at the top and bottom of the screen in scroll mode.
    private let scrollFadeMask = CAGradientLayer()
    private lazy var edgeTap = UITapGestureRecognizer(target: self, action: #selector(handleEdgeTap(_:)))
    private var presenter: PageTurnPresenter?
    private var presenterKind: PresenterKind?
    private var current: ChapterView!
    private var spares: [ChapterView] = []
    private var spreadPlan = SpreadPlan(spine: [], landscape: false)
    private var lastLayoutSize: CGSize = .zero
    private var reconfigureTask: Task<Void, Never>?
    private var preloadTask: Task<Void, Never>?
    /// Increments with each jump, so a slow load can't override a later one.
    private var navigationID = 0
    /// A tap that arrived while a turn couldn't be cut short; it runs when that turn ends.
    private var queuedTurn: PageTurn.Side?
    private var hasSelection = false
    /// Set while listening turns the page, so the turn isn't taken for the reader browsing.
    private var isSpeechNavigation = false
    /// Orders read-aloud marks, so `reader.js` can drop any that arrive after a newer one.
    private var speechSequence = 0

    init(model: ReaderModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var publication: Publication { model.publication }
    private var contentRoot: URL { model.container.root }
    private var chapters: [ChapterView] { [current] + spares }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.clipsToBounds = true
        parkingView.frame = view.bounds
        parkingView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        parkingView.isUserInteractionEnabled = false
        view.addSubview(parkingView)
        backdropView.frame = view.bounds
        backdropView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backdropView.isUserInteractionEnabled = false
        view.addSubview(backdropView)
        view.addGestureRecognizer(touchTracker)
        edgeTap.delegate = self
        edgeTap.cancelsTouchesInView = false
        view.addGestureRecognizer(edgeTap)

        messageProxy.handler = { [weak self] message in self?.handle(message) }
        userContentController.add(messageProxy, contentWorld: world, name: "mb")
        current = makeChapterView()
        current.isActive = true
        spares = (0..<2).map { _ in makeChapterView() }
        spares.forEach(park)
        installPresenter()
        updateBackground()
        model.navigator = self
        model.speechFollower = self
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        updateScrollFades()
        if lastLayoutSize == .zero {
            lastLayoutSize = size
            spreadPlan = makeSpreadPlan()
            installUserScripts()
            go(to: model.location, animated: false)
        } else if size != lastLayoutSize {
            lastLayoutSize = size
            scheduleReconfigure()
        }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        if lastLayoutSize != .zero { scheduleReconfigure() }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Preloaded chapters are a convenience; give their memory back and preload again later.
        preloadTask?.cancel()
        for spare in spares where presenter?.isTurning != true {
            spare.reset()
            spare.webView.loadHTMLString("", baseURL: nil)
        }
    }

    private func makeChapterView() -> ChapterView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userContentController
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.dataDetectorTypes = []
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.isTextInteractionEnabled = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile

        let chapter = ChapterView(configuration: configuration)
        chapter.frame = view.bounds
        chapter.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        chapter.webView.navigationDelegate = self
        chapter.webView.uiDelegate = self
        chapter.webView.menuActions = BookWebView.MenuActions(
            highlight: { [weak self] in Task { await self?.model.highlightSelection() } },
            note: { [weak self] in Task { await self?.model.addNoteToSelection() } },
            search: { [weak self] text in
                self?.model.searchQuery = text
                self?.model.sheet = .search
            },
            listen: { [weak self] in self?.model.startListening(fromSelection: true) })
        chapter.webView.scrollView.panGestureRecognizer.addTarget(self, action: #selector(handleScrollPan(_:)))
        return chapter
    }

    private func installUserScripts() {
        userContentController.removeAllUserScripts()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        userContentController.addUserScript(WKUserScript(
            source: "((__MB_VERSION__) => {\n\(ReaderScripts.readingSystem)\n})(\(ReaderScripts.jsonString(version)));",
            injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        userContentController.addUserScript(WKUserScript(
            source: ReaderScripts.guarded("((__MB_CONFIG__) => {\n\(ReaderScripts.reader)\n})(\(scriptConfig().json));"),
            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
        userContentController.addUserScript(WKUserScript(
            source: ReaderScripts.frame, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
    }

    // MARK: - Configuration

    private func scriptConfig() -> ScriptConfiguration {
        let style = model.preferences.style
        let layout = ReaderLayout(
            size: view.bounds.size, safeArea: view.safeAreaInsets, margins: style.margins,
            fontScale: model.preferences.fontScale, scrolls: model.isScrollMode, allowsColumns: style.allowMultipleColumns)
        let palette = model.palette
        return ScriptConfiguration(
            layout: publication.layout.rawValue,
            mode: model.isScrollMode ? "scroll" : "paginated",
            insets: .init(top: layout.top, bottom: layout.bottom, side: layout.side),
            columns: layout.columns,
            fontScale: model.preferences.fontScale,
            fontFamily: style.font.cssFamily,
            bold: style.boldText,
            lineHeight: style.lineSpacing,
            letterSpacing: style.characterSpacing,
            wordSpacing: style.wordSpacing,
            justify: style.justify,
            dark: model.isDarkAppearance,
            colors: .init(
                background: palette.background.cssHex,
                text: palette.text.cssHex,
                link: palette.link.cssHex,
                override: model.preferences.theme.overridesPublisherColors(dark: model.isDarkAppearance)))
    }

    private func updateBackground() {
        let color = UIColor(model.palette.backgroundColor)
        view.backgroundColor = color
        backdropView.backgroundColor = color
        presenter?.view.backgroundColor = color
        for chapter in chapters {
            chapter.backgroundColor = color
            chapter.webView.underPageBackgroundColor = color
        }
    }

    private func updateScrollFades() {
        guard let host = presenter?.view else { return }
        guard model.isScrollMode else {
            host.layer.mask = nil
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrollFadeMask.colors = [UIColor.clear, .black, .black, .clear].map(\.cgColor)
        // The page fills this view; its own bounds may not have caught up during layout.
        scrollFadeMask.locations = ReaderLayout.scrollFadeStops(height: view.bounds.height, safeArea: view.safeAreaInsets)
            .map { NSNumber(value: Double($0)) }
        scrollFadeMask.frame = view.bounds
        host.layer.mask = scrollFadeMask
        CATransaction.commit()
    }

    private func updateScrolling() {
        for chapter in chapters { chapter.setScrolls(scrolls(chapter.document)) }
    }

    /// Rolls always scroll; reflowable chapters scroll in scroll mode. Everything else turns pages.
    private func scrolls(_ document: ReaderDocument?) -> Bool {
        switch document {
        case .roll: true
        case .reflowable: model.isScrollMode
        case .fixed, nil: false
        }
    }

    private var desiredPresenterKind: PresenterKind {
        if publication.layout == .roll || model.isScrollMode { return .push }
        switch model.preferences.pageTurn {
        case .curl: return .curl(mirrored: publication.readingProgression == .rtl)
        case .fade: return .fade
        // Fixed layouts can't scroll, so they slide.
        case .slide, .scroll: return .slide
        }
    }

    /// Swaps in the presenter for the current page-turn style, moving the page across.
    private func installPresenter() {
        let kind = desiredPresenterKind
        guard kind != presenterKind else { return }
        let presenter: PageTurnPresenter = switch kind {
        case .slide: SlidePagePresenter(style: .slide)
        case .fade: SlidePagePresenter(style: .fade)
        case .push: SlidePagePresenter(style: .push)
        case .curl(let mirrored): CurlPagePresenter(mirrored: mirrored)
        }
        presenter.dataSource = self
        addChild(presenter)
        presenter.view.frame = view.bounds
        presenter.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        presenter.view.backgroundColor = UIColor(model.palette.backgroundColor)
        view.addSubview(presenter.view)
        presenter.didMove(toParent: self)
        // Move the page before removing the old presenter, so it never leaves the window.
        presenter.setPage(current)
        if let old = self.presenter {
            old.willMove(toParent: nil)
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        self.presenter = presenter
        presenterKind = kind
        queuedTurn = nil
        updateScrollFades()
    }

    private func makeSpreadPlan() -> SpreadPlan {
        guard publication.layout == .prePaginated else {
            return SpreadPlan(spine: publication.spine, landscape: false)
        }
        let size = view.bounds.size
        return SpreadPlan(
            spine: publication.spine, landscape: size.width > size.height,
            rtl: publication.readingProgression == .rtl)
    }

    /// Pushes new settings to the loaded documents after rotation, resizing, or a preference change.
    private func scheduleReconfigure() {
        reconfigureTask?.cancel()
        reconfigureTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, !Task.isCancelled else { return }
            self.reconfigure()
        }
    }

    private func reconfigure() {
        updateBackground()
        installUserScripts()
        installPresenter()
        updateScrolling()
        updateScrollFades()
        let plan = makeSpreadPlan()
        if plan != spreadPlan {
            spreadPlan = plan
            if case .fixed = current.document {
                spares.forEach { $0.reset() }
                open(document(containing: model.location.spineIndex), at: .locator(model.location))
                return
            }
        }
        // Spares relayout too, and return to their first or last page when `reader.js` reports the new layout.
        let config = scriptConfig().json
        for chapter in chapters where chapter.isReady {
            Task { _ = try? await call("MB.configure(JSON.parse(config))", ["config": config], in: chapter) }
        }
    }

    // MARK: - Documents

    private func document(containing spineIndex: Int) -> ReaderDocument {
        if publication.layout == .roll { return .roll }
        let item = publication.spine[spineIndex]
        guard item.layout == .prePaginated else {
            // Images and SVG in a reflowable spine are shown like fixed-layout pages.
            return item.item.isXHTML ? .reflowable(spineIndex) : .fixed([spineIndex])
        }
        guard publication.layout == .prePaginated else { return .fixed([spineIndex]) }
        return .fixed(spreadPlan.spreads[spreadPlan.spreadIndex(containing: spineIndex)])
    }

    /// The document before or after `document` in reading order.
    private func document(adjacentTo document: ReaderDocument, forward: Bool) -> ReaderDocument? {
        let next: Int
        switch document {
        case .reflowable(let index): next = index + (forward ? 1 : -1)
        case .fixed(let indexes): next = forward ? (indexes.max() ?? 0) + 1 : (indexes.min() ?? 0) - 1
        case .roll: return nil
        }
        return publication.spine.indices.contains(next) ? self.document(containing: next) : nil
    }

    private func url(for document: ReaderDocument) -> URL? {
        switch document {
        case .reflowable(let index):
            return model.container.url(for: publication.spine[index].item.path)
        case .fixed(let indexes):
            let html = WrapperDocument.spread(indexes.map(page(for:)), rtl: publication.readingProgression == .rtl)
            return writeWrapper(named: "fixed-\(indexes.map(String.init).joined(separator: "-")).html", html: html)
        case .roll:
            return writeWrapper(named: "roll.html", html: WrapperDocument.roll(publication.spine.indices.map(page(for:))))
        }
    }

    private func page(for spineIndex: Int) -> WrapperDocument.Page {
        let item = publication.spine[spineIndex].item
        let size = FixedLayoutGeometry.size(of: item, in: model.container) ?? FixedLayoutGeometry.fallback
        return WrapperDocument.Page(path: item.path, size: size, isImage: item.isImage && !item.isSVG)
    }

    private func writeWrapper(named name: String, html: String) -> URL? {
        let directory = contentRoot.appending(path: WrapperDocument.directoryName, directoryHint: .isDirectory)
        let url = directory.appending(path: name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(html.utf8).write(to: url, options: .atomic)
            return url
        } catch {
            Self.logger.error("Couldn't write \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Loading

    /// Starts loading `document` into `chapter`, unless it already has it.
    private func startLoading(_ document: ReaderDocument, in chapter: ChapterView) {
        guard chapter.document != document else { return }
        guard let url = url(for: document) else {
            chapter.reset()
            return
        }
        chapter.load(document, url: url, readAccess: contentRoot)
        chapter.setScrolls(scrolls(document))
    }

    /// Waits for `chapter` to load `document`, then moves it to `target` and makes sure it's visible.
    /// Returns false if the chapter was given another document meanwhile.
    private func position(_ chapter: ChapterView, _ document: ReaderDocument, at target: Target) async -> Bool {
        chapter.isSettled = false
        chapter.placement = target.placement
        guard await chapter.waitUntilReady(), chapter.document == document else { return false }
        switch document {
        case .reflowable(let spineIndex):
            _ = try? await call("MB.setHighlights(list)", ["list": highlights(forSpineIndex: spineIndex)], in: chapter)
            switch target {
            case .search(let result, let query):
                _ = try? await call("MB.goToPosition(MB.find(query, offset, occurrence))", [
                    "query": query, "offset": result.offset, "occurrence": result.occurrence,
                ], in: chapter)
            case .start, .end, .locator:
                _ = try? await call("MB.goToPosition(MB.positionFor(target))", ["target": positionTarget(target)], in: chapter)
            case .textOffset(let offset):
                _ = try? await call("MB.goToPosition(MB.positionForOffset(offset))", ["offset": offset], in: chapter)
            }
        case .roll:
            if case .locator(let locator) = target {
                _ = try? await call("MB.scrollToItem(index, progression)", [
                    "index": locator.spineIndex, "progression": locator.fragment == nil ? locator.progression : 0,
                ], in: chapter)
            }
        case .fixed:
            break
        }
        guard chapter.document == document else { return false }
        if chapter.webView.alpha < 1 {
            // Let WebKit commit the new scroll position before revealing it.
            try? await Task.sleep(for: .milliseconds(50))
            UIView.animate(withDuration: 0.15) { chapter.webView.alpha = 1 }
        }
        chapter.isSettled = chapter.document == document
        return chapter.isSettled
    }

    private func positionTarget(_ target: Target) -> [String: Any] {
        switch target {
        case .start: return ["progression": 0]
        case .end: return ["progression": 1, "position": "end"]
        case .locator(let locator):
            var result: [String: Any] = ["progression": locator.progression]
            if let cfi = locator.cfi { result["cfi"] = cfi }
            if let fragment = locator.fragment { result["fragment"] = fragment }
            return result
        case .search, .textOffset: return [:]
        }
    }

    /// Loads and positions `chapter` without blocking; if it has become the current page by then, it's revealed.
    private func prepareInBackground(_ chapter: ChapterView, _ document: ReaderDocument, at target: Target) {
        startLoading(document, in: chapter)
        chapter.placement = target.placement
        Task {
            guard await position(chapter, document, at: target) else { return }
            if chapter === current { await currentDidSettle() }
        }
    }

    /// Shows `target` in `document`: in place if it's the current document, otherwise by cross-fading
    /// to a spare once it's ready, so the old page stays up while the new one loads.
    private func open(_ document: ReaderDocument, at target: Target) {
        navigationID += 1
        let id = navigationID
        queuedTurn = nil
        presenter?.completeRunningTurn()
        preloadTask?.cancel()

        if current.document == nil {
            // The first page, or a reload after WebKit's process ended: fade in once ready.
            let chapter = current!
            chapter.webView.alpha = 0
            startLoading(document, in: chapter)
            Task {
                guard await position(chapter, document, at: target), id == navigationID, chapter === current else { return }
                await currentDidSettle()
            }
        } else if current.document == document, current.isReady {
            let chapter = current!
            let cover = coverPage()
            Task {
                let positioned = await position(chapter, document, at: target)
                try? await Task.sleep(for: .milliseconds(50))
                uncover(cover)
                if positioned, chapter === current { await currentDidSettle() }
            }
        } else {
            let chapter = spares.first { $0.document == document } ?? spares[0]
            startLoading(document, in: chapter)
            Task {
                guard await position(chapter, document, at: target), id == navigationID else { return }
                if let host = presenter?.view {
                    UIView.transition(with: host, duration: 0.25, options: [.transitionCrossDissolve, .allowAnimatedContent]) {
                        self.activate(chapter)
                    }
                } else {
                    activate(chapter)
                }
                await currentDidSettle()
            }
        }
    }

    /// Makes a spare the page the reader sees and interacts with; the old page becomes a spare.
    private func activate(_ chapter: ChapterView) {
        guard chapter !== current, let index = spares.firstIndex(where: { $0 === chapter }) else { return }
        let previous = current!
        spares[index] = previous
        current = chapter
        previous.isActive = false
        chapter.isActive = true
        hasSelection = false
        presenter?.setPage(chapter)
        park(previous)
        updateScrolling()
    }

    private func park(_ chapter: ChapterView) {
        chapter.transform = .identity
        chapter.alpha = 1
        chapter.frame = parkingView.bounds
        parkingView.addSubview(chapter)
    }

    /// Reports where the reader is, then preloads the chapters on either side.
    private func currentDidSettle() async {
        await reportLocation()
        schedulePreload()
    }

    private func schedulePreload() {
        preloadTask?.cancel()
        preloadTask = Task { [weak self] in
            // Leave the new page a moment to finish painting first.
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            self.preloadNeighbors()
        }
    }

    /// Loads the previous document at its last page and the next at its first, reusing spares that have them.
    private func preloadNeighbors() {
        guard current.isSettled, let document = current.document else { return }
        guard presenter?.isTurning != true else {
            schedulePreload()
            return
        }
        let wanted: [(document: ReaderDocument, placement: ChapterView.Placement)] = [
            (self.document(adjacentTo: document, forward: true), .start),
            (self.document(adjacentTo: document, forward: false), .end),
        ].compactMap { neighbor, placement in neighbor.map { ($0, placement) } }
        var free = spares.filter { spare in !wanted.contains { $0.document == spare.document } }
        for (neighbor, placement) in wanted {
            if let spare = spares.first(where: { $0.document == neighbor }) {
                if spare.placement != placement { prepareInBackground(spare, neighbor, at: Target(placement)) }
            } else if !free.isEmpty {
                prepareInBackground(free.removeFirst(), neighbor, at: Target(placement))
            }
        }
    }

    // MARK: - Messages from reader.js

    private func handle(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let chapter = chapters.first(where: { $0.webView === message.webView })
        else { return }
        let isCurrent = chapter === current
        switch body["type"] as? String {
        case "ready":
            chapter.didBecomeReady(url: message.frameInfo.request.url, rtl: body["rtl"] as? Bool ?? false)
        case "layout":
            didChangeLayout(chapter, body)
        case "relocated" where isCurrent:
            didRelocate(body)
        case "tap" where isCurrent:
            didTap(at: CGPoint(x: body.double("x"), y: body.double("y")))
        case "link" where isCurrent:
            if let href = body["href"] as? String, let url = URL(string: href) { follow(url) }
        case "footnote" where isCurrent:
            model.popover = ReaderPopover(content: .footnote(body["text"] as? String ?? ""), rect: body.rect("rect"))
        case "highlightTap" where isCurrent:
            if let id = (body["id"] as? String).flatMap(UUID.init) {
                model.popover = ReaderPopover(content: .highlight(id), rect: body.rect("rect"))
            }
        case "selection" where isCurrent:
            hasSelection = body["active"] as? Bool ?? false
        case "log":
            Self.logger.error("reader.js: \(body["message"] as? String ?? "", privacy: .public)")
        default:
            break
        }
    }

    private func didRelocate(_ message: [String: Any]) {
        guard current.isSettled else { return }
        switch current.document {
        case .reflowable(let spineIndex):
            report(message, spineIndex: spineIndex)
        case .roll:
            let locator = Locator(spineIndex: message.int("spineIndex"), progression: message.double("progression"))
            model.didRelocate(to: locator, page: 0, pageCount: 1)
        default:
            break
        }
    }

    private func reportLocation() async {
        let chapter = current!
        switch chapter.document {
        case .reflowable(let spineIndex):
            if let location = try? await call("return MB.location()", in: chapter) as? [String: Any], chapter === current {
                report(location, spineIndex: spineIndex)
            }
        case .fixed(let indexes):
            let first = indexes.first ?? 0
            let isSpread = publication.layout == .prePaginated
            model.didRelocate(
                to: Locator(spineIndex: first),
                page: isSpread ? spreadPlan.spreadIndex(containing: first) : 0,
                pageCount: isSpread ? spreadPlan.spreads.count : 1)
        case .roll:
            if let location = try? await call("return MB.rollLocation()", in: chapter) as? [String: Any], chapter === current {
                didRelocate(location)
            }
        case nil:
            break
        }
    }

    private func report(_ location: [String: Any], spineIndex: Int) {
        let locator = Locator(
            spineIndex: spineIndex, progression: location.double("progression"), cfi: location["cfi"] as? String)
        model.didRelocate(to: locator, page: location.int("page"), pageCount: max(1, location.int("pageCount")))
    }

    /// Fonts, images, or settings changed the layout: keep the reader's place, or a spare's first or last page.
    private func didChangeLayout(_ chapter: ChapterView, _ message: [String: Any]) {
        guard chapter.isSettled, case .reflowable(let spineIndex) = chapter.document else { return }
        Task {
            if chapter === current {
                if let anchor = message["anchorPosition"] as? [String: Any] {
                    _ = try? await call("MB.goToPosition(position)", ["position": anchor], in: chapter)
                }
                if chapter === current, let location = try? await call("return MB.location()", in: chapter) as? [String: Any] {
                    report(location, spineIndex: spineIndex)
                }
            } else if let placement = chapter.placement {
                _ = try? await call("MB.goToPosition(MB.positionFor(target))", [
                    "target": positionTarget(Target(placement)),
                ], in: chapter)
            }
        }
    }

    /// Taps that `reader.js` reports: the middle of the page toggles the chrome, and the edges of
    /// fixed-layout pages turn them. `handleEdgeTap(_:)` turns reflowable pages without waiting for WebKit's click.
    private func didTap(at point: CGPoint) {
        if model.popover != nil {
            model.popover = nil
            return
        }
        guard let side = edgeSide(at: point) else {
            model.toggleChrome()
            return
        }
        if !handlesEdgeTapsNatively { turn(toward: side) }
    }

    /// The side whose page a tap at `point` turns to, if it's near an edge of a paged document.
    private func edgeSide(at point: CGPoint) -> PageTurn.Side? {
        guard current.document != .roll, !model.isScrollMode else { return nil }
        let width = view.bounds.width
        let edge = min(width * 0.22, 140)
        if point.x < edge { return .left }
        if point.x > width - edge { return .right }
        return nil
    }

    /// Reflowable pages can be hit-tested, so their edge taps turn on touch up. Fixed-layout pages sit
    /// in other-origin iframes, so they rely on `frame.js` to report taps that miss links.
    private var handlesEdgeTapsNatively: Bool {
        if case .reflowable = current.document { true } else { false }
    }

    @objc private func handleEdgeTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: view)
        guard handlesEdgeTapsNatively, let side = edgeSide(at: point), model.popover == nil, !hasSelection else { return }
        let chapter = current!
        Task {
            let hit = try? await call("return MB.isInteractiveAt(x, y)", ["x": point.x, "y": point.y], in: chapter)
            guard hit as? Bool == false, chapter === current else { return }
            turn(toward: side)
        }
    }

    private func follow(_ url: URL) {
        if model.open(url) { return }
        guard let scheme = url.scheme?.lowercased(), ["http", "https", "mailto", "tel"].contains(scheme) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Page turning

    private var isRTLProgression: Bool {
        if case .reflowable = current.document { return current.isRTL || publication.readingProgression == .rtl }
        return publication.readingProgression == .rtl
    }

    /// Turns to the page on `side`, for taps and keys.
    private func turn(toward side: PageTurn.Side) {
        guard let presenter else { return }
        if presenter.isTurning {
            presenter.completeRunningTurn()
            if presenter.isTurning {
                queuedTurn = side
                return
            }
        }
        guard let turn = pageTurn(toward: side) else { return }
        presenter.perform(turn)
    }

    /// Moves forward or back in reading order.
    private func advance(forward: Bool) {
        guard model.isScrollMode, case .reflowable = current.document else {
            turn(toward: forward != isRTLProgression ? .right : .left)
            return
        }
        let scrollView = current.webView.scrollView
        let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        let y = scrollView.contentOffset.y
        if (forward && y >= maxY - 1) || (!forward && y <= 1) {
            turn(toward: forward ? .bottom : .top)
        } else {
            let delta = (scrollView.bounds.height - 120) * (forward ? 1 : -1)
            scrollView.setContentOffset(CGPoint(x: 0, y: min(maxY, max(0, y + delta))), animated: true)
        }
    }

    private func runQueuedTurn() {
        guard let side = queuedTurn else { return }
        queuedTurn = nil
        Task { turn(toward: side) }
    }

    /// The scroll position of the page next to the current one within the chapter, if there is one.
    private func adjacentPageOffset(toward side: PageTurn.Side) -> CGPoint? {
        let scrollView = current.webView.scrollView
        let width = scrollView.bounds.width
        guard width > 0, side == .left || side == .right else { return nil }
        let page = (scrollView.contentOffset.x / width).rounded()
        let target = (page + (side == .right ? 1 : -1)) * width
        let maxX = max(0, scrollView.contentSize.width - width)
        guard target >= -1, target <= maxX + 1 else { return nil }
        return CGPoint(x: min(max(target, 0), maxX), y: 0)
    }

    /// A turn within the chapter: a snapshot of this page leaves while the web view, already moved to
    /// the next page, comes in.
    private func pageTurnWithinChapter(toward side: PageTurn.Side, to offset: CGPoint) -> PageTurn {
        let chapter = current!
        let scrollView = chapter.webView.scrollView
        let original = scrollView.contentOffset
        let snapshot = chapter.snapshotView(afterScreenUpdates: false) ?? UIView()
        snapshot.backgroundColor = chapter.backgroundColor
        scrollView.setContentOffset(offset, animated: false)
        return PageTurn(side: side, outgoing: snapshot, incoming: chapter) { [weak self] completed in
            guard let self, chapter === self.current else {
                snapshot.removeFromSuperview()
                return
            }
            if !completed { scrollView.setContentOffset(original, animated: false) }
            self.presenter?.setPage(chapter)
            if completed {
                snapshot.removeFromSuperview()
                Task { await self.reportLocation() }
            } else {
                self.hold(snapshot)
            }
            self.runQueuedTurn()
        }
    }

    /// A turn into the adjacent document, which a spare has usually preloaded already.
    private func pageTurnAcrossDocuments(toward side: PageTurn.Side, forward: Bool) -> PageTurn? {
        guard let document = current.document, let next = self.document(adjacentTo: document, forward: forward) else {
            return nil
        }
        let placement: ChapterView.Placement = forward ? .start : .end
        let incoming: ChapterView
        if let spare = spares.first(where: { $0.document == next && $0.placement == placement }) {
            incoming = spare
        } else {
            incoming = spares.first { $0.document == next } ?? spares.first { $0.document != current.document } ?? spares[0]
            // Show the page's background until it's ready rather than a half-positioned document.
            incoming.webView.alpha = 0
            prepareInBackground(incoming, next, at: Target(placement))
        }
        let outgoing = current!
        return PageTurn(side: side, outgoing: outgoing, incoming: incoming) { [weak self] completed in
            guard let self, outgoing === self.current else { return }
            if completed {
                // The reader left the old chapter at its edge, which is where a spare for it waits.
                outgoing.placement = forward ? .end : .start
                self.activate(incoming)
                if incoming.isSettled { Task { await self.currentDidSettle() } }
            } else {
                self.presenter?.setPage(outgoing)
                self.park(incoming)
            }
            self.runQueuedTurn()
        }
    }

    /// Keeps a snapshot up for a moment while WebKit repaints the page beneath it.
    private func hold(_ snapshot: UIView) {
        guard let host = presenter?.view else {
            snapshot.removeFromSuperview()
            return
        }
        snapshot.transform = .identity
        snapshot.alpha = 1
        snapshot.frame = host.bounds
        host.addSubview(snapshot)
        Task {
            try? await Task.sleep(for: .milliseconds(60))
            snapshot.removeFromSuperview()
        }
    }

    /// Covers the page with a snapshot while it moves, for jumps within a chapter.
    private func coverPage() -> UIView? {
        guard let host = presenter?.view, let snapshot = current.snapshotView(afterScreenUpdates: false) else { return nil }
        snapshot.frame = host.bounds
        host.addSubview(snapshot)
        return snapshot
    }

    private func uncover(_ cover: UIView?) {
        guard let cover else { return }
        UIView.animate(withDuration: 0.2, animations: { cover.alpha = 0 }, completion: { _ in cover.removeFromSuperview() })
    }

    // MARK: - Gestures

    /// In scroll mode, pulling past the top or bottom of a chapter moves to the adjacent one.
    @objc private func handleScrollPan(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began, model.isScrollMode { model.userDidNavigate() }
        guard gesture.state == .ended, model.isScrollMode, gesture.view === current.webView.scrollView,
              current.isSettled, case .reflowable = current.document
        else { return }
        let scrollView = current.webView.scrollView
        let threshold: CGFloat = 56
        let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        if scrollView.contentOffset.y > maxY + threshold {
            turn(toward: .bottom)
        } else if scrollView.contentOffset.y < -threshold {
            turn(toward: .top)
        }
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        let commands = [
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(nextKey)),
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(previousKey)),
            UIKeyCommand(input: " ", modifierFlags: [], action: #selector(spaceKey)),
        ]
        commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return commands
    }

    @objc private func nextKey() { model.isScrollMode ? advance(forward: !isRTLProgression) : turn(toward: .right) }
    @objc private func previousKey() { model.isScrollMode ? advance(forward: isRTLProgression) : turn(toward: .left) }
    @objc private func spaceKey() { advance(forward: true) }

    // MARK: - JavaScript

    @discardableResult
    private func call(_ body: String, _ arguments: [String: Any] = [:], in chapter: ChapterView? = nil) async throws -> Any? {
        let script = body.hasPrefix("return") ? body : "return \(body)"
        return try await (chapter ?? current).webView.callAsyncJavaScript(
            script, arguments: arguments, in: nil, contentWorld: world)
    }

    private func highlights(forSpineIndex spineIndex: Int) -> [[String: Any]] {
        model.highlights(forSpineIndex: spineIndex).compactMap { annotation in
            guard let start = annotation.rangeStart, let end = annotation.rangeEnd else { return nil }
            return ["id": annotation.id.uuidString, "start": start, "end": end, "color": annotation.color.rawValue]
        }
    }
}

// MARK: - PageTurnDataSource

extension ReaderViewController: PageTurnDataSource {
    func canBeginInteractivePageTurn() -> Bool {
        // A press held before moving is selecting text, not turning the page.
        !hasSelection && current.isSettled && touchTracker.timeSinceTouchBegan < 0.45
    }

    func pageTurn(toward side: PageTurn.Side) -> PageTurn? {
        guard current.isSettled, let document = current.document, document != .roll else { return nil }
        // Turns that follow the narration leave the controls and popovers alone; the reader may be using them.
        if !isSpeechNavigation {
            model.userDidNavigate()
            model.popover = nil
            model.hideChrome()
        }
        let forward = side == .left || side == .right ? (side == .right) != isRTLProgression : side == .bottom
        if case .reflowable = document, !model.isScrollMode, let offset = adjacentPageOffset(toward: side) {
            return pageTurnWithinChapter(toward: side, to: offset)
        }
        return pageTurnAcrossDocuments(toward: side, forward: forward)
    }
}

// MARK: - ReaderNavigator

extension ReaderViewController: ReaderNavigator {
    func go(to locator: Locator, animated: Bool) {
        let index = min(max(locator.spineIndex, 0), publication.spine.count - 1)
        if current.document == .roll, current.isSettled {
            Task {
                _ = try? await call("MB.scrollToItem(index, progression)", [
                    "index": index, "progression": locator.fragment == nil ? locator.progression : 0,
                ])
            }
            return
        }
        open(document(containing: index), at: .locator(locator))
    }

    func turnPage(forward: Bool) {
        advance(forward: forward)
    }

    func applyPreferences() {
        scheduleReconfigure()
    }

    func reloadHighlights() {
        for chapter in chapters where chapter.isReady {
            guard case .reflowable(let spineIndex) = chapter.document else { continue }
            let list = highlights(forSpineIndex: spineIndex)
            Task { _ = try? await call("MB.setHighlights(list)", ["list": list], in: chapter) }
        }
    }

    func currentSelection() async -> TextSelection? {
        guard let value = try? await call("return JSON.stringify(MB.selection())") as? String,
              let data = value.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(TextSelection.self, from: data)
    }

    func clearSelection() {
        Task { _ = try? await call("MB.clearSelection()") }
    }

    func show(_ result: BookSearchResult) {
        open(document(containing: result.spineIndex), at: .search(result, query: model.searchQuery))
    }

    func pages(forCFIs cfis: [String]) async -> [Int?] {
        guard case .reflowable = current.document, current.isReady else { return cfis.map { _ in nil } }
        let script = "return cfis.map((cfi) => { const p = cfi ? MB.positionFor({ cfi }) : null; return p ? p.page : -1; })"
        let pages = (try? await call(script, ["cfis": cfis])) as? [Int] ?? []
        return cfis.indices.map { pages.indices.contains($0) && pages[$0] >= 0 ? pages[$0] : nil }
    }
}

// MARK: - SpeechFollowing

extension ReaderViewController: SpeechFollowing {
    func visibleTextOffset() async -> (spineIndex: Int, offset: Int?)? {
        switch current.document {
        case .reflowable(let spineIndex):
            let offset = (try? await call("return MB.firstVisibleOffset()")) as? Int
            return (spineIndex, offset)
        case .fixed(let indexes):
            return indexes.min().map { ($0, nil) }
        case .roll:
            return (model.location.spineIndex, nil)
        case nil:
            return nil
        }
    }

    func selectionTextOffset() async -> (spineIndex: Int, offset: Int)? {
        guard case .reflowable(let spineIndex) = current.document,
              let offset = (try? await call("return MB.selectionOffset()")) as? Int
        else { return nil }
        return (spineIndex, offset)
    }

    func markSpeech(spineIndex: Int, start: Int, end: Int, word: Range<Int>?, reveal: Bool) async -> SpeechMark? {
        // Numbered in the order they're asked for: one that waits for a chapter to load mustn't land after a newer one.
        speechSequence += 1
        let sequence = speechSequence
        if current.document != .reflowable(spineIndex) {
            guard reveal, publication.spine.indices.contains(spineIndex) else {
                clearSpeech()
                return nil
            }
            let document = document(containing: spineIndex)
            guard case .reflowable = document else {
                // Fixed layouts show the page; their text sits in iframes this script doesn't reach.
                showSpineItem(spineIndex)
                return nil
            }
            open(document, at: .textOffset(start))
            // Wait for the chapter to be shown before marking it.
            for _ in 0..<60 where !(current.document == document && current.isSettled) {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard current.document == document, current.isSettled else { return nil }
        }
        guard current.isReady else { return nil }
        guard sequence == speechSequence else { return nil }
        var arguments: [String: Any] = ["start": start, "end": end, "sequence": sequence]
        if let word {
            arguments["wordStart"] = word.lowerBound
            arguments["wordEnd"] = word.upperBound
        }
        let script = word == nil
            ? "return JSON.stringify(MB.speechMark(start, end, undefined, undefined, sequence))"
            : "return JSON.stringify(MB.speechMark(start, end, wordStart, wordEnd, sequence))"
        guard let json = try? await call(script, arguments) as? String, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SpeechMark.self, from: data)
    }

    func showSpeechPage(_ page: Int) {
        guard case .reflowable = current.document, current.isSettled, !model.isScrollMode else { return }
        let scrollView = current.webView.scrollView
        let width = scrollView.bounds.width
        guard width > 0 else { return }
        let currentPage = Int((abs(scrollView.contentOffset.x) / width).rounded())
        if page == currentPage + 1 || page == currentPage - 1 {
            // Turn like the reader would, with the page-turn animation.
            let forward = page > currentPage
            isSpeechNavigation = true
            turn(toward: forward != isRTLProgression ? .right : .left)
            isSpeechNavigation = false
        } else if page != currentPage {
            let chapter = current!
            Task {
                _ = try? await call("MB.goToPosition({ page })", ["page": page], in: chapter)
                await reportLocation()
            }
        }
    }

    func scrollSpeech(to y: Double) {
        guard case .reflowable = current.document, current.isSettled else { return }
        let scrollView = current.webView.scrollView
        let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        scrollView.setContentOffset(CGPoint(x: 0, y: min(maxY, max(0, y))), animated: true)
    }

    func showSpineItem(_ spineIndex: Int) {
        switch current.document {
        case .fixed(let indexes) where indexes.contains(spineIndex): return
        case .reflowable(spineIndex): return
        default: go(to: Locator(spineIndex: spineIndex), animated: true)
        }
    }

    func clearSpeech() {
        speechSequence += 1
        let sequence = speechSequence
        for chapter in chapters where chapter.isReady {
            Task { _ = try? await call("MB.speechClear(sequence)", ["sequence": sequence], in: chapter) }
        }
    }
}

// MARK: - WebKit delegates

extension ReaderViewController: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        if navigationAction.navigationType == .linkActivated || navigationAction.targetFrame == nil {
            if webView === current.webView { follow(url) }
            return .cancel
        }
        if navigationAction.targetFrame?.isMainFrame == true {
            let root = contentRoot.standardizedFileURL.path
            return url.isFileURL && url.standardizedFileURL.path.hasPrefix(root) ? .allow : .cancel
        }
        // Subframes: fixed-layout pages and embedded content, including remote resources EPUB allows.
        return .allow
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if webView === current.webView, let url = navigationAction.request.url { follow(url) }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let chapter = chapters.first(where: { $0.webView === webView }) else { return }
        chapter.reset()
        if chapter === current {
            open(document(containing: model.location.spineIndex), at: .locator(model.location))
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        didFail(webView, navigation)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        didFail(webView, navigation)
    }

    private func didFail(_ webView: WKWebView, _ navigation: WKNavigation?) {
        guard let chapter = chapters.first(where: { $0.webView === webView }) else { return }
        chapter.didFail(navigation)
        if chapter === current { chapter.webView.alpha = 1 }
    }
}

extension ReaderViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === edgeTap else { return true }
        return handlesEdgeTapsNatively && edgeSide(at: touch.location(in: view)) != nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === edgeTap
    }
}

// MARK: - Supporting types

struct ScriptConfiguration: Encodable, Equatable {
    struct Insets: Encodable, Equatable {
        let top: CGFloat
        let bottom: CGFloat
        let side: CGFloat
    }

    struct Colors: Encodable, Equatable {
        let background: String
        let text: String
        let link: String
        let override: Bool
    }

    let layout: String
    let mode: String
    let insets: Insets
    let columns: Int
    let fontScale: Double
    let fontFamily: String?
    let bold: Bool
    let lineHeight: Double?
    let letterSpacing: Double
    let wordSpacing: Double
    let justify: Bool
    let dark: Bool
    let colors: Colors

    var json: String {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

enum ReaderScripts {
    static let reader = load("reader")
    static let readingSystem = load("epub-reading-system")
    static let frame = load("frame")

    private static func load(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else { preconditionFailure("Missing bundled script \(name).js") }
        return source
    }

    /// Reports script errors to the native log instead of failing silently.
    static func guarded(_ source: String) -> String {
        """
        try {
        \(source)
        } catch (error) {
          try { window.webkit.messageHandlers.mb.postMessage({ type: 'log', message: String(error) + '\\n' + error.stack }); } catch (_) {}
        }
        """
    }

    static func jsonString(_ value: String) -> String {
        (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }
}

private extension Dictionary where Key == String, Value == Any {
    func double(_ key: String) -> Double {
        let value = (self[key] as? NSNumber)?.doubleValue ?? 0
        return value.isFinite ? value : 0
    }
    /// An integer from JavaScript, where Infinity and NaN can't be trusted to convert.
    func int(_ key: String) -> Int {
        let value = double(key)
        return value.isFinite ? Int(Swift.min(Swift.max(value, -1_000_000), 1_000_000)) : 0
    }

    func rect(_ key: String) -> CGRect {
        guard let value = self[key] as? [String: Any] else { return .zero }
        return CGRect(x: value.double("x"), y: value.double("y"), width: value.double("width"), height: value.double("height"))
    }
}
