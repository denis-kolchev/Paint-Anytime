import SwiftUI

struct AutosaveCountdownView: View {
    let timerRange: ClosedRange<Date>
    /// A quiet autosave is writing: the clock icon turns into a loading wheel.
    var isSaving = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 3) {
            ZStack {
                if isSaving {
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

/// Places the countdown centered horizontally at the hidden system clock's height.
struct AutosaveCountdownOverlay: View {
    /// Center of the system clock text, in points from the top of the screen.
    private static let clockCenterY: CGFloat = 27
    let autosave: CanvasAutosave

    var body: some View {
        // Read here, not in the GeometryReader's closure: that closure runs during
        // layout, where an observable read may not be tracked, so the wheel never
        // replaced the clock icon when a save started.
        let isSaving = autosave.isSaving
        if let timerRange = autosave.timerRange {
            GeometryReader { overlay in
                let frame = overlay.frame(in: .global)
                // Fixed screen height of the hidden clock's center (measured on Apple Watch
                // Ultra). Toolbar frames are not used: they differ in the free camera.
                AutosaveCountdownView(timerRange: timerRange, isSaving: isSaving)
                    .position(x: overlay.size.width / 2, y: Self.clockCenterY - frame.minY)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }
}
