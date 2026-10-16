import OSLog
import UIKit

/// The Curl style. Uses UIKit's page curl, which follows the finger like a paper page.
///
/// `UIPageViewController` asks its data source for the next page as a curl starts, so each turn is
/// prepared then: the current page shows the turn's outgoing view and a new slot holds the incoming one.
final class CurlPagePresenter: UIViewController, PageTurnPresenting {
    private static let logger = Logger(subsystem: "com.mbbooks.MBBooks", category: "PageCurl")

    weak var dataSource: PageTurnDataSource?
    private let pageController: UIPageViewController
    /// Right-to-left books keep their spine on the right and curl from the left edge.
    private let isMirrored: Bool
    /// A turn the user is dragging.
    private var interactiveTurn: PageTurn?
    /// A turn started by a tap or key press.
    private var performedTurn: PageTurn?

    var isTurning: Bool { interactiveTurn != nil || performedTurn != nil }

    init(mirrored: Bool) {
        isMirrored = mirrored
        let spine: UIPageViewController.SpineLocation = mirrored ? .max : .min
        pageController = UIPageViewController(
            transitionStyle: .pageCurl, navigationOrientation: .horizontal,
            options: [.spineLocation: NSNumber(value: spine.rawValue)])
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.clipsToBounds = true
        pageController.isDoubleSided = false
        pageController.dataSource = self
        pageController.delegate = self
        addChild(pageController)
        pageController.view.frame = view.bounds
        pageController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pageController.view)
        pageController.didMove(toParent: self)
        // Taps are handled by the reader, which knows when a tap lands on a link.
        for recognizer in pageController.gestureRecognizers where recognizer is UITapGestureRecognizer {
            recognizer.isEnabled = false
        }
    }

    private var displayedSlot: PageSlot? { pageController.viewControllers?.first as? PageSlot }

    func setPage(_ page: UIView) {
        loadViewIfNeeded()
        if let slot = displayedSlot {
            slot.show(page)
        } else {
            pageController.setViewControllers([PageSlot(page)], direction: .forward, animated: false)
        }
    }

    func perform(_ turn: PageTurn) {
        guard !isTurning else {
            turn.finish(completed: false)
            return
        }
        performedTurn = turn
        displayedSlot?.show(turn.outgoing)
        pageController.setViewControllers([PageSlot(turn.incoming)], direction: direction(toward: turn.side), animated: true) {
            [weak self] _ in
            self?.performedTurn = nil
            turn.finish(completed: true)
        }
    }

    /// UIKit's curl can't be fast-forwarded; the reader queues turns that arrive meanwhile.
    func completeRunningTurn() {}

    private func direction(toward side: PageTurn.Side) -> UIPageViewController.NavigationDirection {
        (side == .right) != isMirrored ? .forward : .reverse
    }

    /// Prepares the page a curl reveals.
    private func incomingSlot(toward side: PageTurn.Side) -> UIViewController? {
        guard performedTurn == nil else { return nil }
        if let stale = interactiveTurn {
            // Asked again without a transition in between; put the first turn back.
            Self.logger.debug("Discarding a curl that never started")
            interactiveTurn = nil
            stale.finish(completed: false)
        }
        guard let dataSource, dataSource.canBeginInteractivePageTurn(),
              let turn = dataSource.pageTurn(toward: side)
        else { return nil }
        interactiveTurn = turn
        displayedSlot?.show(turn.outgoing)
        return PageSlot(turn.incoming)
    }
}

extension CurlPagePresenter: UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    func pageViewController(_ pageViewController: UIPageViewController,
                            viewControllerBefore viewController: UIViewController) -> UIViewController? {
        incomingSlot(toward: isMirrored ? .right : .left)
    }

    func pageViewController(_ pageViewController: UIPageViewController,
                            viewControllerAfter viewController: UIViewController) -> UIViewController? {
        incomingSlot(toward: isMirrored ? .left : .right)
    }

    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard let turn = interactiveTurn else { return }
        interactiveTurn = nil
        turn.finish(completed: completed)
    }
}

/// Hosts one page view inside the page curl.
private final class PageSlot: UIViewController {
    private(set) var page: UIView

    init(_ page: UIView) {
        self.page = page
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        // Start at the page's size, so the web view inside isn't squeezed to zero and re-laid out.
        view = UIView(frame: CGRect(origin: .zero, size: page.bounds.size))
        view.clipsToBounds = true
        attach()
    }

    func show(_ page: UIView) {
        if page !== self.page {
            if self.page.superview === viewIfLoaded { self.page.removeFromSuperview() }
            self.page = page
        }
        if isViewLoaded { attach() }
    }

    private func attach() {
        page.transform = .identity
        page.alpha = 1
        page.frame = view.bounds
        page.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if page.superview !== view { view.addSubview(page) }
    }
}
