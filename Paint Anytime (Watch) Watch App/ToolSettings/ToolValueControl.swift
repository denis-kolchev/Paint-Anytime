import SwiftUI

struct ToolValueControl: View {
    static let idealSize = CGSize(width: 40, height: 112)
    static let minimumHeight: CGFloat = 72
    @Binding var value: Double
    let range: ClosedRange<Double>
    let valueTitle: String
    let title: String
    let isEnabled: Bool

    var body: some View {
        GeometryReader { geometry in
            let metrics = ToolValueControlMetrics(availableHeight: geometry.size.height)
            VStack(spacing: metrics.spacing) {

                Button {
                    adjust(by: 1)
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 40, height: metrics.buttonHeight)
                        .contentShape(Rectangle())
                }
                .disabled(!isEnabled || value >= range.upperBound)

                Text(valueTitle)
                    .font(.caption2)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: 40, height: metrics.valueHeight)
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
                        .frame(width: 40, height: metrics.buttonHeight)
                        .contentShape(Rectangle())
                }
                .disabled(!isEnabled || value <= range.lowerBound)

            }
            .frame(width: geometry.size.width, height: geometry.size.height)
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

/// One continuous rule for every viewport, independent of device or tutorial.
nonisolated struct ToolValueControlMetrics {
    let spacing: CGFloat
    let buttonHeight: CGFloat
    let valueHeight: CGFloat

    init(availableHeight: CGFloat) {
        let height = min(112, max(0, availableHeight))
        spacing = min(8, max(0, (height - 96) / 2))
        // Remove gaps first, then unused room around the glyphs and value.
        let compression = min(1, max(0, (96 - height) / 24))
        let emergencyScale = min(1, height / 72)
        buttonHeight = (30 - 4 * compression) * emergencyScale
        valueHeight = (36 - 16 * compression) * emergencyScale
    }
}
