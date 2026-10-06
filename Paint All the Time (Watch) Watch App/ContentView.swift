import SwiftUI

struct ContentView: View {
    var isActive = true
    var onStartTutorial: () -> Void = {}
    @State private var startsTutorialAfterDismiss = false
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @StateObject private var session = DrawingSessionController()
    private var controller: CanvasController { session.canvas }
    @AppStorage("experimental.morphToolbar") private var usesMorphToolbar = false
    @State private var showsMorphToolbar = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsToolSettings = false
    @State private var isMovingCanvas = false
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
                    let rowHeight = min(diameter, max(24, (geometry.size.height - top - 16) / 5))
                    let panelHeight = showsMorphToolbar ? rowHeight * 5 : diameter
                    morphToolbar(diameter: diameter, rowHeight: rowHeight)
                        .position(x: centerX, y: top + panelHeight / 2)
                        .zIndex(3)

                    // Both controls use the same glass and explicit outer diameter.
                    // Native toolbar slots remain installed solely for system layout.
                    let moreFrame = canvasControlFrames[.more]
                    morphButton("More", height: diameter) {
                        controller.cancelStroke()
                        showsAppSettings = true
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .frame(width: diameter)
                    .modifier(CanvasMorphGlass())
                    // The native toolbar host owns touches in this top-bar slot.
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .position(x: (moreFrame?.midX ?? (canvasFrame.minX + 30)) - canvasFrame.minX,
                              y: (moreFrame?.midY ?? (canvasFrame.minY + 34)) - canvasFrame.minY)
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
                    Button { session.requestCanvasAction(.clear) } label: {
                        BroomIcon()
                    }
                    .watchToolbarButtonStyle()
                    .disabled(!controller.canClear)
                    .accessibilityLabel(L10n.text("Clear canvas"))
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
                        session.saveDrawing(size: canvasSize, scale: displayScale)
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .watchToolbarButtonStyle()
                    .accessibilityLabel(L10n.text("Save drawing"))
                    .trackCanvasControl(.save, frames: $canvasControlFrames)
                }
            }

            if isActive && !showsGallery && !showsToolSettings {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        controller.cancelStroke()
                        showsAppSettings = true
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 18, height: 18, alignment: .center)
                            .opacity(usesMorphToolbar ? 0 : 1)
                            .contentShape(Rectangle())
                    }
                    .watchToolbarButtonStyle(hidesNativeChrome: usesMorphToolbar || isMovingCanvas || controller.activeStroke != nil)
                    .accessibilityLabel(L10n.text("More"))
                    .trackCanvasControl(.more, frames: $canvasControlFrames)
                    .opacity(isMovingCanvas || controller.activeStroke != nil ? 0 : 1)
                    .allowsHitTesting(!isMovingCanvas && controller.activeStroke == nil)
                    .accessibilityHidden(isMovingCanvas || controller.activeStroke != nil)
                }
            }
            if isActive && !showsGallery {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    controller.cancelStroke()
                    if isMovingCanvas { isMovingCanvas = false }
                    else if usesMorphToolbar && !showsToolSettings && showsMorphToolbar {
                        // In the expanded capsule this same screen position is
                        // occupied by the first action, Tool settings.
                        showsMorphToolbar = false
                        showsToolSettings = true
                    } else if usesMorphToolbar && !showsToolSettings {
                        withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
                            showsMorphToolbar.toggle()
                        }
                    } else { showsToolSettings.toggle() }
                } label: {
                    Group {
                        if showsToolSettings || isMovingCanvas {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.green)
                        } else if usesMorphToolbar {
                            Image(systemName: "chevron.up")
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
                SavedDrawingView(drawing: drawing, photoTransferStatus: session.photoTransferStatus,
                                 canRetryPhotoTransfer: session.photoTransferCanRetry)
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
            showsMorphToolbar = false
        }
        .onChange(of: isActive) { _, active in
            if !active { showsMorphToolbar = false }
        }
        .onChange(of: isMovingCanvas) { _, moving in
            if moving { showsMorphToolbar = false }
        }
        .onChange(of: session.canvasSessionID) { _, _ in
            showsMorphToolbar = false
            isMovingCanvas = false
            showsToolSettings = false
            showsGallery = false
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                if !showsAppSettings && session.savedDrawing == nil && session.pendingCanvasAction == nil {
                    showsMorphToolbar = false
                }
                controller.cancelStroke()
                controller.flushStylePreferences()
            }
        }
    }

    @MainActor
    private func resetMorphBehindPresentation() async {
        guard showsMorphToolbar else { return }
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
        }
    }

    private var morphOwnsTrailingControl: Bool {
        usesMorphToolbar && !showsToolSettings && !isMovingCanvas
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
                morphButton("Clear canvas", height: rowHeight) {
                    session.requestCanvasAction(.clear)
                } label: { BroomIcon() }
                .disabled(!controller.canClear)
                morphButton("Undo", height: rowHeight, action: { controller.undo() }) {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(!controller.canUndo)
                morphButton("Redo", height: rowHeight, action: { controller.redo() }) {
                    Image(systemName: "arrow.uturn.forward")
                }
                .disabled(!controller.canRedo)
                morphButton("Save drawing", height: rowHeight) {
                    session.saveDrawing(size: canvasSize, scale: displayScale)
                } label: { Image(systemName: "square.and.arrow.down") }
            } else {
                morphButton("Open drawing controls", height: diameter) {
                    controller.cancelStroke()
                    withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
                        showsMorphToolbar = true
                    }
                } label: {
                    Image(systemName: "chevron.up")
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
        WatchCanvasView(controller: controller, acceptsInput: isActive && !showsToolSettings && !showsAppSettings && !showsGallery && session.savedDrawing == nil && session.pendingCanvasAction == nil, protectedControls: protectedCanvasControls, isMovingCanvas: $isMovingCanvas, onCanvasInteraction: {
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
            if isMovingCanvas { return control == .tools }
            if usesMorphToolbar { return control == .more || control == .tools || control == .morph }
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
