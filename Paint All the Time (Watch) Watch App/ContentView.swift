import SwiftUI

struct ContentView: View {
    var isActive = true
    var onStartTutorial: () -> Void = {}
    @State private var startsTutorialAfterDismiss = false
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @StateObject private var controller = CanvasController()
    @State private var showsToolSettings = false
    @State private var isMovingCanvas = false
    @State private var showsAppSettings = false
    @State private var showsGallery = false
    @State private var canvasSessionID = UUID()
    @State private var canvasSize: CGSize = .zero
    @State private var canvasControlFrames: [CanvasToolbarControl: CGRect] = [:]
    @State private var savedDrawing: CanvasExport?
    @State private var pendingCanvasAction: PendingCanvasAction?
    @State private var photoTransferStatus = ""
    @State private var photoTransferCanRetry = false
    @State private var exportError: String?
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
                        requestCanvasAction(.open(document))
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .zIndex(2)
                }

                if showsToolSettings {
                    WatchToolSettingsView(controller: controller)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .background(.black)
                    .transition(.identity)
                    .zIndex(1)
                }
            }
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
                    Button { requestCanvasAction(.clear) } label: {
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
                        do {
                            let drawing = try CanvasExportStore.save(
                                strokes: controller.document.strokes, size: canvasSize, scale: displayScale)
                            controller.markSaved()
                            let queued = WatchPhotoTransfer.shared.queue(drawing.url)
                            photoTransferCanRetry = !queued
                            photoTransferStatus = queued
                                ? L10n.text("Your drawing is being sent to Photos on iPhone.")
                                : L10n.text("Your drawing is saved on your watch. Open the iPhone app to send it to Photos.")
                            savedDrawing = drawing
                        } catch { exportError = error.localizedDescription }
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .watchToolbarButtonStyle()
                    .accessibilityLabel(L10n.text("Save drawing"))
                    .trackCanvasControl(.save, frames: $canvasControlFrames)
                }
            }

            if isActive && !showsGallery && !showsToolSettings && !isMovingCanvas && controller.activeStroke == nil {
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
                }
            }
            if isActive && !showsGallery && (showsToolSettings || controller.activeStroke == nil) {
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
        .sheet(item: $savedDrawing) { drawing in
            NavigationStack {
                SavedDrawingView(drawing: drawing, photoTransferStatus: photoTransferStatus,
                                 canRetryPhotoTransfer: photoTransferCanRetry)
            }
        }
        .fullScreenCover(item: $pendingCanvasAction) { action in
            DestructiveConfirmationView(title: action.title, confirmTitle: L10n.text("Clear")) {
                pendingCanvasAction = nil
            } onConfirm: {
                pendingCanvasAction = nil
                performCanvasAction(action)
            }
        }
        .alert(L10n.text("Could not save"), isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } }
        )) {
            Button(L10n.text("OK"), role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                controller.cancelStroke()
                controller.flushStylePreferences()
            }
        }
    }

    private var drawingPage: some View {
        WatchCanvasView(controller: controller, rendersArtwork: !showsToolSettings && !showsGallery, acceptsInput: isActive && !showsToolSettings && !showsAppSettings && !showsGallery && savedDrawing == nil && pendingCanvasAction == nil, protectedControls: protectedCanvasControls, isMovingCanvas: $isMovingCanvas)
            .id(canvasSessionID)
    }

    private var protectedCanvasControls: [CanvasToolbarControl: CGRect] {
        guard !showsGallery && !showsToolSettings && controller.activeStroke == nil else { return [:] }
        return canvasControlFrames.filter { control, _ in
            !isMovingCanvas || control == .tools
        }
    }

    private func requestCanvasAction(_ action: PendingCanvasAction) {
        controller.cancelStroke()
        if controller.needsDiscardConfirmation {
            pendingCanvasAction = action
        } else {
            performCanvasAction(action)
        }
    }

    private func performCanvasAction(_ action: PendingCanvasAction) {
        switch action {
        case .clear:
            controller.clear()
        case .open(let document):
            controller.load(document)
            // Reset zoom, offset, and gesture state whenever a saved drawing opens.
            canvasSessionID = UUID()
            isMovingCanvas = false
            showsToolSettings = false
            showsGallery = false
        }
    }

    private enum PendingCanvasAction: Identifiable {
        case clear
        case open(CanvasDocument)

        var id: Int {
            switch self {
            case .clear: 0
            case .open: 1
            }
        }

        var title: String {
            switch self {
            case .clear: L10n.text("Clear the canvas?")
            case .open: L10n.text("Discard the previous unsaved canvas?")
            }
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
                        Text(L10n.text("No"))
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
