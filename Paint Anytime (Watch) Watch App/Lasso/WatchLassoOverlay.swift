import SwiftUI

struct WatchLassoOverlay: View {
    @ObservedObject var lasso: WatchLassoController
    let canvasToScreen: CGAffineTransform

    var body: some View {
        Canvas { context, _ in
            if !lasso.outline.isEmpty {
                // Only show the finger's trail. Selection calculation closes
                // the contour separately, without drawing a line to its start.
                let path = Path(WatchLassoGeometry.path(lasso.outline, closed: false)).applying(canvasToScreen)
                context.stroke(path, with: .color(.white.opacity(0.8)),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round, dash: [0.1, 4]))
                context.stroke(path, with: .color(.gray),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [0.1, 4]))
            }
            if let bounds = lasso.bounds, !lasso.hidesControls || lasso.activeResizeHandle != nil {
                let orientation = WatchLassoGeometry.rotation(lasso.rotation, around: bounds)
                    .concatenating(canvasToScreen)
                let borderColor = Color(red: 0.20, green: 0.43, blue: 1)
                let handleColor = Color(red: 0.16, green: 0.67, blue: 0.87)
                if !lasso.hidesControls {
                    context.stroke(Path(bounds).applying(orientation), with: .color(borderColor), lineWidth: 1)
                }
                let handles = WatchLassoGeometry.handles(bounds).map { $0.applying(orientation) }
                for index in handles.indices {
                    if let active = lasso.activeResizeHandle, index != active { continue }
                    let point = handles[index]
                    let radius = WatchLassoGeometry.handleRadius
                    let handle = Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                                                      width: radius * 2, height: radius * 2))
                    context.fill(handle, with: .color(handleColor))
                    context.stroke(handle, with: .color(.white), lineWidth: 1)
                }
            }
        }
        .overlay {
            if let bounds = lasso.rotationHandleBounds, !lasso.hidesControls || lasso.isRotating {
                let scale = hypot(canvasToScreen.a, canvasToScreen.b)
                let orientation = WatchLassoGeometry.rotation(lasso.rotation, around: bounds)
                    .concatenating(canvasToScreen)
                let point = WatchLassoGeometry.rotationHandle(bounds,
                    offset: WatchLassoGeometry.rotationHandleOffset / max(scale, 0.001)).applying(orientation)
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Color(red: 0.16, green: 0.67, blue: 0.87), in: Circle())
                    .overlay { Circle().strokeBorder(.white, lineWidth: 1) }
                    .rotationEffect(.radians(Double(lasso.rotation)))
                    .position(point)
            }
        }
        .overlay(alignment: .bottom) {
            if lasso.activeResizeHandle != nil, let bounds = lasso.bounds {
                // Document points, independent of the canvas zoom level.
                Text(verbatim: L10n.format("w: %.0f pt  h: %.0f pt", Double(bounds.width), Double(bounds.height)))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.25), lineWidth: 1) }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
        }
        .overlay { if lasso.isPreparing { ProgressView().tint(.cyan) } }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

}
