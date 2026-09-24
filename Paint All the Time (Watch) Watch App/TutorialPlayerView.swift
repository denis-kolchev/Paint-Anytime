import SwiftUI

struct TutorialPlayerView: View {
    let folder: URL
    let onFinish: () -> Void
    @StateObject private var tutorial = TutorialSession()
    @StateObject private var controller = CanvasController(persistsPreferences: false)
    @State private var page: Page = .canvas
    @State private var isMovingCanvas = false
    @State private var canvasSize = CGSize.zero
    @State private var controls: [CanvasToolbarControl: CGRect] = [:]
    @State private var savedDrawing: CanvasExport?
    @State private var confirmsClear = false
    @State private var didConfirmClear = false
    @State private var saveError: String?
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase
    private enum Page { case canvas, tools, saved, menu, gallery }

    var body: some View {
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
                                    page = .canvas
                                    tutorial.record(.returnedToCanvas)
                                }, onEditDrawing: { _ in })
                            }
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .onAppear { canvasSize = geometry.size }
                        .onChange(of: geometry.size) { _, size in canvasSize = size }
                    }
                    .ignoresSafeArea()

                    if page == .saved, let savedDrawing {
                        SavedDrawingView(drawing: savedDrawing, photoTransferStatus: "", canRetryPhotoTransfer: false,
                                         tutorial: tutorial)
                            .background(.black)
                    }

                    if page == .menu {
                        List {
                            Button {
                                page = .gallery
                                tutorial.record(.openedGallery)
                            } label: {
                                Label(L10n.text("Gallery"), systemImage: "photo.on.rectangle")
                            }
                        }
                        .navigationTitle(L10n.text("More"))
                    }
                }
                .toolbar {
                    if page == .canvas && tutorial.permits([2]) {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                page = .tools
                                tutorial.record(.openedTools)
                            } label: {
                                ToolIcon(instrument: controller.pencilStyle.instrument).frame(width: 18, height: 18)
                            }
                            .accessibilityLabel(L10n.text("Tool settings"))
                            .trackCanvasControl(.tools, frames: $controls)
                        }
                    }
                    if (page == .tools && tutorial.permits([9])) || (page == .canvas && tutorial.permits([11])) {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                if page == .tools {
                                    page = .canvas
                                    tutorial.record(.closedTools)
                                } else {
                                    isMovingCanvas = false
                                    tutorial.record(.finishedCamera)
                                }
                            } label: {
                                Image(systemName: "checkmark").foregroundStyle(.green)
                            }
                            .disabled(page == .canvas && !tutorial.canFinishCamera)
                            .accessibilityLabel(L10n.text("Done"))
                            .trackCanvasControl(.tools, frames: $controls)
                        }
                    }
                    if page == .canvas && tutorial.permits([12]) {
                        ToolbarItemGroup(placement: .bottomBar) {
                            // Keep the same four slots as the regular canvas toolbar.
                            Button {} label: { BroomIcon() }
                                .hidden()
                                .disabled(true)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                            Spacer(minLength: 0)
                            Button {
                                controller.undo()
                                tutorial.record(.history)
                            } label: { Image(systemName: "arrow.uturn.backward") }
                            .disabled(!controller.canUndo)
                            .accessibilityLabel(L10n.text("Undo"))
                            .trackCanvasControl(.undo, frames: $controls)
                            Spacer(minLength: 0)
                            Button {
                                controller.redo()
                                tutorial.record(.history)
                            } label: { Image(systemName: "arrow.uturn.forward") }
                            .disabled(!controller.canRedo)
                            .accessibilityLabel(L10n.text("Redo"))
                            .trackCanvasControl(.redo, frames: $controls)
                            Spacer(minLength: 0)
                            Button {} label: { Image(systemName: "square.and.arrow.down") }
                                .hidden()
                                .disabled(true)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    if page == .canvas && tutorial.permits([13]) {
                        ToolbarItem(placement: .bottomBar) {
                            HStack {
                                Spacer()
                                Button(action: save) { Image(systemName: "square.and.arrow.down") }
                                    .accessibilityLabel(L10n.text("Save drawing"))
                                    .trackCanvasControl(.save, frames: $controls)
                            }
                        }
                    }
                    if page == .saved && tutorial.permits([14]) {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                page = .canvas
                                tutorial.record(.closedSave)
                            } label: { Image(systemName: "xmark") }
                            .accessibilityLabel(L10n.text("Back"))
                        }
                    }
                    if page == .canvas && tutorial.permits([15]) {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { page = .menu; tutorial.activity() } label: { Image(systemName: "ellipsis") }
                                .accessibilityLabel(L10n.text("More"))
                                .trackCanvasControl(.more, frames: $controls)
                        }
                    }
                    if page == .canvas && tutorial.permits([19]) {
                        ToolbarItem(placement: .bottomBar) {
                            HStack {
                                Button {
                                    tutorial.pauseReminders()
                                    confirmsClear = true
                                } label: { BroomIcon() }
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
        .toolbarBackgroundVisibility(tutorial.showsInstruction ? .hidden : .automatic, for: .navigationBar)
        .onAppear {
            if !tutorial.isActive {
                // Carry the color and width taught earlier into the new brush, without changing user preferences.
                controller.setSynchronizeWidth(true)
                controller.setSynchronizeColor(true)
                tutorial.start()
            }
            else { tutorial.resumeReminders() }
        }
        .onChange(of: tutorial.step) { _, _ in controls = [:] }
        .onChange(of: tutorial.showsInstruction) { _, showing in
            if showing { controller.cancelStroke() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { tutorial.resumeReminders() }
            else { tutorial.pauseReminders(); controller.cancelStroke() }
        }
        .onDisappear { tutorial.pauseReminders() }
        .fullScreenCover(isPresented: $confirmsClear, onDismiss: {
            tutorial.resumeReminders()
            if didConfirmClear {
                didConfirmClear = false
                controller.clear()
                tutorial.record(.cleared)
            }
        }) {
            DestructiveConfirmationView(title: L10n.text("Clear the canvas?"), confirmTitle: L10n.text("Clear")) {
                confirmsClear = false
            } onConfirm: {
                didConfirmClear = true
                confirmsClear = false
            }
        }
        .alert(L10n.text("Could not save"), isPresented: Binding(
            get: { saveError != nil }, set: { if !$0 { saveError = nil; tutorial.resumeReminders() } }
        )) {
            Button(L10n.text("OK"), role: .cancel) { saveError = nil; tutorial.resumeReminders() }
        } message: { Text(saveError ?? "") }
    }

    private func save() {
        do {
            savedDrawing = try CanvasExportStore.save(strokes: controller.document.strokes,
                                                      size: canvasSize, scale: displayScale, in: folder)
            controller.markSaved()
            // Training never queues files to the real iPhone photo library.
            page = .saved
            tutorial.record(.saved)
        } catch {
            tutorial.pauseReminders()
            saveError = error.localizedDescription
        }
    }
}
