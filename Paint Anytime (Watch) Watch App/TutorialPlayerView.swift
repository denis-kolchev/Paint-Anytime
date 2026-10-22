import SwiftUI
import WatchKit

struct TutorialPlayerView: View {
    let folder: URL
    let onFinish: () -> Void
    @StateObject private var player: TutorialPlayerController
    private var tutorial: TutorialSession { player.tutorial }
    private var controller: CanvasController { player.canvas }
    private var page: TutorialPlayerController.Page { player.page }
    @State private var tutorialPaletteLibrary = InkPaletteLibrary.tutorial
    @State private var confirmsFinish = false
    @State private var isMovingCanvas = false
    @State private var canvasSize = CGSize.zero
    @State private var hintHeight: CGFloat = 0
    @State private var savedExitCenterX: CGFloat?
    @State private var savedNoticeID: UUID?
    @State private var controls: [CanvasToolbarControl: CGRect] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var panGuideOffset = CGSize.zero
    @State private var panGuideVisible = false
    @State private var historyEmphasizesRedo = false
    @State private var shareEmphasizesExit = false
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
            // Native palette pages retain horizontal safe-area insets. The
            // floating card uses the same full screen width on every lesson.
            let hintWidth = screen.size.width + screen.safeAreaInsets.leading + screen.safeAreaInsets.trailing
            // The card measures itself independently of the controls it moves.
            let measuredHintHeight = hintHeight > 0 ? hintHeight : screen.size.height * 0.32 + 20
            // Measurement includes 10 pt of clear padding above the card; keep only a 2 pt gap.
            let hintReservedHeight = max(0, measuredHintHeight - 8)
            ZStack(alignment: .bottom) {
                ZStack {
                    GeometryReader { geometry in
                        ZStack {
                            WatchCanvasView(controller: controller, tutorial: tutorial,
                                            rendersArtwork: page == .canvas || page == .saved,
                                            acceptsInput: page == .canvas && tutorial.acceptsActions,
                                            acceptsZoomOnlyInput: page == .saved && tutorial.acceptsActions,
                                            protectedControls: canvasProtectedControls, isMovingCanvas: $isMovingCanvas)
                                .opacity(page == .canvas || page == .saved ? 1 : 0)
                                .allowsHitTesting((page == .canvas || page == .saved) && tutorial.acceptsActions)
                                .accessibilityHidden(page != .canvas && page != .saved)

                            if showsCircleGuide {
                                TutorialCirclePresentation(guideHeight: max(0, geometry.size.height - hintReservedHeight),
                                                           isFadingAttempt: tutorial.isFadingCircleAttempt)
                                    .transition(.identity)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }

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
                                ZStack {
                                    if !tutorial.isPaletteLesson {
                                        // Mount with the saved palette already installed, so the
                                        // returning picker never animates removal of the old colors.
                                        WatchToolSettingsView(controller: controller, tutorial: tutorial,
                                                              tutorialColors: tutorialPaletteLibrary.activePalette.selectedColors)
                                            .background(.black)
                                            .transition(.opacity)
                                    } else {
                                        InkPaletteBrowser(library: tutorialPaletteLibrary, controller: controller,
                                                          tutorial: tutorial) { library in
                                            tutorialPaletteLibrary = library
                                            withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3)) {
                                                tutorial.record(.savedColor)
                                            }
                                        }
                                        // Extend beneath the floating card while preserving
                                        // the native toolbar inset at the top.
                                        .ignoresSafeArea(.container, edges: .bottom)
                                        .background(Color.black.ignoresSafeArea())
                                        .environment(\.colorScheme, .dark)
                                        .transition(.opacity)
                                        .zIndex(1)
                                    }
                                }
                                .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3),
                                           value: tutorial.isPaletteLesson)
                                .transition(.opacity)
                                .zIndex(1)
                            }
                            if page == .gallery {
                                SavedDrawingsView(tutorial: tutorial, galleryFolder: folder, onClose: {
                                    withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3)) {
                                        player.closeGallery()
                                    }
                                }, onEditDrawing: { _ in })
                                .transition(.opacity)
                                .zIndex(1)
                            }
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .onAppear { canvasSize = geometry.size }
                        .onChange(of: geometry.size) { _, size in canvasSize = size }
                    }

                    if page == .saved, let savedDrawing = player.savedDrawing {
                        // Keep the existing canvas visible for the share lesson instead
                        // of mounting a gallery pager that starts with an empty black frame.
                        Color.clear
                            .overlay(alignment: .bottom) {
                                ShareLink(item: DrawingShareItem(url: savedDrawing.url),
                                          preview: SharePreview("Paint Anytime", image: DrawingShareItem(url: savedDrawing.url))) {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.system(size: 17))
                                        .frame(width: 24, height: 24, alignment: .center)
                                        .tutorialHint(tutorial, steps: [.shareDrawing], isSuggested: !shareEmphasizesExit)
                                }
                                .accessibilityLabel(L10n.text("Share"))
                                .simultaneousGesture(TapGesture().onEnded { tutorial.activity() })
                                .buttonStyle(TutorialOverlayButtonStyle())
                                // Follow the measured, localized tip with a little breathing room.
                                .padding(.bottom, hintReservedHeight + 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .offset(x: (savedExitCenterX.map {
                                    $0 - screen.frame(in: .global).minX
                                } ?? 38) - 22)
                            }
                    }

                    if page == .menu {
                        WatchAppSettingsView(controller: controller,
                                             onOpenDrawings: { player.openGallery() },
                                             onStartTutorial: {},
                                             tutorial: tutorial)
                    }

                    if let savedNoticeID, page == .saved {
                        Text(L10n.text("Artwork saved to gallery"))
                            .font(.headline)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .minimumScaleFactor(0.5)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                            .padding(.horizontal, 42)
                            // Center in the space above the measured lesson card,
                            // leaving a gap even when localized tips become taller.
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.bottom, measuredHintHeight + 4)
                            .id(savedNoticeID)
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.85).combined(with: .opacity))
                            .allowsHitTesting(false)
                            .zIndex(4)
                            .task(id: savedNoticeID) {
                                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                                withAnimation(.easeOut(duration: 0.2)) { self.savedNoticeID = nil }
                            }
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
                    // Keep both top slots installed throughout canvas/tools/share lessons
                    // so the native system clock stays centered between them.
                    if (page == .canvas || page == .tools || page == .saved) && !tutorial.isPaletteLesson {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                if page == .tools {
                                    withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3)) {
                                        player.closeTools()
                                    }
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
                            .watchToolbarButtonStyle(diameter: 32, usesCanvasMaterial: true)
                            .accessibilityLabel(L10n.text(primaryControlIsDone ? "Done" : "Tool settings"))
                            .trackCanvasControl(.tools, frames: $controls)
                            .opacity(showsPrimaryControl ? 1 : 0)
                            .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3), value: showsPrimaryControl)
                            .allowsHitTesting(showsPrimaryControl)
                            .accessibilityHidden(!showsPrimaryControl)
                        }
                    }
                    if page == .saved {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                player.closeSavedDrawing()
                            } label: {
                                Image(systemName: "xmark")
                                    .tutorialHint(tutorial, steps: [.shareDrawing], isSuggested: shareEmphasizesExit)
                                    .frame(width: 32, height: 32)
                                    .contentShape(Circle())
                            }
                            .watchToolbarButtonStyle(usesCanvasMaterial: true, hidesNativeChrome: !tutorial.permits([.shareDrawing]))
                            .accessibilityLabel(L10n.text("Back"))
                            .onGeometryChange(for: CGFloat.self) { geometry in
                                geometry.frame(in: .global).midX
                            } action: { centerX in
                                savedExitCenterX = centerX
                            }
                            .opacity(tutorial.permits([.shareDrawing]) ? 1 : 0)
                            .allowsHitTesting(tutorial.permits([.shareDrawing]))
                            .accessibilityHidden(!tutorial.permits([.shareDrawing]))
                        }
                    }
                    if page == .canvas {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { player.openMenu() } label: {
                                Image(systemName: "ellipsis").tutorialHint(tutorial, steps: [.openMenu])
                                    .frame(width: 32, height: 32)
                                    .contentShape(Circle())
                            }
                                .watchToolbarButtonStyle(usesCanvasMaterial: true, hidesNativeChrome: !tutorial.permits([.openMenu]))
                                .accessibilityLabel(L10n.text("More"))
                                .trackCanvasControl(.more, frames: $controls)
                                .opacity(tutorial.permits([.openMenu]) ? 1 : 0)
                                .allowsHitTesting(tutorial.permits([.openMenu]))
                                .accessibilityHidden(!tutorial.permits([.openMenu]))
                        }
                    }
                }
                .toolbarBackground(page == .tools ? .hidden : .automatic, for: .navigationBar)
                .frame(width: screen.size.width, height: screen.size.height)
                .environment(\.tutorialHintReservedHeight, hintReservedHeight)

                TutorialLessonView(tutorial: tutorial, onFinish: {
                    if player.preserveDrawing() { onFinish() }
                },
                                   screenWidth: hintWidth,
                                   screenHeight: screen.size.height,
                                   // Reserve the tool chrome, carousel, and a readable
                                   // three-item control. The card already scrolls overflow.
                                   maximumCardHeight: page == .tools && !tutorial.isPaletteLesson
                                    ? max(32, screen.size.height - 40 - 30
                                          - ToolValueControl.minimumHeight - 12) : nil,
                                   confirmsFinish: $confirmsFinish)
                    .frame(width: hintWidth)
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        GeometryReader { hintGeometry in
                            Color.clear.preference(key: TutorialHintHeightKey.self,
                                                   value: hintGeometry.size.height)
                        }
                    }
                    .frame(width: screen.size.width)
            }
        }
        // Native menu and palette content start below the navigation toolbar.
        // Their full-height layouts extend through the bottom safe area,
        // with the lesson card layered above rather than reserving space.
        .ignoresSafeArea(.container, edges: page == .menu || tutorial.isPaletteLesson ? .bottom : .all)
        .onPreferenceChange(TutorialHintHeightKey.self) { height in
            if height > 0 { hintHeight = height }
        }
        .background(Color.black.ignoresSafeArea())
        .overlay {
            if confirmsFinish {
                // Keep confirmation in the outgoing tutorial hierarchy so it
                // crossfades directly to the editor without revealing the lesson.
                ZStack {
                    Color.black.ignoresSafeArea()
                    DestructiveConfirmationView(
                        title: L10n.text("Finish the tutorial?"),
                        confirmTitle: L10n.text("Yes"),
                        cancelTitle: L10n.text("No")
                    ) {
                        confirmsFinish = false
                        tutorial.resumeReminders()
                    } onConfirm: {
                        guard player.preserveDrawing() else {
                            confirmsFinish = false
                            return
                        }
                        withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3)) {
                            onFinish()
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
                .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3), value: confirmsFinish)
        // Flatten the opaque confirmation and lesson before the host applies
        // its exit opacity; otherwise the lesson can show through fading children.
        .compositingGroup()
        .toolbar(confirmsFinish ? .hidden : .automatic, for: .navigationBar, .bottomBar)
        .modifier(TutorialCrownHint(tutorial: tutorial))
        .onAppear {
            player.startOrResume()
        }
        .onChange(of: tutorial.step) { _, step in
            guard step == .holdCircle,
                  let red = InkPreset.all.first(where: { $0.nameKey == "Red" }) else { return }
            var style = controller.pencilStyle
            style.color = red.rgba
            style.opacity = 1
            controller.pencilStyle = style
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
        .task(id: tutorial.step) {
            shareEmphasizesExit = false
            guard tutorial.step == .shareDrawing else { return }
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(1400))
                    shareEmphasizesExit.toggle()
                }
            } catch {}
        }
        .onChange(of: page) { _, page in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                savedNoticeID = page == .saved ? UUID() : nil
            }
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

    private var showsCircleGuide: Bool {
        page == .canvas && tutorial.step == .holdCircle
            && !tutorial.showsResult && !tutorial.remindersPaused
            && controller.activeStroke == nil && scenePhase == .active
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
            case .morph, .contentMorph, .canvasToolsMorph: return false
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

/// Prepare the paper before starting the demonstration. Removing this view on
/// first contact removes the dimming immediately and cancels the pending guide.
private struct TutorialCirclePresentation: View {
    let guideHeight: CGFloat
    let isFadingAttempt: Bool
    @State private var paperOpacity = 0.0
    @State private var isGuideReady = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.white.opacity(paperOpacity)
            if isGuideReady && !isFadingAttempt {
                TutorialCircleGuide()
                    .frame(height: guideHeight)
            }
        }
        .task {
            do {
                // Start alongside the failed stroke fade, using the same delay and duration.
                try await Task.sleep(for: .milliseconds(20))
                withAnimation(.easeOut(duration: 0.22)) { paperOpacity = 0.5 }
                try await Task.sleep(for: .milliseconds(220))
                try Task.checkCancellation()
                isGuideReady = true
            } catch { }
        }
    }
}

