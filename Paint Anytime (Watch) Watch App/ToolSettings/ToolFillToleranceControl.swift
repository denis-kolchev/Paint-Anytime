import SwiftUI

struct ToolFillToleranceControl: View {
    static let idealSize = ToolDirectionControl.idealSize
    @Binding var value: Double
    let isEnabled: Bool
    var includesOuterSpacing = false

    var body: some View {
        VStack(spacing: includesOuterSpacing ? 0 : 8) {
            if includesOuterSpacing { Spacer(minLength: 0) }

            Button {
                adjust(by: 1)
            } label: {
                Image(systemName: "plus")
                    .frame(width: 40, height: 30)
                    .contentShape(Rectangle())
            }
            .disabled(!isEnabled || value >= 100)

            if includesOuterSpacing { Spacer(minLength: 0) }

            Text(L10n.percent(value / 100))
                .font(.caption2)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 40, height: 36)
                .accessibilityLabel(L10n.text("Sensitivity"))
                .accessibilityValue(L10n.percent(value / 100))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: adjust(by: 1)
                    case .decrement: adjust(by: -1)
                    @unknown default: break
                    }
                }

            if includesOuterSpacing { Spacer(minLength: 0) }

            Button {
                adjust(by: -1)
            } label: {
                Image(systemName: "minus")
                    .frame(width: 40, height: 30)
                    .contentShape(Rectangle())
            }
            .disabled(!isEnabled || value <= 0)

            if includesOuterSpacing { Spacer(minLength: 0) }
        }
        .frame(width: Self.idealSize.width)
        .buttonStyle(.borderless)
        .buttonRepeatBehavior(.enabled)
    }

    private func adjust(by delta: Double) {
        guard isEnabled else { return }
        value = min(100, max(0, value.rounded() + delta))
    }
}
