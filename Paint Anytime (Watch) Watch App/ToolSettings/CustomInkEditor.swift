import SwiftUI

struct CustomInkEditor: View {
    var initialColor: SIMD4<Float>? = nil
    var saveTitle = "Add color"
    var dismissesOnSave = true
    @ObservedObject var tutorial = TutorialSession.inactive
    @State private var acceptsColorChanges = false
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rgb = [128.0, 128.0, 128.0]
    @State private var hsb = [0.0, 0.0, 128.0 / 255 * 100]
    @State private var page = 0
    let onSave: (InkPreset) -> Void

    private var hex: String {
        String(format: "#%02X%02X%02X", Int(rgb[0].rounded()), Int(rgb[1].rounded()), Int(rgb[2].rounded()))
    }
    private var colorName: String { NamedInkColors.name(forHex: hex) ?? hex }

    private var rgbBinding: Binding<[Double]> {
        Binding { rgb } set: { values in
            let changed = values != rgb
            rgb = values
            let r = values[0] / 255, g = values[1] / 255, b = values[2] / 255
            let high = max(r, g, b), low = min(r, g, b), delta = high - low
            // Retain hue for gray and hue/saturation for black so they can be restored.
            if delta > 0 {
                let sector = high == r ? (g - b) / delta : high == g ? (b - r) / delta + 2 : (r - g) / delta + 4
                hsb[0] = (sector * 60 + 360).truncatingRemainder(dividingBy: 360)
            }
            if high > 0 { hsb[1] = delta / high * 100 }
            hsb[2] = high * 100
            if changed && acceptsColorChanges { tutorial.record(.adjustedColor) }
        }
    }
    private var hsbBinding: Binding<[Double]> {
        Binding { hsb } set: { values in
            let changed = values != hsb
            hsb = values
            let h = values[0] / 60, s = values[1] / 100, v = values[2] / 100
            let c = v * s, x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)), m = v - c
            let components: [Double]
            switch Int(h) % 6 {
            case 0: components = [c, x, 0]
            case 1: components = [x, c, 0]
            case 2: components = [0, c, x]
            case 3: components = [0, x, c]
            case 4: components = [x, 0, c]
            default: components = [c, 0, x]
            }
            rgb = components.map { min(255, max(0, ($0 + m) * 255)) }
            if changed && acceptsColorChanges { tutorial.record(.adjustedColor) }
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                // Keep both pages in this exact viewport. A watchOS page-style
                // TabView adds its own safe-area layout and can crop the last row.
                HStack(spacing: 0) {
                    InkComponentsEditor(values: hsbBinding, isHue: true, isActive: page == 0)
                        .environment(\.layoutDirection, layoutDirection)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .accessibilityHidden(page != 0)
                    InkComponentsEditor(values: rgbBinding, isHue: false, isActive: page == 1)
                        .environment(\.layoutDirection, layoutDirection)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .accessibilityHidden(page != 1)
                }
                .environment(\.layoutDirection, .leftToRight)
                .offset(x: -CGFloat(page) * geometry.size.width)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
                .clipped()
                .contentShape(Rectangle())

            }
            Text(colorName)
                .font(.caption2.monospaced())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 8)
            schemeCarousel
                .frame(height: 24)
        }
        .onAppear {
            if let c = initialColor { rgbBinding.wrappedValue = [Double(c.x) * 255, Double(c.y) * 255, Double(c.z) * 255] }
            acceptsColorChanges = true
        }
        .padding(.bottom, 8)
        // Use the empty space below the clock in tutorial color lessons.
        // Move the editor content together; the native toolbar stays in place.
        .offset(y: tutorial.isActive ? -20 : 0)
        .navigationBarBackButtonHidden(tutorial.isActive)
        .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    guard tutorial.permits([.savePaletteColor]) else { return }
                    onSave(InkPreset(customID: UUID().uuidString, nameKey: colorName,
                                     rgba: SIMD4(Float(rgb[0] / 255), Float(rgb[1] / 255), Float(rgb[2] / 255), 1)))
                    if dismissesOnSave { dismiss() }
                } label: {
                    Image(systemName: "checkmark")
                        .tutorialHint(tutorial, steps: [.savePaletteColor])
                }
                .watchToolbarButtonStyle(usesCanvasMaterial: tutorial.isActive)
                .opacity(tutorial.permits([.savePaletteColor]) ? 1 : 0)
                .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3),
                           value: tutorial.permits([.savePaletteColor]))
                .disabled(!tutorial.permits([.savePaletteColor]))
                .accessibilityHidden(!tutorial.permits([.savePaletteColor]))
                .accessibilityLabel(L10n.text(saveTitle))
            }
        }
    }

    private var schemeCarousel: some View {
        GeometryReader { geometry in
            let itemWidth: CGFloat = 60
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        schemeButton("HSB", page: 0)
                        schemeButton("RGB", page: 1)
                    }
                    .padding(.horizontal, max(0, (geometry.size.width - itemWidth) / 2))
                }
                .scrollIndicators(.hidden)
                .scrollDisabled(true)
                .onAppear { proxy.scrollTo(page, anchor: .center) }
                .onChange(of: geometry.size.width) { _, _ in
                    proxy.scrollTo(page, anchor: .center)
                }
                .onChange(of: page) { _, target in
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { value in
            guard abs(value.translation.width) > abs(value.translation.height) else { return }
            let forward = layoutDirection == .rightToLeft
                ? value.translation.width > 0 : value.translation.width < 0
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                page = min(1, max(0, page + (forward ? 1 : -1)))
            }
        })
    }

    private func schemeButton(_ title: String, page target: Int) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { page = target }
        } label: {
            Text(title)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(page == target ? .primary : .secondary)
                .frame(width: 60, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityAddTraits(page == target ? [.isSelected] : [])
        .id(target)
    }

}
