import SwiftUI

struct ContentView: View {
    var isActive = true
    var onStartTutorial: () -> Void = {}
    @State private var startsTutorialAfterDismiss = false
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @StateObject private var session = DrawingSessionController()
    private var controller: CanvasController { session.canvas }
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
            if isActive && !showsGallery && !showsToolSettings && !isMovingCanvas && controller.activeStroke == nil {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { session.requestCanvasAction(.clear) } label: {
                        BroomIcon()
                    }
                    .watchToolbarButtonStyle()
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
                    }
                    .watchToolbarButtonStyle()
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
                    else { showsToolSettings.toggle() }
                } label: {
                    Group {
                        if showsToolSettings || isMovingCanvas {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.green)
                        } else {
                            ToolIcon(instrument: controller.pencilStyle.instrument)
                                .frame(width: 18, height: 18)
                        }
                    }
                }
                .watchToolbarButtonStyle()
                .accessibilityLabel(showsToolSettings || isMovingCanvas ? L10n.text("Done") : L10n.text("Tool settings"))
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
        }
        .sheet(item: $session.savedDrawing) { drawing in
            NavigationStack {
                SavedDrawingView(drawing: drawing, photoTransferStatus: session.photoTransferStatus,
                                 canRetryPhotoTransfer: session.photoTransferCanRetry)
            }
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
        .onChange(of: session.canvasSessionID) { _, _ in
            isMovingCanvas = false
            showsToolSettings = false
            showsGallery = false
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                controller.cancelStroke()
                controller.flushStylePreferences()
            }
        }
    }

    private var drawingPage: some View {
        // Animate the whole page above, keeping the cached artwork fully visible inside it.
        WatchCanvasView(controller: controller, acceptsInput: isActive && !showsToolSettings && !showsAppSettings && !showsGallery && session.savedDrawing == nil && session.pendingCanvasAction == nil, protectedControls: protectedCanvasControls, isMovingCanvas: $isMovingCanvas)
            .id(session.canvasSessionID)
    }

    private var protectedCanvasControls: [CanvasToolbarControl: CGRect] {
        guard !showsGallery && !showsToolSettings && controller.activeStroke == nil else { return [:] }
        return canvasControlFrames.filter { control, _ in
            !isMovingCanvas || control == .tools
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
