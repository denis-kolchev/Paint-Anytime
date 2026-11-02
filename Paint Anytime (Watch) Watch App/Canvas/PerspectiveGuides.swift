import SwiftUI

enum PerspectivePreset: Int, CaseIterable, Identifiable {
    case one = 1, two, three

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .one: L10n.text("1-point perspective")
        case .two: L10n.text("2-point perspective")
        case .three: L10n.text("3-point perspective")
        }
    }
}

/// A guide line in canvas points. Rays start at their vanishing point.
struct PerspectiveGuideLine: Equatable {
    enum Kind: Equatable { case horizon, vanishing, ruler }

    var point: CGPoint
    /// Unit direction.
    var direction: CGPoint
    var kind: Kind
    var isRay = false

    func project(_ location: CGPoint) -> CGPoint {
        let t = (location.x - point.x) * direction.x + (location.y - point.y) * direction.y
        return CGPoint(x: point.x + direction.x * t, y: point.y + direction.y * t)
    }

    func distance(to location: CGPoint) -> CGFloat {
        let t = (location.x - point.x) * direction.x + (location.y - point.y) * direction.y
        let foot = isRay && t < 0 ? point : project(location)
        return hypot(location.x - foot.x, location.y - foot.y)
    }
}

/// Resolved guide geometry for one paper size. Display-only: it never enters the document.
struct PerspectiveGuideLayout: Equatable {
    static let handleDistance: CGFloat = 40
    static let handleHitRadius: CGFloat = 16

    var preset: PerspectivePreset
    var center: CGPoint
    var rotation: Double
    var viewAngle: Double
    var paperSize: CGSize

    var axis: CGPoint { CGPoint(x: cos(rotation), y: sin(rotation)) }
    /// Perpendicular to the horizon, pointing down when the guides are not rotated.
    var normal: CGPoint { CGPoint(x: -sin(rotation), y: cos(rotation)) }

    /// Distance from the center of vision to the side vanishing points. A wider view
    /// angle brings them closer, like a wider lens, and steepens the vanishing lines.
    private var vanishingDistance: CGFloat {
        let half = max(paperSize.width, paperSize.height) / 2
        return half / CGFloat(tan(viewAngle * .pi / 360))
    }

    var vanishingPoints: [CGPoint] {
        let d = vanishingDistance
        switch preset {
        case .one:
            return [center]
        case .two:
            return [offset(center, axis, -d), offset(center, axis, d)]
        case .three:
            return [offset(center, axis, -d), offset(center, axis, d), offset(center, normal, d)]
        }
    }

    var lines: [PerspectiveGuideLine] {
        var result = [PerspectiveGuideLine(point: center, direction: axis, kind: .horizon)]
        let paper = CGRect(origin: .zero, size: paperSize)
        for point in vanishingPoints {
            if paper.contains(point) {
                // A point on the paper gets a full fan; with one point the angle sets its spacing.
                let step = preset == .one ? viewAngle / 4 : 15
                var angle = step
                while angle < 180 - 0.001 {
                    let radians = rotation + angle * .pi / 180
                    result.append(PerspectiveGuideLine(point: point,
                        direction: CGPoint(x: cos(radians), y: sin(radians)), kind: .vanishing))
                    angle += step
                }
            } else {
                // Fan rays across the paper, which keeps them fixed while the canvas pans.
                let base = atan2(paper.midY - point.y, paper.midX - point.x)
                let corners = [CGPoint(x: paper.minX, y: paper.minY), CGPoint(x: paper.maxX, y: paper.minY),
                               CGPoint(x: paper.minX, y: paper.maxY), CGPoint(x: paper.maxX, y: paper.maxY)]
                let deltas = corners.map { corner -> CGFloat in
                    var delta = atan2(corner.y - point.y, corner.x - point.x) - base
                    while delta > .pi { delta -= 2 * .pi }
                    while delta < -.pi { delta += 2 * .pi }
                    return delta
                }
                let low = deltas.min() ?? 0, high = deltas.max() ?? 0
                let count = 9
                for index in 0..<count {
                    let radians = base + low + (high - low) * CGFloat(index) / CGFloat(count - 1)
                    result.append(PerspectiveGuideLine(point: point,
                        direction: CGPoint(x: cos(radians), y: sin(radians)), kind: .vanishing, isRay: true))
                }
            }
        }
        return result
    }

    func isNearGuide(_ location: CGPoint, tolerance: CGFloat) -> Bool {
        vanishingPoints.contains { hypot($0.x - location.x, $0.y - location.y) <= tolerance }
            || lines.contains { $0.distance(to: location) <= tolerance }
    }

