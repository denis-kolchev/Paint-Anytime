import SwiftUI

struct ContentView: View {
    @Binding var launchRequest: WatchLaunchRequest?
    var isActive = true
    var onStartTutorial: () -> Void = {}
    @State private var startsTutorialAfterDismiss = false
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @StateObject private var session = DrawingSessionController()
    private var controller: CanvasController { session.canvas }
    @AppStorage("experimental.morphToolbar") private var usesMorphToolbar = false
    @State private var showsMorphToolbar = false
    @State private var showsContentActions = false
    @State private var showsCanvasSize = false
    @State private var showsLayers = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsToolSettings = false
    @State private var isMovingCanvas = false
    @State private var isEyedropperActive = false
    @State private var hasEyedropperSession = false
    @State private var showsAppSettings = false
    @State private var showsGallery = false
    @State private var canvasSize: CGSize = .zero
    @State private var canvasControlFrames: [CanvasToolbarControl: CGRect] = [:]
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

                if usesMorphToolbar && isActive && !showsGallery && !showsToolSettings && !isMovingCanvas && controller.activeStroke == nil {
                    let canvasFrame = geometry.frame(in: .global)
                    let buttonFrame = canvasControlFrames[.tools]
                    let diameter: CGFloat = 36
                    let top = (buttonFrame?.midY ?? (canvasFrame.minY + 34)) - canvasFrame.minY - diameter / 2
                    let centerX = (buttonFrame?.midX ?? (canvasFrame.maxX - 30)) - canvasFrame.minX
                    let rowHeight = min(diameter, max(20, (geometry.size.height - top - 16) / 4))
                    let panelHeight = showsMorphToolbar ? rowHeight * 4 : diameter
                    morphToolbar(diameter: diameter, rowHeight: rowHeight)
                        .position(x: centerX, y: top + panelHeight / 2)
                        .zIndex(3)

                    // Both controls use the same glass and explicit outer diameter.
                    // Native toolbar slots remain installed solely for system layout.
                    let moreFrame = canvasControlFrames[.more]
                    let contentTop = (moreFrame?.midY ?? (canvasFrame.minY + 34)) - canvasFrame.minY - diameter / 2
                    let contentRowCount: CGFloat = AppReleaseFeatures.current.showsCanvasSizeControls ? 4 : 3
                    let contentRowHeight = min(diameter, max(20, (geometry.size.height - contentTop - 16) / contentRowCount))
                    let contentHeight = showsContentActions ? contentRowHeight * contentRowCount : diameter
                    morphContentActions(diameter: diameter, rowHeight: contentRowHeight)
                        .position(x: (moreFrame?.midX ?? (canvasFrame.minX + 30)) - canvasFrame.minX,
                                  y: contentTop + contentHeight / 2)
                        .zIndex(3)
                }

                if !usesMorphToolbar && isActive && !showsGallery && !showsToolSettings && !isMovingCanvas && controller.activeStroke == nil {
                    let canvasFrame = geometry.frame(in: .global)
                    let buttonFrame = canvasControlFrames[.clear]
                    let diameter: CGFloat = 36
                    let height = showsContentActions ? diameter * 2 : diameter
                    contentActions(diameter: diameter)
                        .position(x: (buttonFrame?.midX ?? (canvasFrame.minX + 30)) - canvasFrame.minX,
                                  y: (buttonFrame?.midY ?? (canvasFrame.maxY - 26)) - canvasFrame.minY + diameter / 2 - height / 2)
                        .zIndex(3)
                }

                if showsGallery {
                    SavedDrawingsView(onClose: { showsGallery = false }) { document in
                        session.requestCanvasAction(.open(document))
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .zIndex(2)
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
            if !usesMorphToolbar && isActive && !showsGallery && !showsToolSettings && !isMovingCanvas && controller.activeStroke == nil {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button {
                        controller.cancelStroke()
                        if showsContentActions {
                            showsContentActions = false
                            session.saveDrawing(size: canvasSize, scale: displayScale)
                        } else {
                            withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
                                showsContentActions = true
                            }
                        }
                    } label: {
                        Image(systemName: "doc.badge.gearshape")
                            .frame(width: 18, height: 18).opacity(0)
                            .contentShape(Rectangle())
                    }
                    .watchToolbarButtonStyle(hidesNativeChrome: true)
                    .accessibilityLabel(L10n.text(showsContentActions ? "Save drawing" : "Canvas actions"))
                    .trackCanvasControl(.clear, frames: $canvasControlFrames)
                    Spacer(minLength: 0)
                    Button { controller.undo() } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .disabled(!controller.canUndo)
                    .watchToolbarButtonStyle()
                    .accessibilityLabel(L10n.text("Undo"))
                    .trackCanvasControl(.undo, frames: $canvasControlFrames)
                    Spacer(minLength: 0)
                    Button { controller.redo() } label: {
                        Image(systemName: "arrow.uturn.forward")
                    }
                    .disabled(!controller.canRedo)
                    .watchToolbarButtonStyle()
                    .accessibilityLabel(L10n.text("Redo"))
                    .trackCanvasControl(.redo, frames: $canvasControlFrames)
                    Spacer(minLength: 0)
                    Button {
                        controller.cancelStroke()
                        showsContentActions = false
                        showsLayers = true
                    } label: {
                        Image(systemName: "square.3.layers.3d")
                    }
                    .watchToolbarButtonStyle()
                    .accessibilityLabel(L10n.text("Layers"))
                    .trackCanvasControl(.save, frames: $canvasControlFrames)
                }
            }

