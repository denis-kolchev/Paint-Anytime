import Foundation
import CoreGraphics

nonisolated enum WatchLassoGeometry {
    // Screen-point sizes stay constant as the artwork zooms.
    static let handleRadius: CGFloat = 6
    static let handleHitRadius: CGFloat = 22
    static let rotationHandleOffset: CGFloat = 28

    static func rotationHandle(_ rect: CGRect, offset: CGFloat = rotationHandleOffset) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.minY - offset)
    }

    static func rotation(_ angle: CGFloat, around rect: CGRect) -> CGAffineTransform {
        let c = cos(angle), s = sin(angle), x = rect.midX, y = rect.midY
        return CGAffineTransform(a: c, b: s, c: -s, d: c,
                                 tx: x - c * x + s * y, ty: y - s * x - c * y)
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    static func path(_ points: [CGPoint], closed: Bool = true) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        if closed { path.closeSubpath() }
        return path
    }

    static func handles(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY),
         CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY)]
    }

}
