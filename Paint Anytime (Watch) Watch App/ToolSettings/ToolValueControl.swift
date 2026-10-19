import SwiftUI

struct ToolValueControl: View {
    static let idealSize = CGSize(width: 40, height: 112)
    @Binding var value: Double
    let range: ClosedRange<Double>
    let valueTitle: String
    let title: String
    let isEnabled: Bool

    var body: some View {
        VStack(spacing: 8) {

            Button {
                adjust(by: 1)
            } label: {
                Image(systemName: "plus")
                    .frame(width: 40, height: 30)
                    .contentShape(Rectangle())
            }
            .disabled(!isEnabled || value >= range.upperBound)


            Text(valueTitle)
                .font(.caption2)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 40, height: 36)
                .accessibilityLabel(title)
                .accessibilityValue(valueTitle)
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: adjust(by: 1)
                    case .decrement: adjust(by: -1)
                    @unknown default: break
                    }
                }


            Button {
                adjust(by: -1)
            } label: {
                Image(systemName: "minus")
                    .frame(width: 40, height: 30)
                    .contentShape(Rectangle())
            }
            .disabled(!isEnabled || value <= range.lowerBound)

        }
        .frame(width: Self.idealSize.width)
        .buttonStyle(.borderless)
        .buttonRepeatBehavior(.enabled)
    }

    private func adjust(by delta: Double) {
        guard isEnabled else { return }
        value = min(range.upperBound, max(range.lowerBound, value.rounded() + delta))
    }
}
