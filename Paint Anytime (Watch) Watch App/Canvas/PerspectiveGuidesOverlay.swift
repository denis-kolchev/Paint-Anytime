import SwiftUI

/// Draws perspective guides across the whole viewport, including beyond the paper.
/// Value-only inputs let SwiftUI skip redrawing while a stroke updates the canvas.
struct PerspectiveGuidesOverlay: View {
    let layout: PerspectiveGuideLayout
    let canvasToScreen: CGAffineTransform
    let activeRuler: PerspectiveGuideLine?
    let showsHandles: Bool

    private static let horizonColor = Color(red: 1, green: 0.62, blue: 0.2)
    private static let handleColor = Color(red: 0.16, green: 0.67, blue: 0.87)

    var body: some View {
        Canvas { context, size in
            // Long enough to leave any viewport at every zoom level.
            let reach = 2 * (size.width + size.height)
            var horizon = Path()
            var vanishing = Path()
            for line in layout.lines {
                let segment = screenSegment(line, reach: reach)
                if line.kind == .horizon { horizon.addLines(segment) } else { vanishing.addLines(segment) }
            }
            context.stroke(vanishing, with: .color(.black.opacity(0.3)), lineWidth: 2)
            context.stroke(vanishing, with: .color(.white.opacity(0.55)), lineWidth: 0.75)
            context.stroke(horizon, with: .color(.black.opacity(0.35)), lineWidth: 3)
            context.stroke(horizon, with: .color(Self.horizonColor), lineWidth: 1.5)
            if let activeRuler {
                var ruler = Path()
                ruler.addLines(screenSegment(activeRuler, reach: reach))
                context.stroke(ruler, with: .color(Self.handleColor), lineWidth: 1.5)
            }
            for point in layout.vanishingPoints {
                let screen = point.applying(canvasToScreen)
                let marker = Path(ellipseIn: CGRect(x: screen.x - 3, y: screen.y - 3, width: 6, height: 6))
                context.fill(marker, with: .color(Self.horizonColor))
                context.stroke(marker, with: .color(.white), lineWidth: 1)
            }
        }
        .overlay {
            if showsHandles {
                let handles = layout.handles(canvasToScreen)
                handle("arrow.up.and.down.and.arrow.left.and.right").position(handles.move)
                handle("arrow.clockwise").position(handles.rotate)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func screenSegment(_ line: PerspectiveGuideLine, reach: CGFloat) -> [CGPoint] {
        let start = line.point.applying(canvasToScreen)
        let back = line.isRay ? 0 : reach
        return [CGPoint(x: start.x - line.direction.x * back, y: start.y - line.direction.y * back),
                CGPoint(x: start.x + line.direction.x * reach, y: start.y + line.direction.y * reach)]
    }

    private func handle(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Self.handleColor, in: Circle())
            .overlay { Circle().strokeBorder(.white, lineWidth: 1) }
            .rotationEffect(.radians(layout.rotation))
    }
}
