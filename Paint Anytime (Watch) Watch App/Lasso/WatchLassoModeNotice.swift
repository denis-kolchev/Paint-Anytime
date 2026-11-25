import SwiftUI

/// Uses the gallery save notice's appearance for both the editor and tutorial.
struct WatchLassoModeNotice: View {
    @ObservedObject var lasso: WatchLassoController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var noticeID: UUID?

    var body: some View {
        ZStack {
            if let noticeID, lasso.isActive {
                VStack(spacing: 3) {
                    Text(L10n.text(lasso.mode.title))
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.5)
                    // Complete strokes needs a first step the other modes do not.
                    if lasso.mode == .sketchAssist {
                        Text(L10n.text("Circle the strokes to redraw"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.6)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 42)
                .id(noticeID)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.85).combined(with: .opacity))
                .task(id: noticeID) {
                    let seconds = lasso.mode == .sketchAssist ? 3.0 : 2.0
                    do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                    withAnimation(.easeOut(duration: 0.2)) { self.noticeID = nil }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .onChange(of: lasso.mode) { _, _ in
            guard lasso.isActive else { return }
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2)
                          : .spring(response: 0.35, dampingFraction: 0.8)) {
                noticeID = UUID()
            }
        }
        .onChange(of: lasso.isActive) { _, active in
            // Opening straight into Complete strokes keeps the mode, so show its hint here.
            noticeID = active && lasso.mode == .sketchAssist ? UUID() : nil
        }
        // The selection brings its own center hint; do not stack two notices.
        .onChange(of: lasso.sketchAssistStage) { _, stage in
            if stage != .idle { noticeID = nil }
        }
    }
}
