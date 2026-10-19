import UIKit
// swiftlint:disable:next duplicate_imports - the submodule exposes the gesture recognizer subclass API.
import UIKit.UIGestureRecognizerSubclass

/// One page turn: the page on screen and the page the turn reveals.
///
/// The data source creates turns and owns both views. A presenter animates them and calls
/// `finish(completed:)` exactly once; the data source then settles on a page with `setPage(_:)`.
final class PageTurn {
    /// The side the incoming page enters from.
    enum Side {
        case left, right, top, bottom
    }

    let side: Side
    let outgoing: UIView
    let incoming: UIView
    private var completion: ((_ completed: Bool) -> Void)?

    init(side: Side, outgoing: UIView, incoming: UIView, completion: @escaping (_ completed: Bool) -> Void) {
        self.side = side
        self.outgoing = outgoing
        self.incoming = incoming
        self.completion = completion
    }

    /// Ends the turn. `completed` is false when the reader let go before turning the page.
    func finish(completed: Bool) {
        let completion = self.completion
        self.completion = nil
        completion?(completed)
    }
}

protocol PageTurnDataSource: AnyObject {
    /// Whether the touch in progress may start a turn (not, for example, while selecting text).
    func canBeginInteractivePageTurn() -> Bool
    /// Prepares a turn toward `side`, or returns nil when there is no page there.
    func pageTurn(toward side: PageTurn.Side) -> PageTurn?
}

/// Shows the current page and animates turns in one of the reader's page-turn styles.
protocol PageTurnPresenting: AnyObject {
    var dataSource: PageTurnDataSource? { get set }
    /// Whether a turn is being dragged or animated.
    var isTurning: Bool { get }
    /// Shows `page` at rest.
    func setPage(_ page: UIView)
    /// Animates a turn that no gesture drives, such as a tap or key press.
    func perform(_ turn: PageTurn)
    /// Jumps a settling turn to its end. Presenters that can't do this keep turning.
    func completeRunningTurn()
}

typealias PageTurnPresenter = UIViewController & PageTurnPresenting

/// How interactive turns respond to the finger, shared by every style.
enum PageTurnPhysics {
    /// Release speed, in pages per second, that decides a turn regardless of how far it got.
    static let flickVelocity: CGFloat = 0.8
    /// How far ahead, in seconds, a slower release is projected before checking the halfway mark.
    static let projection: CGFloat = 0.15
    /// The settle animation's perceived duration. Short, with no bounce, so turns feel crisp.
    static let settleDuration: TimeInterval = 0.34

    /// Whether releasing a drag completes the turn.
    /// - Parameters:
    ///   - progress: How far the turn got, from 0 (the outgoing page) to 1 (the incoming page).
    ///   - velocity: Release speed in pages per second, positive toward the incoming page.
    static func shouldComplete(progress: CGFloat, velocity: CGFloat) -> Bool {
        if abs(velocity) >= flickVelocity { return velocity > 0 }
        return progress + velocity * projection >= 0.5
    }

    /// Resistance when dragging past the first or last page, like a scroll view's rubber band.
    static func rubberBand(_ offset: CGFloat, dimension: CGFloat) -> CGFloat {
        guard dimension > 0 else { return 0 }
        let resisted = (1 - 1 / (abs(offset) * 0.55 / dimension + 1)) * dimension
        return offset < 0 ? -resisted : resisted
    }

    /// A spring that starts at the finger's speed, so a flick carries straight into the animation.
    /// - Parameters:
    ///   - distance: What is left of the turn, in pages.
    ///   - velocity: Release speed in pages per second toward the animation's end.
    static func settleTiming(distance: CGFloat, velocity: CGFloat) -> UISpringTimingParameters {
        let relative = distance > 0.001 ? min(max(velocity / distance, -10), 30) : 0
        return UISpringTimingParameters(
            duration: settleDuration, bounce: 0, initialVelocity: CGVector(dx: relative, dy: relative))
    }
}

/// The Slide and Fast Fade styles, plus the vertical push between chapters in scroll mode.
final class SlidePagePresenter: UIViewController, PageTurnPresenting, UIGestureRecognizerDelegate {
    enum Style {
        /// Pages move side by side and follow the finger.
        case slide
        /// A quick cross-fade as soon as a swipe starts.
        case fade
        /// Vertical slides with no gesture of their own, for scroll mode.
        case push
    }

