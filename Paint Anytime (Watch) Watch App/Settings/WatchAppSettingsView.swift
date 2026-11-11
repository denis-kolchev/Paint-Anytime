import SwiftUI

struct WatchAppSettingsView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @AppStorage(CanvasControlLayout.storageKey) private var controlLayoutData = Data()
    @AppStorage(CanvasControlLayout.enabledKey) private var customLayoutEnabled = false
    @Environment(\.openURL) private var openURL
    @Environment(\.restartWelcome) private var restartWelcome
    @State private var confirmsStartOver = false
    private let supportEmail = "paintanytime.app@gmail.com"
    @ObservedObject var controller: CanvasController
    let viewportSize: CGSize
    var onOpenDrawings: () -> Void
    var onStartTutorial: ([TutorialChapter]) -> Void
    var completedTutorialChapters: Set<TutorialChapter> = []
    var opensTutorialChapters = false
    var onClose: (() -> Void)? = nil
    /// Runs a canvas action chosen in the menu; the caller closes the menu first.
    /// Without it the menu offers no canvas actions.
    var onCanvasAction: ((CanvasQuickAction) -> Void)? = nil
    @ObservedObject var tutorial = TutorialSession.inactive

    var body: some View {
        NavigationStack {
            if opensTutorialChapters {
                // The canvas Tutorial button opens straight into the choice of tour.
                TutorialChaptersView(completed: completedTutorialChapters, onStart: onStartTutorial)
                    .toolbar { closeToolbar }
            } else {
                menu
            }
        }
    }

    private var menu: some View {
        List {
            Button(action: onOpenDrawings) {
                Label(L10n.text("Gallery"), systemImage: "photo.on.rectangle")
                    .tutorialHint(tutorial, steps: [.openGallery])
            }
            if !tutorial.isActive {
                if let onCanvasAction {
                    ForEach(actionsMissingFromCanvas) { action in
                        MenuCanvasActionButton(action: action, controller: controller, perform: onCanvasAction)
                    }
                }
                NavigationLink {
                    DrawingSettingsView(controller: controller, viewportSize: viewportSize)
                } label: {
                    Label(L10n.text("Drawing"), systemImage: "paintbrush")
                }
                NavigationLink {
                    CanvasSettingsView(controller: controller, viewportSize: viewportSize)
                } label: {
                    Label {
                        Text(L10n.text("Canvas"))
                    } icon: {
                        // The current name arrived in watchOS 11; watchOS 10 has the older one.
                        Group {
                            if #available(watchOS 11, *) {
                                Image(systemName: "inset.filled.applewatch.case")
                            } else {
                                Image(systemName: "applewatch.case.inset.filled")
                            }
                        }
                        // The narrow watch outline looks smaller than its neighbours at the default scale.
                        .imageScale(.large)
                    }
                }
                NavigationLink {
                    TutorialChaptersView(completed: completedTutorialChapters, onStart: onStartTutorial)
                } label: {
                    Label(L10n.text("Tutorial"), systemImage: "graduationcap")
                }
                if restartWelcome != nil {
                    Button { confirmsStartOver = true } label: {
                        Label(L10n.text("Start over"), systemImage: "arrow.counterclockwise")
                    }
                }
                NavigationLink {
                    AutosaveSettingsView()
                } label: {
                    Label(L10n.text("Autosave"), systemImage: "clock.arrow.circlepath")
                }
                NavigationLink {
                    AppLanguageSelectionView()
                } label: {
                    Label(L10n.text("Language"), systemImage: "globe")
                }
                NavigationLink {
                    WatchLegalDocumentView(title: "Privacy Policy", paragraphs: WatchLegalText.privacy)
                } label: {
                    Label(L10n.text("Privacy Policy"), systemImage: "hand.raised")
                }
                Button(action: reportBug) {
                    Label(L10n.text("Report a bug"), systemImage: "envelope")
                }
                if RenderDebug.isEnabled {
                    // Debug builds only; not localized.
                    NavigationLink {
                        RenderDebugSettingsView()
                    } label: {
                        Label { Text(verbatim: "Render debug") } icon: { Image(systemName: "speedometer") }
                    }
                }
            }
        }
        .labelStyle(CenteredMenuLabelStyle())
        .navigationTitle(L10n.text("More"))
        .toolbarTitleDisplayMode(.inline)
        .toolbar { closeToolbar }
        .alert(L10n.text("Show the welcome screen again?"), isPresented: $confirmsStartOver) {
            Button(L10n.text("Start over")) {
                // Close the menu, then show the first-launch questions over the kept editor.
                onClose?()
                restartWelcome?()
            }
            Button(L10n.text("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("The language and tutorial questions will appear again. Your drawings and the current canvas stay as they are."))
        }
    }

    /// Tool settings, Layers, Save, Lasso and Clear appear here only once the canvas
    /// editor has removed them from the canvas, so they always stay reachable.
    private var actionsMissingFromCanvas: [CanvasQuickAction] {
        let onCanvas = CanvasControlLayout.current(from: controlLayoutData, enabled: customLayoutEnabled).actions
        return [CanvasQuickAction.brush, .layers, .save, .lasso, .clear].filter { !onCanvas.contains($0) }
    }

    @ToolbarContentBuilder private var closeToolbar: some ToolbarContent {
        if let onClose {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        // Keep the symbol centered when the navigation host
                        // restores this item after showing a back button.
                        .frame(width: 32, height: 32, alignment: .center)
                        .contentShape(Circle())
                }
                .watchToolbarButtonStyle()
                .accessibilityLabel(L10n.text("Close"))
            }
        }
    }

    private func reportBug() {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Paint Anytime — " + L10n.text("Report a bug"))
        ]
        guard let url = components.url else { return }
        // watchOS handles mail availability and any error UI; the completion overload is unavailable.
        openURL(url)
    }
}

