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
    @State private var hintHeight: CGFloat = 0
    @State private var controls: [CanvasToolbarControl: CGRect] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var panGuideOffset = CGSize.zero
    @State private var panGuideVisible = false
    @State private var historyEmphasizesRedo = false
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase

    init(folder: URL, onFinish: @escaping () -> Void) {
        self.folder = folder
        self.onFinish = onFinish
        _player = StateObject(wrappedValue: TutorialPlayerController(folder: folder))
    }

    var body: some View {
        let _ = TutorialDebug.trace("player.body", "page=\(page) \(tutorial.debugState)")
        GeometryReader { screen in
            // The card measures itself independently of the controls it moves.
            let measuredHintHeight = hintHeight > 0 ? hintHeight : screen.size.height * 0.32 + 20
            // Measurement includes 10 pt of clear padding above the card; keep only a 2 pt gap.
            let hintReservedHeight = max(0, measuredHintHeight - 8)
            ZStack(alignment: .bottom) {
                ZStack {
                    GeometryReader { geometry in
                        ZStack {
                            WatchCanvasView(controller: controller, tutorial: tutorial,
                                            rendersArtwork: page == .canvas,
                                            acceptsInput: page == .canvas && tutorial.acceptsActions,
                                            protectedControls: canvasProtectedControls, isMovingCanvas: $isMovingCanvas)
                                .opacity(page == .canvas ? 1 : 0)
                                .allowsHitTesting(page == .canvas && tutorial.acceptsActions)
                                .accessibilityHidden(page != .canvas)

                            if page == .canvas && tutorial.showsPanGuide {
                                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                                    .font(.title2.bold())
                                    .foregroundStyle(.white)
                                    .padding(10)
                                    .background(.regularMaterial, in: Circle())
                                    .offset(panGuideOffset)
                                    .opacity(panGuideVisible ? 1 : 0)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                                    .task {
                                        let offsets: [CGSize] = [
                                            CGSize(width: -24, height: 0), .zero,
                                            CGSize(width: 24, height: 0), .zero,
                                            CGSize(width: 0, height: -24), .zero,
                                            CGSize(width: 0, height: 24), .zero
                                        ]
                                        panGuideVisible = false
                                        panGuideOffset = .zero
                                        do {
                                            try await Task.sleep(for: .seconds(1))
                                            try Task.checkCancellation()
                                            panGuideVisible = true
                                            guard !reduceMotion else { return }
                                            while !Task.isCancelled {
                                                for offset in offsets {
                                                    withAnimation(.easeInOut(duration: 0.45)) { panGuideOffset = offset }
                                                    try await Task.sleep(for: .milliseconds(500))
                                                }
                                            }
                                        } catch { panGuideVisible = false; panGuideOffset = .zero }
                                    }
                            }

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

                    if page == .saved, let savedDrawing = player.savedDrawing {
                        SavedDrawingView(drawing: savedDrawing, photoTransferStatus: "", canRetryPhotoTransfer: false,
                                         tutorial: tutorial)
                            .background(.black)
                    }

                    if page == .menu {
                        WatchAppSettingsView(controller: controller,
                                             onOpenDrawings: { player.openGallery() },
                                             onStartTutorial: {},
                                             tutorial: tutorial)
                    }
                }
                .overlay(alignment: .bottom) {
                    tutorialBottomControls(hitDiameter: min(44, (screen.size.width - 16) / 4))
                        .padding(.horizontal, 8)
                        .padding(.bottom, hintReservedHeight)
                }
                .toolbar {
                    // Keep one native toolbar item and Button alive when Done
                    // becomes Tool settings; replacing animated toolbar hosts
                    // during their own action is fragile on watchOS 10.
                    if showsPrimaryControl {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                if page == .tools {
                                    player.closeTools()
                                } else if isMovingCanvas {
                                    isMovingCanvas = false
                                    tutorial.record(.finishedCamera)
                                } else {
                                    player.openTools()
                                }
                            } label: {
                                ZStack {
                                    ToolIcon(instrument: controller.pencilStyle.instrument)
                                        .frame(width: 18, height: 18)
                                        .opacity(primaryControlIsDone ? 0 : 1)
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.green)
                                        .opacity(primaryControlIsDone ? 1 : 0)
                                }
                                .tutorialHint(tutorial, steps: [.openTools, .closeTools, .finishCamera])
                                .frame(width: 32, height: 32)
                                .contentShape(Circle())
                            }
                            .watchToolbarButtonStyle(usesCanvasMaterial: true)
                            .accessibilityLabel(L10n.text(primaryControlIsDone ? "Done" : "Tool settings"))
                            .trackCanvasControl(.tools, frames: $controls)
                        }
                    }
                    if page == .saved && tutorial.permits([.shareDrawing]) {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                player.closeSavedDrawing()
                            } label: {
                                Image(systemName: "xmark").tutorialHint(tutorial, steps: [.shareDrawing])
                                    .frame(width: 32, height: 32)
                                    .contentShape(Circle())
                            }
                            .watchToolbarButtonStyle(usesCanvasMaterial: true)
                            .accessibilityLabel(L10n.text("Back"))
                        }
                    }
                    if page == .canvas && tutorial.permits([.openMenu]) {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { player.openMenu() } label: {
                                Image(systemName: "ellipsis").tutorialHint(tutorial, steps: [.openMenu])
                                    .frame(width: 32, height: 32)
                                    .contentShape(Circle())
                            }
                                .watchToolbarButtonStyle(usesCanvasMaterial: true)
                                .accessibilityLabel(L10n.text("More"))
                                .trackCanvasControl(.more, frames: $controls)
                        }
                    }
                }
                .toolbarBackground(page == .tools ? .hidden : .automatic, for: .navigationBar)
                .frame(width: screen.size.width, height: screen.size.height)
                .environment(\.tutorialHintReservedHeight, hintReservedHeight)

                TutorialLessonView(tutorial: tutorial, onFinish: {
                    if player.preserveDrawing() { onFinish() }
                },
                                   screenWidth: screen.size.width,
                                   screenHeight: screen.size.height)
                    .frame(width: screen.size.width)
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        GeometryReader { hintGeometry in
                            Color.clear.preference(key: TutorialHintHeightKey.self,
                                                   value: hintGeometry.size.height)
                        }
                    }
            }
        }
        // The native menu needs the top safe area to place its first row below
        // the navigation title. Its bottom still extends behind the hint card.
        .ignoresSafeArea(.container, edges: page == .menu ? .bottom : .all)
        .onPreferenceChange(TutorialHintHeightKey.self) { height in
            if height > 0 { hintHeight = height }
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            player.startOrResume()
        }
        .task(id: tutorial.step) {
            guard tutorial.step == .history else { return }
            historyEmphasizesRedo = false
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(1400))
                    historyEmphasizesRedo.toggle()
                }
            } catch {}
        }
        .onChange(of: controller.canRedo) { _, canRedo in
            if canRedo { historyEmphasizesRedo = true }
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

    private var primaryControlIsDone: Bool { page == .tools || isMovingCanvas }

    private var showsPrimaryControl: Bool {
        (page == .tools && tutorial.permits([.closeTools])) ||
        (page == .canvas && (isMovingCanvas
            ? tutorial.acceptsActions && tutorial.canFinishCamera
            : tutorial.permits([.openTools])))
    }

    private var canvasProtectedControls: [CanvasToolbarControl: CGRect] {
        guard page == .canvas else { return [:] }
        // Retain measurements for stable toolbar items across lessons. A frame
        // may not be reported again when only the button's label changes.
        return controls.filter { control, _ in
            switch control {
            case .tools: return showsPrimaryControl
            case .more: return tutorial.permits([.openMenu])
            case .undo, .redo: return tutorial.permits([.history])
            case .save: return tutorial.permits([.saveDrawing])
            case .clear: return tutorial.permits([.clearCanvas])
            }
        }
    }

    // Four targets must also fit the narrower 40 mm watches without overlap.
    @ViewBuilder private func tutorialBottomControls(hitDiameter: CGFloat) -> some View {
        if page == .canvas && tutorial.permits([.history, .saveDrawing]) {
            HStack {
                // Keep the same four slots as the regular canvas toolbar.
                Button {} label: { BroomIcon() }
                    .buttonStyle(TutorialOverlayButtonStyle(hitDiameter: hitDiameter))
                    .hidden()
                    .disabled(true)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                Button {
                    player.undo()
                } label: { Image(systemName: "arrow.uturn.backward").tutorialHint(tutorial, steps: [.history], isSuggested: !historyEmphasizesRedo || !controller.canRedo) }
                .disabled(!controller.canUndo || tutorial.step != .history)
                .buttonStyle(TutorialOverlayButtonStyle(hitDiameter: hitDiameter))
                .opacity(tutorial.step == .history ? 1 : 0)
                .allowsHitTesting(tutorial.step == .history)
                .accessibilityHidden(tutorial.step != .history)
                .accessibilityLabel(L10n.text("Undo"))
                .trackCanvasControl(.undo, frames: $controls)
                Spacer(minLength: 0)
                Button {
                    player.redo()
                } label: { Image(systemName: "arrow.uturn.forward").tutorialHint(tutorial, steps: [.history], isSuggested: historyEmphasizesRedo || !controller.canUndo) }
                .disabled(!controller.canRedo || tutorial.step != .history)
                .buttonStyle(TutorialOverlayButtonStyle(hitDiameter: hitDiameter))
                .opacity(tutorial.step == .history ? 1 : 0)
                .allowsHitTesting(tutorial.step == .history)
                .accessibilityHidden(tutorial.step != .history)
                .accessibilityLabel(L10n.text("Redo"))
                .trackCanvasControl(.redo, frames: $controls)
                Spacer(minLength: 0)
                Button { player.save(size: canvasSize, scale: displayScale) } label: {
                    Image(systemName: "square.and.arrow.down").tutorialHint(tutorial, steps: [.saveDrawing])
                }
                .buttonStyle(TutorialOverlayButtonStyle(hitDiameter: hitDiameter))
                .opacity(tutorial.step == .saveDrawing ? 1 : 0)
                .allowsHitTesting(tutorial.step == .saveDrawing)
                .disabled(tutorial.step != .saveDrawing)
                .accessibilityHidden(tutorial.step != .saveDrawing)
                .accessibilityLabel(L10n.text("Save drawing"))
                .trackCanvasControl(.save, frames: $controls)
            }
        }
        if page == .canvas && (tutorial.step == .clearCanvas || tutorial.step == .finished) {
            Group {
                HStack {
                    Button {
                        player.requestClear()
                    } label: { BroomIcon().tutorialHint(tutorial, steps: [.clearCanvas]) }
                    .buttonStyle(TutorialOverlayButtonStyle(hitDiameter: hitDiameter))
                    .disabled(!tutorial.permits([.clearCanvas]))
                    .accessibilityLabel(L10n.text("Clear canvas"))
                    .trackCanvasControl(.clear, frames: $controls)
                    Spacer()
                }
            }
        }
    }
}

private struct TutorialHintHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
