import SwiftUI

struct TutorialPlayerView: View {
    let folder: URL
    let onFinish: () -> Void
    @StateObject private var player: TutorialPlayerController
    private var tutorial: TutorialSession { player.tutorial }
    private var controller: CanvasController { player.canvas }
    private var page: TutorialPlayerController.Page { player.page }
    @State private var isMovingCanvas = false
    @State private var canvasSize = CGSize.zero
    @State private var controls: [CanvasToolbarControl: CGRect] = [:]
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase

    init(folder: URL, onFinish: @escaping () -> Void) {
        self.folder = folder
        self.onFinish = onFinish
        _player = StateObject(wrappedValue: TutorialPlayerController(folder: folder))
    }

    var body: some View {
        let _ = TutorialDebug.trace("player.body", "page=\(page) \(tutorial.debugState)")
        ZStack {
            Group {
                ZStack {
                    GeometryReader { geometry in
                        ZStack {
                            WatchCanvasView(controller: controller, tutorial: tutorial,
                                            rendersArtwork: page == .canvas,
                                            acceptsInput: page == .canvas && tutorial.acceptsActions,
                                            protectedControls: controls, isMovingCanvas: $isMovingCanvas)
                                .opacity(page == .canvas ? 1 : 0)
                                .allowsHitTesting(page == .canvas && tutorial.acceptsActions)
                                .accessibilityHidden(page != .canvas || tutorial.showsInstruction)

                            if page == .tools {
                                WatchToolSettingsView(controller: controller, tutorial: tutorial)
                                    .background(.black)
                            }
                            if page == .gallery {
                                SavedDrawingsView(tutorial: tutorial, galleryFolder: folder, onClose: {
                                    player.closeGallery()
                                }, onEditDrawing: { _ in })
                            }
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .onAppear { canvasSize = geometry.size }
                        .onChange(of: geometry.size) { _, size in canvasSize = size }
                    }
                    .ignoresSafeArea()

                    if page == .saved, let savedDrawing = player.savedDrawing {
                        SavedDrawingView(drawing: savedDrawing, photoTransferStatus: "", canRetryPhotoTransfer: false,
                                         tutorial: tutorial)
                            .background(.black)
                    }

                    if page == .menu {
                        List {
                            Button {
                                player.openGallery()
                            } label: {
                                Label(L10n.text("Gallery"), systemImage: "photo.on.rectangle")
                            }
                        }
                        .navigationTitle(L10n.text("More"))
                    }
                }
                .toolbar {
                    if page == .canvas && tutorial.permits([.openTools]) {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                TutorialDebug.trace("tools.tap", tutorial.debugState)
                                player.openTools()
                            } label: {
                                ToolIcon(instrument: controller.pencilStyle.instrument).frame(width: 18, height: 18)
                            }
                            .watchToolbarButtonStyle()
                            .accessibilityLabel(L10n.text("Tool settings"))
                            .onAppear { TutorialDebug.trace("tools.button.appear", tutorial.debugState) }
                            .trackCanvasControl(.tools, frames: $controls)
                        }
                    }
                    if (page == .tools && tutorial.permits([.reedStrokes])) || (page == .canvas && tutorial.permits([.panCanvas])) {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                if page == .tools {
                                    player.closeTools()
                                } else {
                                    isMovingCanvas = false
                                    tutorial.record(.finishedCamera)
                                }
                            } label: {
                                Image(systemName: "checkmark").foregroundStyle(.green)
                            }
                            .disabled(page == .canvas && !tutorial.canFinishCamera)
                            .watchToolbarButtonStyle()
                            .accessibilityLabel(L10n.text("Done"))
                            .onAppear { TutorialDebug.trace("tools.button.appear", tutorial.debugState) }
                            .trackCanvasControl(.tools, frames: $controls)
                        }
                    }
                    if page == .canvas && tutorial.permits([.history]) {
                        ToolbarItemGroup(placement: .bottomBar) {
                            // Keep the same four slots as the regular canvas toolbar.
                            Button {} label: { BroomIcon() }
                                .watchToolbarButtonStyle()
                                .hidden()
                                .disabled(true)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                            Spacer(minLength: 0)
                            Button {
                                player.undo()
                            } label: { Image(systemName: "arrow.uturn.backward") }
                            .disabled(!controller.canUndo)
                            .watchToolbarButtonStyle()
                            .accessibilityLabel(L10n.text("Undo"))
                            .trackCanvasControl(.undo, frames: $controls)
                            Spacer(minLength: 0)
                            Button {
                                player.redo()
                            } label: { Image(systemName: "arrow.uturn.forward") }
                            .disabled(!controller.canRedo)
                            .watchToolbarButtonStyle()
                            .accessibilityLabel(L10n.text("Redo"))
                            .trackCanvasControl(.redo, frames: $controls)
                            Spacer(minLength: 0)
                            Button {} label: { Image(systemName: "square.and.arrow.down") }
                                .watchToolbarButtonStyle()
                                .hidden()
                                .disabled(true)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    if page == .canvas && tutorial.permits([.saveDrawing]) {
                        ToolbarItem(placement: .bottomBar) {
                            HStack {
                                Spacer()
                                Button { player.save(size: canvasSize, scale: displayScale) } label: { Image(systemName: "square.and.arrow.down") }
                                    .watchToolbarButtonStyle()
                                    .accessibilityLabel(L10n.text("Save drawing"))
                                    .trackCanvasControl(.save, frames: $controls)
                            }
                        }
                    }
                    if page == .saved && tutorial.permits([.shareDrawing]) {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                player.closeSavedDrawing()
                            } label: { Image(systemName: "xmark") }
                            .watchToolbarButtonStyle()
                            .accessibilityLabel(L10n.text("Back"))
                        }
                    }
                    if page == .canvas && tutorial.permits([.openGallery]) {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { player.openMenu() } label: { Image(systemName: "ellipsis") }
                                .watchToolbarButtonStyle()
                                .accessibilityLabel(L10n.text("More"))
                                .trackCanvasControl(.more, frames: $controls)
                        }
                    }
                    if page == .canvas && tutorial.permits([.clearCanvas]) {
                        ToolbarItem(placement: .bottomBar) {
                            HStack {
                                Button {
                                    player.requestClear()
                                } label: { BroomIcon() }
                                .watchToolbarButtonStyle()
                                .accessibilityLabel(L10n.text("Clear canvas"))
                                .trackCanvasControl(.clear, frames: $controls)
                                Spacer()
                            }
                        }
                    }
                }
            }
            .opacity(tutorial.isActive && !tutorial.showsInstruction ? 1 : 0)
            .allowsHitTesting(!tutorial.showsInstruction)
            .accessibilityHidden(tutorial.showsInstruction)

            if tutorial.showsInstruction {
                TutorialLessonView(tutorial: tutorial, onFinish: onFinish)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .tutorialToolbarBackground(hidden: tutorial.showsInstruction)
        .onAppear {
            player.startOrResume()
        }
        .onChange(of: tutorial.step) { _, _ in
            controls = [:]
        }
        .onChange(of: tutorial.showsInstruction) { _, showing in
            TutorialDebug.trace("player.instruction", "showing=\(showing) page=\(page) \(tutorial.debugState)")
            if showing { controller.cancelStroke() }
        }
        .onChange(of: scenePhase) { _, phase in
            TutorialDebug.trace("player.scenePhase", "phase=\(phase)")
            player.setActive(phase == .active)
        }
        .onDisappear {
            tutorial.pauseReminders()
        }
        .fullScreenCover(isPresented: $player.confirmsClear, onDismiss: {
            player.didDismissClearConfirmation()
        }) {
            DestructiveConfirmationView(title: L10n.text("Clear the canvas?"), confirmTitle: L10n.text("Clear")) {
                player.confirmsClear = false
            } onConfirm: {
                player.confirmClear()
            }
        }
        .alert(L10n.text("Could not save"), isPresented: Binding(
            get: { player.saveError != nil }, set: { if !$0 { player.dismissSaveError() } }
        )) {
            Button(L10n.text("OK"), role: .cancel) { player.dismissSaveError() }
        } message: { Text(player.saveError ?? "") }
    }
}

private extension View {
    @ViewBuilder
    func tutorialToolbarBackground(hidden: Bool) -> some View {
        if #available(watchOS 11.0, *) {
            toolbarBackgroundVisibility(hidden ? .hidden : .automatic, for: .navigationBar)
        } else {
            toolbarBackground(hidden ? .hidden : .automatic, for: .navigationBar)
        }
    }
}
