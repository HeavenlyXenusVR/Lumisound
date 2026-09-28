import SwiftUI
import UIKit

// MARK: - HorizontalSwipeGesture
//
// A sideways-swipe gesture that leaves vertical drags to the enclosing
// ScrollView. A SwiftUI `DragGesture` inside a ScrollView — even attached
// with `.simultaneousGesture` — claims every drag that starts on it, so Now
// Playing wouldn't scroll when a swipe began on the artwork (screenshot runs
// 3 and 5). This wraps a `UIPanGestureRecognizer` that only begins when the
// movement is clearly horizontal; anything else fails it immediately and the
// scroll view's own pan takes over.

struct HorizontalSwipeGesture: UIGestureRecognizerRepresentable {
    /// Horizontal translation while the finger moves.
    var onChanged: (CGFloat) -> Void = { _ in }
    /// Final horizontal and vertical translation (also on cancel).
    var onEnded: (CGFloat, CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view)
        switch recognizer.state {
        case .changed:
            onChanged(translation.x)
        case .ended, .cancelled, .failed:
            onEnded(translation.x, translation.y)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.2
        }
    }
}
