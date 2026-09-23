import SwiftUI

private struct InkPreset {
    let name: String
    let rgba: SIMD4<Float>

    var color: Color {
        Color(.sRGB, red: Double(rgba.x), green: Double(rgba.y),
              blue: Double(rgba.z), opacity: Double(rgba.w))
    }

    static var all: [InkPreset] {
        let presets: [InkPreset] = [
            .init(name: L10n.text("Black"), rgba: SIMD4(0, 0, 0, 1)),
            .init(name: L10n.text("Gray"), rgba: SIMD4(0.45, 0.45, 0.48, 1)),
            .init(name: L10n.text("Red"), rgba: SIMD4(0.95, 0.18, 0.22, 1)),
            .init(name: L10n.text("Orange"), rgba: SIMD4(1, 0.5, 0.1, 1)),
            .init(name: L10n.text("Yellow"), rgba: SIMD4(1, 0.8, 0.1, 1)),
            .init(name: L10n.text("Green"), rgba: SIMD4(0.2, 0.7, 0.35, 1)),
            .init(name: L10n.text("Light blue"), rgba: SIMD4(0.15, 0.7, 0.9, 1)),
            .init(name: L10n.text("Blue"), rgba: SIMD4(0.15, 0.35, 0.95, 1)),
            .init(name: L10n.text("Purple"), rgba: SIMD4(0.6, 0.3, 0.85, 1)),
            .init(name: L10n.text("Pink"), rgba: SIMD4(0.95, 0.35, 0.65, 1)),
            .init(name: L10n.text("Brown"), rgba: SIMD4(0.55, 0.32, 0.18, 1)),
            .init(name: L10n.text("White"), rgba: SIMD4(1, 1, 1, 1))
        ]
        return presets.filter { AppReleaseFeatures.current.allowsColor($0.rgba) }
    }
}

