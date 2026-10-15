import OSLog
import SwiftUI
import UIKit
import WebKit

/// Renders a publication in a single `WKWebView` and implements page turning.
///
/// Reflowable chapters load directly and paginate with CSS columns (`reader.js`). Fixed-layout
/// spreads and rolls load generated wrapper pages that scale each document inside an iframe.
final class ReaderViewController: UIViewController {
    private static let logger = Logger(subsystem: "com.mbbooks.MBBooks", category: "Reader")

    private enum Document: Equatable {
        case reflowable(Int)
        case fixed([Int])
        case roll
    }

    private enum Transition {
        case none
        /// Cross-fade from the previous page, used for jumps such as table-of-contents links.
        case cover
        /// A page turn in the user's chosen style.
        case turn(forward: Bool, visualRight: Bool)
    }

    private struct PendingLoad {
        let document: Document
        let target: Locator
        let atEnd: Bool
        let transition: Transition
        var search: BookSearchResult?
        var query: String?
    }

    private let model: ReaderModel
    private let world = WKContentWorld.world(name: "MBReader")
    private let messageProxy = ScriptMessageProxy()
    private let containerView = UIView()
    private var webView: BookWebView!
    private var document: Document?
    private var pending: PendingLoad?
    private var isReady = false
    private var transitionCover: UIView?
    private var spreadPlan = SpreadPlan(spine: [], landscape: false)
    private var lastLayoutSize: CGSize = .zero
    private var reconfigureTask: Task<Void, Never>?
    private var isRTLDocument = false
    private var swipeGestures: [UISwipeGestureRecognizer] = []

    init(model: ReaderModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var publication: Publication { model.publication }
    private var contentRoot: URL { model.container.root }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.clipsToBounds = true
        containerView.frame = view.bounds
        containerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(containerView)
        configureWebView()
        updateBackground()
        model.navigator = self
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }
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

    private func configureWebView() {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.dataDetectorTypes = []
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.isTextInteractionEnabled = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        messageProxy.handler = { [weak self] message in self?.handle(message) }
        configuration.userContentController.add(messageProxy, contentWorld: world, name: "mb")

        let webView = BookWebView(frame: containerView.bounds, configuration: configuration)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.navigationDelegate = self
        webView.uiDelegate = self
        #if DEBUG
        webView.isInspectable = true
        #endif
        webView.menuActions = BookWebView.MenuActions(
            highlight: { [weak self] in Task { await self?.model.highlightSelection() } },
            note: { [weak self] in Task { await self?.model.addNoteToSelection() } },
            search: { [weak self] text in
                self?.model.searchQuery = text
                self?.model.sheet = .search
            })

        let scrollView = webView.scrollView
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.isDirectionalLockEnabled = true
        scrollView.decelerationRate = .fast
        scrollView.pinchGestureRecognizer?.isEnabled = false
        scrollView.panGestureRecognizer.addTarget(self, action: #selector(handlePan(_:)))

        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
            swipe.direction = direction
            swipe.delegate = self
            webView.addGestureRecognizer(swipe)
            swipeGestures.append(swipe)
        }

        containerView.addSubview(webView)
        self.webView = webView
    }

