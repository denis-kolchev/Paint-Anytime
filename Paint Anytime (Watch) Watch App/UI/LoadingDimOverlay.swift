import SwiftUI

/// Dimmed backdrop with a white spinner. Shared by opening a gallery drawing
/// and by explicit Save so both loading states look identical. Once a long save has
/// an estimate, the spinner gives way to a progress bar at the same center, with the
/// time left below it: one indicator at a time.
struct LoadingDimOverlay: View {
    var progress: SaveProgressModel? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Only `isShown` is read here: the per-update values redraw `SaveTimeLeftView` alone.
        let showsTime = progress?.isShown == true
        ZStack {
            Color.black.opacity(0.3)
            ZStack {
                if showsTime, let progress {
                    SaveTimeLeftView(progress: progress)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.4)))
                } else {
                    ProgressView().tint(.white)
                        .fixedSize()
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.4)))
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: showsTime)
        }
        .contentShape(Rectangle())
    }
}

/// A solid bar filling as the save's estimated time passes, centered where the spinner
/// was, and the time left below it (an overlay, so the bar itself stays centered).
/// Reads the model here, so its updates redraw only this view.
struct SaveTimeLeftView: View {
    let progress: SaveProgressModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let fraction = progress.fraction ?? 0
        let remaining = progress.remaining
        SaveProgressBar(fraction: fraction)
            .frame(width: 110, height: 6)
            .overlay(alignment: .top) {
                Text(verbatim: remaining.map { SaveDurationText.short($0) } ?? " ")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
                    .contentTransition(.numericText(countsDown: true))
                    .fixedSize()
                    .offset(y: 12)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: fraction)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("Saving…"))
            .accessibilityValue(remaining.map { SaveDurationText.spoken($0) } ?? "")
    }
}

/// A rounded track with a solid fill from the leading edge.
struct SaveProgressBar: View {
    let fraction: Double
    var tint: Color = .white

    var body: some View {
        GeometryReader { geometry in
            Capsule()
                .fill(tint.opacity(0.25))
                .overlay(alignment: .leading) {
                    Capsule().fill(tint)
                        .frame(width: geometry.size.width * min(1, max(0, fraction)))
                }
        }
        .accessibilityHidden(true)
    }
}

/// Durations in the app's language: "5 s", "1 min 20 s" (narrow) and the full words
/// for VoiceOver. Whole seconds; under one second reads as one.
enum SaveDurationText {
    private static var locale: Locale { Locale(identifier: AppLanguage.currentCode) }

    private static func rounded(_ seconds: Double) -> Duration {
        .seconds(max(1, Int(seconds.rounded(.up))))
    }

    static func short(_ seconds: Double) -> String {
        rounded(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .narrow).locale(locale))
    }

    static func spoken(_ seconds: Double) -> String {
        rounded(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .wide).locale(locale))
    }
}
