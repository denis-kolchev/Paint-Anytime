import SwiftUI

struct ToolColorPicker: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var choiceAnimation: Animation? { reduceMotion ? nil : .easeOut(duration: 0.18) }
    let colorIndex: Int
    let isActive: Bool
    let isEnabled: Bool
    let onSelect: (Int) -> Void

    private var rowHeight: CGFloat { 30 }
    private var swatchSize: CGFloat { 22 }

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: "chevron.up")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .opacity(colorIndex > 0 ? 1 : 0.25)
                .accessibilityHidden(true)

            GeometryReader { geometry in
                ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 3) {
                        ForEach(InkPreset.all.indices, id: \.self) { index in
                            Button {
                                onSelect(index)
                            } label: {
                                Circle()
                                    .fill(InkPreset.all[index].color)
                                    .frame(width: swatchSize, height: swatchSize)
                                    .overlay { Circle().strokeBorder(.gray.opacity(0.5), lineWidth: 1) }
                                    .padding(3)
                                    .scaleEffect(reduceMotion ? 1 : !isActive ? 0.35
                                                 : colorIndex == index ? 1 : 0.72)
                                    .animation(choiceAnimation, value: colorIndex)
                                    .frame(width: 40, height: rowHeight)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .disabled(!isEnabled)
                            .accessibilityLabel(InkPreset.all[index].name)
                            .accessibilityAddTraits(colorIndex == index ? [.isSelected] : [])
                            .id(index)
                        }
                    }
                    .padding(.vertical, max(0, (geometry.size.height - rowHeight) / 2))
                }
                .scrollIndicators(.hidden)
                .scrollDisabled(true)
                .overlay(alignment: .center) {
                    // The selection window stays fixed while swatches move beneath it.
                    Circle()
                        .strokeBorder(.white, lineWidth: 2)
                        .frame(width: swatchSize + 6, height: swatchSize + 6)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .onAppear { proxy.scrollTo(colorIndex, anchor: .center) }
                .onChange(of: geometry.size.height) { _, _ in
                    proxy.scrollTo(colorIndex, anchor: .center)
                }
                .onChange(of: colorIndex) { _, index in
                    withAnimation(choiceAnimation) {
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
                }
            }

            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .opacity(colorIndex < InkPreset.all.count - 1 ? 1 : 0.25)
                .accessibilityHidden(true)

            Text("\(colorIndex + 1)/\(InkPreset.all.count)")
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel(L10n.format("Color %d of %d", colorIndex + 1, InkPreset.all.count))
        }
    }
}