    private func installUserScripts() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        controller.addUserScript(WKUserScript(
            source: "((__MB_VERSION__) => {\n\(ReaderScripts.readingSystem)\n})(\(ReaderScripts.jsonString(version)));",
            injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        controller.addUserScript(WKUserScript(
            source: ReaderScripts.guarded("((__MB_CONFIG__) => {\n\(ReaderScripts.reader)\n})(\(scriptConfig().json));"),
            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
        controller.addUserScript(WKUserScript(
            source: ReaderScripts.frame, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
    }

    // MARK: - Configuration

    private func scriptConfig() -> ScriptConfiguration {
        let style = model.preferences.style
        let size = view.bounds.size
        let safe = view.safeAreaInsets
        let isWide = size.width >= 600
        let landscape = size.width > size.height
        let horizontalSafe = max(safe.left, safe.right)
        let baseMargin: CGFloat = isWide ? 52 : 24
        let palette = model.palette
        return ScriptConfiguration(
            layout: publication.layout.rawValue,
            mode: model.isScrollMode ? "scroll" : "paginated",
            insets: .init(
                top: safe.top + (isWide ? 52 : 40),
                bottom: safe.bottom + (isWide ? 44 : 34),
                side: baseMargin * style.margins + horizontalSafe),
            columns: style.allowMultipleColumns && landscape && size.width >= 700 && !model.isScrollMode ? 2 : 1,
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
        containerView.backgroundColor = color
        webView.underPageBackgroundColor = color
    }

    private func updateScrollBehavior() {
        let scrollView = webView.scrollView
        let isReflowable: Bool = if case .reflowable = document { true } else { false }
        let isRoll = document == .roll
        let style = model.preferences.pageTurn
        let paged = isReflowable && !model.isScrollMode
        scrollView.isPagingEnabled = paged && style == .slide
        scrollView.isScrollEnabled = isRoll || (isReflowable && (model.isScrollMode || style == .slide))
        scrollView.alwaysBounceHorizontal = paged && style == .slide
        scrollView.alwaysBounceVertical = isRoll || (isReflowable && model.isScrollMode)
        scrollView.showsVerticalScrollIndicator = isRoll || model.isScrollMode
        let swipes = !isRoll && !(isReflowable && (model.isScrollMode || style == .slide))
        swipeGestures.forEach { $0.isEnabled = swipes }
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

    /// Pushes new settings to the loaded document after rotation, resizing, or a preference change.
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
        updateScrollBehavior()
        let plan = makeSpreadPlan()
        if plan != spreadPlan {
            spreadPlan = plan
            if case .fixed = document {
                load(spineIndex: model.location.spineIndex, target: model.location, atEnd: false, transition: .cover)
                return
            }
        }
        guard isReady else { return }
        Task { _ = try? await call("MB.configure(JSON.parse(config))", ["config": scriptConfig().json]) }
    }

    // MARK: - Loading

    private func documentFor(spineIndex: Int) -> Document {
        if publication.layout == .roll { return .roll }
        let item = publication.spine[spineIndex]
        guard item.layout == .prePaginated else {
            // Images and SVG in a reflowable spine are shown like fixed-layout pages.
            return item.item.isXHTML ? .reflowable(spineIndex) : .fixed([spineIndex])
        }
        guard publication.layout == .prePaginated else { return .fixed([spineIndex]) }
        return .fixed(spreadPlan.spreads[spreadPlan.spreadIndex(containing: spineIndex)])
    }

    private func load(spineIndex: Int, target: Locator, atEnd: Bool, transition: Transition,
                      search: BookSearchResult? = nil, query: String? = nil) {
        guard publication.spine.indices.contains(spineIndex) else { return }
        let document = documentFor(spineIndex: spineIndex)
        pending = PendingLoad(
            document: document, target: target, atEnd: atEnd, transition: transition, search: search, query: query)
        beginTransition(transition)
        isReady = false
        self.document = document
        updateScrollBehavior()
        switch document {
        case .reflowable(let index):
            let url = model.container.url(for: publication.spine[index].item.path)
            webView.loadFileURL(url, allowingReadAccessTo: contentRoot)
        case .fixed(let indexes):
            let html = WrapperDocument.spread(indexes.map(page(for:)), rtl: publication.readingProgression == .rtl)
            loadWrapper(named: "fixed-\(indexes.map(String.init).joined(separator: "-")).html", html: html)
        case .roll:
            loadWrapper(named: "roll.html", html: WrapperDocument.roll(publication.spine.indices.map(page(for:))))
        }
    }

    private func page(for spineIndex: Int) -> WrapperDocument.Page {
        let item = publication.spine[spineIndex].item
        let size = FixedLayoutGeometry.size(of: item, in: model.container) ?? FixedLayoutGeometry.fallback
        return WrapperDocument.Page(path: item.path, size: size, isImage: item.isImage && !item.isSVG)
    }

    private func loadWrapper(named name: String, html: String) {
        let directory = contentRoot.appending(path: WrapperDocument.directoryName, directoryHint: .isDirectory)
        let url = directory.appending(path: name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(html.utf8).write(to: url, options: .atomic)
            webView.loadFileURL(url, allowingReadAccessTo: contentRoot)
        } catch {
            finishTransition()
        }
    }

    // MARK: - Messages from reader.js

    private func handle(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "ready": didBecomeReady(message)
        case "relocated": didRelocate(message)
        case "layout": didChangeLayout(message)
        case "tap": didTap(at: CGPoint(x: message.double("x"), y: message.double("y")))
        case "link":
            if let href = message["href"] as? String, let url = URL(string: href) { follow(url) }
        case "footnote":
            model.popover = ReaderPopover(
                content: .footnote(message["text"] as? String ?? ""), rect: message.rect("rect"))
        case "log":
            Self.logger.error("reader.js: \(message["message"] as? String ?? "", privacy: .public)")
        case "highlightTap":
            if let id = (message["id"] as? String).flatMap(UUID.init) {
                model.popover = ReaderPopover(content: .highlight(id), rect: message.rect("rect"))
            }
        default: break
        }
    }

    private func didBecomeReady(_ message: [String: Any]) {
        guard let pending else { return }
        isReady = true
        isRTLDocument = message["rtl"] as? Bool ?? false
        updateScrollBehavior()
        Task {
            switch pending.document {
            case .reflowable(let spineIndex):
                await position(at: pending, spineIndex: spineIndex)
            case .fixed(let indexes):
                reportFixedLocation(indexes)
            case .roll:
                _ = try? await call("MB.scrollToItem(index, progression)", [
                    "index": pending.target.spineIndex, "progression": pending.target.progression,
                ])
                model.didRelocate(to: pending.target, page: 0, pageCount: 1)
            }
            self.pending = nil
            // Let WebKit commit the new scroll position before revealing it.
            try? await Task.sleep(for: .milliseconds(50))
            finishTransition(pending.transition)
        }
    }

    private func position(at pending: PendingLoad, spineIndex: Int) async {
        reloadHighlights()
        var target: [String: Any] = ["progression": pending.target.progression]
        if pending.atEnd { target["position"] = "end" }
        if let cfi = pending.target.cfi { target["cfi"] = cfi }
        if let fragment = pending.target.fragment { target["fragment"] = fragment }
        if let search = pending.search, let query = pending.query {
            _ = try? await call("MB.goToPosition(MB.find(query, offset, occurrence))", [
                "query": query, "offset": search.offset, "occurrence": search.occurrence,
            ])
        } else {
            _ = try? await call("MB.goToPosition(MB.positionFor(target))", ["target": target])
        }
        if let location = try? await call("return MB.location()") as? [String: Any] {
            report(location, spineIndex: spineIndex)
        }
    }

    private func didRelocate(_ message: [String: Any]) {
        switch document {
        case .reflowable(let spineIndex):
            guard pending == nil else { return }
            report(message, spineIndex: spineIndex)
        case .roll:
            let locator = Locator(spineIndex: message.int("spineIndex"), progression: message.double("progression"))
            model.didRelocate(to: locator, page: 0, pageCount: 1)
        default:
            break
        }
    }

    private func report(_ location: [String: Any], spineIndex: Int) {
        let locator = Locator(
            spineIndex: spineIndex, progression: location.double("progression"), cfi: location["cfi"] as? String)
        model.didRelocate(to: locator, page: location.int("page"), pageCount: max(1, location.int("pageCount")))
    }

    private func reportFixedLocation(_ indexes: [Int]) {
        let first = indexes.first ?? 0
        let page = publication.layout == .prePaginated ? spreadPlan.spreadIndex(containing: first) : 0
        let count = publication.layout == .prePaginated ? spreadPlan.spreads.count : 1
        model.didRelocate(to: Locator(spineIndex: first), page: page, pageCount: count)
    }

    private func didChangeLayout(_ message: [String: Any]) {
        guard pending == nil, case .reflowable(let spineIndex) = document else { return }
        Task {
            if let anchor = message["anchorPosition"] as? [String: Any] {
                _ = try? await call("MB.goToPosition(position)", ["position": anchor])
            }
            if let location = try? await call("return MB.location()") as? [String: Any] {
                report(location, spineIndex: spineIndex)
            }
        }
    }

    private func didTap(at point: CGPoint) {
        if model.popover != nil {
            model.popover = nil
            return
        }
        let width = view.bounds.width
        let edge = min(width * 0.22, 140)
        let isPaged = document != .roll && !model.isScrollMode
        if isPaged && point.x < edge {
            model.hideChrome()
            turnVisually(right: false)
        } else if isPaged && point.x > width - edge {
            model.hideChrome()
            turnVisually(right: true)
        } else {
            model.toggleChrome()
        }
    }

    private func follow(_ url: URL) {
        if model.open(url) { return }
        guard let scheme = url.scheme?.lowercased(), ["http", "https", "mailto", "tel"].contains(scheme) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Page turning

    private var isRTLProgression: Bool {
        if case .reflowable = document { return isRTLDocument || publication.readingProgression == .rtl }
        return publication.readingProgression == .rtl
    }

    private func turnVisually(right: Bool) {
        turn(forward: right != isRTLProgression, visualRight: right)
    }

    private func turn(forward: Bool, visualRight: Bool) {
        guard pending == nil else { return }
        switch document {
        case .reflowable(let spineIndex):
            if model.isScrollMode {
                let scrollView = webView.scrollView
                let delta = (scrollView.bounds.height - 120) * (forward ? 1 : -1)
                let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
                if (forward && scrollView.contentOffset.y >= maxY - 1) || (!forward && scrollView.contentOffset.y <= 1) {
                    changeChapter(from: spineIndex, forward: forward, visualRight: visualRight)
                } else {
                    scrollView.setContentOffset(CGPoint(x: 0, y: min(maxY, max(0, scrollView.contentOffset.y + delta))), animated: true)
                }
                return
            }
            let scrollView = webView.scrollView
            let width = scrollView.bounds.width
            let current = (scrollView.contentOffset.x / width).rounded() * width
            let target = current + (visualRight ? width : -width)
            let maxX = max(0, scrollView.contentSize.width - width)
            if target < -1 || target > maxX + 1 {
                changeChapter(from: spineIndex, forward: forward, visualRight: visualRight)
            } else {
                animatePageChange(forward: forward) {
                    scrollView.setContentOffset(CGPoint(x: target, y: 0), animated: $0)
                }
            }
        case .fixed(let indexes):
            let next = forward ? (indexes.max() ?? 0) + 1 : (indexes.min() ?? 0) - 1
            guard publication.spine.indices.contains(next) else { return }
            load(spineIndex: next, target: Locator(spineIndex: next), atEnd: !forward,
                 transition: .turn(forward: forward, visualRight: visualRight))
        case .roll, nil:
            break
        }
    }

    private func changeChapter(from spineIndex: Int, forward: Bool, visualRight: Bool) {
        let next = spineIndex + (forward ? 1 : -1)
        guard publication.spine.indices.contains(next) else { return }
        load(spineIndex: next, target: Locator(spineIndex: next), atEnd: !forward,
             transition: .turn(forward: forward, visualRight: visualRight))
    }

    /// Moves within a chapter using the selected page-turn animation.
    private func animatePageChange(forward: Bool, _ change: @escaping (_ animated: Bool) -> Void) {
        switch model.preferences.pageTurn {
        case .slide, .scroll:
            change(true)
        case .curl:
            UIView.transition(with: view, duration: 0.45,
                              options: [forward ? .transitionCurlUp : .transitionCurlDown, .allowAnimatedContent]) {
                change(false)
            }
        case .fade:
            UIView.transition(with: view, duration: 0.2, options: [.transitionCrossDissolve, .allowAnimatedContent]) {
                change(false)
            }
        }
    }

    // MARK: - Transitions between documents

    private func beginTransition(_ transition: Transition) {
        transitionCover?.removeFromSuperview()
        transitionCover = nil
        switch transition {
        case .none:
            webView.alpha = 0
        case .cover, .turn:
            guard let snapshot = containerView.snapshotView(afterScreenUpdates: false) else { return }
            snapshot.frame = containerView.frame
            view.addSubview(snapshot)
            transitionCover = snapshot
        }
    }

    private func finishTransition(_ transition: Transition = .cover) {
        let cover = transitionCover
        transitionCover = nil
        switch transition {
        case .none:
            UIView.animate(withDuration: 0.2) { self.webView.alpha = 1 }
        case .cover:
            UIView.animate(withDuration: 0.2, animations: { cover?.alpha = 0 }, completion: { _ in cover?.removeFromSuperview() })
        case .turn(let forward, let visualRight):
            guard let cover else { return }
            switch model.preferences.pageTurn {
            case .slide, .scroll:
                let width = view.bounds.width * (visualRight ? 1 : -1)
                containerView.transform = CGAffineTransform(translationX: width, y: 0)
                UIView.animate(withDuration: 0.32, delay: 0, options: .curveEaseOut) {
                    cover.transform = CGAffineTransform(translationX: -width, y: 0)
                    self.containerView.transform = .identity
                } completion: { _ in cover.removeFromSuperview() }
            case .curl:
                UIView.transition(with: view, duration: 0.45, options: forward ? .transitionCurlUp : .transitionCurlDown) {
                    cover.isHidden = true
                } completion: { _ in cover.removeFromSuperview() }
            case .fade:
                UIView.transition(with: view, duration: 0.2, options: .transitionCrossDissolve) {
                    cover.isHidden = true
                } completion: { _ in cover.removeFromSuperview() }
            }
        }
    }

    // MARK: - Gestures

    @objc private func handleSwipe(_ gesture: UISwipeGestureRecognizer) {
        model.hideChrome()
        // Swiping left reveals the page to the right.
        turnVisually(right: gesture.direction == .left)
    }

    /// Overscrolling past a chapter's first or last page moves to the adjacent chapter.
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .ended, case .reflowable(let spineIndex) = document, pending == nil else { return }
        let scrollView = webView.scrollView
        let threshold: CGFloat = 56
        if model.isScrollMode {
            let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
            if scrollView.contentOffset.y > maxY + threshold {
                changeChapter(from: spineIndex, forward: true, visualRight: true)
            } else if scrollView.contentOffset.y < -threshold {
                changeChapter(from: spineIndex, forward: false, visualRight: false)
            }
            return
        }
        guard model.preferences.pageTurn == .slide else { return }
        let maxX = max(0, scrollView.contentSize.width - scrollView.bounds.width)
        if scrollView.contentOffset.x > maxX + threshold {
            changeChapter(from: spineIndex, forward: !isRTLProgression, visualRight: true)
        } else if scrollView.contentOffset.x < -threshold {
            changeChapter(from: spineIndex, forward: isRTLProgression, visualRight: false)
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

    @objc private func nextKey() { turnVisually(right: true) }
    @objc private func previousKey() { turnVisually(right: false) }
    @objc private func spaceKey() { turn(forward: true, visualRight: !isRTLProgression) }

    // MARK: - JavaScript

    @discardableResult
    private func call(_ body: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        let script = body.hasPrefix("return") ? body : "return \(body)"
        return try await webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: world)
    }
}

// MARK: - ReaderNavigator

extension ReaderViewController: ReaderNavigator {
    func go(to locator: Locator, animated: Bool) {
        let index = min(max(locator.spineIndex, 0), publication.spine.count - 1)
        let transition: Transition = document == nil ? .none : .cover
        if document == .roll, isReady {
            Task {
                _ = try? await call("MB.scrollToItem(index, progression)", [
                    "index": index, "progression": locator.fragment == nil ? locator.progression : 0,
                ])
            }
            return
        }
        if case .reflowable(index) = document, isReady {
            Task {
                var target: [String: Any] = ["progression": locator.progression]
                if let cfi = locator.cfi { target["cfi"] = cfi }
                if let fragment = locator.fragment { target["fragment"] = fragment }
                beginTransition(.cover)
                _ = try? await call("MB.goToPosition(MB.positionFor(target))", ["target": target])
                try? await Task.sleep(for: .milliseconds(50))
                finishTransition(.cover)
            }
            return
        }
        load(spineIndex: index, target: locator, atEnd: false, transition: transition)
    }

    func turnPage(forward: Bool) {
        turn(forward: forward, visualRight: forward != isRTLProgression)
    }

    func applyPreferences() {
        scheduleReconfigure()
    }

    func reloadHighlights() {
        guard case .reflowable(let spineIndex) = document else { return }
        let highlights = model.highlights(forSpineIndex: spineIndex).compactMap { annotation -> [String: Any]? in
            guard let start = annotation.rangeStart, let end = annotation.rangeEnd else { return nil }
            return ["id": annotation.id.uuidString, "start": start, "end": end, "color": annotation.color.rawValue]
        }
        Task { _ = try? await call("MB.setHighlights(list)", ["list": highlights]) }
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
        load(spineIndex: result.spineIndex, target: Locator(spineIndex: result.spineIndex), atEnd: false,
             transition: .cover, search: result, query: model.searchQuery)
    }

    func pages(forCFIs cfis: [String]) async -> [Int?] {
        guard case .reflowable = document, isReady else { return cfis.map { _ in nil } }
        let script = "return cfis.map((cfi) => { const p = cfi ? MB.positionFor({ cfi }) : null; return p ? p.page : -1; })"
        let pages = (try? await call(script, ["cfis": cfis])) as? [Int] ?? []
        return cfis.indices.map { pages.indices.contains($0) && pages[$0] >= 0 ? pages[$0] : nil }
    }
}

// MARK: - WebKit delegates

extension ReaderViewController: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        if navigationAction.navigationType == .linkActivated || navigationAction.targetFrame == nil {
            follow(url)
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
        if let url = navigationAction.request.url { follow(url) }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        load(spineIndex: model.location.spineIndex, target: model.location, atEnd: false, transition: .none)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finishTransition()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finishTransition()
    }
}

extension ReaderViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

// MARK: - Supporting types

/// Avoids the retain cycle between `WKUserContentController` and its handler.
private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    var handler: (([String: Any]) -> Void)?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        handler?(body)
    }
}

/// Adds Highlight, Note, and Search to the text selection menu, like Apple Books.
final class BookWebView: WKWebView {
    struct MenuActions {
        let highlight: () -> Void
        let note: () -> Void
        let search: (String) -> Void
    }

    var menuActions: MenuActions?

    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard let actions = menuActions else { return }
        let highlight = UIAction(title: String(localized: "Highlight"), image: UIImage(systemName: "highlighter")) { _ in
            actions.highlight()
        }
        let note = UIAction(title: String(localized: "Add Note"), image: UIImage(systemName: "note.text.badge.plus")) { _ in
            actions.note()
        }
        let search = UIAction(title: String(localized: "Search Book"), image: UIImage(systemName: "magnifyingglass")) {
            [weak self] _ in
            Task { @MainActor in
                let text = (try? await self?.evaluateJavaScript("window.getSelection().toString()")) as? String ?? ""
                actions.search(text)
            }
        }
        builder.insertChild(UIMenu(options: .displayInline, children: [highlight, note]), atStartOfMenu: .root)
        builder.insertChild(UIMenu(options: .displayInline, children: [search]), atEndOfMenu: .root)
    }
}

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
    func double(_ key: String) -> Double { (self[key] as? NSNumber)?.doubleValue ?? 0 }
    func int(_ key: String) -> Int { (self[key] as? NSNumber)?.intValue ?? 0 }

    func rect(_ key: String) -> CGRect {
        guard let value = self[key] as? [String: Any] else { return .zero }
        return CGRect(x: value.double("x"), y: value.double("y"), width: value.double("width"), height: value.double("height"))
    }
}
