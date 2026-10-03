import SwiftUI

struct WatchToolSettingsView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @ObservedObject var controller: CanvasController
    @ObservedObject var tutorial = TutorialSession.inactive
    @Environment(\.tutorialHintReservedHeight) private var tutorialHintReservedHeight
    @State private var showsInformation = false
    @State private var strokePreviewHeight: CGFloat = 0
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var crownFocused: Bool
    @AppStorage("watch.settings.lastPage") private var savedPage = 1
    @State private var selectedPage = 1
    @State private var didRestorePage = false

    private struct TutorialCrownFocusRequest: Equatable {
        let enabled: Bool
        let step: TutorialStep
        let page: Int
    }

    private var tutorialCrownFocusRequest: TutorialCrownFocusRequest {
        TutorialCrownFocusRequest(
            enabled: scenePhase == .active && !showsInformation
                && tutorial.allowsToolAdjustment(page: selection.rawValue),
            step: tutorial.step, page: selection.rawValue)
    }

    private var selection: ToolSetting {
        get {
            let stored = ToolSetting(rawValue: selectedPage) ?? .color
            return availableSettings.contains(stored) ? stored : .instrument
        }
        nonmutating set { selectedPage = newValue.rawValue }
    }

    private var colors: [InkPreset] { tutorial.isActive ? InkPreset.all.filter { $0.nameKey != "White" } : InkPreset.all }

    private var isEraser: Bool { controller.pencilStyle.instrument == .eraser }
    private var instruments: [DrawingInstrument] { DrawingInstrument.displayOrder }
    private var instrumentIndex: Int { instruments.firstIndex(of: controller.pencilStyle.instrument) ?? 0 }

    private var availableSettings: [ToolSetting] {
        let pages: [ToolSetting]
        if isEraser { pages = [.width, .instrument, .mode] }
        else if controller.pencilStyle.instrument == .reed { pages = [.color, .width, .instrument, .direction] }
        else { pages = [.color, .width, .instrument] }
        return pages
    }

    private var valueTitle: String {
        switch selection {
        case .width: L10n.format("%d pt", Int(controller.pencilStyle.width))
        case .color: colors[colorIndex].name
        case .instrument: controller.pencilStyle.instrument.title
        case .mode: controller.pencilStyle.eraserMode.title
        case .direction: "\(Int(controller.pencilStyle.reedAngle))°"
        }
    }

    private var crownMaximum: Double {
        switch selection {
        case .width: Double(controller.maximumWidth)
        case .color: Double(colors.count - 1)
        case .instrument: Double(instruments.count - 1)
        case .mode: 1
        case .direction: 90
        }
    }

    private var colorIndex: Int {
        colors.firstIndex { $0.rgba == controller.pencilStyle.color } ?? 0
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
                let index = min(colors.count - 1, max(0, Int(value.rounded())))
                style.color = colors[index].rgba
            case .instrument:
                break
            }
            // Fractional Crown events often round to the same setting.
            // Avoid publishing those duplicates to every observing view.
            if style != controller.pencilStyle { controller.pencilStyle = style }
        }
    }

    private let topChromeHeight: CGFloat = 40

    private var pageAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.3)
    }

    var body: some View {
        VStack(spacing: tutorial.isActive ? 0 : 4) {
            GeometryReader { settingsGeometry in
                let angleHeight = settingsGeometry.size.height + (tutorial.isActive ? 40 : 0)
                let angleScale = min(1, max(0, angleHeight) / ToolDirectionControl.idealSize.height)
                let panelWidth = selection == .width ? 0 : selection == .direction
                    ? ToolDirectionControl.idealSize.width * angleScale : 40
                let panelSpacing = selection == .width ? 0 : selection == .direction ? 8 * angleScale : 8
                HStack(spacing: panelSpacing) {
                    VStack(spacing: 6) {
                        ToolStrokePreview(style: controller.pencilStyle)
                            .background {
                                GeometryReader { previewGeometry in
                                    Color.clear.preference(key: StrokePreviewHeightKey.self,
                                                           value: previewGeometry.size.height)
                                }
                            }
                        Text(valueTitle)
                            .font(.caption2)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    // Keep both panels alive: animate their space and contents together.
                    GeometryReader { pickerGeometry in
                        let selectionOffset = tutorial.isActive && strokePreviewHeight > 0
                            ? (strokePreviewHeight - pickerGeometry.size.height) / 2 : 0
                        ZStack {
                            ToolInstrumentPicker(instruments: instruments, instrumentIndex: instrumentIndex,
                                                 isActive: selection == .instrument,
                                                 isEnabled: tutorial.allowsToolAdjustment(page: ToolSetting.instrument.rawValue),
                                                 extendsBeyondViewport: tutorial.isActive,
                                                 showsNavigationHints: !tutorial.isActive) { instrument in
                                guard tutorial.allowsToolAdjustment(page: ToolSetting.instrument.rawValue) else { return }
                                tutorial.activity()
                                controller.selectInstrument(instrument)
                                crownFocused = true
                            }
                            .frame(width: 40)
                            .offset(y: selectionOffset)
                            .opacity(selection == .instrument ? 1 : 0)
                            .allowsHitTesting(selection == .instrument)
                            .accessibilityHidden(selection != .instrument)

                            ToolColorPicker(presets: colors, colorIndex: colorIndex, isActive: selection == .color,
                                            isEnabled: tutorial.allowsToolAdjustment(page: ToolSetting.color.rawValue),
                                            extendsBeyondViewport: tutorial.isActive,
                                                 showsNavigationHints: !tutorial.isActive) { index in
                                guard tutorial.allowsToolAdjustment(page: ToolSetting.color.rawValue) else { return }
                                tutorial.activity()
                                controller.pencilStyle.color = colors[index].rgba
                                crownFocused = true
                            }
                                .frame(width: 40)
                                .offset(y: selectionOffset)
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


                        }
                        .frame(width: pickerGeometry.size.width, height: pickerGeometry.size.height)
                    }
                    .frame(width: panelWidth)
                    .opacity(selection == .width ? 0 : 1)
                    .modifier(ToolPickerViewportClip(isEnabled: !tutorial.isActive))
                }
                .frame(width: settingsGeometry.size.width, height: settingsGeometry.size.height)
            }
            .animation(pageAnimation, value: selection)

            ToolSettingCarousel(availableSettings: availableSettings, selection: selection,
                                isEnabled: { tutorial.allowsToolPage($0.rawValue) }, onSelect: select,
                                tutorial: tutorial,
                                trailingInset: tutorial.isActive && selection == .direction ? 48 : 0)
                .frame(height: 30)
        }
        .overlay(alignment: .trailing) {
            // Extend 8 pt to the bottom of the clock area and 2 pt to the card.
            // The control shares the remaining height among four equal gaps.
            GeometryReader { geometry in
                let height = tutorial.isActive ? geometry.size.height + 10
                    : max(0, geometry.size.height - 34)
                let scale = min(1, max(0, height) / ToolDirectionControl.idealSize.height)
                ToolDirectionControl(angle: controller.pencilStyle.reedAngle,
                                     isEnabled: tutorial.allowsToolAdjustment(page: ToolSetting.direction.rawValue),
                                     onAdjust: { adjustDirection(by: $0) },
                                     includesOuterSpacing: tutorial.isActive)
                    .frame(width: ToolDirectionControl.idealSize.width,
                           height: max(ToolDirectionControl.idealSize.height,
                                       height / max(scale, 0.001)))
                    .scaleEffect(scale)
                    .frame(width: ToolDirectionControl.idealSize.width * scale,
                           height: height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .offset(y: tutorial.isActive ? -8 : 0)
            }
            .opacity(selection == .direction ? 1 : 0)
            .allowsHitTesting(selection == .direction)
            .accessibilityHidden(selection != .direction)
        }
        .padding(.horizontal, 10)
        // Keep the preview and pickers below the toolbar in both editor and tutorial.
        .padding(.top, topChromeHeight)
        .padding(.bottom, tutorial.isActive ? tutorialHintReservedHeight : 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            if tutorial.isActive {
                Rectangle()
                    .fill(.regularMaterial)
                    .mask {
                        LinearGradient(stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.65),
                            .init(color: .clear, location: 1)
                        ], startPoint: .top, endPoint: .bottom)
                    }
                    // End above the preview, independent of the system toolbar's fade.
                    .frame(height: topChromeHeight - 2)
                    .clipped()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        // A new lesson changes the card height after measurement. Animate the
        // entire settings layout, including the carousel and angle overlay.
        .animation(tutorial.isActive ? pageAnimation : nil, value: tutorialHintReservedHeight)
        // Picker alignment follows the preview's measured height on a later update.
        .animation(tutorial.isActive ? pageAnimation : nil, value: strokePreviewHeight)
        .onPreferenceChange(StrokePreviewHeightKey.self) { strokePreviewHeight = $0 }
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
        .focusable(!showsInformation && tutorial.allowsToolAdjustment(page: selection.rawValue))
        .focused($crownFocused)
        .modifier(TutorialCrownAccessory(tutorial: tutorial, isSuggested: !showsInformation))
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
        .task(id: tutorialCrownFocusRequest) {
            // Keep the regular editor's focus behavior. In the tutorial, both
            // a lesson change and a picker-page change can replace focus peers
            // even though allowsToolAdjustment remains true.
            guard tutorial.isActive else { return }
            crownFocused = false
            guard tutorialCrownFocusRequest.enabled else { return }
            do {
                try await Task.sleep(for: .milliseconds(100))
                try Task.checkCancellation()
                crownFocused = true
            } catch {}
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    guard !showsInformation else { return }
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    guard let current = availableSettings.firstIndex(of: selection) else { return }
                    // Match the carousel’s mirrored order in Arabic and Hebrew.
                    let movesForward = layoutDirection == .rightToLeft
                        ? value.translation.width > 0 : value.translation.width < 0
                    let next = current + (movesForward ? 1 : -1)
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
            tutorial.changedStyle(from: controller.pencilStyle, to: controller.pencilStyle, page: selection.rawValue)
            if !tutorial.isActive { crownFocused = true }
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
            if !tutorial.isActive { crownFocused = true }
        }
        .onDisappear { controller.flushStylePreferences() }
        .onChange(of: tutorial.showsInstruction) { _, showing in
            if !tutorial.isActive {
                crownFocused = !showing && tutorial.allowsToolAdjustment(page: selection.rawValue)
            }
        }
        .onChange(of: tutorial.allowsToolAdjustment(page: selection.rawValue)) { _, allowed in
            if !tutorial.isActive { crownFocused = !showsInformation && allowed }
        }
        .onChange(of: selectedPage) { _, page in
            if !tutorial.isActive { savedPage = page }
            tutorial.changedPage(page)
            tutorial.changedStyle(from: controller.pencilStyle, to: controller.pencilStyle, page: page)
        }
        .onChange(of: controller.pencilStyle) { old, style in
            tutorial.changedStyle(from: old, to: style, page: selection.rawValue)
        }
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

private struct ToolPickerViewportClip: ViewModifier {
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.clipped()
        } else {
            // Continue above the viewport, but stop before the horizontal settings carousel.
            content.mask {
                Rectangle()
                    .padding(.top, -40)
            }
        }
    }
}

private struct StrokePreviewHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
