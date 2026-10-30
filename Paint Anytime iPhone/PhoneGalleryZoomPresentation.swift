import SwiftUI
import Observation
import UIKit

/// The displayed position is also the next gesture's starting position.
@MainActor
@Observable
final class PhoneGalleryZoomPresentation {
    var scale: CGFloat = 1
    var position: CGFloat = 0
    var elasticAnchor: CGPoint = .zero
    var offsetY: CGFloat = 0

    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var startedAt: CFTimeInterval = 0
    @ObservationIgnored private var duration: Double = 0
    @ObservationIgnored private var startSize: CGFloat = 0
    @ObservationIgnored private var endSize: CGFloat = 0
    @ObservationIgnored private var targetPosition: CGFloat = 0
    @ObservationIgnored private var gridTransition = false
    @ObservationIgnored private var completion: (() -> Void)?

    static func position(for columns: Int) -> CGFloat {
        columns == 1 ? 2 : (columns == 3 ? 1 : 0)
    }

    private static func sizeProgress(_ position: CGFloat) -> CGFloat {
        position <= 1 ? position / 6 : 1.0 / 6 + (position - 1) * 5 / 6
    }

    private static func positionFromSize(_ size: CGFloat) -> CGFloat {
        size <= 1.0 / 6 ? size * 6 : 1 + (size - 1.0 / 6) * 6 / 5
    }

    func stopAnimation() {
        displayLink?.invalidate()
        displayLink = nil
        completion = nil
    }

    func animate(to target: CGFloat, duration: Double, gridTransition: Bool,
                 completion: @escaping () -> Void) {
        stopAnimation()
        guard duration > 0, position != target else {
            position = target
            completion()
            return
        }
        startSize = Self.sizeProgress(position)
        endSize = Self.sizeProgress(target)
        targetPosition = target
        self.duration = duration
        self.gridTransition = gridTransition
        self.completion = completion
        startedAt = CACurrentMediaTime()
        let link = CADisplayLink(target: TickTarget(owner: self), selector: #selector(TickTarget.tick(_:)))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    private func tick(_ link: CADisplayLink) {
        let time = min(1, max(0, (link.targetTimestamp - startedAt) / duration))
        let progress: Double
        if gridTransition {
            // Smoothstep: the existing cubic curve with linear time coordinates.
            progress = time * time * (3 - 2 * time)
        } else {
            // Preserve the rebound's (0.33, 1, 0.67, 1) timing curve.
            var low = 0.0
            var high = 1.0
            for _ in 0..<14 {
                let t = (low + high) / 2
                let x = 3 * (1 - t) * (1 - t) * t * 0.33 + 3 * (1 - t) * t * t * 0.67 + t * t * t
                if x < time { low = t } else { high = t }
            }
            let t = (low + high) / 2
            progress = 1 - pow(1 - t, 3)
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            position = time >= 1 ? targetPosition
                : Self.positionFromSize(startSize + (endSize - startSize) * CGFloat(progress))
        }
        if time >= 1 {
            let finished = completion
            stopAnimation()
            finished?()
        }
    }

    @MainActor
    private final class TickTarget: NSObject {
        weak var owner: PhoneGalleryZoomPresentation?
        init(owner: PhoneGalleryZoomPresentation) { self.owner = owner }
        @objc func tick(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.tick(link)
        }
    }
}
