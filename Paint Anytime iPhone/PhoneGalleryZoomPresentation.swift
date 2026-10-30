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
        GalleryZoomRules.position(columns)
    }

    private static func sizeProgress(_ position: CGFloat) -> CGFloat {
        GalleryZoomRules.sizeProgress(position)
    }

    private static func positionFromSize(_ size: CGFloat) -> CGFloat {
        GalleryZoomRules.positionFromSize(size)
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
        let progress = GalleryZoomRules.easing(time, gridTransition: gridTransition)
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
