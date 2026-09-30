import SwiftUI

struct ToolEraserModePicker: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var choiceAnimation: Animation? { reduceMotion ? nil : .easeOut(duration: 0.18) }
    let selectedMode: EraserMode
    let isEnabled: Bool
    var isCompact = false
    let onSelect: (EraserMode) -> Void

    var body: some View {
        VStack(spacing: isCompact ? 2 : 8) {
            ForEach(EraserMode.allCases, id: \.rawValue) { mode in
                Button {
                    onSelect(mode)
                } label: {
                    Image(systemName: mode == .pixels ? "square.grid.3x3.fill" : "scribble")
                        .frame(width: 36, height: isCompact ? 24 : 36)
                        .background(selectedMode == mode
                                    ? Color.white.opacity(0.2) : .clear, in: Circle())
                        .scaleEffect(reduceMotion ? 1 : selectedMode == mode ? 1 : 0.75)
                }
                .buttonStyle(.borderless)
                .disabled(!isEnabled)
                .accessibilityLabel(mode.title)
                .accessibilityAddTraits(selectedMode == mode ? [.isSelected] : [])
            }
        }
        .animation(choiceAnimation, value: selectedMode)
    }
}
