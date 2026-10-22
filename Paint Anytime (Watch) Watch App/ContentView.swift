import SwiftUI

struct ContentView: View {
    @Binding var launchRequest: WatchLaunchRequest?
    var isActive = true
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @StateObject private var session = DrawingSessionController()
    @StateObject private var menuOnboarding = OnboardingController()
    private var controller: CanvasController { session.canvas }
    @AppStorage("experimental.morphToolbar") private var usesMorphToolbar = true
    private var canvasToolbarDiameter: CGFloat {
        usesMorphToolbar ? 32 : MorphPanelGeometry.buttonDiameter
    }
    private var showsMorphToolbar: Bool {
        get { morphState.showsMorphToolbar }
        nonmutating set { morphState.showsMorphToolbar = newValue }
    }
    private var showsContentActions: Bool {
        get { morphState.showsContentActions }
        nonmutating set { morphState.showsContentActions = newValue }
    }
    @State private var showsCanvasSize = false
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
        Group {
        GeometryReader { geometry in
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
                    Text(layerMoveName)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 42)
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
                                  isVisible: isActive && !showsGallery && !showsToolSettings,
                                  usesMorphToolbar: usesMorphToolbar, isMovingCanvas: isMovingCanvas,
                                  isEyedropperActive: isEyedropperActive,
                                  showsToolSettings: $showsToolSettings, showsAppSettings: $showsAppSettings,
                                  showsCanvasSize: $showsCanvasSize, showsLayers: $showsLayers,
                                  onStartLasso: startLasso, onFinishLasso: finishLasso,
                                  onMoveSelectionLayer: moveSelectionLayer,
                                  onClearLayerMoveName: { layerMoveName = nil })
                    .modifier(CanvasMenuControlVisibility(isHidden: showsAppSettings))
                    .zIndex(3)

                if showsGallery {
                    SavedDrawingsView(initialArtworkFilename: galleryArtworkFilename, initialBitmap: galleryInitialBitmap, onClose: {
                        showsGallery = false
                        galleryArtworkFilename = nil
                        galleryInitialBitmap = nil
                        savedNoticeID = nil
                    }) { document in
                        session.requestCanvasAction(.open(document))
                    }
                    .id(galleryLaunchID)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .transition(.opacity)
                    .zIndex(2)
                }