    /// The ruler for a stroke that starts at `start` on a guide, chosen by the stroke's initial
    /// direction: the guide itself, a line toward a vanishing point or a horizon-aligned line.
    func ruler(from start: CGPoint, toward location: CGPoint, tolerance: CGFloat) -> PerspectiveGuideLine? {
        let movement = CGPoint(x: location.x - start.x, y: location.y - start.y)
        let length = hypot(movement.x, movement.y)
        guard length > 0.001 else { return nil }
        let heading = CGPoint(x: movement.x / length, y: movement.y / length)
        if let point = vanishingPoints.first(where: { hypot($0.x - start.x, $0.y - start.y) <= tolerance }) {
            // Any direction out of a vanishing point is a valid vanishing line.
            return PerspectiveGuideLine(point: point, direction: heading, kind: .ruler)
        }
        var candidates = lines.filter { $0.distance(to: start) <= tolerance }
        guard !candidates.isEmpty else { return nil }
        for point in vanishingPoints {
            let dx = point.x - start.x, dy = point.y - start.y
            let distance = hypot(dx, dy)
            guard distance > tolerance else { continue }
            candidates.append(PerspectiveGuideLine(point: start,
                direction: CGPoint(x: dx / distance, y: dy / distance), kind: .ruler))
        }
        candidates.append(PerspectiveGuideLine(point: start, direction: axis, kind: .ruler))
        if preset != .three {
            // Verticals stay parallel without a third vanishing point.
            candidates.append(PerspectiveGuideLine(point: start, direction: normal, kind: .ruler))
        }
        var best = candidates[0]
        var bestAlignment = -CGFloat.infinity
        for candidate in candidates {
            let alignment = abs(candidate.direction.x * heading.x + candidate.direction.y * heading.y)
            if alignment > bestAlignment {
                best = candidate
                bestAlignment = alignment
            }
        }
        best.kind = .ruler
        best.isRay = false
        return best
    }

    /// Screen positions of the move and rotation handles on the horizon.
    func handles(_ canvasToScreen: CGAffineTransform) -> (move: CGPoint, rotate: CGPoint) {
        let screenCenter = center.applying(canvasToScreen)
        return (offset(screenCenter, axis, -Self.handleDistance), offset(screenCenter, axis, Self.handleDistance))
    }

    private func offset(_ point: CGPoint, _ direction: CGPoint, _ distance: CGFloat) -> CGPoint {
        CGPoint(x: point.x + direction.x * distance, y: point.y + direction.y * distance)
    }
}

/// Perspective guide preferences and placement. Kept outside the document, history and exports.
final class PerspectiveGuides: ObservableObject {
    static let shared = PerspectiveGuides()
    static let viewAngleRange: ClosedRange<Double> = 30...90

    private enum Key {
        static let enabled = "perspectiveGuides.enabled"
        static let preset = "perspectiveGuides.preset"
        static let viewAngle = "perspectiveGuides.viewAngle"
        static let rotation = "perspectiveGuides.rotation"
        static let centerX = "perspectiveGuides.centerX"
        static let centerY = "perspectiveGuides.centerY"
    }

    private let defaults: UserDefaults

    @Published var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Key.enabled) } }
    @Published var preset: PerspectivePreset { didSet { defaults.set(preset.rawValue, forKey: Key.preset) } }
    @Published var viewAngle: Double { didSet { defaults.set(viewAngle, forKey: Key.viewAngle) } }
    /// Radians in (-π, π]. Canvas drags persist it through `savePlacement()`.
    @Published var rotation: Double
    /// Center of vision as a fraction of the paper size, so it follows canvas resizing.
    @Published var center: CGPoint
    /// The line the current stroke follows, for highlighting.
    @Published var activeRuler: PerspectiveGuideLine?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Key.enabled)
        preset = PerspectivePreset(rawValue: defaults.integer(forKey: Key.preset)) ?? .two
        let angle = defaults.object(forKey: Key.viewAngle) as? Double ?? 60
        viewAngle = min(Self.viewAngleRange.upperBound, max(Self.viewAngleRange.lowerBound, angle))
        rotation = defaults.double(forKey: Key.rotation)
        center = CGPoint(x: defaults.object(forKey: Key.centerX) as? Double ?? 0.5,
                         y: defaults.object(forKey: Key.centerY) as? Double ?? 0.5)
    }

    func layout(paperSize: CGSize) -> PerspectiveGuideLayout {
        PerspectiveGuideLayout(preset: preset,
            center: CGPoint(x: center.x * paperSize.width, y: center.y * paperSize.height),
            rotation: rotation, viewAngle: viewAngle, paperSize: paperSize)
    }

    func savePlacement() {
        defaults.set(rotation, forKey: Key.rotation)
        defaults.set(Double(center.x), forKey: Key.centerX)
        defaults.set(Double(center.y), forKey: Key.centerY)
    }

    func resetPlacement() {
        rotation = 0
        center = CGPoint(x: 0.5, y: 0.5)
        savePlacement()
    }

    static func normalizedRotation(_ radians: Double) -> Double {
        var value = radians.truncatingRemainder(dividingBy: 2 * .pi)
        if value > .pi { value -= 2 * .pi }
        if value <= -.pi { value += 2 * .pi }
        return value
    }
}