struct CenteredMenuLabelStyle: LabelStyle {
    @ScaledMetric(relativeTo: .body) private var iconWidth = 24.0

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 8) {
            configuration.icon
                .frame(width: iconWidth)
            configuration.title
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct DrawingSettingsView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @ObservedObject var controller: CanvasController
    let viewportSize: CGSize

    var body: some View {
        List {
            NavigationLink {
                PaletteVisibilitySettingsView(controller: controller)
            } label: {
                Label(L10n.text("Visible palettes"), systemImage: "paintpalette")
            }
            NavigationLink {
                ColorBlendingSelectionView(controller: controller)
            } label: {
                Label(L10n.text("Color blending"), systemImage: "circle.lefthalf.filled")
            }
            NavigationLink {
                ToolSynchronizationView(controller: controller)
            } label: {
                Label(L10n.text("Tool synchronization"), systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .labelStyle(CenteredMenuLabelStyle())
        .navigationTitle(L10n.text("Drawing"))
        .toolbarTitleDisplayMode(.inline)
    }
}

/// The canvas itself: its size, the arrangement of its controls and its guides.
private struct CanvasSettingsView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @ObservedObject var controller: CanvasController
    let viewportSize: CGSize
    @Environment(\.displayScale) private var displayScale
    @State private var showsEditor = false

    var body: some View {
        List {
            if AppReleaseFeatures.current.showsCanvasSizeControls {
                NavigationLink {
                    WatchCanvasSizeView(controller: controller, viewportSize: viewportSize,
                                        displayScale: displayScale)
                        .onAppear { controller.cancelStroke() }
                } label: {
                    Label(L10n.text("Canvas size"), systemImage: "arrow.up.left.and.arrow.down.right")
                }
            }
            // Opens the editor itself: Reset and Save live on its canvas preview.
            Button {
                showsEditor = true
            } label: {
                Label {
                    Text(L10n.text("Canvas editor"))
                } icon: {
                    CanvasLayoutIcon()
                }
            }
            NavigationLink {
                PerspectiveGuidesSettingsView(controller: controller, viewportSize: viewportSize)
            } label: {
                Label(L10n.text("Perspective guides"), systemImage: "perspective")
            }
        }
        .labelStyle(CenteredMenuLabelStyle())
        .navigationTitle(L10n.text("Canvas"))
        .toolbarTitleDisplayMode(.inline)
        // Not a sheet: the sheet's clock band sits above its content and takes
        // the taps of the editor's top buttons drawn in the clock's place.
        .fullScreenCover(isPresented: $showsEditor) {
            CanvasLayoutEditorView(instrument: controller.pencilStyle.instrument)
        }
    }
}

/// A canvas action in the More menu, with the same icon and title as in the canvas editor.
private struct MenuCanvasActionButton: View {
    let action: CanvasQuickAction
    @ObservedObject var controller: CanvasController
    let perform: (CanvasQuickAction) -> Void

    var body: some View {
        Button { perform(action) } label: {
            CanvasQuickActionLabel(action: action, instrument: controller.pencilStyle.instrument)
        }
        // Mirrors the canvas, which ignores Clear on an empty drawing.
        .disabled(action == .clear && !controller.canClear)
    }
}

struct PaletteVisibilitySettingsView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @AppStorage("watch.inkPalette.v1") private var paletteData = Data()
    @AppStorage("watch.inkPalettes.v2") private var palettesData = Data()
    @ObservedObject var controller: CanvasController
    @State private var showsPalettes = false

    private var library: InkPaletteLibrary {
        InkPaletteLibrary.decode(palettesData, legacy: paletteData)
    }

    var body: some View {
        List {
            // The palette cards, to see what a palette holds before showing or hiding it.
            Section {
                Button {
                    showsPalettes = true
                } label: {
                    Label { Text(L10n.text("Palettes")) } icon: { PalettesIcon() }
                }
            }
            if library.palettes.contains(where: { !$0.isBuiltIn }) {
                NavigationLink {
                    List { paletteRows(builtIn: true) }
                        .navigationTitle(L10n.text("Ready-made palettes"))
                } label: {
                    Label(L10n.text("Ready-made palettes"), systemImage: "paintpalette")
                }
                NavigationLink {
                    List { paletteRows(builtIn: false) }
                        .navigationTitle(L10n.text("My palettes"))
                } label: {
                    Label(L10n.text("My palettes"), systemImage: "person.crop.square")
                }
            } else {
                paletteRows(builtIn: true)
            }
        }
        .navigationTitle(L10n.text("Visible palettes"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    PaletteVisibilityInformationView()
                } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel(L10n.text("About visible palettes"))
            }
        }
        // Full screen like everywhere else the palettes open: their carousel needs the whole display.
        .fullScreenCover(isPresented: $showsPalettes) {
            InkPaletteBrowser(library: library, controller: controller, startsBrowsing: true) { updated in
                if let data = try? JSONEncoder().encode(updated) { palettesData = data }
                if !updated.activePalette.selectedColors.contains(where: { $0.rgba == controller.pencilStyle.color }),
                   let first = updated.activePalette.selectedColors.first {
                    controller.pencilStyle.color = first.rgba
                }
            }
            .environment(\.colorScheme, .dark)
        }
    }

    private func paletteRows(builtIn: Bool) -> some View {
        ForEach(library.palettes.filter { $0.isBuiltIn == builtIn }) { entry in
            Button {
                setVisible(!entry.isVisible, id: entry.id)
            } label: {
                HStack {
                    Text(entry.palette.displayTitle)
                    Spacer()
                    Image(systemName: entry.isVisible ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(entry.isVisible ? Color.green : Color.secondary)
                }
            }
            .disabled(entry.isVisible && library.visiblePalettes.count == 1)
            .accessibilityAddTraits(entry.isVisible ? .isSelected : [])
        }
    }

    private func setVisible(_ visible: Bool, id: String) {
        var updated = library
        let previousActiveID = updated.activeID
        guard let index = updated.palettes.firstIndex(where: { $0.id == id }) else { return }
        guard visible || !updated.palettes[index].isVisible || updated.visiblePalettes.count > 1 else { return }
        updated.palettes[index].isHidden = !visible
        // Keep an available palette selected when hiding the active one.
        if !visible && updated.activeID == id {
            guard let fallback = updated.visiblePalettes.first(where: { !$0.palette.selectedColors.isEmpty }) else { return }
            updated.activeID = fallback.id
        }
        guard let data = try? JSONEncoder().encode(updated) else { return }
        palettesData = data
        if updated.activeID != previousActiveID,
           !updated.activePalette.selectedColors.contains(where: { $0.rgba == controller.pencilStyle.color }),
           let first = updated.activePalette.selectedColors.first {
            controller.pencilStyle.color = first.rgba
        }
    }
}

/// What hiding a palette does, opened from the Visible palettes info button.
private struct PaletteVisibilityInformationView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text("Choose which palettes you can switch between when picking a color. Hidden palettes keep their colors and can be shown again at any time."))
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.text("At least one palette always stays visible."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
        .navigationTitle(L10n.text("Visible palettes"))
    }
}