                if let savedNoticeID, !showsGallery {
                    Text(L10n.text("Artwork saved to gallery"))
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.5)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 42)
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
            .onAppear { canvasSize = geometry.size }
            .onChange(of: geometry.size) { _, size in canvasSize = size }
        }
        // Establish full-screen bounds before applying any presentation effects.
        .ignoresSafeArea()
        // Reinstall toolbar items when returning from onboarding so watchOS
        // recalculates the clock position around the trailing tool button.
        .toolbar {
            if !usesMorphToolbar && isActive && menuOnboarding.tutorialFolder == nil && !showsGallery && !showsToolSettings && !isMovingCanvas && !lasso.isActive && controller.activeStroke == nil {
                ToolbarItemGroup(placement: .bottomBar) {
                    MorphControlsScope {
                        Button {
                            if showsContentActions {
                                startLasso()
                            } else {
                                withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
                                    showsContentActions = true
                                }
                            }
                        } label: {
                            Image(systemName: "doc.badge.gearshape")
                                .frame(width: 18, height: 18).opacity(0)
                        }
                        .watchToolbarButtonStyle(diameter: canvasToolbarDiameter, usesCanvasMaterial: true, hidesNativeChrome: true)
                        .accessibilityLabel(L10n.text(showsContentActions ? "Lasso" : "Canvas actions"))
                        .trackCanvasControl(.clear, frames: controlFramesBinding)
                        .modifier(CanvasMenuControlVisibility(isHidden: showsAppSettings))
                    }
                    Spacer(minLength: 0)
                    Button { controller.undo() } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .disabled(!controller.canUndo)
                    .watchToolbarButtonStyle(diameter: canvasToolbarDiameter, usesCanvasMaterial: true)
                    .accessibilityLabel(L10n.text("Undo"))
                    .trackCanvasControl(.undo, frames: controlFramesBinding)
                    .modifier(CanvasMenuControlVisibility(isHidden: showsAppSettings))
                    Spacer(minLength: 0)
                    Button { controller.redo() } label: {
                        Image(systemName: "arrow.uturn.forward")
                    }
                    .disabled(!controller.canRedo)
                    .watchToolbarButtonStyle(diameter: canvasToolbarDiameter, usesCanvasMaterial: true)
                    .accessibilityLabel(L10n.text("Redo"))
                    .trackCanvasControl(.redo, frames: controlFramesBinding)
                    .modifier(CanvasMenuControlVisibility(isHidden: showsAppSettings))
                    Spacer(minLength: 0)
                    Button {
                        controller.cancelStroke()
                        showsContentActions = false
                        showsLayers = true
                    } label: {
                        Image(systemName: "square.3.layers.3d")
                    }
                    .watchToolbarButtonStyle(diameter: canvasToolbarDiameter, usesCanvasMaterial: true)
                    .accessibilityLabel(L10n.text("Layers"))
                    .trackCanvasControl(.save, frames: controlFramesBinding)
                    .modifier(CanvasMenuControlVisibility(isHidden: showsAppSettings))
                }
            }

            if isActive && menuOnboarding.tutorialFolder == nil && !showsGallery && !showsToolSettings && lasso.isActive {
                ToolbarItem(placement: .topBarLeading) {
                    // Balance Done to center the system clock, and forward this
                    // native toolbar region's drags to the same lasso controller.
                    WatchLassoToolbarTouchRegion(input: lassoToolbarInput, lasso: lasso,
                        controller: controller, diameter: canvasToolbarDiameter)
                }
            }
            if isActive && menuOnboarding.tutorialFolder == nil && !showsGallery && !showsToolSettings && !lasso.isActive {
                ToolbarItem(placement: .topBarLeading) {
                    MorphControlsScope {
                        Button {
                            if lasso.isActive {
                                if showsSelectionActions { moveSelectionLayer(1) }
                                else { lasso.setMode(.strokes) }
                            } else if isMovingCanvas {
                                controller.cancelStroke()
                                isEyedropperActive.toggle()
                                hasEyedropperSession = true
                            } else if usesMorphToolbar {
                                if showsContentActions {
                                    showsContentActions = false
                                    showsAppSettings = true
                                } else {
                                    withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
                                        showsMorphToolbar = false
                                        showsContentActions = true
                                    }
                                }
                            } else { showsAppSettings = true }
                        } label: {
                            Image(systemName: lasso.isActive ? "checkmark" : isMovingCanvas ? "eyedropper" : usesMorphToolbar ? "doc.badge.gearshape" : "ellipsis")
                                .foregroundStyle(lasso.isActive || isEyedropperActive ? .green : .primary)
                                .frame(width: 18, height: 18, alignment: .center)
                                .opacity(lasso.isActive || isMovingCanvas || usesMorphToolbar ? 0 : 1)
                                .contentShape(Rectangle())
                        }
                        .watchToolbarButtonStyle(diameter: canvasToolbarDiameter, usesCanvasMaterial: true, hidesNativeChrome: lasso.isActive ? true : (usesMorphToolbar || isMovingCanvas) || controller.activeStroke != nil)
                        .accessibilityLabel(L10n.text(lasso.isActive ? (showsSelectionActions ? "Move to layer above" : WatchLassoMode.strokes.title) : isMovingCanvas ? "Eyedropper" : usesMorphToolbar && !showsContentActions ? "Canvas actions" : "More"))
                        .disabled(lasso.isActive && showsSelectionActions && !lasso.canMoveLayer(1, controller: controller))
                        .accessibilityAddTraits(isEyedropperActive ? [.isSelected] : [])
                        .trackCanvasControl(.more, frames: controlFramesBinding)
                        .modifier(CanvasMenuControlVisibility(isHidden: showsAppSettings))
                        .opacity(controller.activeStroke != nil ? 0 : 1)
                        .allowsHitTesting(controller.activeStroke == nil)
                        .accessibilityHidden(controller.activeStroke != nil)
                    }
                }
            }
            if isActive && menuOnboarding.tutorialFolder == nil && !showsGallery {
                ToolbarItem(placement: .topBarTrailing) {
                    MorphControlsScope {
                        Button {
                            if lasso.isActive {
                                finishLasso()
                            } else if isMovingCanvas {
                                finishCameraTool()
                            }
                            else if usesMorphToolbar && !showsToolSettings {
                                if showsMorphToolbar {
                                    showsMorphToolbar = false
                                    showsToolSettings = true
                                } else {
                                    withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
                                        showsContentActions = false
                                        showsMorphToolbar = true
                                    }
                                }
                            } else { showsToolSettings.toggle() }
                        } label: {
                            Group {
                                if showsToolSettings || isMovingCanvas || lasso.isActive {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.green)
                                } else if usesMorphToolbar {
                                    Image(systemName: "paintbrush.pointed")
                                } else {
                                    ToolIcon(instrument: controller.pencilStyle.instrument)
                                }
                            }
                            // Keep the label bounds identical when switching to Done,
                            // so the toolbar centers the checkmark like the tool icon.
                            .frame(width: 18, height: 18, alignment: .center)
                            .opacity(morphOwnsTrailingControl ? 0 : 1)
                            .contentShape(Rectangle())
                        }
                        .watchToolbarButtonStyle(diameter: canvasToolbarDiameter, usesCanvasMaterial: true, hidesNativeChrome: morphOwnsTrailingControl || lasso.hidesControls || (!showsToolSettings && controller.activeStroke != nil))
                        .accessibilityLabel(showsToolSettings || isMovingCanvas || lasso.isActive ? L10n.text("Done") : L10n.text(usesMorphToolbar && !showsMorphToolbar ? "Open drawing controls" : "Tool settings"))
                        .trackCanvasControl(.tools, frames: controlFramesBinding)
                        .modifier(CanvasMenuControlVisibility(isHidden: showsAppSettings))
                        // Keep the toolbar slot installed so the system clock does not
                        // move when drawing temporarily hides the button.
                        .opacity((!showsToolSettings && controller.activeStroke != nil) || lasso.hidesControls ? 0 : 1)
                        .allowsHitTesting((showsToolSettings || controller.activeStroke == nil) && !lasso.hidesControls)
                        .accessibilityHidden((!showsToolSettings && controller.activeStroke != nil) || lasso.hidesControls)
                    }
                }
            }
        }
        }
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
        .sheet(isPresented: $showsCanvasSize) {
            WatchCanvasSizeView(controller: controller, viewportSize: canvasSize, displayScale: displayScale)
        }
        .sheet(isPresented: $showsLayers) {
            WatchLayersView(controller: controller, canvasSize: controller.document.size(fallback: canvasSize))
        }
        .onChange(of: showsLayers) { _, shows in
            if shows { showsMorphToolbar = false; showsContentActions = false }
        }
        .onChange(of: showsToolSettings) { _, shows in
            if shows { showsContentActions = false }
        }
        .onChange(of: showsAppSettings) { _, shows in
            if shows { showsContentActions = false }
            else if menuOnboarding.tutorialFolder != nil { menuOnboarding.finishTutorial() }
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
        )) {
            TutorialMenuPresentation(controller: controller, onboarding: menuOnboarding, onOpenDrawings: {
                showsAppSettings = false
                savedNoticeID = nil
                galleryArtworkFilename = nil
                galleryInitialBitmap = nil
                galleryLaunchID = UUID()
                showsGallery = true
            }, onFinish: {
                showsAppSettings = false
            })
            .task { await resetMorphBehindPresentation() }
        }
        .overlay {
            if showsAppSettings, let folder = menuOnboarding.tutorialFolder {
                NavigationStack {
                    TutorialPlayerView(folder: folder) {
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
                showsMorphToolbar = false
                showsContentActions = false
                galleryArtworkFilename = nil
                galleryInitialBitmap = nil
                galleryLaunchID = UUID()
                session.savedDrawing = nil
            }
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.8)) {
                savedNoticeID = UUID()
            }
        }
        .fullScreenCover(item: $session.pendingCanvasAction) { action in
            DestructiveConfirmationView(title: action.title, confirmTitle: L10n.text("Clear")) {
                session.pendingCanvasAction = nil
            } onConfirm: {
                session.pendingCanvasAction = nil
                session.performCanvasAction(action)
            }
            .task { await resetMorphBehindPresentation() }
        }
        .alert(L10n.text("Could not save"), isPresented: Binding(
            get: { session.exportError != nil }, set: { if !$0 { session.exportError = nil } }
        )) {
            Button(L10n.text("OK"), role: .cancel) { session.exportError = nil }
        } message: {
            Text(session.exportError ?? "")
        }
        .onChange(of: lasso.bounds) { _, bounds in
            if bounds != nil { showsSelectionActions = true }
        }
        .onChange(of: usesMorphToolbar) { _, _ in
            showsContentActions = false
            showsMorphToolbar = false
        }
        .onChange(of: isActive) { _, active in
            if !active { showsMorphToolbar = false; showsContentActions = false }
        }
        .onChange(of: isMovingCanvas) { _, moving in
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
            showsGallery = false
        }
        .task(id: isActive ? launchRequest?.id : nil) {
            guard isActive, let request = launchRequest else { return }
            await openComplication(request)
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
    }

    @MainActor
    private func openComplication(_ request: WatchLaunchRequest) async {
        guard request.destination != .app else { return }
        controller.cancelStroke()
        let hasPresentation = showsCanvasSize || showsLayers || showsAppSettings
            || session.savedDrawing != nil || session.pendingCanvasAction != nil || session.exportError != nil
        showsCanvasSize = false
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
        case .app:
            break
        case .newCanvas:
            session.requestCanvasAction(.open(CanvasDocument()))
        case .gallery:
            galleryArtworkFilename = request.artworkFilename
            galleryLaunchID = request.id
            showsGallery = true
        }
        launchRequest = nil
    }

    @MainActor
    private func resetMorphBehindPresentation() async {
        guard showsMorphToolbar || showsContentActions else { return }
        // onAppear/task starts during the presentation transition, not after it.
        // A view-owned task is cancelled if the user dismisses the window early.
        do {
            try await Task.sleep(for: .seconds(1))
            try Task.checkCancellation()
        } catch {
            return
        }
        guard showsAppSettings || session.savedDrawing != nil || session.pendingCanvasAction != nil else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            showsMorphToolbar = false
            showsContentActions = false
        }
    }

    private var morphOwnsTrailingControl: Bool {
        !showsToolSettings && (isMovingCanvas || (lasso.isActive && showsSelectionActions) ||
            (!lasso.isActive && usesMorphToolbar))
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

    private func startLasso() {
        controller.cancelStroke()
        isMovingCanvas = false
        isEyedropperActive = false
        hasEyedropperSession = false
        showsContentActions = false
        showsMorphToolbar = false
        showsSelectionActions = false
        lasso.activate()
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
        WatchCanvasView(controller: controller, lasso: lasso, lassoToolbarInput: lassoToolbarInput, acceptsInput: isActive && !showsCanvasSize && !showsLayers && !showsSampledPalette && !showsToolSettings && !showsAppSettings && !showsGallery && session.savedDrawing == nil && session.pendingCanvasAction == nil, protectedControlsProvider: { protectedCanvasControls }, isMovingCanvas: $isMovingCanvas, isEyedropperActive: isEyedropperActive, onSampleColor: { color in
            cameraSampledColor = color
        }, onCanvasInteraction: {
            if showsContentActions {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { showsContentActions = false }
            }
            if showsMorphToolbar {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    showsMorphToolbar = false
                }
            }
        })
            .id(session.canvasSessionID)
    }

    private var protectedCanvasControls: [CanvasToolbarControl: CGRect] {
        guard isActive && !showsGallery && !showsToolSettings && controller.activeStroke == nil && !lasso.hidesControls else { return [:] }
        return canvasControlFrames.filter { control, _ in
            if lasso.isActive { return (!showsSelectionActions && control == .tools) || control == .canvasToolsMorph || (showsSelectionActions && control == .morph) }
            if isMovingCanvas { return control == .tools || control == .more }
            if usesMorphToolbar { return control == .morph || control == .contentMorph }
            return control != .morph && control != .canvasToolsMorph && control != .clear
        }
    }
}

