import SwiftUI

/// Dimmed backdrop with a white spinner. Shared by opening a gallery drawing
/// and by explicit Save so both loading states look identical. Once a long save has
/// an estimate, the spinner gives way to a progress ring at the same center: the
/// autosave capsule's ring, larger. One indicator at a time, no time text.
struct LoadingDimOverlay: View {
    var progress: SaveProgressModel? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Only `isShown` is read here: the per-update values redraw `SaveProgressRingView` alone.
        let showsProgress = progress?.isShown == true
        ZStack {
            Color.black.opacity(0.3)
            ZStack {
                if showsProgress, let progress {
                    SaveProgressRingView(progress: progress, diameter: 22, lineWidth: 2.6, tint: .white)
                        .accessibilityLabel(L10n.text("Saving…"))
                        .transition(.opacity)
                } else {
                    ProgressView().tint(.white)
                        .fixedSize()
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: showsProgress)
        }
        .contentShape(Rectangle())
    }
}

/// A save's progress as a ring filling clockwise from the top over a faint track:
/// the explicit Save overlay and the autosave capsule draw the same one. Reads the
/// model here, so its updates redraw only the ring. VoiceOver reads the percent.
struct SaveProgressRingView: View {
    let progress: SaveProgressModel
    let diameter: CGFloat
    let lineWidth: CGFloat
    var tint: Color = .primary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let fraction = min(1, max(0, progress.fraction ?? 0))
        ZStack {
            Circle()
                .stroke(tint.opacity(0.3), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: fraction)
        .accessibilityElement(children: .ignore)
        .accessibilityValue(L10n.percent(fraction))
    }
}
