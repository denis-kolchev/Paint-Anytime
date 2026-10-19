import SwiftUI

struct ToolFillToleranceControl: View {
    static let idealSize = ToolDirectionControl.idealSize
    @Binding var value: Double
    let isEnabled: Bool

    var body: some View {
        GeometryReader { geometry in
            let travel = max(1, geometry.size.height - 22)
            let fraction = min(1, max(0, value / 100))
            ZStack(alignment: .top) {
                Capsule()
                    .fill(.secondary.opacity(0.35))
                    .frame(width: 4, height: travel)
                    .offset(y: 11)
                Capsule()
                    .fill(.primary)
                    .frame(width: 4, height: travel * fraction)
                    .offset(y: 11 + travel * (1 - fraction))
                Circle()
                    .fill(.primary)
                    .frame(width: 22, height: 22)
                    .offset(y: travel * (1 - fraction))
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                guard isEnabled else { return }
                value = Double(min(100, max(0, (100 * (1 - (gesture.location.y - 11) / travel)).rounded())))
            })
        }
        .frame(width: Self.idealSize.width)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("Sensitivity"))
        .accessibilityValue(L10n.percent(value / 100))
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            switch direction {
            case .increment: value = min(100, value + 1)
            case .decrement: value = max(0, value - 1)
            @unknown default: break
            }
        }
    }
}