extension View {
    func trackCanvasControl(_ control: CanvasToolbarControl,
                            frames: Binding<[CanvasToolbarControl: CGRect]>) -> some View {
        onGeometryChange(for: CGRect.self) { geometry in
            // Toolbar items and the canvas have different local coordinate spaces.
            TutorialDebug.measure("toolbar.geometry.read") { geometry.frame(in: .global) }
        } action: { frame in
            guard frames.wrappedValue[control] != frame else { return }
            TutorialDebug.trace("toolbar.geometry.beforeWrite", "control=\(control) old=\(String(describing: frames.wrappedValue[control])) new=\(frame)")
            frames.wrappedValue[control] = frame
            TutorialDebug.trace("toolbar.geometry.afterWrite", "control=\(control)")
        }
    }
}

struct DestructiveConfirmationView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @Environment(\.layoutDirection) private var layoutDirection
    let title: String
    let confirmTitle: String
    var cancelTitle: String = L10n.text("No")
    var onCancel: () -> Void
    var onConfirm: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                ConfirmationButtonsLayout(layoutDirection: layoutDirection) {
                    Button(action: onCancel) {
                        Text(cancelTitle)
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .watchActionButtonStyle()

                    Button(role: .destructive, action: onConfirm) {
                        Text(confirmTitle)
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .watchActionButtonStyle()
                    .tint(.red)
                    .foregroundStyle(.red)
                }
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 16)
        }
        .background(.black)
    }
}