struct WatchToolSettingsView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @ObservedObject var controller: CanvasController
    let onClose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var crownFocused: Bool
    @AppStorage("watch.settings.lastPage") private var selectedPage = 1

    private var selection: Setting {
        get {
            let stored = Setting(rawValue: selectedPage) ?? .color
            return availableSettings.contains(stored) ? stored : .instrument
        }
        nonmutating set { selectedPage = newValue.rawValue }
    }

    private var isEraser: Bool { controller.pencilStyle.instrument == .eraser }
    private var instruments: [DrawingInstrument] { DrawingInstrument.displayOrder }
    private var instrumentIndex: Int { instruments.firstIndex(of: controller.pencilStyle.instrument) ?? 0 }

    private var availableSettings: [Setting] {
        if isEraser { return [.width, .instrument, .mode] }
        if controller.pencilStyle.instrument == .reed { return [.color, .width, .instrument, .direction] }
        return [.color, .width, .instrument]
    }

    private func title(for setting: Setting) -> String { setting.title }

    private var valueTitle: String {
        switch selection {
        case .width: L10n.format("%d pt", Int(controller.pencilStyle.width))
        case .color: InkPreset.all[colorIndex].name
        case .instrument: controller.pencilStyle.instrument.title
        case .mode: controller.pencilStyle.eraserMode.title
        case .direction: "\(Int(controller.pencilStyle.reedAngle))°"
        }
    }

    private var crownMaximum: Double {
        switch selection {
        case .width: Double(controller.maximumWidth)
        case .color: Double(InkPreset.all.count - 1)
        case .instrument: Double(instruments.count - 1)
        case .mode: 1
        case .direction: 90
        }
    }

    private enum Setting: Int, CaseIterable {
        case width, color, instrument, mode, direction
        var title: String {
            switch self {
            case .width: L10n.text("Width")
            case .color: L10n.text("Color")
            case .instrument: L10n.text("Tool")
            case .mode: L10n.text("Mode")
            case .direction: L10n.text("Angle")
            }
        }
    }

    private var colorIndex: Int {
        InkPreset.all.firstIndex { $0.rgba == controller.pencilStyle.color } ?? 0
    }

    // One focused Crown target; changing the page changes what it edits.
    private var crownValue: Binding<Double> {
        Binding {
            switch selection {
            case .width: Double(controller.pencilStyle.width)
            case .color: Double(colorIndex)
            case .instrument: Double(instrumentIndex)
            case .mode: Double(controller.pencilStyle.eraserMode.rawValue)
            case .direction: Double(controller.pencilStyle.reedAngle)
            }
        } set: { value in
            if selection == .width {
                controller.pencilStyle.width = Float(min(crownMaximum, max(1, value.rounded())))
            } else if selection == .instrument {
                let index = min(instruments.count - 1, max(0, Int(value.rounded())))
                controller.selectInstrument(instruments[index])
            } else if selection == .mode {
                controller.pencilStyle.eraserMode = value.rounded() < 1 ? .pixels : .objects
            } else if selection == .direction {
                controller.pencilStyle.reedAngle = Float(min(90, max(-90, (value / 5).rounded() * 5)))
            } else {
                let index = min(InkPreset.all.count - 1, max(0, Int(value.rounded())))
                controller.pencilStyle.color = InkPreset.all[index].rgba
            }
        }
    }

    private var pageAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.3)
    }

    private var choiceAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.18)
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: selection == .width ? 0 : 8) {
                VStack(spacing: 6) {
                    strokePreview
                    Text(valueTitle)
                        .font(.caption2)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                // Keep both panels alive: animate their space and contents together.
                ZStack {
                    instrumentPalette
                    .frame(width: 40)
                    .opacity(selection == .instrument ? 1 : 0)
                    .allowsHitTesting(selection == .instrument)
                    .accessibilityHidden(selection != .instrument)

                    palette
                        .frame(width: 40)
                        .opacity(selection == .color ? 1 : 0)
                        .allowsHitTesting(selection == .color)
                        .accessibilityHidden(selection != .color)

                    eraserModes
                        .frame(width: 40)
                        .opacity(selection == .mode ? 1 : 0)
                        .scaleEffect(reduceMotion || selection == .mode ? 1 : 0.35)
                        .allowsHitTesting(selection == .mode)
                        .accessibilityHidden(selection != .mode)

                    directionControl
                        .frame(width: 40)
                        .opacity(selection == .direction ? 1 : 0)
                        .scaleEffect(reduceMotion || selection == .direction ? 1 : 0.35)
                        .allowsHitTesting(selection == .direction)
                        .accessibilityHidden(selection != .direction)
                }
                .frame(width: selection == .width ? 0 : 40)
                .opacity(selection == .width ? 0 : 1)
                .clipped()
            }
            .frame(maxHeight: .infinity)
            .animation(pageAnimation, value: selection)

            settingCarousel
                .frame(height: 30)
        }
        .padding(.horizontal, 10)
        .padding(.top, 40)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
        .focusable()
        .focused($crownFocused)
        .digitalCrownRotation(
            crownValue,
            from: selection == .width ? 1 : selection == .direction ? -90 : 0,
            through: crownMaximum,
            by: selection == .direction ? 5 : 1,
            sensitivity: .low,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    guard let current = availableSettings.firstIndex(of: selection) else { return }
                    let next = current + (value.translation.width < 0 ? 1 : -1)
                    if availableSettings.indices.contains(next) { select(availableSettings[next]) }
                }
        )
        .onAppear {
            // Migrate the old eraser page, previously stored in the color slot.
            if isEraser && selectedPage == Setting.color.rawValue { selectedPage = Setting.mode.rawValue }
            else { selectedPage = selection.rawValue }
            crownFocused = true
        }
        .onChange(of: controller.pencilStyle.instrument) { _, _ in
            withAnimation(pageAnimation) { selectedPage = selection.rawValue }
        }
    }

    private func select(_ setting: Setting) {
        withAnimation(pageAnimation) {
            selection = setting
        }
        crownFocused = true
    }

    private var settingCarousel: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(availableSettings, id: \.rawValue) { setting in
                            Button {
                                select(setting)
                            } label: {
                                Text(title(for: setting))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(selection == setting ? .primary : .secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.65)
                                    .frame(width: 90, height: 30)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selection == setting ? [.isSelected] : [])
                            .id(setting)
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.7).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, max(0, (geometry.size.width - 90) / 2))
                    .animation(pageAnimation, value: availableSettings)
                }
                .scrollIndicators(.hidden)
                .scrollDisabled(true)
                .onAppear { proxy.scrollTo(selection, anchor: .center) }
                .onChange(of: selection) { _, setting in
                    withAnimation(pageAnimation) {
                        proxy.scrollTo(setting, anchor: .center)
                    }
                }
                .onChange(of: availableSettings) { _, _ in
                    withAnimation(pageAnimation) {
                        proxy.scrollTo(selection, anchor: .center)
                    }
                }
            }
        }
    }

    private var instrumentPalette: some View {
        VStack(spacing: 2) {
            Image(systemName: "chevron.up")
                .font(.system(size: 9, weight: .bold))
                .opacity(instrumentIndex > 0 ? 1 : 0.25)
                .accessibilityHidden(true)
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(spacing: 4) {
                            ForEach(instruments.indices, id: \.self) { index in
                                let instrument = instruments[index]
                                Button {
                                    controller.selectInstrument(instrument)
                                    crownFocused = true
                                } label: {
                                    ToolIcon(instrument: instrument)
                                        .scaleEffect(reduceMotion ? 1 : selection != .instrument ? 0.35
                                                     : instrumentIndex == index ? 1 : 0.72)
                                        .animation(choiceAnimation, value: instrumentIndex)
                                        .frame(width: 40, height: 36)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(instrument.title)
                                .accessibilityAddTraits(instrumentIndex == index ? [.isSelected] : [])
                                .id(index)
                            }
                        }
                        .padding(.vertical, max(0, (geometry.size.height - 36) / 2))
                    }
                    .scrollIndicators(.hidden)
                    .scrollDisabled(true)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.white, lineWidth: 1.5)
                            .frame(width: 36, height: 36)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    .onAppear { proxy.scrollTo(instrumentIndex, anchor: .center) }
                    .onChange(of: geometry.size.height) { _, _ in
                        proxy.scrollTo(instrumentIndex, anchor: .center)
                    }
                    .onChange(of: instrumentIndex) { _, index in
                        withAnimation(choiceAnimation) { proxy.scrollTo(index, anchor: .center) }
                    }
                }
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .opacity(instrumentIndex < instruments.count - 1 ? 1 : 0.25)
                .accessibilityHidden(true)
            Text("\(instrumentIndex + 1)/\(instruments.count)")
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var directionControl: some View {
        VStack(spacing: 8) {
            Button {
                adjustDirection(by: 5)
            } label: {
                Image(systemName: "rotate.right")
                    .frame(width: 40, height: 30)
            }
            .disabled(controller.pencilStyle.reedAngle >= 90)
            .accessibilityLabel(L10n.text("Rotate tip clockwise"))

            Circle()
                .strokeBorder(.secondary, lineWidth: 1)
                .frame(width: 36, height: 36)
                .overlay {
                    Capsule()
                        .fill(.primary)
                        .frame(width: 26, height: 4)
                        .rotationEffect(.degrees(Double(controller.pencilStyle.reedAngle)))
                }
                .animation(choiceAnimation, value: controller.pencilStyle.reedAngle)
                .accessibilityLabel(L10n.text("Tip direction"))
                .accessibilityValue(L10n.format("%d degrees", Int(controller.pencilStyle.reedAngle)))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: adjustDirection(by: 5)
                    case .decrement: adjustDirection(by: -5)
                    @unknown default: break
                    }
                }

            Button {
                adjustDirection(by: -5)
            } label: {
                Image(systemName: "rotate.left")
                    .frame(width: 40, height: 30)
            }
            .disabled(controller.pencilStyle.reedAngle <= -90)
            .accessibilityLabel(L10n.text("Rotate tip counterclockwise"))
        }
        .buttonStyle(.plain)
    }

    private func adjustDirection(by amount: Float) {
        controller.pencilStyle.reedAngle = min(90, max(-90, controller.pencilStyle.reedAngle + amount))
        crownFocused = true
    }

    private var eraserModes: some View {
        VStack(spacing: 8) {
            ForEach(EraserMode.allCases, id: \.rawValue) { mode in
                Button {
                    controller.pencilStyle.eraserMode = mode
                    crownFocused = true
                } label: {
                    Image(systemName: mode == .pixels ? "square.grid.3x3.fill" : "scribble")
                        .frame(width: 36, height: 36)
                        .background(controller.pencilStyle.eraserMode == mode
                                    ? Color.white.opacity(0.2) : .clear, in: Circle())
                        .scaleEffect(reduceMotion ? 1 : controller.pencilStyle.eraserMode == mode ? 1 : 0.75)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode.title)
                .accessibilityAddTraits(controller.pencilStyle.eraserMode == mode ? [.isSelected] : [])
            }
        }
        .animation(choiceAnimation, value: controller.pencilStyle.eraserMode)
    }

    private var palette: some View {
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
                                controller.pencilStyle.color = InkPreset.all[index].rgba
                                crownFocused = true
                            } label: {
                                Circle()
                                    .fill(InkPreset.all[index].color)
                                    .frame(width: 22, height: 22)
                                    .overlay { Circle().strokeBorder(.gray.opacity(0.5), lineWidth: 1) }
                                    .padding(3)
                                    .scaleEffect(reduceMotion ? 1 : selection != .color ? 0.35
                                                 : colorIndex == index ? 1 : 0.72)
                                    .animation(choiceAnimation, value: colorIndex)
                                    .frame(width: 40, height: 30)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(InkPreset.all[index].name)
                            .accessibilityAddTraits(colorIndex == index ? [.isSelected] : [])
                            .id(index)
                        }
                    }
                    .padding(.vertical, max(0, (geometry.size.height - 30) / 2))
                }
                .scrollIndicators(.hidden)
                .scrollDisabled(true)
                .overlay(alignment: .center) {
                    // The selection window stays fixed while swatches move beneath it.
                    Circle()
                        .strokeBorder(.white, lineWidth: 2)
                        .frame(width: 28, height: 28)
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

    private var strokePreview: some View {
        Canvas { context, size in
            let a = SIMD2<Float>(Float(size.width * 0.15), Float(size.height * 0.7))
            let b = SIMD2<Float>(Float(size.width * 0.35), Float(size.height * 0.05))
            let c = SIMD2<Float>(Float(size.width * 0.65), Float(size.height * 0.95))
            let d = SIMD2<Float>(Float(size.width * 0.85), Float(size.height * 0.3))
            let samples = (0...40).map { index -> PointerSample in
                let t = Float(index) / 40
                let u = 1 - t
                let position = a * (u*u*u) + b * (3*u*u*t) + c * (3*u*t*t) + d * (t*t*t)
                return PointerSample(position: position, pressure: 1, timestamp: Double(t))
            }
            context.drawLayer { layer in
                if isEraser {
                    var demoStyle = PencilStyle.initial(for: .monoline)
                    demoStyle.color = SIMD4(0.15, 0.35, 0.95, 1)
                    demoStyle.width = 5
                    for row in 1...3 {
                        if controller.pencilStyle.eraserMode == .objects && row == 2 { continue }
                        let y = Float(size.height) * Float(row) / 4
                        let line = [PointerSample(position: SIMD2(Float(size.width) * 0.1, y), pressure: 1, timestamp: 0),
                                    PointerSample(position: SIMD2(Float(size.width) * 0.9, y), pressure: 1, timestamp: 1)]
                        WatchStrokeDrawing.draw(Stroke(points: line, style: demoStyle), in: &layer)
                    }
                }
                WatchStrokeDrawing.draw(Stroke(points: samples, style: controller.pencilStyle), in: &layer)
            }
        }
        .background(Color(white: 0.88), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityLabel(L10n.text("Stroke preview"))
    }
}
