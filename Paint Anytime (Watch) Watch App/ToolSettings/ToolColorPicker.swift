import SwiftUI

struct ToolColorPicker: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var choiceAnimation: Animation? { reduceMotion ? nil : .easeOut(duration: 0.18) }
    var presets: [InkPreset] = InkPreset.all
    let colorIndex: Int
    let isActive: Bool
    let isEnabled: Bool
    var extendsBeyondViewport = false
    var showsNavigationHints = true
    var includesAddButton = false
    private var itemCount: Int { presets.count + (includesAddButton ? 1 : 0) }
    let onSelect: (Int) -> Void

    private var rowHeight: CGFloat { 30 }
    private var swatchSize: CGFloat { 22 }

    var body: some View {
        VStack(spacing: 2) {
            if showsNavigationHints {
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .opacity(colorIndex > 0 ? 1 : 0.25)
                    .accessibilityHidden(true)
            }
            GeometryReader { geometry in
                ZStack(alignment: .top) {
                    VStack(spacing: 3) {
                        ForEach(0..<itemCount, id: \.self) { index in
                            Button {
                                onSelect(index)
                            } label: {
                                Circle()
                                    .fill(index < presets.count ? presets[index].color : .gray)
                                    .overlay {
                                        if index == presets.count {
                                            Image(systemName: "plus").font(.system(size: 14, weight: .bold)).foregroundStyle(.black)
                                        }
                                    }
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
                            .accessibilityLabel(index < presets.count ? presets[index].name : L10n.text("Add colors"))
                            .accessibilityAddTraits(colorIndex == index ? [.isSelected] : [])
                            .id(index)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(y: (geometry.size.height - rowHeight) / 2
                            - CGFloat(colorIndex) * (rowHeight + 3))
                    .animation(choiceAnimation, value: colorIndex)
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                .mask {
                    Rectangle()
                        .padding(.vertical, extendsBeyondViewport ? -CGFloat(itemCount) * (rowHeight + 3) : 0)
                }
                .overlay(alignment: .center) {
                    // The selection window stays fixed while swatches move beneath it.
                    Circle()
                        .strokeBorder(.white, lineWidth: 2)
                        .frame(width: swatchSize + 6, height: swatchSize + 6)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }

            if showsNavigationHints {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .opacity(colorIndex < itemCount - 1 ? 1 : 0.25)
                    .accessibilityHidden(true)

                Text("\(colorIndex + 1)/\(itemCount)")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(L10n.format("Color %d of %d", colorIndex + 1, itemCount))
            }
        }
    }
}
