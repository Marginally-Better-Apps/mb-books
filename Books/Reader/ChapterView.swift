import UIKit
import WebKit

/// What a `ChapterView` shows: a reflowable spine item, a fixed-layout spread, or the whole roll.
enum ReaderDocument: Equatable {
    case reflowable(Int)
    case fixed([Int])
    case roll
}

/// A web view showing one `ReaderDocument`, and whether that document is ready to show.
///
/// The reader keeps a few of these: the current page, plus spares that preload the chapters on either
/// side so turning into them is instant.
final class ChapterView: UIView {
    /// Where a spare chapter waits: on its first page (to turn forward into) or its last.
    enum Placement {
        case start, end
    }

    let webView: BookWebView
    private(set) var document: ReaderDocument?
    /// Whether `reader.js` has laid out the document.
    private(set) var isReady = false
    /// Whether the document is loaded and positioned where the reader wants it.
    var isSettled = false
    /// Whether the document's own writing direction is right to left.
    private(set) var isRTL = false
    var placement: Placement?
    private var loadingURL: URL?
    private var navigation: WKNavigation?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    init(configuration: WKWebViewConfiguration) {
        webView = BookWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)
        webView.frame = bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.isOpaque = false
        webView.backgroundColor = .clear
        #if DEBUG
        webView.isInspectable = true
        #endif
        let scrollView = webView.scrollView
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.isDirectionalLockEnabled = true
        scrollView.pinchGestureRecognizer?.isEnabled = false
        addSubview(webView)
        // Inactive until the reader shows it.
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Whether this is the page the reader interacts with. Spares stay silent, untouchable,
    /// and hidden from VoiceOver.
    var isActive = false {
        didSet {
            isUserInteractionEnabled = isActive
            accessibilityElementsHidden = !isActive
            webView.setAllMediaPlaybackSuspended(!isActive)
        }
    }

    /// Lets the web view scroll (scroll mode and rolls) or keeps it still for page turns.
    func setScrolls(_ scrolls: Bool) {
        let scrollView = webView.scrollView
        scrollView.isPagingEnabled = false
        scrollView.isScrollEnabled = scrolls
        scrollView.alwaysBounceHorizontal = false
        scrollView.alwaysBounceVertical = scrolls
        scrollView.showsVerticalScrollIndicator = scrolls
    }

    // MARK: - Loading

    /// Starts loading `document` from `url`. Anyone waiting on an earlier document is told it failed.
    func load(_ document: ReaderDocument, url: URL, readAccess: URL) {
        resumeWaiters(false)
        self.document = document
        isReady = false
        isSettled = false
        placement = nil
        loadingURL = url
        navigation = webView.loadFileURL(url, allowingReadAccessTo: readAccess)
    }

    /// Waits until the current document is laid out. Returns false if it failed or was replaced.
    func waitUntilReady() async -> Bool {
        if isReady { return true }
        guard document != nil else { return false }
        return await withCheckedContinuation { waiters.append($0) }
    }

    /// Called when `reader.js` in the frame at `url` reports that it has laid out.
    func didBecomeReady(url: URL?, rtl: Bool) {
        // Ignore a late message from the document this view was showing before.
        guard let url, let loadingURL, url.resolvingSymlinksInPath().path == loadingURL.resolvingSymlinksInPath().path
        else { return }
        isReady = true
        isRTL = rtl
        webView.setAllMediaPlaybackSuspended(!isActive)
        resumeWaiters(true)
    }

    func didFail(_ failed: WKNavigation?) {
        guard failed === navigation else { return }
        reset()
    }

    /// Forgets the document, for example after its web content process ended.
    func reset() {
        document = nil
        isReady = false
        isSettled = false
        placement = nil
        loadingURL = nil
        navigation = nil
        resumeWaiters(false)
    }

    private func resumeWaiters(_ result: Bool) {
        let waiters = self.waiters
        self.waiters = []
        waiters.forEach { $0.resume(returning: result) }
    }
}

/// Avoids the retain cycle between `WKUserContentController` and its handler.
final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    var handler: ((WKScriptMessage) -> Void)?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        handler?(message)
    }
}

/// Adds Highlight, Note, and Search to the text selection menu, like Apple Books.
final class BookWebView: WKWebView {
    struct MenuActions {
        let highlight: () -> Void
        let note: () -> Void
        let search: (String) -> Void
        let listen: () -> Void
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
        let listen = UIAction(title: String(localized: "Listen from Here"), image: UIImage(systemName: "headphones")) { _ in
            actions.listen()
        }
        builder.insertChild(UIMenu(options: .displayInline, children: [highlight, note]), atStartOfMenu: .root)
        builder.insertChild(UIMenu(options: .displayInline, children: [search, listen]), atEndOfMenu: .root)
    }
}
