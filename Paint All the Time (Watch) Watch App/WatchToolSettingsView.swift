import SwiftUI

private struct InkPreset {
    let nameKey: String
    var name: String { L10n.text(nameKey) }
    let rgba: SIMD4<Float>

    var color: Color {
        Color(.sRGB, red: Double(rgba.x), green: Double(rgba.y),
              blue: Double(rgba.z), opacity: Double(rgba.w))
    }

    static let all: [InkPreset] = {
        let presets: [InkPreset] = [
            .init(nameKey: "Black", rgba: SIMD4(0, 0, 0, 1)),
            .init(nameKey: "Gray", rgba: SIMD4(0.45, 0.45, 0.48, 1)),
            .init(nameKey: "Red", rgba: SIMD4(0.95, 0.18, 0.22, 1)),
            .init(nameKey: "Orange", rgba: SIMD4(1, 0.5, 0.1, 1)),
            .init(nameKey: "Yellow", rgba: SIMD4(1, 0.8, 0.1, 1)),
            .init(nameKey: "Green", rgba: SIMD4(0.2, 0.7, 0.35, 1)),
            .init(nameKey: "Light blue", rgba: SIMD4(0.15, 0.7, 0.9, 1)),
            .init(nameKey: "Blue", rgba: SIMD4(0.15, 0.35, 0.95, 1)),
            .init(nameKey: "Purple", rgba: SIMD4(0.6, 0.3, 0.85, 1)),
            .init(nameKey: "Pink", rgba: SIMD4(0.95, 0.35, 0.65, 1)),
            .init(nameKey: "Brown", rgba: SIMD4(0.55, 0.32, 0.18, 1)),
            .init(nameKey: "White", rgba: SIMD4(1, 1, 1, 1))
        ]
        return presets.filter { AppReleaseFeatures.current.allowsColor($0.rgba) }
    }()
}

