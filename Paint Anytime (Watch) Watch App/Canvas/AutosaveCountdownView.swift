import SwiftUI

struct AutosaveCountdownView: View {
    let timerRange: ClosedRange<Date>
    /// A quiet autosave is writing: the clock icon turns into a loading wheel, and a
    /// long one's wheel into a ring filling with its estimated time.
    var isSaving = false
    var progress: SaveProgressModel? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 3) {
            ZStack {
                if isSaving, let progress, progress.isShown {
                    AutosaveProgressRing(progress: progress)
                        .transition(iconTransition)
                } else if isSaving {
                    AutosaveSpinner()
                        .transition(iconTransition)
                } else {
                    Image(systemName: AutosaveSettings.symbolName)
                        .transition(iconTransition)
                }
            }
            .accessibilityHidden(true)
            Text(timerInterval: timerRange, countsDown: true, showsHours: false)
                .monospacedDigit()
                .fixedSize()
        }
        .font(.caption2)
        .foregroundStyle(.primary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: Capsule())
        .animation(.easeInOut(duration: 0.25), value: isSaving)
        // The wheel turns into the progress ring when the estimate appears.
        .animation(.easeInOut(duration: 0.3), value: progress?.isShown == true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("Autosave"))
        .allowsHitTesting(false)
    }

    private var iconTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.5))
    }
}

/// A small loading wheel the size of the caption icon it replaces.
private struct AutosaveSpinner: View {
    @ScaledMetric(relativeTo: .caption2) private var diameter: CGFloat = 11
    @State private var isSpinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(.primary, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .frame(width: diameter, height: diameter)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: isSpinning)
            .onAppear { isSpinning = true }
    }
}

/// The caption-sized ring of an autosave's progress, replacing the loading wheel once
/// the estimate exists: the explicit Save's ring at the wheel's size and stroke.
private struct AutosaveProgressRing: View {
    let progress: SaveProgressModel
    @ScaledMetric(relativeTo: .caption2) private var diameter: CGFloat = 11

    var body: some View {
        SaveProgressRingView(progress: progress, diameter: diameter, lineWidth: 1.6)
            .accessibilityLabel(L10n.text("Autosaving…"))
    }
}

/// Places the countdown centered horizontally at the hidden system clock's height,
/// and the zoom percent below it while zooming, or at that height without a countdown.
struct CanvasStatusOverlay: View {
    /// Center of the system clock text, in points from the top of the screen.
    private static let clockCenterY: CGFloat = 27
    /// Gap between the countdown and the zoom label below it.
    private static let rowGap: CGFloat = 4
    let autosave: CanvasAutosave
    let showsCountdown: Bool
    let zoom: CanvasZoomReadout
    var autosaveProgress: SaveProgressModel? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Read here, not in the GeometryReader's closure: that closure runs during
        // layout, where an observable read may not be tracked, so the wheel never
        // replaced the clock icon when a save started.
        let isSaving = autosave.isSaving
        let timerRange = showsCountdown ? autosave.timerRange : nil
        let percent = zoom.percent
        GeometryReader { overlay in
            let frame = overlay.frame(in: .global)
            // Fixed screen height of the hidden clock's center (measured on Apple Watch
            // Ultra). Toolbar frames are not used: they differ in the free camera.
            let clockY = Self.clockCenterY - frame.minY
            if let timerRange {
                // Stacked, so no text size makes them overlap. An invisible copy of the
                // label above keeps the countdown itself centered at the clock's height.
                VStack(spacing: Self.rowGap) {
                    if let percent {
                        CanvasZoomLabel(percent: percent)
                            .hidden()
                            .accessibilityHidden(true)
                    }
                    AutosaveCountdownView(timerRange: timerRange, isSaving: isSaving, progress: autosaveProgress)
                    if let percent {
                        CanvasZoomLabel(percent: percent)
                            .transition(.opacity)
                    }
                }
                .fixedSize()
                .position(x: overlay.size.width / 2, y: clockY)
            } else if let percent {
                CanvasZoomLabel(percent: percent)
                    .position(x: overlay.size.width / 2, y: clockY)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: percent == nil)
    }
}