/// Share spare width equally after measuring the localized button labels.
private struct ConfirmationButtonsLayout: Layout {
    let layoutDirection: LayoutDirection
    private let spacing: CGFloat = 8

    private func widths(for proposedWidth: CGFloat?, subviews: Subviews) -> [CGFloat] {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }
        guard ideal.count == 2 else { return ideal }
        let available = max(0, (proposedWidth ?? (ideal[0] + ideal[1] + spacing)) - spacing)
        let minimum = min(44, available / 2)
        let first = min(available - minimum, max(minimum, (available + ideal[0] - ideal[1]) / 2))
        return [first, available - first]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths = widths(for: proposal.width, subviews: subviews)
        let height = zip(subviews, widths).map { view, width in
            view.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }.max() ?? 0
        return CGSize(width: widths.reduce(0, +) + spacing, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = widths(for: bounds.width, subviews: subviews)
        var offset: CGFloat = 0
        for (view, width) in zip(subviews, widths) {
            let x = layoutDirection == .rightToLeft
                ? bounds.maxX - offset - width / 2
                : bounds.minX + offset + width / 2
            view.place(at: CGPoint(x: x, y: bounds.midY), anchor: .center,
                       proposal: ProposedViewSize(width: width, height: bounds.height))
            offset += width + spacing
        }
    }
}

/// Retain toolbar slots while fading every canvas control behind the menu.
private struct CanvasMenuControlVisibility: ViewModifier {
    let isHidden: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(isHidden ? 0 : 1)
            .animation(.easeInOut(duration: reduceMotion ? 0.1 : 0.22), value: isHidden)
            .allowsHitTesting(!isHidden)
            .accessibilityHidden(isHidden)
    }
}
