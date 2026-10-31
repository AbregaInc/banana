#if os(iOS)
import SwiftUI
import UIKit

/// Tap- and drag-to-create for a calendar column, done in UIKit because SwiftUI cannot.
///
/// On iOS 26 a SwiftUI `DragGesture` attached inside a `ScrollView` still loses to the scroll
/// view: measured at 0 pt of travel against 320 pt for the same drag with the gesture removed.
/// `.simultaneousGesture`, direction gating, `minimumDistance` and `LongPressGesture.sequenced`
/// were all tried and none of them work. A `SpatialTapGesture` fares no better once the column
/// sits inside the week grid's nested horizontal and vertical scroll views — measured opening
/// nothing at all, which is why creating an event meant using the toolbar button and correcting
/// its guessed start time every single time.
///
/// UIKit can express what SwiftUI cannot: recognizers that coexist with the scroll view's own pan
/// instead of competing with it, and a long press the scroll view is told to wait for. The day
/// view already proved this shape works; this is the same idea packaged so the week grid can use
/// it without its scrolling being rebuilt.
struct CalendarCreateGesture: UIViewRepresentable {
    /// Whether a create may start at this point, in the overlay's own coordinates. Used to leave
    /// existing events alone: a press on one of those is the start of a move, not a create.
    var canBegin: (CGPoint) -> Bool
    /// A plain tap: create something of a default length at this instant. Nil for no tap at all —
    /// the iPhone grids, where a tap is far too often just the end of a scroll.
    var onTap: ((CGPoint) -> Void)?
    /// A press-and-drag in progress, reported continuously so the draft block can be drawn.
    var onDragChanged: (CGPoint, CGPoint) -> Void
    var onDragEnded: (CGPoint, CGPoint) -> Void
    var onDragCancelled: () -> Void
    /// Whether this overlay owns press-and-drag as well as tapping.
    ///
    /// Day mode runs its own UIKit scroll view and already recognises the hold there, so it takes
    /// taps from here and nothing else. Adding a second long press would give that mode two
    /// recognizers racing over one gesture.
    var handlesDrag: Bool = true

    /// How long a press must be held before it starts drawing an event instead of scrolling.
    ///
    /// The scroll view is told to wait for this recognizer, so every value here is paid by anyone
    /// who just wants to scroll. 0.3 s is short enough to feel like a direct manipulation and long
    /// enough that a flick moves past `allowableMovement` first and scrolls normally.
    ///
    /// 0.45 s, matching day mode. At 0.3 s a finger that paused for a moment while panning around
    /// the week started drawing an event instead.
    static let holdToCreate: TimeInterval = 0.45

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> CreateSurface {
        let view = CreateSurface()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true

        if onTap != nil {
            let tap = UITapGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.didTap(_:)))
            tap.cancelsTouchesInView = false
            tap.delegate = context.coordinator
            view.addGestureRecognizer(tap)
        }

        guard handlesDrag else {
            context.coordinator.view = view
            return view
        }

        let press = UILongPressGestureRecognizer(target: context.coordinator,
                                                 action: #selector(Coordinator.didPress(_:)))
        press.minimumPressDuration = Self.holdToCreate
        // Small on purpose: a drag that travels further than this before the hold completes is a
        // scroll, and failing fast is what keeps scrolling feeling normal.
        press.allowableMovement = 10
        press.cancelsTouchesInView = false
        press.delegate = context.coordinator
        view.addGestureRecognizer(press)

        view.onAttach = { [weak press] surface in
            guard let press else { return }
            // Walk up to whichever scroll view actually carries this column and make its pan wait
            // for the hold. Without this the scroll starts first and the drag never arrives.
            var parent: UIView? = surface.superview
            while let candidate = parent {
                if let scroll = candidate as? UIScrollView {
                    scroll.panGestureRecognizer.require(toFail: press)
                }
                parent = candidate.superview
            }
        }
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: CreateSurface, context: Context) {
        context.coordinator.parent = self
    }

    /// A plain view that reports when it joins a window, so the enclosing scroll views can be
    /// found and told to wait for the hold. They do not exist yet at `makeUIView` time.
    final class CreateSurface: UIView {
        var onAttach: ((CreateSurface) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { onAttach?(self) }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: CalendarCreateGesture
        weak var view: UIView?
        private var pressOrigin: CGPoint?

        init(_ parent: CalendarCreateGesture) { self.parent = parent }

        @objc func didTap(_ recognizer: UITapGestureRecognizer) {
            guard let view else { return }
            guard !tapLandedOnMovingGrid else { return }
            let point = recognizer.location(in: view)
            guard parent.canBegin(point) else { return }
            parent.onTap?(point)
        }

        /// Set when a touch lands while any enclosing scroll view is still moving.
        ///
        /// Touching a scrolling grid is how you stop it, and that touch is a perfectly good tap to
        /// UIKit — so, recognised alongside the scroll, it opened a new event every time someone
        /// stopped a fling or nudged the week. A tap only creates when the grid was at rest.
        private var tapLandedOnMovingGrid = false

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool {
            guard gestureRecognizer is UITapGestureRecognizer else { return true }
            tapLandedOnMovingGrid = Self.enclosingScrollViewIsMoving(view)
            return true
        }

        static func enclosingScrollViewIsMoving(_ view: UIView?) -> Bool {
            var parent = view?.superview
            while let candidate = parent {
                if let scroll = candidate as? UIScrollView,
                   scroll.isDecelerating || scroll.isDragging {
                    return true
                }
                parent = candidate.superview
            }
            return false
        }

        @objc func didPress(_ recognizer: UILongPressGestureRecognizer) {
            guard let view else { return }
            let point = recognizer.location(in: view)
            switch recognizer.state {
            case .began:
                guard parent.canBegin(point) else { return }
                pressOrigin = point
                // A hold that has taken hold should say so before anything is drawn, since the
                // finger is not moving yet and nothing else would confirm it worked.
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                parent.onDragChanged(point, point)
            case .changed:
                guard let origin = pressOrigin else { return }
                parent.onDragChanged(origin, point)
            case .ended:
                guard let origin = pressOrigin else { return }
                pressOrigin = nil
                parent.onDragEnded(origin, point)
            case .cancelled, .failed:
                guard pressOrigin != nil else { return }
                pressOrigin = nil
                parent.onDragCancelled()
            default:
                break
            }
        }

        /// Coexist with everything. These recognizers add behaviour to the grid; they must never
        /// be the reason a scroll, a page swipe or a pinch stops working.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
#endif
