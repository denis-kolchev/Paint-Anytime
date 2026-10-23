import Foundation
import CoreGraphics

/// Screen-space calibration from Apple's DeviceKit simulator chrome geometry.
/// watchOS exposes the Crown's side, but no public API for its screen coordinate.
enum TutorialCrownPlacement {
    static func rightCrownY(screenSize: CGSize) -> CGFloat {
        switch (Int(screenSize.width.rounded()), Int(screenSize.height.rounded())) {
        case (162, 197): return 49       // 40 mm: watch2
        case (184, 224): return 57       // 44 mm: watch2b
        case (176, 215): return 56       // 41 mm: watch3s
        case (198, 242): return 66       // 45 mm: watch3b
        case (187, 223): return 56       // 42 mm, Series 10+: watch5s
        case (208, 248): return 66       // 46 mm, Series 10+: watch5b
        case (205, 251): return 83.5     // Ultra / Ultra 2: watch4
        case (211, 257): return 85.5     // Ultra 3 / Ultra 4: watch6
        default: return screenSize.height * 0.26
        }
    }

    static func position(screenBounds: CGRect, overlayFrame: CGRect, crownOnLeft: Bool) -> CGPoint {
        let y = rightCrownY(screenSize: screenBounds.size)
        // Left-Crown orientation rotates the physical case by 180 degrees.
        return CGPoint(
            x: (crownOnLeft ? screenBounds.minX + 15 : screenBounds.maxX - 15) - overlayFrame.minX,
            y: screenBounds.minY + (crownOnLeft ? screenBounds.height - y : y) - overlayFrame.minY
        )
    }
}
