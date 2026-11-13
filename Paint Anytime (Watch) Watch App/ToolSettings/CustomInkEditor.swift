import SwiftUI

struct CustomInkEditor: View {
    var initialColor: SIMD4<Float>? = nil
    var saveTitle = "Add color"
    var dismissesOnSave = true
    /// Supplies the canvas for the eyedropper. Without it the editor has no eyedropper.
    var eyedropperController: CanvasController? = nil
    /// With a palette the checkmark corner opens its colors instead: a swatch is
    /// confirmed there, and the wheel's own color is kept on Back.
    var palette: InkPalette? = nil
    @ObservedObject var tutorial = TutorialSession.inactive
    @State private var showsPaletteList = false
    @State private var paletteSelectionID: String?
    @State private var initialRGB: [Double]?
    /// Set once a color is handed back, so leaving does not save it again.
    @State private var finished = false
    @State private var acceptsColorChanges = false
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.tutorialHintReservedHeight) private var tutorialHintReservedHeight
    /// Global frames of the tutorial's top corner buttons, which the wheel must clear.
    @State private var topButtonFrames: [Int: CGRect] = [:]
    /// The wheel's frame from the color steps, kept while the lesson moves on.
    @State private var heldWheelBand: CGRect?
    @State private var rgb = [128.0, 128.0, 128.0]
    @State private var hsb = [0.0, 0.0, (128.0 / 255 * 100).rounded()]
    /// 0 the color wheel, 1 HSB, 2 RGB. Every editor, the tutorial's too, opens on the wheel.
    @State private var pageSelection: Int?
    @State private var showsEyedropper = false
    private var page: Int { pageSelection ?? 0 }
    private static let lastPage = 2
    let onSave: (InkPreset) -> Void

    /// Where adding a color starts when nothing was sampled.
    static let newColor = SIMD4<Float>(1, 1, 1, 1)

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
            // Whole steps, as the sliders and the Crown use. A fractional value
            // would be snapped by the next page's Crown and nudge the color.
            if delta > 0 {
                let sector = high == r ? (g - b) / delta : high == g ? (b - r) / delta + 2 : (r - g) / delta + 4
                hsb[0] = (sector * 60 + 360).rounded().truncatingRemainder(dividingBy: 360)
            }
            if high > 0 { hsb[1] = (delta / high * 100).rounded() }
            hsb[2] = (high * 100).rounded()
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
            rgb = components.map { min(255, max(0, (($0 + m) * 255).rounded())) }
            if changed && acceptsColorChanges { tutorial.record(.adjustedColor) }
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                // Keep both pages in this exact viewport. A watchOS page-style
                // TabView adds its own safe-area layout and can crop the last row.
                HStack(spacing: 0) {
                    // The wheel is laid out against the whole screen in an overlay;
                    // this slot only keeps the pages in order.
                    Color.clear
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    InkComponentsEditor(values: hsbBinding, isHue: true, isActive: page == 1)
                        .environment(\.layoutDirection, layoutDirection)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .accessibilityHidden(page != 1)
                    InkComponentsEditor(values: rgbBinding, isHue: false, isActive: page == 2)
                        .environment(\.layoutDirection, layoutDirection)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .accessibilityHidden(page != 2)
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
                // The wheel's lower rim reaches this line.
                .opacity(page == 0 ? 0 : 1)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: page)
            schemeCarousel
                .frame(height: 24)
        }
        // The palette list replaces the pages in place; nothing covers them.
        .opacity(showsPaletteList ? 0 : 1)
        .allowsHitTesting(!showsPaletteList)
        .accessibilityHidden(showsPaletteList)
        .onAppear {
            // A new color starts from white unless the eyedropper supplied one.
            // White is the wheel's centre at full brightness, so the wheel is never dimmed.
            let c = initialColor ?? Self.newColor
            rgbBinding.wrappedValue = [Double(c.x) * 255, Double(c.y) * 255, Double(c.z) * 255].map { $0.rounded() }
            if initialRGB == nil { initialRGB = rgb }
            acceptsColorChanges = true
        }
        .onDisappear {
            // Back saves before the pop starts. This only catches other ways out,
            // which report after their animation. The eyedropper's cover is not a departure.
            guard !showsEyedropper else { return }
            saveWheelColorIfChanged()
        }
        .padding(.bottom, 8)
        // Use the empty space below the clock in tutorial color lessons.
        // Move the editor content together; the native toolbar stays in place.
        .offset(y: tutorial.isActive ? -20 : 0)
        // With a palette our own Back saves the color as it is tapped; the
        // system one only reports after the pop, so the paper changed late.
        .navigationBarBackButtonHidden(tutorial.isActive || palette != nil)
        .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
        .overlay {
            // Spans the whole screen at rest. Only its size is used, never its
            // position, so navigation and dismissal animations carry the wheel
            // along instead of holding it at the screen centre.
            GeometryReader { geometry in
                let liveBand = wheelBand(in: geometry)
                let band = holdsWheelBand ? (heldWheelBand ?? liveBand) : liveBand
                ColorWheelEditor(values: hsbBinding, isActive: page == 0 && !showsEyedropper && !showsPaletteList,
                                 size: band.size)
                    .offset(x: -CGFloat(page) * geometry.size.width, y: band.minY)
                    .opacity(page == 0 && !showsPaletteList ? 1 : 0)
                    .scaleEffect(showsPaletteList && !reduceMotion ? 0.9 : 1)
                    .allowsHitTesting(page == 0 && !showsPaletteList)
                    .accessibilityHidden(page != 0)
                    .onChange(of: liveBand, initial: true) { _, rect in
                        if !holdsWheelBand { heldWheelBand = rect }
                    }
            }
            .ignoresSafeArea()
        }
        .overlay {
            // Above the wheel, which is laid out against the whole screen.
            if showsPaletteList, let palette {
                PaletteColorList(palette: palette, selectionID: $paletteSelectionID)
                    // Grows out of the shrinking wheel; no backdrop of its own,
                    // so no rectangle edge shows during the cross-fade.
                    .transition(reduceMotion ? .opacity
                                : .opacity.combined(with: .scale(scale: 1.08)))
            }
        }
        .fullScreenCover(isPresented: $showsEyedropper) {
            if let controller = eyedropperController {
                PaletteEyedropperView(controller: controller, onCancel: {
                    showsEyedropper = false
                }) { color in
                    rgbBinding.wrappedValue = [Double(color.x) * 255, Double(color.y) * 255,
                                               Double(color.z) * 255].map { $0.rounded() }
                    showsEyedropper = false
                }
            }
        }
        .toolbar {
            if palette != nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        if showsPaletteList {
                            setPaletteListShown(false)
                        } else {
                            saveWheelColorIfChanged()
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "chevron.backward")
                    }
                    .accessibilityLabel(L10n.text("Back"))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        if showsPaletteList { confirmPaletteColor() } else { setPaletteListShown(true) }
                    } label: {
                        ZStack {
                            CurrentPaletteIcon()
                                .opacity(showsPaletteList ? 0 : 1)
                                .scaleEffect(reduceMotion || !showsPaletteList ? 1 : 0.6)
                            Image(systemName: "checkmark")
                                .opacity(showsPaletteList ? 1 : 0)
                                .scaleEffect(reduceMotion || showsPaletteList ? 1 : 0.6)
                        }
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: showsPaletteList)
                    }
                    .watchToolbarButtonStyle()
                    .disabled(showsPaletteList && selectedPaletteColor == nil)
                    .accessibilityLabel(L10n.text(showsPaletteList ? saveTitle : "Current palette"))
                }
            } else {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        guard tutorial.permits([.savePaletteColor]) else { return }
                        onSave(currentPreset)
                        if dismissesOnSave { dismiss() }
                    } label: {
                        Image(systemName: "checkmark")
                            .tutorialHint(tutorial, steps: [.savePaletteColor])
                    }
                    .watchToolbarButtonStyle(usesCanvasMaterial: tutorial.isActive)
                    .modifier(TopButtonFrame(id: 1, isTracked: tutorial.isActive, frames: $topButtonFrames))
                    .opacity(tutorial.permits([.savePaletteColor]) ? 1 : 0)
                    .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3),
                               value: tutorial.permits([.savePaletteColor]))
                    .disabled(!tutorial.permits([.savePaletteColor]))
                    .accessibilityHidden(!tutorial.permits([.savePaletteColor]))
                    .accessibilityLabel(L10n.text(saveTitle))
                }
            }
            if eyedropperController != nil && tutorial.isActive && palette == nil {
                // The lesson card covers the bottom corners, and the tutorial hides
                // Back, so the eyedropper takes the free leading slot at the top.
                // Always installed so the slot stays occupied; hidden until the lesson allows it.
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        guard tutorial.permits(Self.tutorialEyedropperSteps) else { return }
                        showsEyedropper = true
                    } label: {
                        Image(systemName: "eyedropper")
                    }
                    .watchToolbarButtonStyle(usesCanvasMaterial: true)
                    .modifier(TopButtonFrame(id: 0, isTracked: true, frames: $topButtonFrames))
                    .opacity(tutorial.permits(Self.tutorialEyedropperSteps) ? 1 : 0)
                    .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3),
                               value: tutorial.permits(Self.tutorialEyedropperSteps))
                    .disabled(!tutorial.permits(Self.tutorialEyedropperSteps))
                    .accessibilityHidden(!tutorial.permits(Self.tutorialEyedropperSteps))
                    .accessibilityLabel(L10n.text("Eyedropper"))
                }
            } else if eyedropperController != nil {
                // A native bottom-bar item gets the same size, glass and corner
                // insets as Back and the checkmark above it.
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { showsEyedropper = true } label: {
                        Image(systemName: "eyedropper")
                    }
                    .watchToolbarButtonStyle()
                    .accessibilityLabel(L10n.text("Eyedropper"))
                    // Stays installed on every page so the bar does not relayout;
                    // the HSB and RGB pages put the "Wheel" label in this corner.
                    // The palette list hides it too.
                    .opacity(page == 0 && !showsPaletteList ? 1 : 0)
                    .allowsHitTesting(page == 0 && !showsPaletteList)
                    .accessibilityHidden(page != 0 || showsPaletteList)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: page)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: showsPaletteList)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private static let tutorialEyedropperSteps: Set<TutorialStep> = [.adjustPaletteColor, .savePaletteColor]

    /// After ✓ the lesson moves on while the editor fades out. The next card's
    /// height would resize the wheel mid-fade, so it keeps its last lesson frame.
    private var holdsWheelBand: Bool {
        tutorial.isActive && !Self.tutorialEyedropperSteps.contains(tutorial.step)
    }

    /// Where the wheel is centred, in the full-screen overlay. Outside the tutorial
    /// it is the whole screen; only its size is used there, so navigation carries the wheel.
    /// In the tutorial the lesson card covers the bottom, so the wheel sits just above it
    /// and grows up into the top safe area, as large as it can be without reaching
    /// the toolbar buttons in the top corners.
    private func wheelBand(in geometry: GeometryProxy) -> CGRect {
        let full = CGRect(origin: .zero, size: geometry.size)
        let width = geometry.size.width
        // Room under the rim for the thumb when saturation is full.
        let bottom = geometry.size.height - tutorialHintReservedHeight - 10
        guard tutorial.isActive, bottom > 0 else { return full }
        let origin = geometry.frame(in: .global).origin
        let buttons = topButtonFrames.values.map { frame in
            (center: CGPoint(x: frame.midX - origin.x, y: frame.midY - origin.y),
             radius: min(frame.width, frame.height) / 2)
        }
        // Brightness arc: its ends lie this far out, 35° above the horizontal.
        let arcAngle = 35 * CGFloat.pi / 180
        func fits(_ radius: CGFloat) -> Bool {
            let center = CGPoint(x: width / 2, y: bottom - radius)
            guard center.y - radius >= 0 else { return false }
            let arcRadius = radius + 9
            let arcEnds = [-1, 1].map { side in
                CGPoint(x: center.x + CGFloat(side) * cos(arcAngle) * arcRadius,
                        y: center.y - sin(arcAngle) * arcRadius)
            }
            return buttons.allSatisfy { button in
                hypot(center.x - button.center.x, center.y - button.center.y) >= radius + button.radius + 4
                    && arcEnds.allSatisfy { end in
                        hypot(end.x - button.center.x, end.y - button.center.y) >= button.radius + 4
                    }
            }
        }
        // The largest fitting radius, never past the full-screen wheel's size.
        var low: CGFloat = 0, high = width * 0.4
        if fits(high) { low = high } else {
            for _ in 0..<12 {
                let middle = (low + high) / 2
                if fits(middle) { low = middle } else { high = middle }
            }
        }
        guard low > 20 else { return full }
        // The wheel takes 0.9 of the band's height, so this band yields exactly 2 × low.
        let height = 2 * low / 0.9
        return CGRect(x: 0, y: bottom - low - height / 2, width: width, height: height)
    }

    private var currentPreset: InkPreset {
        InkPreset(customID: UUID().uuidString, nameKey: colorName,
                  rgba: SIMD4(Float(rgb[0] / 255), Float(rgb[1] / 255), Float(rgb[2] / 255), 1))
    }

    private var selectedPaletteColor: InkPreset? {
        palette?.allColors.first { $0.id == paletteSelectionID }
    }

    private func setPaletteListShown(_ shown: Bool) {
        if shown, let palette {
            // Start on the swatch matching the current color, if there is one.
            let current = SIMD3(Float(rgb[0] / 255), Float(rgb[1] / 255), Float(rgb[2] / 255))
            paletteSelectionID = palette.allColors.first { preset in
                let c = SIMD3(preset.rgba.x, preset.rgba.y, preset.rgba.z)
                return ((c - current) * (c - current)).sum() < 1e-5
            }?.id
        }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.86)) {
            showsPaletteList = shown
        }
    }

    /// Hands back the wheel's color once, and only if it was changed.
    private func saveWheelColorIfChanged() {
        guard palette != nil, !finished, let initialRGB, rgb != initialRGB else { return }
        finished = true
        onSave(currentPreset)
    }

    private func confirmPaletteColor() {
        guard let preset = selectedPaletteColor else { return }
        finished = true
        onSave(preset)
        dismiss()
    }

    private var schemeCarousel: some View {
        GeometryReader { geometry in
            let itemWidth: CGFloat = 60
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        schemeButton("Wheel", page: 0)
                        schemeButton("HSB", page: 1)
                        schemeButton("RGB", page: 2)
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
                pageSelection = min(Self.lastPage, max(0, page + (forward ? 1 : -1)))
            }
        })
    }

    private func schemeButton(_ title: String, page target: Int) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { pageSelection = target }
        } label: {
            Text(L10n.text(title))
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

/// The current palette's swatches for picking one of them. Unlike the palette
/// editor it selects a single color and changes nothing in the palette.
private struct PaletteColorList: View {
    let palette: InkPalette
    @Binding var selectionID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text(palette.displayTitle)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 16) {
                    ForEach(palette.allColors) { preset in
                        let selected = selectionID == preset.id
                        Button {
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                                selectionID = preset.id
                            }
                        } label: {
                            PaletteSwatchLabel(preset: preset, selected: selected)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(preset.name)
                        .accessibilityAddTraits(selected ? [.isSelected] : [])
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Records a toolbar button's global frame while `isTracked`.
private struct TopButtonFrame: ViewModifier {
    let id: Int
    let isTracked: Bool
    @Binding var frames: [Int: CGRect]

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            guard isTracked, frames[id] != frame else { return }
            frames[id] = frame
        }
    }
}
