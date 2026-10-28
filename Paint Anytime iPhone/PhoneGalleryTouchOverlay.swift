#if DEBUG
import SwiftUI
import UIKit

/// Passive, raw touch visualization. It never recognizes or consumes a gesture.
struct PhoneGalleryTouchOverlay: UIViewRepresentable {
    func makeUIView(context: Context) -> TouchView { TouchView() }
    func updateUIView(_ uiView: TouchView, context: Context) {}

    static func dismantleUIView(_ uiView: TouchView, coordinator: ()) {
        uiView.detach()
    }

    final class TouchView: UIView {
        private var observer: TouchObserver?
        var positions: [CGPoint] = [] {
            didSet { setNeedsDisplay() }
        }

        init() {
            super.init(frame: .zero)
            isOpaque = false
            backgroundColor = .clear
            isUserInteractionEnabled = false
            accessibilityElementsHidden = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            guard let window else { return }
            let observer = TouchObserver(overlay: self)
            self.observer = observer
            // Observe the ancestor receiving raw events; the overlay itself
            // remains transparent to hit testing and does not intercept buttons.
            window.addGestureRecognizer(observer)
        }

        func detach() {
            if let observer { observer.view?.removeGestureRecognizer(observer) }
            observer = nil
            positions = []
        }

        override func draw(_ rect: CGRect) {
            for position in positions {
                let circle = UIBezierPath(ovalIn: CGRect(x: position.x - 18, y: position.y - 18,
                                                        width: 36, height: 36))
                UIColor.systemOrange.withAlphaComponent(0.28).setFill()
                circle.fill()
                UIColor.white.setStroke()
                circle.lineWidth = 3
                circle.stroke()
                UIColor.systemOrange.setStroke()
                circle.lineWidth = 1
                circle.stroke()
            }
        }
    }

    final class TouchObserver: UIGestureRecognizer, UIGestureRecognizerDelegate {
        private weak var overlay: TouchView?
        private var tracked: Set<UITouch> = []

        init(overlay: TouchView) {
            self.overlay = overlay
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
            delegate = self
        }

        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let overlay else { return }
            for touch in touches where overlay.bounds.contains(touch.location(in: overlay)) {
                tracked.insert(touch)
            }
            publish()
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { publish() }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            finish(touches)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            finish(touches)
        }

        private func finish(_ touches: Set<UITouch>) {
            tracked.subtract(touches)
            publish()
            // Staying possible avoids recognizing a competing gesture. Failing
            // when all tracked fingers lift lets UIKit reset for the next sequence.
            if tracked.isEmpty { state = .failed }
        }

        private func publish() {
            guard let overlay else { return }
            overlay.positions = tracked.map { $0.location(in: overlay) }
        }

        override func reset() {
            super.reset()
            tracked.removeAll()
            overlay?.positions = []
        }
    }
}
#endif