struct WatchToolSettingsView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @ObservedObject var controller: CanvasController
    @ObservedObject var tutorial = TutorialSession.inactive
    @State private var showsInformation = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var crownFocused: Bool
    @AppStorage("watch.settings.lastPage") private var savedPage = 1
    @State private var selectedPage = 1
    @State private var didRestorePage = false

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
        let pages: [Setting]
        if isEraser { pages = [.width, .instrument, .mode] }
        else if controller.pencilStyle.instrument == .reed { pages = [.color, .width, .instrument, .direction] }
        else { pages = [.color, .width, .instrument] }
        return tutorial.isActive ? pages.filter { tutorial.visibleToolPages.contains($0.rawValue) } : pages
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
            guard !showsInformation, tutorial.allowsToolAdjustment(page: selection.rawValue) else { return }
            tutorial.activity()
            if selection == .instrument {
                let index = min(instruments.count - 1, max(0, Int(value.rounded())))
                controller.selectInstrument(instruments[index])
                return
            }
            var style = controller.pencilStyle
            switch selection {
            case .width:
                style.width = Float(min(crownMaximum, max(1, value.rounded())))
            case .mode:
                style.eraserMode = value.rounded() < 1 ? .pixels : .objects
            case .direction:
                style.reedAngle = Float(min(90, max(-90, (value / 5).rounded() * 5)))
            case .color:
                let index = min(InkPreset.all.count - 1, max(0, Int(value.rounded())))
                style.color = InkPreset.all[index].rgba
            case .instrument:
                break
            }
            // Fractional Crown events often round to the same setting.
            // Avoid publishing those duplicates to every observing view.
            if style != controller.pencilStyle { controller.pencilStyle = style }
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
        .focusable(!showsInformation && tutorial.allowsToolAdjustment(page: selection.rawValue))
        .focused($crownFocused)
        .digitalCrownRotation(
            crownValue,
            from: selection == .width ? 1 : selection == .direction ? -90 : 0,
            through: crownMaximum,
            // Reduce angular travel by another half; displayed values still snap to 5°.
            by: selection == .direction ? 1.25 : 1,
            sensitivity: selection == .direction ? .high : .low,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    guard !showsInformation else { return }
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    guard let current = availableSettings.firstIndex(of: selection) else { return }
                    let next = current + (value.translation.width < 0 ? 1 : -1)
                    if availableSettings.indices.contains(next) { select(availableSettings[next]) }
                }
        )
        .toolbar {
            if (selection == .instrument || selection == .mode) && tutorial.allowsToolInfo {
                ToolbarItem(placement: .topBarLeading) {
                    // Reference: the compact Information button seen after returning
                    // from Width. The shared modifier fixes that diameter on first
                    // appearance too, and applies it to every canvas toolbar button.
                    Button {
                        crownFocused = false
                        tutorial.record(.openedInfo)
                        showsInformation = true
                    } label: {
                        Image(systemName: "info")
                    }
                    .watchToolbarButtonStyle()
                    .accessibilityLabel(L10n.text("Information"))
                }
            }
        }
        .fullScreenCover(isPresented: $showsInformation, onDismiss: {
            tutorial.record(.closedInfo)
            crownFocused = tutorial.allowsToolAdjustment(page: selection.rawValue)
        }) {
            ToolInformationView(
                title: selection == .mode ? controller.pencilStyle.eraserMode.title : controller.pencilStyle.instrument.title,
                description: selection == .mode ? controller.pencilStyle.eraserMode.helpDescription : controller.pencilStyle.instrument.helpDescription
            )
            .presentationBackground(.black)
            .environment(\.colorScheme, .dark)
        }
        .onAppear {
            if !didRestorePage {
                selectedPage = tutorial.isActive ? Setting.color.rawValue : savedPage
                didRestorePage = true
            }
            // Migrate the old eraser page, previously stored in the color slot.
            if isEraser && selectedPage == Setting.color.rawValue { selectedPage = Setting.mode.rawValue }
            else { selectedPage = selection.rawValue }
            crownFocused = tutorial.allowsToolAdjustment(page: selection.rawValue)
        }
        .onDisappear { controller.flushStylePreferences() }
        .onChange(of: tutorial.showsInstruction) { _, showing in
            crownFocused = !showing && tutorial.allowsToolAdjustment(page: selection.rawValue)
        }
        .onChange(of: selectedPage) { _, page in
            if !tutorial.isActive { savedPage = page }
            tutorial.changedPage(page)
        }
        .onChange(of: controller.pencilStyle) { _, style in tutorial.changedStyle(style) }
        .onChange(of: controller.pencilStyle.instrument) { _, _ in
            withAnimation(pageAnimation) { selectedPage = selection.rawValue }
        }
    }

    private func select(_ setting: Setting) {
        guard tutorial.allowsToolPage(setting.rawValue) else { return }
        tutorial.activity()
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
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .disabled(!tutorial.allowsToolPage(setting.rawValue))
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
                                    guard tutorial.allowsToolAdjustment(page: Setting.instrument.rawValue) else { return }
                                    tutorial.activity()
                                    controller.selectInstrument(instrument)
                                    crownFocused = true
                                } label: {
                                    ToolIcon(instrument: instrument)
                                        .scaleEffect(reduceMotion ? 1 : selection != .instrument ? 0.35
                                                     : instrumentIndex == index ? 1 : 0.72)
                                        .animation(choiceAnimation, value: instrumentIndex)
                                        .frame(width: 40, height: 36)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.borderless)
                                .disabled(!tutorial.allowsToolAdjustment(page: Setting.instrument.rawValue))
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
                    .contentShape(Rectangle())
            }
            .disabled(controller.pencilStyle.reedAngle >= 90 || !tutorial.allowsToolAdjustment(page: Setting.direction.rawValue))
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
                    .contentShape(Rectangle())
            }
            .disabled(controller.pencilStyle.reedAngle <= -90 || !tutorial.allowsToolAdjustment(page: Setting.direction.rawValue))
            .accessibilityLabel(L10n.text("Rotate tip counterclockwise"))
        }
        .buttonStyle(.borderless)
    }

    private func adjustDirection(by amount: Float) {
        guard tutorial.allowsToolAdjustment(page: Setting.direction.rawValue) else { return }
        tutorial.activity()
        controller.pencilStyle.reedAngle = min(90, max(-90, controller.pencilStyle.reedAngle + amount))
        crownFocused = true
    }

    private var eraserModes: some View {
        VStack(spacing: 8) {
            ForEach(EraserMode.allCases, id: \.rawValue) { mode in
                Button {
                    guard tutorial.allowsToolAdjustment(page: Setting.mode.rawValue) else { return }
                    controller.pencilStyle.eraserMode = mode
                    crownFocused = true
                } label: {
                    Image(systemName: mode == .pixels ? "square.grid.3x3.fill" : "scribble")
                        .frame(width: 36, height: 36)
                        .background(controller.pencilStyle.eraserMode == mode
                                    ? Color.white.opacity(0.2) : .clear, in: Circle())
                        .scaleEffect(reduceMotion ? 1 : controller.pencilStyle.eraserMode == mode ? 1 : 0.75)
                }
                .buttonStyle(.borderless)
                .disabled(!tutorial.allowsToolAdjustment(page: Setting.mode.rawValue))
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
                                guard tutorial.allowsToolAdjustment(page: Setting.color.rawValue) else { return }
                                tutorial.activity()
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
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .disabled(!tutorial.allowsToolAdjustment(page: Setting.color.rawValue))
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

private struct ToolInformationView: View {
    let title: String
    let description: String

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(title)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text(description)
                        .font(.body)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(Color.black.ignoresSafeArea())
            .containerBackground(.black, for: .navigation)
        }
    }
}