    weak var dataSource: PageTurnDataSource?
    private let style: Style
    private var page: UIView?
    private var turn: PageTurn?
    private var animator: UIViewPropertyAnimator?
    private var isDragging = false
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))

    var isTurning: Bool { turn != nil || isDragging || animator != nil }

    init(style: Style) {
        self.style = style
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        view = UIView()
        view.clipsToBounds = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard style != .push else { return }
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
    }

    func setPage(_ page: UIView) {
        self.page = page
        place(page)
        view.bringSubviewToFront(page)
    }

    func perform(_ turn: PageTurn) {
        completeRunningTurn()
        begin(turn)
        settle(completing: true, from: 0, velocity: 0)
    }

    func completeRunningTurn() {
        guard let animator, !isDragging else { return }
        animator.stopAnimation(false)
        animator.finishAnimation(at: .end)
    }

    // MARK: - Layout

    private func place(_ page: UIView) {
        if page.superview !== view { view.addSubview(page) }
        page.transform = .identity
        page.alpha = 1
        page.frame = view.bounds
        page.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    private func begin(_ turn: PageTurn) {
        self.turn = turn
        place(turn.incoming)
        place(turn.outgoing)
        view.bringSubviewToFront(turn.outgoing)
        apply(progress: 0)
    }

    /// Positions the turn's pages, from 0 (the outgoing page) to 1 (the incoming page).
    private func apply(progress: CGFloat) {
        guard let turn else { return }
        switch style {
        case .fade:
            turn.outgoing.alpha = 1 - progress
        case .slide, .push:
            let size = view.bounds.size
            let start: CGPoint = switch turn.side {
            case .right: CGPoint(x: size.width, y: 0)
            case .left: CGPoint(x: -size.width, y: 0)
            case .bottom: CGPoint(x: 0, y: size.height)
            case .top: CGPoint(x: 0, y: -size.height)
            }
            turn.outgoing.transform = CGAffineTransform(translationX: -start.x * progress, y: -start.y * progress)
            turn.incoming.transform = CGAffineTransform(translationX: start.x * (1 - progress), y: start.y * (1 - progress))
        }
    }

    // MARK: - Animation

    /// Animates to the end (or back to the start) of the turn, keeping the finger's momentum.
    /// - Parameter velocity: Pages per second toward the incoming page.
    private func settle(completing: Bool, from progress: CGFloat, velocity: CGFloat) {
        guard let turn else { return }
        let target: CGFloat = completing ? 1 : 0
        let animator: UIViewPropertyAnimator
        if style == .fade {
            animator = UIViewPropertyAnimator(duration: 0.16, curve: .easeOut)
        } else {
            let timing = PageTurnPhysics.settleTiming(
                distance: abs(target - progress), velocity: completing ? velocity : -velocity)
            animator = UIViewPropertyAnimator(duration: PageTurnPhysics.settleDuration, timingParameters: timing)
        }
        animator.addAnimations { [weak self] in self?.apply(progress: target) }
        animator.addCompletion { [weak self] _ in self?.end(turn, completed: completing) }
        self.animator = animator
        animator.startAnimation()
    }

    private func end(_ turn: PageTurn, completed: Bool) {
        animator = nil
        self.turn = nil
        view.bringSubviewToFront(completed ? turn.incoming : turn.outgoing)
        for page in [turn.outgoing, turn.incoming] {
            page.transform = .identity
            page.alpha = 1
        }
        turn.finish(completed: completed)
    }

    // MARK: - Dragging

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let width = max(view.bounds.width, 1)
        let translation = gesture.translation(in: view).x
        switch gesture.state {
        case .began:
            completeRunningTurn()
            isDragging = true
            let direction = translation != 0 ? translation : gesture.velocity(in: view).x
            if let turn = dataSource?.pageTurn(toward: direction < 0 ? .right : .left) {
                begin(turn)
                if style == .fade {
                    // Fast Fade turns as soon as the swipe is recognized.
                    isDragging = false
                    settle(completing: true, from: 0, velocity: 0)
                    return
                }
            }
            track(translation, width: width)
        case .changed:
            track(translation, width: width)
        case .ended, .cancelled, .failed:
            guard isDragging else { return }
            isDragging = false
            guard let turn else {
                bounceBack()
                return
            }
            let sign: CGFloat = turn.side == .right ? -1 : 1
            let progress = progress(of: translation, width: width)
            let velocity = gesture.velocity(in: view).x * sign / width
            let completing = gesture.state == .ended && PageTurnPhysics.shouldComplete(progress: progress, velocity: velocity)
            settle(completing: completing, from: progress, velocity: velocity)
        default:
            break
        }
    }

    private func progress(of translation: CGFloat, width: CGFloat) -> CGFloat {
        let sign: CGFloat = turn?.side == .right ? -1 : 1
        return min(max(translation * sign / width, 0), 1)
    }

    private func track(_ translation: CGFloat, width: CGFloat) {
        if turn != nil {
            if style == .slide { apply(progress: progress(of: translation, width: width)) }
        } else if let page {
            // No page that way: the first or last page resists like a scroll view.
            page.transform = CGAffineTransform(translationX: PageTurnPhysics.rubberBand(translation, dimension: width), y: 0)
        }
    }

    private func bounceBack() {
        guard let page, page.transform != .identity else { return }
        let animator = UIViewPropertyAnimator(
            duration: PageTurnPhysics.settleDuration, timingParameters: UISpringTimingParameters(duration: 0.4, bounce: 0))
        animator.addAnimations { page.transform = .identity }
        animator.addCompletion { [weak self] _ in self?.animator = nil }
        self.animator = animator
        animator.startAnimation()
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan else { return true }
        let velocity = pan.velocity(in: view)
        guard abs(velocity.x) > abs(velocity.y) else { return false }
        return dataSource?.canBeginInteractivePageTurn() ?? false
    }
}

/// Records when touches begin, without taking part in gesture recognition.
///
/// Lets page turns tell a swipe from a long press that has started selecting text.
final class TouchStartRecognizer: UIGestureRecognizer {
    private var touchBegan: TimeInterval = 0

    /// Seconds since the latest touch went down.
    var timeSinceTouchBegan: TimeInterval { ProcessInfo.processInfo.systemUptime - touchBegan }

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        touchBegan = touches.map(\.timestamp).min() ?? ProcessInfo.processInfo.systemUptime
        state = .failed
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}
