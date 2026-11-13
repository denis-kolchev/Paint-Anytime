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
    /// The tutorial passes its own practice guides; the editor uses the saved ones.
    var guides = PerspectiveGuides.shared
    /// The tutorial opens Canvas as its own page instead of pushing it.
    var onOpenCanvasSettings: (() -> Void)? = nil
    /// The tutorial opens Drawing as its own page, as it does Canvas.
    var onOpenDrawingSettings: (() -> Void)? = nil

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
            if tutorial.isActive {
                // The tutorial's menu rises over the drawing and crossfades into its pages;
                // a native title stays put in the host's bar and pops in and out in one frame.
                // As the section header it moves and fades with the list; a row instead
                // added the list's minimum row height and pushed the menu down.
                Section {
                    menuRows
                } header: {
                    Text(L10n.text("More"))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .textCase(nil)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        // Closer to the clock, with room below so the title does not touch Gallery.
                        .padding(.bottom, 4)
                        .offset(y: -10)
                        // Shrinks the header from the top, so the title and Gallery rise
                        // together and the gap between them stays the same.
                        .padding(.top, -12)
                        .accessibilityAddTraits(.isHeader)
                }
            } else {
                menuRows
            }
        }
        .labelStyle(CenteredMenuLabelStyle())
        .navigationTitle(tutorial.isActive ? "" : L10n.text("More"))
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

    @ViewBuilder
    private var menuRows: some View {
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
            canvasLink
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
        } else {
            // A lesson shows only the rows on its path. They stay installed for the whole
            // lesson, so removing a row never pops the page it pushed.
            if tutorial.teachesGallerySelection {
                // Optional: the real setting, reachable here as the lesson tip suggests.
                NavigationLink {
                    AutosaveSettingsView()
                } label: {
                    Label(L10n.text("Autosave"), systemImage: "clock.arrow.circlepath")
                }
            }
            if tutorial.teachesBlending, let onOpenDrawingSettings {
                Button(action: onOpenDrawingSettings) {
                    Label(L10n.text("Drawing"), systemImage: "paintbrush")
                        .tutorialHint(tutorial, steps: [.openDrawingSettings])
                }
            }
            if tutorial.teachesPerspective || tutorial.teachesCrop {
                if let onOpenCanvasSettings {
                    Button(action: onOpenCanvasSettings) {
                        canvasLabel.tutorialHint(tutorial, steps: [.openCanvasSettings])
                    }
                } else {
                    canvasLink
                }
            }
        }
    }

    /// Tool settings, Layers, Save, Lasso and Clear appear here only once the canvas
    /// editor has removed them from the canvas, so they always stay reachable.
    private var actionsMissingFromCanvas: [CanvasQuickAction] {
        let onCanvas = CanvasControlLayout.current(from: controlLayoutData, enabled: customLayoutEnabled).actions
        return [CanvasQuickAction.brush, .layers, .save, .lasso, .clear].filter { !onCanvas.contains($0) }
    }

    private var canvasLink: some View {
        NavigationLink {
            CanvasSettingsView(controller: controller, viewportSize: viewportSize, guides: guides)
        } label: {
            canvasLabel
        }
    }

    private var canvasLabel: some View {
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

struct DrawingSettingsView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @ObservedObject var controller: CanvasController
    let viewportSize: CGSize
    @ObservedObject var tutorial = TutorialSession.inactive
    /// The tutorial shows Color blending itself and keeps only that row.
    var onOpenColorBlending: (() -> Void)? = nil

    var body: some View {
        List {
            if let onOpenColorBlending, tutorial.isActive {
                Button(action: onOpenColorBlending) {
                    Label(L10n.text("Color blending"), systemImage: "circle.lefthalf.filled")
                        .tutorialHint(tutorial, steps: [.openColorBlending])
                }
            } else {
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
        }
        .labelStyle(CenteredMenuLabelStyle())
        .navigationTitle(L10n.text("Drawing"))
        .toolbarTitleDisplayMode(.inline)
    }
}

/// The canvas itself: its size, the arrangement of its controls and its guides.
struct CanvasSettingsView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @ObservedObject var controller: CanvasController
    let viewportSize: CGSize
    @ObservedObject var tutorial = TutorialSession.inactive
    var guides = PerspectiveGuides.shared
    /// The tutorial shows these pages itself; without them the rows push their pages.
    var onOpenCanvasSize: (() -> Void)? = nil
    var onOpenPerspective: (() -> Void)? = nil
    @Environment(\.displayScale) private var displayScale
    @State private var showsEditor = false

    var body: some View {
        List {
            // A tutorial lesson keeps only the row it teaches.
            if AppReleaseFeatures.current.showsCanvasSizeControls && (!tutorial.isActive || tutorial.teachesCrop) {
                if let onOpenCanvasSize {
                    Button(action: onOpenCanvasSize) {
                        Label(L10n.text("Canvas size"), systemImage: "arrow.up.left.and.arrow.down.right")
                            .tutorialHint(tutorial, steps: [.openCanvasSize])
                    }
                } else {
                    NavigationLink {
                        WatchCanvasSizeView(controller: controller, viewportSize: viewportSize,
                                            displayScale: displayScale)
                            .onAppear { controller.cancelStroke() }
                    } label: {
                        Label(L10n.text("Canvas size"), systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                }
            }
            if !tutorial.isActive {
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
            }
            if !tutorial.isActive || tutorial.teachesPerspective {
                if let onOpenPerspective {
                    Button(action: onOpenPerspective) {
                        Label(L10n.text("Perspective guides"), systemImage: "perspective")
                            .tutorialHint(tutorial, steps: [.openPerspective])
                    }
                } else {
                    NavigationLink {
                        PerspectiveGuidesSettingsView(controller: controller, viewportSize: viewportSize,
                                                      guides: guides)
                    } label: {
                        Label(L10n.text("Perspective guides"), systemImage: "perspective")
                    }
                }
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
                    PaletteSwatchIcon(palette: entry.palette)
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
    /// When set, a different language is only reported here and not applied;
    /// the caller confirms it first and applies it itself.
    var onChooseWithoutApplying: ((_ code: String) -> Void)? = nil
    /// Another page covers the list but keeps it alive, so its scroll offset survives.
    var isCovered = false
    /// The cover takes the Digital Crown; the list must ask for it back when uncovered.
    @FocusState private var listHasCrownFocus: Bool
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @State private var pendingLanguageCode: String?
    /// Captured in the outgoing language so the overlay never switches mid-change.
    @State private var changingLanguageMessage = ""
    @State private var changingFromCode = AppLanguage.currentCode
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
            .focused($listHasCrownFocus)
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
        // Hidden, not removed, while covered; the fade crossfades with the cover.
        .opacity(isCovered ? 0 : 1)
        .allowsHitTesting(!isCovered)
        .onChange(of: isCovered) { _, covered in
            guard !covered else { return }
            // After the update that uncovers the list, so focus is not refused mid-transition.
            Task { @MainActor in listHasCrownFocus = true }
        }
        .disabled(pendingLanguageCode != nil)
        .accessibilityHidden(pendingLanguageCode != nil || isCovered)
        .overlay {
            if pendingLanguageCode != nil {
                LanguageChangeOverlay(message: changingLanguageMessage, languageCode: changingFromCode)
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
                try await LanguageChangeOverlay.apply { languageCode = code }
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
            if let onChooseWithoutApplying {
                onChooseWithoutApplying(language.id)
                return
            }
            changingFromCode = AppLanguage.currentCode
            changingLanguageMessage = L10n.text("Changing language…")
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

/// Covers the screen while a new language applies. The message is captured in the
/// outgoing language before the change, so it never switches halfway through.
struct LanguageChangeOverlay: View {
    let message: String
    let languageCode: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(verbatim: message)
                .typesettingLanguage(.explicit(Locale.Language(identifier: languageCode)))
                .environment(\.locale, Locale(identifier: languageCode))
                .font(.footnote)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.9))
        .accessibilityElement(children: .combine)
    }

    /// Lets the overlay render, applies the language, then holds the overlay
    /// through the first layout of the updated interface.
    @MainActor static func apply(_ change: () -> Void) async throws {
        try await Task.sleep(for: .milliseconds(100))
        try Task.checkCancellation()
        change()
        try await Task.sleep(for: .milliseconds(150))
        try Task.checkCancellation()
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
    @ObservedObject var tutorial = TutorialSession.inactive

    /// The lesson compares the default with the one mode it teaches.
    private var modes: [ColorBlendingMode] {
        tutorial.isActive ? [.hybrid, .difference] : ColorBlendingMode.allCases
    }

    private func select(_ mode: ColorBlendingMode) {
        guard tutorial.isActive else {
            controller.setBlendingMode(mode)
            return
        }
        guard mode == .difference, tutorial.permits([.chooseColorInversion]) else { return }
        controller.setBlendingMode(mode)
        tutorial.record(.choseColorInversion)
    }

    var body: some View {
        List {
            Section {
                ForEach(modes, id: \.rawValue) { mode in
                    Button {
                        select(mode)
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
                        .tutorialHint(tutorial, steps: [.chooseColorInversion], isSuggested: mode == .difference)
                    }
                    .accessibilityAddTraits(controller.blendingMode == mode ? .isSelected : [])
                }
            } footer: {
                Text(L10n.text("Applies to new marker and watercolor strokes. Hybrid is the default."))
            }
        }
        .navigationTitle(L10n.text("Color blending"))
        .toolbar {
            // A link from the tutorial's own page would push over the lesson.
            if !tutorial.isActive {
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

/// The palette card shrunk to an icon: its first nine colors in the card's order, 3×3.
/// Derived from the saved palette, so it follows edits, reordering and deletions.
private struct PaletteSwatchIcon: View {
    let palette: InkPalette
    @ScaledMetric(relativeTo: .body) private var side = 28.0
    private static let columns = 3

    var body: some View {
        let colors = palette.allColors.prefix(Self.columns * Self.columns).map(\.color)
        Canvas { context, size in
            let cell = size.width / CGFloat(Self.columns)
            for index in 0..<(Self.columns * Self.columns) {
                // A hair of overlap hides seams between neighbouring cells.
                let rect = CGRect(x: CGFloat(index % Self.columns) * cell, y: CGFloat(index / Self.columns) * cell,
                                  width: cell + 0.25, height: cell + 0.25)
                // Empty cells stay faint, so a short palette still reads as a palette.
                let fill = index < colors.count ? colors[index] : Color.white.opacity(0.08)
                context.fill(Path(rect), with: .color(fill))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.2, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: side * 0.2, style: .continuous)
                .strokeBorder(.white.opacity(0.25), lineWidth: 1)
        }
        // Decorative: the palette's title already names it.
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
