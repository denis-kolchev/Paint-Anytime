import SwiftUI

struct ToolDirectionControl: View {
    // Two 30 pt buttons, the 36 pt angle indicator, and two 8 pt gaps.
    static let idealSize = CGSize(width: 40, height: 112)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var choiceAnimation: Animation? { reduceMotion ? nil : .easeOut(duration: 0.18) }
    let angle: Float
    let isEnabled: Bool
    let onAdjust: (Float) -> Void

    var body: some View {
        VStack(spacing: 8) {
            Button {
                onAdjust(5)
            } label: {
                Image(systemName: "rotate.right")
                    .frame(width: 40, height: 30)
                    .contentShape(Rectangle())
            }
            .disabled(angle >= 90 || !isEnabled)
            .accessibilityLabel(L10n.text("Rotate tip clockwise"))

            Circle()
                .strokeBorder(.secondary, lineWidth: 1)
                .frame(width: 36, height: 36)
                .overlay {
                    Capsule()
                        .fill(.primary)
                        .frame(width: 26, height: 4)
                        .rotationEffect(.degrees(Double(angle)))
                }
                .animation(choiceAnimation, value: angle)
                .accessibilityLabel(L10n.text("Tip direction"))
                .accessibilityValue(L10n.format("%d degrees", Int(angle)))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: onAdjust(5)
                    case .decrement: onAdjust(-5)
                    @unknown default: break
                    }
                }

            Button {
                onAdjust(-5)
            } label: {
                Image(systemName: "rotate.left")
                    .frame(width: 40, height: 30)
                    .contentShape(Rectangle())
            }
            .disabled(angle <= -90 || !isEnabled)
            .accessibilityLabel(L10n.text("Rotate tip counterclockwise"))
        }
        .buttonStyle(.borderless)
    }
}
