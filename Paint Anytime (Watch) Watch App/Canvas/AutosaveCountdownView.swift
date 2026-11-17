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
                    Image(systemName: "clock.arrow.circlepath")
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

/// Places the countdown centered horizontally, level with the top buttons: the same
/// native toolbar anchors the top custom controls use, so it lines up with both.
struct AutosaveCountdownOverlay: View {
    let autosave: CanvasAutosave
    let regions: CanvasControlRegions

    var body: some View {
        if let timerRange = autosave.timerRange {
            GeometryReader { overlay in
                let frame = overlay.frame(in: .global)
                AutosaveCountdownView(timerRange: timerRange, isSaving: autosave.isSaving)
                    .position(x: overlay.size.width / 2, y: centerY(in: frame))
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    /// Vertical center of the top buttons in the overlay's coordinates.
    private func centerY(in frame: CGRect) -> CGFloat {
        for control in [CanvasToolbarControl.tools, .more] {
            // Anchors persist after their item leaves, so accept only an on-screen one
            // in the top half, as the custom controls do.
            if let anchor = regions.toolbarAnchors[control], !anchor.isEmpty,
               anchor.midY > frame.minY, anchor.midY < frame.midY {
                return anchor.midY - frame.minY
            }
        }
        // The custom controls' fallback before the native toolbar is measured.
        let geometry = MorphPanelGeometry(size: frame.size, layoutDirection: .leftToRight)
        let canvasTop = regions.screenBounds.isNull ? frame.minY : regions.screenBounds.minY
        return canvasTop + geometry.top + 18 - frame.minY
    }
}
