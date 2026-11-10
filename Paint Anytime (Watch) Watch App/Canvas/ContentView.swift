import SwiftUI

struct ContentView: View {
    /// Center of the system clock text, in points from the top of the screen.
    private static let clockCenterY: CGFloat = 27
    @Binding var launchRequest: WatchLaunchRequest?
    var isActive = true
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @StateObject private var session = DrawingSessionController()
    @AppStorage(AutosaveSettings.enabledKey) private var autosaveEnabled = false
    @AppStorage(AutosaveSettings.intervalKey) private var autosaveMinutes = AutosaveSettings.defaultMinutes
    @AppStorage(AutosaveSettings.showsTimerKey) private var showsAutosaveTimer = AutosaveSettings.defaultShowsTimer
    @State private var autosave = CanvasAutosave()
    @StateObject private var menuOnboarding = OnboardingController()
    private var controller: CanvasController { session.canvas }
    @AppStorage(CanvasControlLayout.storageKey) private var controlLayoutData = Data()
    @AppStorage(CanvasControlLayout.enabledKey) private var customLayoutEnabled = false
    @State private var quickSettings: CanvasQuickAction?
    @AppStorage(WatchSketchAssist.phoneAvailabilityKey) private var sketchAssistOnPhone = false
    @State private var showsSketchAssistRequirements = false
    @Environment(\.openURL) private var openURL
    @State private var layoutCache = CanvasControlLayoutCache()
    private var customLayout: CanvasControlLayout? {
        CanvasControlLayout.custom(from: controlLayoutData, enabled: customLayoutEnabled,
                                   decode: layoutCache.layout(for:))
    }
    /// The built-in controls are the morph menus; any other arrangement is a custom layout.
    private var usesMorphToolbar: Bool { customLayout == nil }
    private var showsMorphToolbar: Bool {
        get { morphState.showsMorphToolbar }
        nonmutating set { morphState.showsMorphToolbar = newValue }
    }
    private var showsContentActions: Bool {
        get { morphState.showsContentActions }
        nonmutating set { morphState.showsContentActions = newValue }
    }
    @State private var showsLayers = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsToolSettings = false
    @State private var isMovingCanvas = false
    @State private var isEyedropperActive = false
    @State private var hasEyedropperSession = false
    @State private var cameraSampledColor: SIMD4<Float>?
    @State private var showsSampledPalette = false
    @AppStorage("watch.inkPalette.v1") private var paletteData = Data()
    @AppStorage("watch.inkPalettes.v2") private var palettesData = Data()
    @StateObject private var lasso = WatchLassoController()
    @State private var lassoToolbarInput = WatchLassoToolbarInput()
    private var showsSelectionActions: Bool {
        get { morphState.showsSelectionActions }
        nonmutating set { morphState.showsSelectionActions = newValue }
    }
    @State private var layerMoveName: String?
    @State private var layerMoveID = UUID()
    @State private var showsAppSettings = false
    /// An action chosen in the More menu, run once the menu has closed.
    @State private var pendingMenuAction: CanvasQuickAction?
    /// The canvas Tutorial button presents the menu sheet on the chapter choice.
    @State private var opensTutorialChapters = false
    @State private var showsGallery = false
    @State private var galleryArtworkFilename: String?
    @State private var galleryInitialBitmap: GalleryBitmap?
    @State private var savedNoticeID: UUID?
    @State private var galleryLaunchID = UUID()
    @State private var canvasSize: CGSize = .zero
    @State private var morphState = CanvasMorphState()
    @State private var controlRegions = CanvasControlRegions()
    private var canvasControlFrames: [CanvasToolbarControl: CGRect] { controlRegions.frames }
    private var controlFramesBinding: Binding<[CanvasToolbarControl: CGRect]> {
        Binding(get: { controlRegions.frames }, set: { controlRegions.updateToolbarFrames($0) })
    }
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        let _ = RenderDiagnostics.bodyEvaluated(.screen)
        Group {
        GeometryReader { geometry in
            canvasStack(geometry)
        }
        // Establish full-screen bounds before applying any presentation effects.
        .ignoresSafeArea()
        .overlay {
            // The canvas hides the system clock, so the countdown takes its place:
            // centered at the clock's height.
            if autosaveEnabled, showsAutosaveTimer, isActive, scenePhase == .active, !autosave.showsProgress,
               menuOnboarding.tutorialFolder == nil,
               !showsGallery, !showsAppSettings, !showsToolSettings, !showsLayers,
               !showsSampledPalette, quickSettings == nil,
               let autosaveTimerRange = autosave.timerRange {
                GeometryReader { overlay in
                    let frame = overlay.frame(in: .global)
                    // Fixed screen height of the hidden clock's center (measured on Apple Watch
                    // Ultra). Toolbar frames are not used: they differ in the free camera.
                    AutosaveCountdownView(timerRange: autosaveTimerRange)
                        .position(x: overlay.size.width / 2, y: Self.clockCenterY - frame.minY)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
        }
        // Reinstall toolbar items when returning from onboarding so watchOS
        // recalculates the clock position around the trailing tool button.
        // Keep the toolbar slots installed during autosave: removing the trailing
        // item makes watchOS move its clock. CanvasMenuControlVisibility hides the
        // controls and disables their hit targets without changing the clock layout.
        .toolbar { canvasToolbar }
        // A custom layout draws every control over the canvas, so its native bars only took
        // touches: strokes started in the top strip or beside an empty bottom slot never
        // reached the canvas. Tool settings keep the bars for their buttons.
        .toolbar(hidesCanvasBars ? .hidden : .automatic, for: .navigationBar, .bottomBar)
        }
        .requestsHiddenClock(isActive && menuOnboarding.tutorialFolder == nil
            && !showsGallery && !showsToolSettings && !showsAppSettings)
        .fullScreenCover(isPresented: $showsSampledPalette) {
            InkPaletteBrowser(library: InkPaletteLibrary.decode(palettesData, legacy: paletteData),
                              controller: controller, initialColor: cameraSampledColor) { library in
                if let data = try? JSONEncoder().encode(library) { palettesData = data }
                if !library.activePalette.selectedColors.contains(where: { $0.rgba == controller.pencilStyle.color }),
                   let first = library.activePalette.selectedColors.first {
                    controller.pencilStyle.color = first.rgba
                }
            }
            .environment(\.colorScheme, .dark)
        }
        .modifier(QuickSettingsPresentation(action: $quickSettings, controller: controller,
                                            viewportSize: canvasSize))
        .modifier(SketchAssistRequirementsAlert(isPresented: $showsSketchAssistRequirements))
        .onChange(of: customLayoutEnabled) { _, _ in
            morphState.customExpandedSlot = nil
        }
        .onChange(of: controlLayoutData) { _, _ in
            morphState.customExpandedSlot = nil
            showsMorphToolbar = false
            showsContentActions = false
        }
        .sheet(isPresented: $showsLayers) {
            WatchLayersView(controller: controller, canvasSize: controller.document.size(fallback: canvasSize))
        }
        .onChange(of: showsAppSettings) { _, shows in
            if !shows { foldMorphsWithoutAnimation() }
            if !shows { opensTutorialChapters = false }
            if !shows, menuOnboarding.tutorialFolder != nil { menuOnboarding.finishTutorial() }
        }
        .accessibilityHidden(showsAppSettings)
        .sheet(isPresented: Binding(
            get: { showsAppSettings && menuOnboarding.tutorialFolder == nil },
            set: { presented in
                // Starting the tutorial dismisses only the menu's system sheet.
                if !presented && menuOnboarding.tutorialFolder == nil {
                    showsAppSettings = false
                }
            }
        ), onDismiss: {
            // Another sheet cannot present while the menu is still dismissing.
            guard let action = pendingMenuAction else { return }
            pendingMenuAction = nil
            performQuickAction(action)
        }) {
            TutorialMenuPresentation(controller: controller, viewportSize: canvasSize, onboarding: menuOnboarding, onOpenDrawings: {
                showsAppSettings = false
                savedNoticeID = nil
                galleryArtworkFilename = nil
                galleryInitialBitmap = nil
                galleryLaunchID = UUID()
                showsGallery = true
            }, onFinish: {
                showsAppSettings = false
            }, opensTutorialChapters: opensTutorialChapters, onCanvasAction: { action in
                pendingMenuAction = action
                showsAppSettings = false
            })
        }
        .overlay {
            if showsAppSettings, let folder = menuOnboarding.tutorialFolder {
                NavigationStack {
                    TutorialPlayerView(folder: folder, chapters: menuOnboarding.tutorialChapters,
                                       onCompleteChapter: menuOnboarding.completeChapter) {
                        showsAppSettings = false
                    }
                    .toolbarColorScheme(.dark, for: .navigationBar, .bottomBar)
                }
                .id(folder)
                .preferredColorScheme(.dark)
                .environment(\.colorScheme, .dark)
                .compositingGroup()
                // Crossfade over the preserved drawing as the menu sheet closes.
                // Inserting an opaque tutorial instantly removes the artwork
                // from the sheet's live backdrop before dismissal finishes.
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3),
                   value: menuOnboarding.tutorialFolder)
        .task(id: session.savedDrawing?.id) {
            guard session.savedDrawing != nil else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                galleryArtworkFilename = nil
                galleryInitialBitmap = nil
                galleryLaunchID = UUID()
                session.savedDrawing = nil
            }
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.8)) {
                savedNoticeID = UUID()
            }
        }
        .onChange(of: session.autosaveNoticeID) { _, noticeID in
            guard noticeID != nil else { return }
            galleryInitialBitmap = nil
            galleryLaunchID = UUID()
        }
        .fullScreenCover(item: $session.pendingCanvasAction) { action in
            DestructiveConfirmationView(title: action.title, confirmTitle: L10n.text("Clear")) {
                session.pendingCanvasAction = nil
            } onConfirm: {
                session.pendingCanvasAction = nil
                session.performCanvasAction(action)
            }
        }
        .alert(L10n.text("Could not save"), isPresented: Binding(
            get: { session.exportError != nil }, set: { if !$0 { session.exportError = nil } }
        )) {
            Button(L10n.text("OK"), role: .cancel) { session.exportError = nil }
        } message: {
            Text(session.exportError ?? "")
        }
        .onChange(of: lasso.bounds) { _, bounds in
            if bounds != nil && !lasso.hidesSelectionActions { showsSelectionActions = true }
        }
        .onChange(of: lasso.hidesSelectionActions) { _, hides in
            // Complete strokes shows object actions only for the generated image.
            if hides { showsSelectionActions = false }
            else if lasso.bounds != nil { showsSelectionActions = true }
        }
        .onChange(of: usesMorphToolbar) { _, _ in
            showsContentActions = false
            showsMorphToolbar = false
        }
        .onChange(of: showsToolSettings) { _, shows in
            if !shows { foldMorphsWithoutAnimation() }
        }
        .onChange(of: isActive) { _, active in
            if !active { morphState.customExpandedSlot = nil }
            if !active { showsMorphToolbar = false; showsContentActions = false }
        }
        .onChange(of: isMovingCanvas) { _, moving in
            morphState.customExpandedSlot = nil
            if moving { showsMorphToolbar = false; showsContentActions = false; cameraSampledColor = nil }
            else {
                lasso.deactivate()
                isEyedropperActive = false
                hasEyedropperSession = false
            }
        }
        .onChange(of: session.canvasSessionID) { _, _ in
            showsContentActions = false
            showsMorphToolbar = false
            isMovingCanvas = false
            isEyedropperActive = false
            hasEyedropperSession = false
            lasso.deactivate()
            showsToolSettings = false
            if !session.isPreparingCanvas { showsGallery = false }
        }
        .task(id: isActive ? launchRequest?.id : nil) {
            guard isActive, let request = launchRequest else { return }
            await openDeepLink(request)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                showsContentActions = false
                if !showsAppSettings && session.savedDrawing == nil && session.pendingCanvasAction == nil {
                    showsMorphToolbar = false
                }
                controller.cancelStroke()
                controller.flushStylePreferences()
            }
        }
        .task(id: autosaveTaskID) {
            await runAutosave()
        }
        .disabled(autosave.showsProgress)
        .overlay {
            if autosave.showsProgress {
                AutosaveProgressView(completed: autosave.completed)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: reduceMotion ? 0.1 : 0.22), value: autosave.showsProgress)
    }

    private var autosaveConfigurationID: String {
        "\(autosaveEnabled)-\(isActive)-\(AutosaveSettings.minutes(autosaveMinutes))-\(session.canvasSessionID)"
    }

    private var autosaveTaskID: String {
        "\(autosaveConfigurationID)-\(scenePhase == .active)"
    }

    private func runAutosave() async {
        await autosave.run(
            configurationID: autosaveConfigurationID,
            seconds: AutosaveSettings.minutes(autosaveMinutes) * 60,
            canRun: { autosaveEnabled && isActive && scenePhase == .active },
            isBusy: { isBusyForAutosave },
            prepare: {
                guard controller.canClear else { return false }
                savedNoticeID = nil
                return true
            },
            save: {
                let previousNotice = session.autosaveNoticeID
                session.saveDrawing(size: canvasSize, scale: displayScale, automatically: true)
                return session.autosaveNoticeID != previousNotice
            })
    }

    /// Interaction and presentations an autosave waits for.
    private var isBusyForAutosave: Bool {
        controller.activeStroke != nil || lasso.isActive || lasso.isPreparing
            || showsGallery || showsAppSettings || showsLayers || showsToolSettings
            || showsSampledPalette || quickSettings != nil || isMovingCanvas
            || session.isPreparingCanvas || session.isSavingDrawing || session.pendingCanvasAction != nil
            || session.savedDrawing != nil || session.exportError != nil
    }

    @MainActor
    private func openDeepLink(_ request: WatchLaunchRequest) async {
        guard request.destination != .app else { return }
        controller.cancelStroke()
        let hasPresentation = showsSampledPalette || showsLayers || showsAppSettings
            || session.savedDrawing != nil || session.pendingCanvasAction != nil || session.exportError != nil
        showsSampledPalette = false
        showsLayers = false
        showsAppSettings = false
        session.savedDrawing = nil
        session.pendingCanvasAction = nil
        session.exportError = nil
        showsToolSettings = false
        showsGallery = false
        galleryInitialBitmap = nil
        savedNoticeID = nil
        showsMorphToolbar = false
        showsContentActions = false
        isMovingCanvas = false
        isEyedropperActive = false
        hasEyedropperSession = false
        lasso.deactivate()
        // Let an existing modal finish dismissing before presenting a discard prompt.
        if hasPresentation {
            do { try await Task.sleep(for: .milliseconds(500)) }
            catch { return }
        }
        guard !Task.isCancelled, isActive, launchRequest?.id == request.id else { return }
        switch request.destination {
        case .app, .canvas:
            break
        case .settings:
            showsAppSettings = true
        case .newCanvas:
            session.requestCanvasAction(.open(CanvasDocument()))
        case .gallery:
            galleryArtworkFilename = request.artworkFilename
            galleryLaunchID = request.id
            showsGallery = true
        }
        launchRequest = nil
    }


    private func canvasStack(_ geometry: GeometryProxy) -> some View {
        ZStack {
            Color.black

            drawingPage
                .frame(width: geometry.size.width, height: geometry.size.height)
                .background(.white)
                .opacity(showsToolSettings || showsGallery ? 0 : 1)
                .allowsHitTesting(!showsToolSettings && !showsGallery)
                .accessibilityHidden(showsToolSettings)
                .zIndex(0)

            if let layerMoveName, lasso.isActive, !showsGallery, !showsToolSettings {
                CanvasNoticeLabel(text: layerMoveName)
                    .id(layerMoveID)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.85).combined(with: .opacity))
                    .allowsHitTesting(false)
                    .zIndex(4)
                    .task(id: layerMoveID) {
                        do { try await Task.sleep(for: .seconds(1.2)) } catch { return }
                        withAnimation(.easeOut(duration: 0.2)) { self.layerMoveName = nil }
                    }
            }

            CanvasMorphPanels(state: morphState, regions: controlRegions,
                              session: session, lasso: lasso, size: geometry.size,
                              canvasOrigin: geometry.frame(in: .global).origin,
                              isVisible: isActive && !showsGallery && !showsToolSettings &&
                                  (customLayout == nil || isMovingCanvas || lasso.isActive),
                              usesMorphToolbar: usesMorphToolbar, isMovingCanvas: isMovingCanvas,
                              isEyedropperActive: isEyedropperActive,
                              showsToolSettings: $showsToolSettings, showsAppSettings: $showsAppSettings,
                              showsLayers: $showsLayers,
                              onStartLasso: { startLasso() }, onFinishLasso: finishLasso,
                              onMoveSelectionLayer: moveSelectionLayer,
                              onClearLayerMoveName: { layerMoveName = nil })
                .modifier(CanvasMenuControlVisibility(isHidden: showsAppSettings || autosave.showsProgress))
                .zIndex(3)

            if let customLayout, isActive, !showsGallery, !showsToolSettings,
               !isMovingCanvas, !lasso.isActive, controller.activeStroke == nil {
                CustomCanvasControls(layout: customLayout, state: morphState,
                                     regions: controlRegions, controller: controller,
                                     size: geometry.size,
                                     canvasOrigin: geometry.frame(in: .global).origin,
                                     onAction: performQuickAction)
                    .modifier(CanvasMenuControlVisibility(isHidden: showsAppSettings || quickSettings != nil || autosave.showsProgress))
                    .zIndex(3)
            }

            if showsGallery {
                SavedDrawingsView(initialArtworkFilename: galleryArtworkFilename, initialBitmap: galleryInitialBitmap,
                    needsDiscardConfirmation: controller.needsDiscardConfirmation,
                    isPreparingCanvas: session.isPreparingCanvas,
                    preparationError: session.canvasPreparationError, onClose: {
                    showsGallery = false
                    galleryArtworkFilename = nil
                    galleryInitialBitmap = nil
                    savedNoticeID = nil
                }) { document in
                    // Gallery confirms discard before it reads the saved project.
                    session.performCanvasAction(.open(document))
                }
                .id(galleryLaunchID)
                .frame(width: geometry.size.width, height: geometry.size.height)
                // Fade the gallery as one surface. Fading its overlapping
                // layers separately reveals the thumbnail grid underneath.
                .compositingGroup()
                .transition(.opacity)
                .zIndex(2)
            }

            if session.isSavingDrawing {
                // Same overlay and fade as opening a drawing from the gallery:
                // appears at once, fades out as the "saved" notice springs in.
                // The fade is scoped to this transition: an `.animation(value:)` on the
                // whole stack would retime the morph collapse that starts in the same update.
                LoadingDimOverlay()
                    .ignoresSafeArea()
                    .transition(.asymmetric(
                        insertion: .identity,
                        removal: .opacity.animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3))))
                    .zIndex(5)
            }

            if let savedNoticeID, !showsGallery {
                CanvasNoticeLabel(text: L10n.text("Artwork saved to gallery"), minimumScaleFactor: 0.5)
                    .id(savedNoticeID)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.85).combined(with: .opacity))
                    .allowsHitTesting(false)
                    .zIndex(4)
                    .task(id: savedNoticeID) {
                        do { try await Task.sleep(for: .seconds(2)) } catch { return }
                        withAnimation(.easeOut(duration: 0.2)) { self.savedNoticeID = nil }
                    }
            }

            if showsToolSettings {
                WatchToolSettingsView(controller: controller)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .background(.black)
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showsToolSettings)
        .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3), value: showsGallery)
        .frame(width: geometry.size.width, height: geometry.size.height)
        .clipped()
        .onAppear {
            canvasSize = geometry.size
            controlRegions.screenBounds = geometry.frame(in: .global)
        }
        .onChange(of: geometry.size) { _, size in
            canvasSize = size
            controlRegions.screenBounds = geometry.frame(in: .global)
        }
    }

    /// The custom canvas layout is on screen with no native control of its own:
    /// the same state that installs only the custom toolbar anchors.
    /// The bars stay up until every anchor has been measured on screen once. Leaving the
    /// first-launch tutorial (its finish confirmation hides the bars) inserted the anchors
    /// straight into hidden bars, so the drawn controls fell back to estimated corners.
    /// The anchors are invisible, so the bars show nothing for that one layout pass.
    private var hidesCanvasBars: Bool {
        customLayout != nil && isActive && menuOnboarding.tutorialFolder == nil
            && !showsGallery && !showsToolSettings && !isMovingCanvas && !lasso.isActive
            && controlRegions.hasCustomLayoutAnchors
    }

    /// Kept out of `body` so the view stays within type-checking limits.
    private var canvasToolbar: CanvasToolbar {
        CanvasToolbar(
            controller: controller, lasso: lasso, lassoToolbarInput: lassoToolbarInput,
            morphState: morphState, customLayout: customLayout,
            isShown: isActive && menuOnboarding.tutorialFolder == nil && !showsGallery,
            isMovingCanvas: isMovingCanvas,
            hasActiveStroke: controller.activeStroke != nil,
            instrument: controller.pencilStyle.instrument,
            lassoIsActive: lasso.isActive,
            awaitsSketchAssistConfirmation: lasso.awaitsSketchAssistConfirmation,
            lassoHidesControls: lasso.hidesControls,
            canMoveSelectionUp: lasso.canMoveLayer(1, controller: controller),
            showsMorphToolbar: showsMorphToolbar,
            showsContentActions: showsContentActions,
            showsSelectionActions: showsSelectionActions,
            hidesMenuControls: showsAppSettings || autosave.showsProgress,
            hidesCustomAnchors: showsAppSettings || quickSettings != nil || autosave.showsProgress,
            reduceMotion: reduceMotion,
            showsToolSettings: $showsToolSettings, showsAppSettings: $showsAppSettings,
            isEyedropperActive: $isEyedropperActive, hasEyedropperSession: $hasEyedropperSession,
            cameraSampledColor: $cameraSampledColor,
            controlFrames: controlFramesBinding,
            onMoveSelectionLayer: moveSelectionLayer,
            onFinishLasso: finishLasso,
            onFinishCameraTool: finishCameraTool,
            onAction: performQuickAction)
    }


    /// A short tap the canvas received inside a drawn custom control's zone: with the native
    /// bars hidden such taps sometimes reach the canvas under the control instead of it
    /// (device log: the top-trailing control). Do what that collapsed control does.
    private func forwardCanvasTap(_ control: CanvasToolbarControl) {
        guard hidesCanvasBars, let customLayout else { return }
        let index: Int
        if case .custom(let slot) = control { index = slot }
        else if let slot = CustomCanvasControls.anchors.firstIndex(of: control) { index = slot }
        else { return }
        guard customLayout.slots.indices.contains(index), !customLayout.slots[index].isEmpty,
              // An open morph's rows are buttons of their own.
              morphState.customExpandedSlot != index else { return }
        let assignment = customLayout.slots[index]
        if assignment.isMorph {
            withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
                morphState.customExpandedSlot = index
            }
        } else if let action = assignment.actions.first {
            performQuickAction(action)
        }
    }

    /// Tool settings and More leave the morph open so a collapse does not fight their
    /// transition. Fold it as the screen starts to close: the menu's controls are still
    /// faded out and the tool settings hide the panels, so the canvas returns folded
    /// without a visible jump.
    private func foldMorphsWithoutAnimation() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            morphState.customExpandedSlot = nil
            showsMorphToolbar = false
            showsContentActions = false
        }
    }

    private func performQuickAction(_ action: CanvasQuickAction) {
        guard isActive, controller.activeStroke == nil, !showsAppSettings,
              quickSettings == nil, !showsGallery, !showsToolSettings,
              !isMovingCanvas, !lasso.isActive else { return }
        // Native toolbar slots stay enabled; a tap with nothing to undo, redo or clear
        // gets a haptic and leaves the morph open.
        guard action.isAvailable(in: controller) else { return UnavailableActionFeedback.play() }
        // Every option except Undo, Redo, Tool settings and More collapses the morph with the
        // same spring as opening; those two screens push in, and a collapse fights that transition.
        // Save shows its overlay now and exports only after the collapse settles:
        // the synchronous exporter would otherwise freeze the spring mid-flight.
        var afterCollapse: (() -> Void)?
        if case .save = action {
            guard session.beginSavingDrawing() else { return }
            let size = canvasSize, scale = displayScale
            afterCollapse = { session.completeSavingDrawing(size: size, scale: scale) }
        }
        if !action.keepsMorphOpen {
            withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8),
                          completionCriteria: .removed) {
                morphState.customExpandedSlot = nil
                showsMorphToolbar = false
                showsContentActions = false
            } completion: {
                afterCollapse?()
            }
        } else {
            afterCollapse?()
        }
        controller.cancelStroke()
        switch action {
        case .brush: showsToolSettings = true
        case .clear:
            if controller.canClear { session.requestCanvasAction(.clear) }
        case .save: break // Started above, after the collapse.
        case .lasso: startLasso()
        case .undo:
            if controller.canUndo { controller.undo() }
        case .redo:
            if controller.canRedo { controller.redo() }
        case .layers: showsLayers = true
        case .gallery:
            savedNoticeID = nil
            galleryArtworkFilename = nil
            galleryInitialBitmap = nil
            galleryLaunchID = UUID()
            showsGallery = true
        case .language, .canvasSize, .toolSynchronization, .visiblePalettes, .blending,
             .perspectiveGuides, .canvasEditor, .autosave, .share:
            quickSettings = action
        case .eraserToggle: controller.toggleEraser()
        // Close only collapses the morph (above).
        case .closeMorph: break
        case .sketchAssist:
            // Opens straight into selecting strokes for Image Playground.
            guard AppReleaseFeatures.current.showsSketchAssist else { break }
            if sketchAssistOnPhone { startLasso(lockedTo: .sketchAssist) }
            else { showsSketchAssistRequirements = true }
        case .tutorial:
            // Let the person choose the full tour or one chapter; the menu's
            // preparation, failure alert and tutorial handoff start it.
            opensTutorialChapters = true
            showsAppSettings = true
        case .reportBug:
            var components = URLComponents()
            components.scheme = "mailto"
            components.path = "paintanytime.app@gmail.com"
            components.queryItems = [URLQueryItem(name: "subject", value: "Paint Anytime — " + L10n.text("Report a bug"))]
            if let url = components.url { openURL(url) }
        case .eyedropper, .camera:
            cameraSampledColor = nil
            hasEyedropperSession = action == .eyedropper
            isEyedropperActive = action == .eyedropper
            isMovingCanvas = true
        case .palettes:
            cameraSampledColor = nil
            showsSampledPalette = true
        case .more: showsAppSettings = true
        case .nothing: break
        }
    }

    private func finishCameraTool() {
        let shouldEditColor = hasEyedropperSession && cameraSampledColor != nil
        controller.cancelStroke()
        lasso.deactivate()
        isEyedropperActive = false
        hasEyedropperSession = false
        isMovingCanvas = false
        if shouldEditColor { showsSampledPalette = true }
    }

    private func startLasso(lockedTo lockedMode: WatchLassoMode? = nil) {
        controller.cancelStroke()
        isMovingCanvas = false
        isEyedropperActive = false
        hasEyedropperSession = false
        showsContentActions = false
        showsMorphToolbar = false
        showsSelectionActions = false
        lasso.activate(lockedTo: lockedMode)
    }

    private func finishLasso() {
        layerMoveName = nil
        lasso.deactivate()
        showsSelectionActions = false
    }

    private func moveSelectionLayer(_ offset: Int) {
        guard let name = lasso.moveLayer(offset, controller: controller) else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.8)) {
            layerMoveID = UUID()
            layerMoveName = name
        }
    }

    private var drawingPage: some View {
        // Animate the whole page above, keeping the cached artwork fully visible inside it.
        return WatchCanvasView(controller: controller, lasso: lasso, lassoToolbarInput: lassoToolbarInput, onArtworkPrepared: { succeeded in
            guard session.isPreparingCanvas else { return }
            session.isPreparingCanvas = false
            if succeeded {
                showsGallery = false
            } else {
                session.canvasPreparationError = L10n.text("Could not open the image.")
            }
        }, acceptsInput: isActive && quickSettings == nil && !showsLayers && !showsSampledPalette && !showsToolSettings && !showsAppSettings && !showsGallery && session.savedDrawing == nil && session.pendingCanvasAction == nil && !session.isSavingDrawing, protectedControlsProvider: { protectedCanvasControls }, isMovingCanvas: $isMovingCanvas, isEyedropperActive: isEyedropperActive, onSampleColor: { color in
            cameraSampledColor = color
        }, onCanvasInteraction: {
            if morphState.customExpandedSlot != nil {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    morphState.customExpandedSlot = nil
                }
            }
            if showsContentActions {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { showsContentActions = false }
            }
            if showsMorphToolbar {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    showsMorphToolbar = false
                }
            }
        }, onProtectedTap: forwardCanvasTap)
            .id(session.canvasSessionID)
    }

    private var protectedCanvasControls: [CanvasToolbarControl: CGRect] {
        guard isActive && !showsGallery && !showsToolSettings && controller.activeStroke == nil && !lasso.hidesControls else { return [:] }
        return canvasControlFrames.filter { control, _ in
            if lasso.isActive { return (!showsSelectionActions && control == .tools) || control == .canvasToolsMorph || (showsSelectionActions && control == .morph) || (lasso.awaitsSketchAssistConfirmation && control == .more) }
            if isMovingCanvas { return control == .tools || control == .more }
            if let customLayout {
                if case .custom = control { return true }
                // An empty slot keeps an invisible native anchor only so the clock stays put;
                // protecting it left a dead zone in an empty corner of the canvas.
                if let index = CustomCanvasControls.anchors.firstIndex(of: control) {
                    return customLayout.slots.indices.contains(index) && !customLayout.slots[index].isEmpty
                }
                return control == .more
            }
            if case .custom = control { return false }
            if usesMorphToolbar { return control == .morph || control == .contentMorph }
            return control != .morph && control != .canvasToolsMorph && control != .clear
        }
    }
}
