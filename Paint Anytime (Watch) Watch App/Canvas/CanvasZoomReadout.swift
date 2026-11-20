import SwiftUI

/// The canvas zoom shown while the Crown changes it, hidden shortly after it settles.
/// Only the status overlay observes it, so a Crown detent never re-evaluates the
/// canvas screen.
@MainActor @Observable
final class CanvasZoomReadout {
    private(set) var percent: Int?
    private var hideTask: Task<Void, Never>?

    func show(_ zoom: Double) {
        let value = Int((zoom * 100).rounded())
        if percent != value { percent = value }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            self?.percent = nil
        }
    }
}

/// Zoom percent in the same capsule as the autosave countdown.
struct CanvasZoomLabel: View {
    let percent: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "plus.magnifyingglass")
                .accessibilityHidden(true)
            Text(verbatim: "\(percent)%")
                .monospacedDigit()
                .fixedSize()
        }
        .font(.caption2)
        .foregroundStyle(.primary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.format("Zoom %d percent", percent))
        .allowsHitTesting(false)
    }
}
