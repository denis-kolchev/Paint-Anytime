import SwiftUI

/// A short, view-only cue; the mask uses the same ink replay as the layer preview.
struct TransparencyBoundaryFeedback: View {
    let layer: CanvasLayer
    let canvasSize: CGSize
    let onFinished: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var boundary: Path?
    @State private var startedAt = Date()
    @State private var finished = false

    var body: some View {
        GeometryReader { geometry in
            if let boundary, !finished {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                    let elapsed = timeline.date.timeIntervalSince(startedAt)
                    let progress = min(1, max(0, elapsed / 1.1))
                    let fade = min(1, elapsed / 0.08) * min(1, (1.3 - elapsed) / 0.25)
                    // Only the paper border is inset; ink uses the full preview coordinates.
                    let inset: CGFloat = layer.locksTransparency ? 0 : 1.5
                    let path = boundary.applying(CGAffineTransform(
                        scaleX: max(0, geometry.size.width - inset * 2),
                        y: max(0, geometry.size.height - inset * 2)))
                        .applying(CGAffineTransform(translationX: inset, y: inset))
                    let highlight = reduceMotion ? path : path.trimmedPath(
                        from: max(0, progress * 1.25 - 0.25), to: min(1, progress * 1.25))
                    ZStack {
                        path.stroke(.cyan.opacity(0.35), lineWidth: 1)
                        highlight.stroke(.cyan, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                            .blur(radius: 3)
                        highlight.stroke(.white, style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                    }
                    .opacity(max(0, fade))
                }
            }
        }
        .task {
            if layer.locksTransparency {
                let strokes = layer.strokes
                let size = canvasSize
                let work = Task.detached(priority: .userInitiated) {
                    TransparencyBoundaryBuilder.inkBoundary(strokes: strokes, size: size)
                }
                let result = await withTaskCancellationHandler {
                    await work.value
                } onCancel: { work.cancel() }
                guard !Task.isCancelled else { return }
                boundary = result
            } else {
                boundary = Path(CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            startedAt = Date()
            do {
                try await Task.sleep(for: .milliseconds(1300))
                finished = true
                onFinished()
            } catch { }
        }
    }
}