            if isActive && !showsGallery && !showsToolSettings {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        controller.cancelStroke()
                        if isMovingCanvas {
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
                        Image(systemName: isMovingCanvas ? "eyedropper" : usesMorphToolbar && !showsContentActions ? "doc.badge.gearshape" : "ellipsis")
                            .foregroundStyle(isEyedropperActive ? .green : .primary)
                            .frame(width: 18, height: 18, alignment: .center)
                            .opacity(usesMorphToolbar && !isMovingCanvas ? 0 : 1)
                            .contentShape(Rectangle())
                    }
                    .watchToolbarButtonStyle(hidesNativeChrome: (usesMorphToolbar && !isMovingCanvas) || controller.activeStroke != nil)
                    .accessibilityLabel(L10n.text(isMovingCanvas ? "Eyedropper" : usesMorphToolbar && !showsContentActions ? "Canvas actions" : "More"))
                    .accessibilityAddTraits(isEyedropperActive ? [.isSelected] : [])
                    .trackCanvasControl(.more, frames: $canvasControlFrames)
                    .opacity(controller.activeStroke != nil ? 0 : 1)
                    .allowsHitTesting(controller.activeStroke == nil)
                    .accessibilityHidden(controller.activeStroke != nil)
                }
            }
            if isActive && !showsGallery {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    controller.cancelStroke()
                    if isMovingCanvas {
                        if hasEyedropperSession {
                            isEyedropperActive = false
                            hasEyedropperSession = false
                        } else { isMovingCanvas = false }
                    }
                    else if usesMorphToolbar && !showsToolSettings && showsMorphToolbar {
                        // In the expanded capsule this same screen position is
                        // occupied by the first action, Tool settings.
                        showsMorphToolbar = false
                        showsToolSettings = true
                    } else if usesMorphToolbar && !showsToolSettings {
                        withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
                            showsContentActions = false
                            showsMorphToolbar.toggle()
                        }
                    } else { showsToolSettings.toggle() }
                } label: {
                    Group {
                        if showsToolSettings || isMovingCanvas {
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
                .watchToolbarButtonStyle(hidesNativeChrome: morphOwnsTrailingControl || (!showsToolSettings && controller.activeStroke != nil))
                .accessibilityLabel(showsToolSettings || isMovingCanvas ? L10n.text("Done") : usesMorphToolbar ? L10n.text(showsMorphToolbar ? "Tool settings" : "Open drawing controls") : L10n.text("Tool settings"))
                .trackCanvasControl(.tools, frames: $canvasControlFrames)
                // Keep the toolbar slot installed so the system clock does not
                // move when drawing temporarily hides the button.
                .opacity(!showsToolSettings && controller.activeStroke != nil ? 0 : 1)
                .allowsHitTesting(showsToolSettings || controller.activeStroke == nil)
                .accessibilityHidden(!showsToolSettings && controller.activeStroke != nil)
            }
            }
        }
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
        }
        .sheet(isPresented: $showsAppSettings, onDismiss: {
            if startsTutorialAfterDismiss {
                startsTutorialAfterDismiss = false
                onStartTutorial()
            }
        }) {
            WatchAppSettingsView(controller: controller, onOpenDrawings: {
                showsAppSettings = false
                showsGallery = true
            }, onStartTutorial: {
                startsTutorialAfterDismiss = true
                showsAppSettings = false
            })
            .task { await resetMorphBehindPresentation() }
        }
        .sheet(item: $session.savedDrawing) { drawing in
            NavigationStack {
                SavedDrawingView(drawing: drawing)
            }
            .task { await resetMorphBehindPresentation() }
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
        .onChange(of: usesMorphToolbar) { _, _ in
            showsContentActions = false
            showsMorphToolbar = false
        }
        .onChange(of: isActive) { _, active in
            if !active { showsMorphToolbar = false; showsContentActions = false }
        }
        .onChange(of: isMovingCanvas) { _, moving in
            if moving { showsMorphToolbar = false; showsContentActions = false }
        }
        .onChange(of: session.canvasSessionID) { _, _ in
            showsContentActions = false
            showsMorphToolbar = false
            isMovingCanvas = false
            isEyedropperActive = false
            hasEyedropperSession = false
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
        startsTutorialAfterDismiss = false
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
        showsMorphToolbar = false
        showsContentActions = false
        isMovingCanvas = false
        isEyedropperActive = false
        hasEyedropperSession = false
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
        usesMorphToolbar && !showsToolSettings && !isMovingCanvas
    }

    private func contentActions(diameter: CGFloat) -> some View {
        VStack(spacing: 0) {
            if showsContentActions {
                morphButton("Clear canvas", height: diameter) {
                    showsContentActions = false
                    session.requestCanvasAction(.clear)
                } label: { BroomIcon() }
                .disabled(!controller.canClear)
                morphButton("Save drawing", height: diameter) {
                    showsContentActions = false
                    session.saveDrawing(size: canvasSize, scale: displayScale)
                } label: { Image(systemName: "square.and.arrow.down") }
            } else {
                morphButton("Canvas actions", height: diameter, action: {}) {
                    Image(systemName: "doc.badge.gearshape")
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .frame(width: diameter)
        .modifier(CanvasMorphGlass())
        .trackCanvasControl(.contentMorph, frames: $canvasControlFrames)
    }

    private func morphContentActions(diameter: CGFloat, rowHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            if showsContentActions {
                morphButton("More", height: rowHeight) {
                    controller.cancelStroke()
                    showsContentActions = false
                    showsAppSettings = true
                } label: { Image(systemName: "ellipsis") }
                morphButton("Clear canvas", height: rowHeight) {
                    showsContentActions = false
                    session.requestCanvasAction(.clear)
                } label: { BroomIcon() }
                .disabled(!controller.canClear)
                morphButton("Save drawing", height: rowHeight) {
                    showsContentActions = false
                    session.saveDrawing(size: canvasSize, scale: displayScale)
                } label: { Image(systemName: "square.and.arrow.down") }
                if AppReleaseFeatures.current.showsCanvasSizeControls {
                    morphButton("Canvas size", height: rowHeight) {
                        controller.cancelStroke()
                        showsContentActions = false
                        showsCanvasSize = true
                    } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                }
            } else {
                // The native leading toolbar slot handles the opening tap.
                morphButton("Canvas actions", height: diameter, action: {}) {
                    Image(systemName: "doc.badge.gearshape")
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .frame(width: diameter)
        .modifier(CanvasMorphGlass())
        .trackCanvasControl(.contentMorph, frames: $canvasControlFrames)
    }

    private func morphToolbar(diameter: CGFloat, rowHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            if showsMorphToolbar {
                morphButton("Tool settings", height: rowHeight) {
                    showsMorphToolbar = false
                    controller.cancelStroke()
                    showsToolSettings = true
                } label: {
                    ToolIcon(instrument: controller.pencilStyle.instrument)
                        .frame(width: 18, height: 18)
                }
                morphButton("Undo", height: rowHeight, action: { controller.undo() }) {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(!controller.canUndo)
                morphButton("Redo", height: rowHeight, action: { controller.redo() }) {
                    Image(systemName: "arrow.uturn.forward")
                }
                .disabled(!controller.canRedo)
                morphButton("Layers", height: rowHeight) {
                    controller.cancelStroke()
                    showsLayers = true
                } label: { Image(systemName: "square.3.layers.3d") }
            } else {
                morphButton("Open drawing controls", height: diameter) {
                    controller.cancelStroke()
                    withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
                        showsMorphToolbar = true
                    }
                } label: {
                    Image(systemName: "paintbrush.pointed")
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .frame(width: diameter)
        .modifier(CanvasMorphGlass())
        .trackCanvasControl(.morph, frames: $canvasControlFrames)
    }

    private func morphButton<Label: View>(_ title: String, height: CGFloat, action: @escaping () -> Void,
                                          @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            label()
                .font(.system(size: 17, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text(title))
    }

    private var drawingPage: some View {
        // Animate the whole page above, keeping the cached artwork fully visible inside it.
        WatchCanvasView(controller: controller, acceptsInput: isActive && !showsCanvasSize && !showsLayers && !showsToolSettings && !showsAppSettings && !showsGallery && session.savedDrawing == nil && session.pendingCanvasAction == nil, protectedControls: protectedCanvasControls, isMovingCanvas: $isMovingCanvas, isEyedropperActive: isEyedropperActive, onCanvasInteraction: {
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
        guard !showsGallery && !showsToolSettings && controller.activeStroke == nil else { return [:] }
        return canvasControlFrames.filter { control, _ in
            if isMovingCanvas { return control == .tools || control == .more }
            if usesMorphToolbar { return control == .more || control == .tools || control == .morph || control == .contentMorph }
            return control != .morph
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

                HStack(spacing: 8) {
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

/// One glass surface persists as the circle expands into a capsule.
private struct CanvasMorphGlass: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(watchOS 26, *) {
            content
                .glassEffect(.regular.interactive(), in: Capsule())
                .environment(\.colorScheme, .dark)
        } else {
            content
                .foregroundStyle(.white)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }
}