struct ToolSynchronizationView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @ObservedObject var controller: CanvasController

    var body: some View {
        List {
            Section {
                Toggle(L10n.text("Shared width"), isOn: Binding(
                    get: { controller.synchronization.width },
                    set: { controller.setSynchronizeWidth($0) }
                ))
                Toggle(L10n.text("Shared opacity"), isOn: Binding(
                    get: { controller.synchronization.opacity },
                    set: { controller.setSynchronizeOpacity($0) }
                ))
                Toggle(L10n.text("Shared color"), isOn: Binding(
                    get: { controller.synchronization.color },
                    set: { controller.setSynchronizeColor($0) }
                ))
            }
        }
        .navigationTitle(L10n.text("Synchronization"))
        .toolbar {
            SettingsInformationButton(
                accessibilityKey: "About synchronization",
                titleKey: "Synchronization",
                messageKey: "Share width, opacity, and color across tools. Color and opacity do not apply to the eraser."
            )
        }
    }
}

/// One described option on an information screen; a nil title is a plain paragraph.
struct SettingsInformationItem: Hashable {
    var titleKey: String?
    var messageKey: String
}

/// Top-trailing info button, level with Back, that opens a settings screen's description.
/// Keeps the explanation out of the list so the controls fit the small display.
struct SettingsInformationButton: ToolbarContent {
    let accessibilityKey: String
    let titleKey: String
    let items: [SettingsInformationItem]

