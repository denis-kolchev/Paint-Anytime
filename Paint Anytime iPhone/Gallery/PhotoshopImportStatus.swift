import Observation
import SwiftUI

/// A running Photoshop import: its progress for the gallery and the work to cancel.
@MainActor @Observable
final class PhotoshopImportStatus {
    private(set) var fraction = 0.0
    /// The detached conversion; cancelling the task that awaits it would not reach it.
    @ObservationIgnored var work: Task<String?, Error>?

    /// Reports from the conversion arrive out of order; progress only moves forward.
    nonisolated func report(_ value: Double) {
        Task { @MainActor in
            if value > self.fraction { self.fraction = min(1, value) }
        }
    }

    func finish() { fraction = 1 }

    func cancel() { work?.cancel() }
}

/// Progress capsule shown at the bottom of the gallery while a PSD is converted.
struct PhotoshopImportProgressView: View {
    let status: PhotoshopImportStatus

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Importing Photoshop File…")
                    .font(.subheadline.weight(.medium))
                ProgressView(value: status.fraction)
                    .animation(.easeOut(duration: 0.2), value: status.fraction)
            }
            Button(action: status.cancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Cancel"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 360)
        .background(.regularMaterial, in: .rect(cornerRadius: 18))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
        .accessibilityValue(Text(status.fraction, format: .percent.precision(.fractionLength(0))))
    }
}
