import SwiftUI

struct WatchToolSettingsView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @ObservedObject var controller: CanvasController
    @ObservedObject var tutorial = TutorialSession.inactive
    @Environment(\.tutorialHintReservedHeight) private var tutorialHintReservedHeight
    @State private var showsInformation = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var crownFocused: Bool
    @AppStorage("watch.settings.lastPage") private var savedPage = 1
    @State private var selectedPage = 1
    @State private var didRestorePage = false

    private var selection: ToolSetting {
        get {
            let stored = ToolSetting(rawValue: selectedPage) ?? .color
            return availableSettings.contains(stored) ? stored : .instrument
        }
        nonmutating set { selectedPage = newValue.rawValue }
    }

    private var isEraser: Bool { controller.pencilStyle.instrument == .eraser }
    private var instruments: [DrawingInstrument] { DrawingInstrument.displayOrder }
    private var instrumentIndex: Int { instruments.firstIndex(of: controller.pencilStyle.instrument) ?? 0 }

    private var availableSettings: [ToolSetting] {
        let pages: [ToolSetting]
        if isEraser { pages = [.width, .instrument, .mode] }
        else if controller.pencilStyle.instrument == .reed { pages = [.color, .width, .instrument, .direction] }
        else { pages = [.color, .width, .instrument] }
        return tutorial.isActive ? pages.filter { tutorial.visibleToolPages.contains($0.rawValue) } : pages
    }

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

    var body: some View {
        VStack(spacing: tutorial.isActive ? 0 : 4) {
            HStack(spacing: selection == .width ? 0 : 8) {
                VStack(spacing: 6) {
                    ToolStrokePreview(style: controller.pencilStyle)
                    Text(valueTitle)
                        .font(.caption2)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                // Keep both panels alive: animate their space and contents together.
                GeometryReader { pickerGeometry in
                    ZStack {
                        ToolInstrumentPicker(instruments: instruments, instrumentIndex: instrumentIndex,
                                             isActive: selection == .instrument,
                                             isEnabled: tutorial.allowsToolAdjustment(page: ToolSetting.instrument.rawValue)) { instrument in
                            guard tutorial.allowsToolAdjustment(page: ToolSetting.instrument.rawValue) else { return }
                            tutorial.activity()
                            controller.selectInstrument(instrument)
                            crownFocused = true
                        }
                        .frame(width: 40)
                        .opacity(selection == .instrument ? 1 : 0)
                        .allowsHitTesting(selection == .instrument)
                        .accessibilityHidden(selection != .instrument)

                        ToolColorPicker(colorIndex: colorIndex, isActive: selection == .color,
                                        isEnabled: tutorial.allowsToolAdjustment(page: ToolSetting.color.rawValue)) { index in
                            guard tutorial.allowsToolAdjustment(page: ToolSetting.color.rawValue) else { return }
                            tutorial.activity()
                            controller.pencilStyle.color = InkPreset.all[index].rgba
                            crownFocused = true
                        }
                            .frame(width: 40)
                            .opacity(selection == .color ? 1 : 0)
                            .allowsHitTesting(selection == .color)
                            .accessibilityHidden(selection != .color)

                        ToolEraserModePicker(selectedMode: controller.pencilStyle.eraserMode,
                                            isEnabled: tutorial.allowsToolAdjustment(page: ToolSetting.mode.rawValue)) { mode in
                            guard tutorial.allowsToolAdjustment(page: ToolSetting.mode.rawValue) else { return }
                            controller.pencilStyle.eraserMode = mode
                            crownFocused = true
                        }
                            .frame(width: 40)
                            .opacity(selection == .mode ? 1 : 0)
                            .scaleEffect(reduceMotion || selection == .mode ? 1 : 0.35)
                            .allowsHitTesting(selection == .mode)
                            .accessibilityHidden(selection != .mode)

                        ToolDirectionControl(angle: controller.pencilStyle.reedAngle,
                                             isEnabled: tutorial.allowsToolAdjustment(page: ToolSetting.direction.rawValue),
                                             onAdjust: { adjustDirection(by: $0) })
                            .frame(width: 40)
                            .opacity(selection == .direction ? 1 : 0)
                            .scaleEffect(reduceMotion || selection == .direction ? 1 : 0.35)
                            .allowsHitTesting(selection == .direction)
                            .accessibilityHidden(selection != .direction)
                    }
                    .frame(width: pickerGeometry.size.width, height: pickerGeometry.size.height)
                }
                .frame(width: selection == .width ? 0 : 40)
                .opacity(selection == .width ? 0 : 1)
                .clipped()
            }
            .frame(maxHeight: .infinity)
            .animation(pageAnimation, value: selection)

            ToolSettingCarousel(availableSettings: availableSettings, selection: selection,
                                isEnabled: { tutorial.allowsToolPage($0.rawValue) }, onSelect: select,
                                tutorial: tutorial)
                .frame(height: 30)
        }
        .padding(.horizontal, 10)
        // Let tutorial controls use the upper safe area instead of reserving the full toolbar height.
        .padding(.top, tutorial.isActive ? 12 : 40)
        .padding(.bottom, tutorial.isActive ? tutorialHintReservedHeight : 8)
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
                            .tutorialHint(tutorial, steps: [.readToolInfo])
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
                selectedPage = tutorial.isActive ? ToolSetting.color.rawValue : savedPage
                didRestorePage = true
            }
            // Migrate the old eraser page, previously stored in the color slot.
            if isEraser && selectedPage == ToolSetting.color.rawValue { selectedPage = ToolSetting.mode.rawValue }
            else { selectedPage = selection.rawValue }
            crownFocused = tutorial.allowsToolAdjustment(page: selection.rawValue)
        }
        .onDisappear { controller.flushStylePreferences() }
        .onChange(of: tutorial.showsInstruction) { _, showing in
            crownFocused = !showing && tutorial.allowsToolAdjustment(page: selection.rawValue)
        }
        .onChange(of: tutorial.allowsToolAdjustment(page: selection.rawValue)) { _, allowed in
            crownFocused = !showsInformation && allowed
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

    private func select(_ setting: ToolSetting) {
        guard tutorial.allowsToolPage(setting.rawValue) else { return }
        tutorial.activity()
        withAnimation(pageAnimation) {
            selection = setting
        }
        crownFocused = true
    }

    private func adjustDirection(by amount: Float) {
        guard tutorial.allowsToolAdjustment(page: ToolSetting.direction.rawValue) else { return }
        tutorial.activity()
        controller.pencilStyle.reedAngle = min(90, max(-90, controller.pencilStyle.reedAngle + amount))
        crownFocused = true
    }

}