    init(accessibilityKey: String, titleKey: String, items: [SettingsInformationItem]) {
        self.accessibilityKey = accessibilityKey
        self.titleKey = titleKey
        self.items = items
    }

    init(accessibilityKey: String, titleKey: String, messageKey: String) {
        self.init(accessibilityKey: accessibilityKey, titleKey: titleKey,
                  items: [SettingsInformationItem(messageKey: messageKey)])
    }

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            NavigationLink {
                SettingsInformationView(titleKey: titleKey, items: items)
            } label: {
                Image(systemName: "info.circle")
            }
            .accessibilityLabel(L10n.text(accessibilityKey))
        }
    }
}

private struct SettingsInformationView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    let titleKey: String
    let items: [SettingsInformationItem]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(items, id: \.self) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        if let itemTitle = item.titleKey {
                            Text(L10n.text(itemTitle))
                                .font(.footnote.weight(.semibold))
                        }
                        Text(L10n.text(item.messageKey))
                            .font(.footnote)
                            .foregroundStyle(item.titleKey == nil ? .primary : .secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
        .navigationTitle(L10n.text(titleKey))
    }
}

struct AppLanguageSelectionView: View {
    var showsTitle = true
    /// First launch: the current (detected) language sits alone on top, highlighted,
    /// so most people confirm it with one tap; the rest follow in display order.
    var pinsCurrentLanguage = false
    /// Receives the language that was active before a different one was applied,
    /// or nil when the current language was tapped.
    var onSelection: ((_ previousCode: String?) -> Void)? = nil
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @State private var pendingLanguageCode: String?
    /// Fixed when the list appears, so the pinned row never jumps while a change applies.
    @State private var pinnedCode = AppLanguage.currentCode

    private var pinnedLanguage: AppLanguage? {
        pinsCurrentLanguage ? AppLanguage.supported.first { $0.id == pinnedCode } : nil
    }

    private var listedLanguages: [AppLanguage] {
        guard let pinnedLanguage else { return AppLanguage.displayOrder }
        return AppLanguage.displayOrder.filter { $0.id != pinnedLanguage.id }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if let pinnedLanguage {
                    Section {
                        row(for: pinnedLanguage)
                            .listRowBackground(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(.green.opacity(0.22)))
                    }
                }
                Section {
                    ForEach(listedLanguages) { language in
                        row(for: language)
                    }
                }
            }
            .onAppear {
                // The pinned language is already on top; there is nothing to scroll to.
                guard pinnedLanguage == nil else { return }
                // Position the list before it shows; an animated scroll during a page transition jerks.
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(AppLanguage.currentCode, anchor: .center)
                }
            }
        }
        .disabled(pendingLanguageCode != nil)
        .accessibilityHidden(pendingLanguageCode != nil)
        .overlay {
            if pendingLanguageCode != nil {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text(L10n.text("Changing language…"))
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.9))
                .accessibilityElement(children: .combine)
            }
        }
        .navigationBarBackButtonHidden(pendingLanguageCode != nil)
        .interactiveDismissDisabled(pendingLanguageCode != nil)
        .navigationTitle(showsTitle ? L10n.text("Language") : "")
        .task(id: pendingLanguageCode) {
            guard let code = pendingLanguageCode else { return }
            defer { pendingLanguageCode = nil }
            let previousCode = AppLanguage.currentCode
            do {
                // Let the indicator render before invalidating all localized views.
                try await Task.sleep(for: .milliseconds(100))
                try Task.checkCancellation()
                languageCode = code
                // Keep the overlay through the first layout of the updated interface.
                try await Task.sleep(for: .milliseconds(150))
                try Task.checkCancellation()
                onSelection?(previousCode)
            } catch {
                // SwiftUI cancels this task if the selection screen disappears.
            }
        }
    }

    private func row(for language: AppLanguage) -> some View {
        Button {
            guard pendingLanguageCode == nil else { return }
            if language.id == AppLanguage.currentCode {
                onSelection?(nil)
                return
            }
            pendingLanguageCode = language.id
        } label: {
            HStack {
                Text(verbatim: language.nativeName)
                    // Native names must use their own script, not the selected UI language.
                    .typesettingLanguage(.explicit(Locale.Language(identifier: language.id)))
                    .environment(\.locale, Locale(identifier: language.id))
                Spacer()
                if AppLanguage.currentCode == language.id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.green)
                }
            }
        }
        .id(language.id)
        .accessibilityAddTraits(AppLanguage.currentCode == language.id ? .isSelected : [])
    }
}

