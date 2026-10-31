import SwiftUI

struct AutosaveCountdownView: View {
    let timerRange: ClosedRange<Date>

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "clock.arrow.circlepath")
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("Autosave"))
        .allowsHitTesting(false)
    }
}