/// A display-only demonstration; never adds strokes to the practice drawing.
private struct TutorialCircleGuide: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = Date()

    // Use the same red swatch as the tutorial's color picker.
    private var ink: Color {
        InkPreset.all.first { $0.nameKey == "Red" }?.color ?? .red
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(startedAt))
            let phase = elapsed.truncatingRemainder(dividingBy: 4.4)
            let drawn = reduceMotion ? 1 : min(1, max(0, (phase - 0.4) / 1.8))
            // Match the real recognizer's half-second hold before straightening.
            let straightened = reduceMotion ? 1 : min(1, max(0, (phase - 2.7) / 0.25))
            let visibility = reduceMotion ? 1 : min(1, max(0, (4.4 - phase) / 0.4))
            Canvas { context, size in
                // Keep the entire loop and contact marker below the clock and
                // above the coach card, even on the smallest watch viewport.
                let top = min(50.0, size.height * 0.5)
                let bottom = max(top, size.height - 12)
                let radiusX = size.width * 0.27
                let radiusY = min(radiusX * 0.65, max(0, (bottom - top) / 2 - 11) / 1.1)
                let center = CGPoint(x: size.width / 2, y: (top + bottom) / 2)
                var path = Path()
                let count = max(1, Int(drawn * 160))
                for index in 0...count {
                    let fraction = min(drawn, Double(index) / 160)
                    let point = point(at: fraction, radiusX: radiusX, radiusY: radiusY, center: center,
                                      straightened: straightened)
                    if index == 0 { path.move(to: point) }
                    else { path.addLine(to: point) }
                }
                context.opacity = visibility
                context.stroke(path, with: .color(ink),
                               style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                let finger = point(at: drawn, radiusX: radiusX, radiusY: radiusY, center: center,
                                   straightened: straightened)
                // A stationary contact marker makes the hold visible after the loop closes.
                if reduceMotion || (phase >= 0.4 && phase < 3.15) {
                    let holding = drawn == 1 && straightened == 0
                    let pulse = holding && !reduceMotion ? 1 + 0.15 * sin((phase - 2.2) * .pi * 4) : 1
                    let marker = CGRect(x: finger.x - 8 * pulse, y: finger.y - 8 * pulse,
                                        width: 16 * pulse, height: 16 * pulse)
                    context.fill(Path(ellipseIn: marker), with: .color(.white.opacity(0.35)))
                    context.stroke(Path(ellipseIn: marker), with: .color(.white.opacity(0.85)), lineWidth: 1.5)
                }
            }
            .onChange(of: straightened == 1) { _, isCircle in
                // Match real shape recognition, once when each animated circle finishes snapping.
                guard isCircle, !reduceMotion else { return }
                WKInterfaceDevice.current().play(.click)
            }
        }
        .onAppear { startedAt = Date() }
    }

    private func point(at fraction: Double, radiusX: CGFloat, radiusY: CGFloat, center: CGPoint,
                       straightened: Double) -> CGPoint {
        let angle = fraction * .pi * 2 - .pi / 2
        // Periodic deviations close naturally, like a slightly uneven hand-drawn loop.
        let wobble = 1 + (1 - straightened)
            * (0.065 * sin(angle * 3 + 0.7) + 0.035 * sin(angle * 7 - 0.4))
        return CGPoint(x: center.x + radiusX * wobble * cos(angle),
                       y: center.y + radiusY * wobble * sin(angle))
    }
}