struct WatchLegalDocumentView: View {
    let title: String
    let paragraphs: [String]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(paragraphs.indices, id: \.self) { index in
                    Text(verbatim: paragraphs[index])
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .navigationTitle(L10n.text(title))
    }
}

struct ColorBlendingSelectionView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @ObservedObject var controller: CanvasController

    var body: some View {
        List {
            Section {
                ForEach(ColorBlendingMode.allCases, id: \.rawValue) { mode in
                    Button {
                        controller.setBlendingMode(mode)
                    } label: {
                        HStack {
                            ColorBlendingSwatchIcon(mode: mode)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(mode.effectTitle)
                                Text(mode.referenceLabel)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            if controller.blendingMode == mode {
                                Image(systemName: "checkmark").foregroundStyle(.green)
                            }
                        }
                    }
                    .accessibilityAddTraits(controller.blendingMode == mode ? .isSelected : [])
                }
            } footer: {
                Text(L10n.text("Applies to new marker and watercolor strokes. Hybrid is the default."))
            }
        }
        .navigationTitle(L10n.text("Color blending"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    ColorBlendingInformationView(mode: controller.blendingMode)
                } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel(L10n.text("About color blending"))
            }
        }
    }
}

private struct ColorBlendingInformationView: View {
    let mode: ColorBlendingMode
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(mode.effectTitle)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(mode.referenceLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(description)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                if !mode.usesMultiplyFastPath {
                    Text(L10n.text("The first stroke colors empty canvas. Blending changes how later strokes overlap existing paint. The white canvas backing is not white paint."))
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ColorBlendingIllustration(mode: mode)
                    .aspectRatio(1, contentMode: .fit)
                    .accessibilityLabel(L10n.text("Blend chart: yellow passes increase to the right; blue passes increase downward."))
                Text(L10n.format("Yellow → · Blue ↓\n0–10 passes, %@ opacity. Yellow first, then blue. Watercolor example; marker builds up more gently.", L10n.percent(0.8)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.text("Applies to new marker and watercolor strokes. Hybrid is the default."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
        .navigationTitle(mode.title)

    }

    private var description: String {
        switch mode {
        case .hybrid: L10n.text("Build up color for painterly shading. Like Multiply, repeated strokes deepen shadows, but retain more of the brush color instead of quickly turning black. The default for marker and watercolor.")
        case .multiply: L10n.text("Paint colored shadows, deepen folds, or tint a sketch while keeping dark lines visible. Each pass darkens the underlying colors. White has no effect; many passes can make shadows muddy.")
        case .normal: L10n.text("Block in flat colors, paint over mistakes, and add crisp details. Opaque strokes replace the color below. Lower opacity lets you build transitions gradually without extra darkening.")
        case .screen: L10n.text("Build soft highlights, haze, and reflected light over darker paint. Repeated passes brighten the image. Black has no effect, and Screen cannot add visible color over white.")
        case .overlay: L10n.text("Tint existing shading while boosting contrast: shadows deepen and light areas brighten. Useful for color accents on a modeled form. Pure black and white stay unchanged; start over midtones.")
        case .softLight: L10n.format("Gently warm or cool existing paint and adjust its lighting. Softer than Overlay, useful for subtle shading and atmosphere. Neutral %@ gray has no effect; work over midtones.", L10n.percent(0.5))
        case .hardLight: L10n.text("Paint dramatic light and strong colored shadows. Light brush colors brighten; dark brush colors deepen the image. Useful for bold lighting accents; lower opacity for more control.")
        case .darken: L10n.text("Add darker accents without lightening existing dark details. Each RGB channel keeps the darker value. Useful for reinforcing linework or shading; repeated identical opaque passes stop changing the result.")
        case .lighten: L10n.text("Add light accents while protecting brighter details. Each RGB channel keeps the lighter value. Useful for highlights on dark paint; it cannot leave a visible mark over white.")
        case .colorDodge: L10n.text("Create intense glow, hot highlights, and luminous edges over existing color. Bright brush colors quickly push highlights toward white. Use low opacity; the effect is invisible over white.")
        case .colorBurn: L10n.text("Deepen rich colored shadows and add gritty contrast. Dark brush colors can quickly crush detail to black. Use low opacity over existing paint; pure white stays white.")
        case .add: L10n.text("Add light for sparks, neon, and bright glow. RGB values add together and clip at white, so highlights can lose detail quickly. Best over dark paint with low opacity.")
        case .difference: L10n.text("Explore inverted colors and graphic effects. Similar colors turn dark; white inverts the underlying color, while black leaves it unchanged. Useful for experimental palettes rather than natural shading.")
        case .exclusion: L10n.text("Create softer inverted colors and muted graphic effects. Similar to Difference with gentler contrast. Black has no effect; white inverts the image. Try it for stylized color shifts.")
        }
    }
}

/// Repeated applications of the actual renderer's blend formula, not an approximation.
private struct ColorBlendingIllustration: View {
    let mode: ColorBlendingMode

    var body: some View {
        Canvas { context, size in
            let margin: CGFloat = 16
            let cell = (min(size.width, size.height) - margin) / 11
            for row in 0...10 {
                for column in 0...10 {
                    let result = mode.referenceSwatch(yellowPasses: column, bluePasses: row)
                    let rect = CGRect(x: margin + CGFloat(column) * cell,
                                      y: margin + CGFloat(row) * cell, width: cell + 0.25, height: cell + 0.25)
                    context.fill(Path(rect), with: .color(Color(.sRGB, red: Double(result.x),
                                                               green: Double(result.y), blue: Double(result.z), opacity: 1)))
                }
            }
            for index in [0, 5, 10] {
                let label = Text(verbatim: String(index)).font(.system(size: 9)).foregroundColor(.secondary)
                let position = margin + (CGFloat(index) + 0.5) * cell
                context.draw(label, at: CGPoint(x: position, y: 6))
                context.draw(label, at: CGPoint(x: 6, y: position))
            }
        }
        .accessibilityElement(children: .ignore)
    }
}

/// The information chart shrunk to an icon: 4×4 cells at 0, 1, 3 and 10 passes
/// (yellow →, blue ↓), so the far corner still shows where many passes lead.
private struct ColorBlendingSwatchIcon: View {
    let mode: ColorBlendingMode
    @ScaledMetric(relativeTo: .body) private var side = 28.0
    private static let passes = [0, 1, 3, 10]

    var body: some View {
        Canvas { context, size in
            let cell = size.width / CGFloat(Self.passes.count)
            for (row, blue) in Self.passes.enumerated() {
                for (column, yellow) in Self.passes.enumerated() {
                    let result = mode.referenceSwatch(yellowPasses: yellow, bluePasses: blue)
                    // A hair of overlap hides seams between neighbouring cells.
                    let rect = CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell,
                                      width: cell + 0.25, height: cell + 0.25)
                    context.fill(Path(rect), with: .color(Color(.sRGB, red: Double(result.x), green: Double(result.y),
                                                               blue: Double(result.z), opacity: 1)))
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.2, style: .continuous))
        // Decorative: the mode's title and reference already say what it does.
        .accessibilityHidden(true)
    }
}

private struct TutorialChaptersView: View {
    let completed: Set<TutorialChapter>
    let onStart: ([TutorialChapter]) -> Void

    var body: some View {
        List {
            Button { onStart(TutorialChapter.allCases) } label: {
                Label(L10n.text("Full tour"), systemImage: "play.fill")
            }
            Section(L10n.text("Chapters")) {
                ForEach(TutorialChapter.allCases) { chapter in
                    Button { onStart([chapter]) } label: {
                        HStack {
                            Label(chapter.title, systemImage: chapter.systemImage)
                            Spacer(minLength: 4)
                            if completed.contains(chapter) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.green)
                                    .accessibilityLabel(L10n.text("Completed"))
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(L10n.text("Tutorial"))
        .toolbarTitleDisplayMode(.inline)
    }
}
