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
    @ObservedObject var tutorial = TutorialSession.inactive
    private var itemCount: Int { presets.count + (includesAddButton ? 1 : 0) }
    let onSelect: (Int) -> Void

    private var rowHeight: CGFloat { 30 }
    private var swatchSize: CGFloat { 22 }
    private var rowStep: CGFloat { rowHeight + 3 }

    /// Rows that can show in the viewport, plus two on each side so a Crown step never
    /// reveals an empty slot. Large palettes otherwise lay out every swatch on each step.
    /// In the tutorial the column shows past the viewport, so every row stays.
    private func visibleIndices(viewportHeight: CGFloat) -> [Int] {
        guard itemCount > 0 else { return [] }
        guard !extendsBeyondViewport else { return Array(0..<itemCount) }
        let reach = Int((viewportHeight / 2 / rowStep).rounded(.up)) + 2
        let lower = max(0, colorIndex - reach)
        let upper = min(itemCount, colorIndex + reach + 1)
        return lower < upper ? Array(lower..<upper) : []
    }

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
                    // Rows sit at fixed positions, so only the window around the choice is built.
                    ZStack(alignment: .top) {
                        ForEach(visibleIndices(viewportHeight: geometry.size.height), id: \.self) { index in
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
                            .offset(y: CGFloat(index) * rowStep)
                        }
                    }
                    .offset(y: (geometry.size.height - rowHeight) / 2
                            - CGFloat(colorIndex) * rowStep)
                    .animation(choiceAnimation, value: colorIndex)
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                .mask {
                    Rectangle()
                        .padding(.vertical, extendsBeyondViewport ? -CGFloat(itemCount) * rowStep : 0)
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
