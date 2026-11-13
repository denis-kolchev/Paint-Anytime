import SwiftUI
import WatchKit

struct TutorialPlayerView: View {
    let folder: URL
    /// The first chapter result asks whether to go on instead of only offering Next.
    let offersRemainingChapters: Bool
    let onCompleteChapter: (TutorialChapter) -> Void
    /// The host plays the exit: both hosts close the tutorial through the iris.
    let onFinish: () -> Void
    private let chapters: [TutorialChapter]
    @State private var offersContinuation = false
    @State private var hasOfferedContinuation = false
    /// Later or Continue was tapped; further taps on the fading question are ignored.
    @State private var answeredContinuation = false
    @StateObject private var player: TutorialPlayerController
    private var tutorial: TutorialSession { player.tutorial }
    private var controller: CanvasController { player.canvas }
    private var page: TutorialPlayerController.Page { player.page }
    @State private var tutorialPaletteLibrary = InkPaletteLibrary.tutorial
    @State private var confirmsFinish = false
    @State private var isMovingCanvas = false
    @State private var canvasSize = CGSize.zero
    @State private var hintHeight: CGFloat = 0
    @State private var savedNoticeID: UUID?
    /// A full-screen page is fading out over the canvas; the page itself changes once
    /// the fade ends, so its native toolbar items can fade with it instead of vanishing.
    @State private var isLeavingPage = false
    /// The menu mounts below the screen, then rises like the editor's sheet.
    @State private var menuRevealed = false
    @State private var controls: [CanvasToolbarControl: CGRect] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var panGuideOffset = CGSize.zero
    @State private var panGuideVisible = false
    @State private var historyEmphasizesRedo = false
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase

    init(folder: URL, chapters: [TutorialChapter] = TutorialChapter.allCases,
         offersRemainingChapters: Bool = false,
         onCompleteChapter: @escaping (TutorialChapter) -> Void = { _ in },
         onFinish: @escaping () -> Void) {
        self.folder = folder
        self.chapters = chapters.isEmpty ? TutorialChapter.allCases : chapters
        self.offersRemainingChapters = offersRemainingChapters
        self.onCompleteChapter = onCompleteChapter
        self.onFinish = onFinish
        _player = StateObject(wrappedValue: TutorialPlayerController(folder: folder, chapters: chapters))
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
                            WatchCanvasView(controller: controller, lasso: player.lasso, tutorial: tutorial,
                                            // The menu slides over the drawing, as the editor's sheet does.
                                            rendersArtwork: page == .canvas || page == .menu || isLeavingPage,
                                            acceptsInput: page == .canvas && tutorial.acceptsActions
                                                && !player.isDemonstrating,
                                            acceptsZoomOnlyInput: false,
                                            protectedControls: canvasProtectedControls, isMovingCanvas: $isMovingCanvas,
                                            guides: player.guides)
                                // A new chapter also starts from the default camera.
                                .id(tutorial.chapterRevision)
                                .opacity(page == .canvas || page == .menu || isLeavingPage ? 1 : 0)
                                // Stays full screen while the menu page restores the top safe area,
                                // so the drawing under the rising menu never shifts.
                                .ignoresSafeArea()
                                .allowsHitTesting(page == .canvas && tutorial.acceptsActions)
                                .accessibilityHidden(page != .canvas)

                            // The canvas fades out in the same animation that crossfades the menu
                            // into a settings page; without an opaque floor the white drawing shows
                            // through mid-transition. Inserted and removed without animation.
                            if coversCanvasWithBackdrop {
                                Color.black
                                    .ignoresSafeArea()
                                    .opacity(isLeavingPage ? 0 : 1)
                                    .transition(.identity)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                                    .zIndex(0.5)
                            }

                            if showsCircleGuide {
                                TutorialCirclePresentation(guideHeight: max(0, geometry.size.height - hintReservedHeight),
                                                           isFadingAttempt: tutorial.isFadingCircleAttempt)
                                    .transition(.identity)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }

                            if showsLassoGuide {
                                TutorialLassoPresentation(guideHeight: max(0, geometry.size.height - hintReservedHeight))
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }

                            // Its own container, so the fade-out animates only the guide
                            // and not the lesson card that advances in the same update.
                            panGuide
                                .animation(.easeOut(duration: reduceMotion ? 0.2 : 0.4), value: tutorial.showsPanGuide)

                            pages(geometry: geometry, screen: screen)
                        }
                        // As in the editor: only the page content crossfades into the tool editor.
                        // A withAnimation around openTools also animated the toolbar, so the clock
                        // slid in from the edge and the editor's text shook while laid out.
                        .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.25), value: page == .tools)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .onAppear { canvasSize = geometry.size }
                        .onChange(of: geometry.size) { _, size in canvasSize = size }
                    }

                    if page == .menu {
                        // Rise from below the screen like the editor's menu sheet, over the drawing.
                        // An explicit offset animates the native List reliably, where an insertion
                        // transition collapses into a crossfade.
                        menuPage(screen: screen)
                    }

                    // Its own container: ••• opens the menu outside an animation, and the notice
                    // must fade out then instead of vanishing.
                    savedNotice(bottomInset: measuredHintHeight + 4)
                        .animation(.easeOut(duration: 0.2), value: page == .canvas)
                        .zIndex(4)
                }
                .overlay(alignment: .bottom) {
                    tutorialBottomControls(hitDiameter: min(44, (screen.size.width - 16) / 4))
                        .padding(.horizontal, 8)
                        .padding(.bottom, hintReservedHeight)
                        // The step changes outside withAnimation; drive the transition here.
                        .animation(.easeInOut(duration: 0.35), value: showsTutorialBottomControls)
                }
                .toolbar {
                    // Keep one native toolbar item and Button alive when Done
                    // becomes Tool settings; replacing animated toolbar hosts
                    // during their own action is fragile on watchOS 10.
                    // Keep both top slots installed on the tools page so the native
                    // system clock stays centered between them. Canvas and share pages
                    // hide the clock, and an installed slot swallows touch-down even
                    // when its button is transparent, so unavailable controls leave them.
                    if (page == .canvas || page == .tools) && !tutorial.isPaletteLesson
                        && installsPrimaryControl {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                if page == .tools {
                                    // ✓ turns back into the tool icon and Information fades while
                                    // the editor fades out, the reverse of opening it.
                                    guard tutorial.permits([.closeTools]) else { return }
                                    leavePage { player.closeTools() }
                                } else if player.lasso.isActive {
                                    player.finishLasso()
                                } else if isMovingCanvas {
                                    isMovingCanvas = false
                                    tutorial.record(.finishedCamera)
                                } else {
                                    // The page crossfade is scoped to the content (see `page == .tools`).
                                    player.openTools()
                                }
                            } label: {
                                ZStack {
                                    ToolIcon(instrument: controller.pencilStyle.instrument)
                                        .frame(width: 18, height: 18)
                                        .opacity(primaryControlIsDone ? 0 : 1)
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundStyle(.green)
                                        .opacity(primaryControlIsDone ? 1 : 0)
                                }
                                // Opening the editor is no longer one animated transaction; cross-fade here.
                                .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.25), value: primaryControlIsDone)
                                .tutorialHint(tutorial, steps: [.openTools, .closeTools, .finishCamera, .finishLasso])
                                .frame(width: MorphPanelGeometry.buttonDiameter,
                                       height: MorphPanelGeometry.buttonDiameter)
                                .contentShape(Circle())
                            }
                            .watchToolbarButtonStyle(diameter: MorphPanelGeometry.buttonDiameter, usesCanvasMaterial: true)
                            .accessibilityLabel(L10n.text(primaryControlIsDone ? "Done" : "Tool settings"))
                            .trackCanvasControl(.tools, frames: $controls)
                            .opacity(showsPrimaryControl ? 1 : 0)
                            .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3), value: showsPrimaryControl)
                            .allowsHitTesting(showsPrimaryControl)
                            .accessibilityHidden(!showsPrimaryControl)
                        }
                    }
                    if page == .layers || page == .layerSettings {
                        ToolbarItem(placement: .topBarLeading) {
                            let back: Set<TutorialStep> = page == .layers ? [.closeLayers] : [.closeLayerSettings]
                            Button {
                                if page == .layers {
                                    guard tutorial.permits([.closeLayers]) else { return }
                                    // Back leaves with the list, so it fades out rather than vanishing.
                                    leavePage { player.closeLayers() }
                                } else {
                                    withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3)) {
                                        player.closeLayerSettings()
                                    }
                                }
                            } label: {
                                Image(systemName: "chevron.backward")
                                    .tutorialHint(tutorial, steps: back)
                                    .frame(width: 32, height: 32)
                                    .contentShape(Circle())
                            }
                            .watchToolbarButtonStyle()
                            .disabled(!tutorial.permits(back) || isLeavingPage)
                            .accessibilityLabel(L10n.text("Back"))
                            .tutorialChromeFade()
                        }
                    }
                    if page == .perspective && tutorial.teachesPerspective {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                guard tutorial.permits([.leavePerspective]) else { return }
                                // The menu returns in place instead of rising again from below.
                                menuRevealed = true
                                withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3)) {
                                    player.leavePerspective()
                                }
                            } label: {
                                Image(systemName: "chevron.backward")
                                    .tutorialHint(tutorial, steps: [.leavePerspective])
                                    .frame(width: 32, height: 32)
                                    .contentShape(Circle())
                            }
                            .watchToolbarButtonStyle()
                            .disabled(!tutorial.permits([.leavePerspective]) || isLeavingPage)
                            .accessibilityLabel(L10n.text("Back"))
                            .tutorialChromeFade()
                        }
                    }
                    if page == .canvas && tutorial.permits([.openMenu]) {
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
                                .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.25), value: tutorial.permits([.openMenu]))
                                .allowsHitTesting(tutorial.permits([.openMenu]))
                                .accessibilityHidden(!tutorial.permits([.openMenu]))
                        }
                    }
                }
                .toolbarBackground(page == .tools ? .hidden : .automatic, for: .navigationBar)
                .frame(width: screen.size.width, height: screen.size.height)
                .environment(\.tutorialHintReservedHeight, hintReservedHeight)
                .environment(\.tutorialChromeHidden, isLeavingPage)

                lessonCard(width: hintWidth, screenHeight: screen.size.height)
                    .frame(width: hintWidth)
                    // The continuation question grows the card to the whole screen.
                    .fixedSize(horizontal: false, vertical: !offersContinuation)
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
        // The menu keeps the top safe area: its List is nested in the host's navigation bar and
        // only starts below that bar when the safe area includes it. Restoring the inset with
        // padding inside the menu left the first row under the bar's blur.
        .ignoresSafeArea(.container, edges: [.menu, .layers, .layerSettings, .canvasSettings,
                                             .canvasSize, .perspective, .crop,
                                             .drawingSettings, .colorBlending, .canvasEditor].contains(page)
                         || tutorial.isPaletteLesson ? .bottom : .all)
        .onPreferenceChange(TutorialHintHeightKey.self) { height in
            // The full-screen question must not move the controls reserved for the compact card.
            if height > 0, !offersContinuation { hintHeight = height }
        }
        .background(Color.black.ignoresSafeArea())
        .overlay {
            if confirmsFinish {
                // Keep confirmation in the outgoing tutorial hierarchy so the exit
                // goes straight to the editor without revealing the lesson.
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
                        // The host's iris closes over this confirmation.
                        onFinish()
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
        .toolbar(coversLesson ? .hidden : .automatic, for: .navigationBar, .bottomBar)
        // The expanded card is the whole screen, so the clock stays hidden over it.
        // Hidden as soon as a page starts leaving for the canvas: once its leading button
        // is removed the clock would otherwise slide from the centre to the corner.
        .requestsHiddenClock(((page == .canvas || isLeavingPage) && !confirmsFinish) || offersContinuation)
        .modifier(TutorialCrownHint(tutorial: tutorial))
        .onAppear {
            player.startOrResume()
        }
        .onChange(of: tutorial.step) { _, step in
            if ![.selectLasso, .transformLasso, .finishLasso].contains(step), player.lasso.isActive {
                player.lasso.deactivate()
            }
            if step == .chapterComplete || step == .finished, let chapter = tutorial.chapter {
                onCompleteChapter(chapter)
            }
            applyCircleInk(for: step)
            applyLayerBrush(for: step)
            withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3)) {
                player.returnToCanvasAfterSetting()
            }
            // The blending lesson draws its own yellow line, and later removes the user's
            // crossing so it can be drawn again with Color inversion.
            if step == .crossMarkerLine {
                player.demonstrateMarkerLine(viewportSize: canvasSize, reduceMotion: reduceMotion)
            } else if step == .redrawMarkerLine {
                player.removeUserMarkerStrokes(reduceMotion: reduceMotion)
            }
        }
        .task(id: tutorial.step) {
            // Ask once: the ring fills (~1.5 s), then the checkmark blinks and bounces for about
            // 2.5 s inviting a tap; without one the card grows into the question by itself.
            guard awaitsContinuation else { return }
            do { try await Task.sleep(for: .milliseconds(reduceMotion ? 2500 : 4000)) } catch { return }
            showContinuationOffer()
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
        .onChange(of: tutorial.chapterRevision) { _, _ in
            isMovingCanvas = false
            // A palette made in the palette lesson must not replace the colors later lessons use.
            tutorialPaletteLibrary = InkPaletteLibrary.tutorial
            player.beginChapter(keepsBrush: tutorial.lessonKeepsBrush)
            // The step change may be handled first; the reset must not drop the lesson ink.
            applyCircleInk(for: tutorial.step)
            applyLayerBrush(for: tutorial.step)
        }
        .onChange(of: player.saveRevision) { _, _ in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                savedNoticeID = UUID()
            }
            // Dismiss on a timer that keeps running even while the notice is hidden
            // (a different page), so it never reappears stale once canvas returns.
            let id = savedNoticeID
            Task { @MainActor in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard savedNoticeID == id else { return }
                withAnimation(.easeOut(duration: 0.2)) { savedNoticeID = nil }
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

    /// The circle exercise uses the guide's red ink.
    private func applyCircleInk(for step: TutorialStep) {
        guard step == .holdCircle,
              let red = InkPreset.all.first(where: { $0.nameKey == "Red" }) else { return }
        var style = controller.pencilStyle
        style.color = red.rgba
        style.opacity = 1
        controller.pencilStyle = style
    }

    /// Layer lessons use a wide brush so painting inside earlier strokes stays visible.
    private func applyLayerBrush(for step: TutorialStep) {
        guard tutorial.chapter == .advanced, step == .firstStrokes else { return }
        var style = controller.pencilStyle
        style.width = 8
        controller.pencilStyle = style
    }

    private var showsCircleGuide: Bool {
        page == .canvas && tutorial.step == .holdCircle
            && !tutorial.showsResult && !tutorial.remindersPaused
            && controller.activeStroke == nil && scenePhase == .active
    }

    private var showsLassoGuide: Bool {
        page == .canvas && [.selectLasso, .transformLasso].contains(tutorial.step)
            && tutorial.acceptsActions && !tutorial.remindersPaused
            && !player.lasso.hidesControls && player.lasso.bounds == nil && scenePhase == .active
    }

    private var primaryControlIsDone: Bool {
        (page == .tools && !isLeavingPage) || isMovingCanvas || player.lasso.isActive
    }

    /// Fades the current full-screen page, its top buttons and the clock out over the
    /// canvas, then changes the page without animation once nothing of it is visible.
    private func leavePage(_ change: @escaping @MainActor () -> Void) {
        guard !isLeavingPage else { return }
        let duration = reduceMotion ? 0.15 : TutorialChromeFade.duration
        withAnimation(.easeInOut(duration: duration)) { isLeavingPage = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                change()
                isLeavingPage = false
            }
        }
    }

    /// The tutorial's menu; kept out of `body` for the type checker.
    private func menuPage(screen: GeometryProxy) -> some View {
        WatchAppSettingsView(controller: controller, viewportSize: screen.size,
                             onOpenDrawings: {
                                 // Crossfade the menu into the gallery like the other menu pages.
                                 withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : 0.35)) { player.openGallery() }
                             },
                             onStartTutorial: { _ in },
                             tutorial: tutorial, guides: player.guides,
                             onOpenCanvasSettings: {
                                 withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3)) { player.openCanvasSettings() }
                             },
                             onOpenDrawingSettings: {
                                 withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3)) { player.openDrawingSettings() }
                             },
                             // Installed for the whole lesson, so the bar never changes while the menu is open.
                             onTutorialBack: tutorial.teachesPerspective ? { closeMenu() } : nil)
            .background(Color.black)
            .offset(y: menuRevealed || reduceMotion
                    ? 0 : screen.size.height + screen.safeAreaInsets.top + screen.safeAreaInsets.bottom)
            .onAppear {
                withAnimation(.spring(duration: 0.45, bounce: 0)) { menuRevealed = true }
            }
            .onDisappear { menuRevealed = false }
            .zIndex(2)
    }

    /// Back from the menu: it slides down over the drawing, as the editor's sheet does,
    /// and the canvas takes input once it has gone.
    private func closeMenu() {
        guard page == .menu, tutorial.permits([.leaveMenu]), menuRevealed else { return }
        guard !reduceMotion else { player.leaveMenu(); return }
        withAnimation(.spring(duration: 0.45, bounce: 0)) { menuRevealed = false }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            player.leaveMenu()
        }
    }

    /// The full-screen pages over the canvas. Siblings in the canvas ZStack, so their
    /// transitions and zIndex behave as before; kept out of `body` for the type checker.
    @ViewBuilder
    private func pages(geometry: GeometryProxy, screen: GeometryProxy) -> some View {
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
            .opacity(isLeavingPage ? 0 : 1)
            .allowsHitTesting(!isLeavingPage)
            .transition(.opacity)
            .zIndex(1)
        }
        if page == .layers {
            WatchLayersView(controller: controller,
                            canvasSize: controller.document.size(fallback: geometry.size),
                            tutorial: tutorial, embedsNavigation: false,
                            onEditLayer: { id in
                                withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3)) {
                                    player.openLayerSettings(id)
                                }
                            })
            .background(Color.black.ignoresSafeArea())
            .opacity(isLeavingPage ? 0 : 1)
            .allowsHitTesting(!isLeavingPage)
            .transition(.opacity)
            .zIndex(1)
        }
        if page == .layerSettings {
            LayerSettingsView(controller: controller, layerID: player.editedLayerID,
                              canvasSize: controller.document.size(fallback: geometry.size),
                              tutorial: tutorial)
            .background(Color.black.ignoresSafeArea())
            .transition(.opacity)
            .zIndex(1)
        }
        // Canvas setting pages stay inside the lesson, so its card and hints remain.
        if page == .canvasSettings {
            CanvasSettingsView(controller: controller, viewportSize: screen.size,
                               tutorial: tutorial, guides: player.guides,
                               onOpenCanvasSize: { withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3)) { player.openCanvasSize() } },
                               onOpenPerspective: { withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3)) { player.openPerspective() } },
                               onOpenCanvasEditor: { withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3)) { player.openCanvasEditor() } })
            .background(Color.black.ignoresSafeArea())
            .transition(.opacity)
            .zIndex(1)
        }
        if page == .canvasEditor {
            // The checkmark fades the editor out over the canvas that shows the new button.
            CanvasLayoutEditorView(instrument: controller.pencilStyle.instrument, tutorial: tutorial,
                                   onTutorialSave: { layout in leavePage { player.finishCanvasEditor(layout) } })
            .opacity(isLeavingPage ? 0 : 1)
            .allowsHitTesting(!isLeavingPage)
            .transition(.opacity)
            .zIndex(1)
        }
        if page == .canvasSize {
            WatchCanvasSizeView(controller: controller, viewportSize: paperSize(screen),
                                displayScale: displayScale, tutorial: tutorial,
                                onOpenCrop: { withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3)) { player.openCrop() } })
            .background(Color.black.ignoresSafeArea())
            .transition(.opacity)
            .zIndex(1)
        }
        if page == .perspective {
            PerspectiveGuidesSettingsView(controller: controller, viewportSize: screen.size,
                                          guides: player.guides, tutorial: tutorial)
            .background(Color.black.ignoresSafeArea())
            .transition(.opacity)
            .zIndex(1)
        }
        if page == .drawingSettings {
            DrawingSettingsView(controller: controller, viewportSize: screen.size,
                                tutorial: tutorial,
                                onOpenColorBlending: { withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3)) { player.openColorBlending() } })
            .background(Color.black.ignoresSafeArea())
            .transition(.opacity)
            .zIndex(1)
        }
        if page == .colorBlending {
            ColorBlendingSelectionView(controller: controller, tutorial: tutorial)
            .background(Color.black.ignoresSafeArea())
            .transition(.opacity)
            .zIndex(1)
        }
        if page == .crop {
            // Apply records the crop; the lesson then returns to the canvas itself.
            WatchCanvasAdjustmentView(controller: controller, viewportSize: paperSize(screen),
                                      displayScale: displayScale, mode: 1,
                                      tutorial: tutorial, onApplied: {})
            .background(Color.black.ignoresSafeArea())
            .transition(.opacity)
            .zIndex(1)
        }
        if page == .gallery {
            SavedDrawingsView(tutorial: tutorial, galleryFolder: folder, onClose: {
                // Back fades out with the gallery instead of leaving with the page.
                leavePage { player.closeGallery() }
            }, onEditDrawing: { _ in })
            .opacity(isLeavingPage ? 0 : 1)
            .allowsHitTesting(!isLeavingPage)
            // The grid settles in from a slight zoom while the menu fades out.
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.94)))
            .zIndex(1)
        }
    }

    /// The whole watch screen, as the full-screen canvas sees it. Setting pages keep the
    /// top safe area, so their `screen.size` lacks the clock band and an unsized canvas
    /// looked almost square in the crop preview.
    private func paperSize(_ screen: GeometryProxy) -> CGSize {
        let insets = screen.safeAreaInsets
        return CGSize(width: screen.size.width + insets.leading + insets.trailing,
                      height: screen.size.height + insets.top + insets.bottom)
    }

    /// Kept out of `body` so the compiler type-checks it on its own.
    private var panGuide: some View {
        let transition: AnyTransition = reduceMotion
            ? .opacity : .scale(scale: 0.6).combined(with: .opacity)
        return ZStack {
            if page == .canvas && tutorial.showsPanGuide {
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.regularMaterial, in: Circle())
                    // Appears like the Crown mini watch: grows in with a light bounce.
                    .scaleEffect(panGuideVisible || reduceMotion ? 1 : 0.6)
                    .offset(panGuideOffset)
                    .opacity(panGuideVisible ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .task { await runPanGuide() }
                    // The first pan fades the guide out where it is, shrinking like the mini watch.
                    .transition(transition)
            }
        }
    }

    @MainActor private func runPanGuide() async {
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
            let appear: Animation = reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.45, bounce: 0.3)
            withAnimation(appear) { panGuideVisible = true }
            guard !reduceMotion else { return }
            // Let the bounce settle before the arrows start moving.
            try await Task.sleep(for: .milliseconds(450))
            while !Task.isCancelled {
                for offset in offsets {
                    withAnimation(.easeInOut(duration: 0.45)) { panGuideOffset = offset }
                    try await Task.sleep(for: .milliseconds(500))
                }
            }
        // The next appearance resets both; resetting here would snap
        // the guide away in the middle of its fade-out.
        } catch {}
    }

    /// Kept out of `body` so the compiler type-checks it on its own.
    private func savedNotice(bottomInset: CGFloat) -> some View {
        let transition: AnyTransition = reduceMotion
            ? .opacity : .scale(scale: 0.85).combined(with: .opacity)
        return ZStack {
            if let savedNoticeID, page == .canvas {
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
                    .padding(.bottom, bottomInset)
                    .id(savedNoticeID)
                    .transition(transition)
                    .allowsHitTesting(false)
            }
        }
    }

    private var showsPrimaryControl: Bool {
        (page == .tools && tutorial.permits([.closeTools])) ||
        (page == .canvas && tutorial.permits([.finishLasso]) && !player.lasso.hidesControls) ||
        (page == .canvas && (isMovingCanvas
            ? tutorial.acceptsActions && tutorial.canFinishCamera
            : tutorial.permits([.openTools])))
    }

    // Lasso drags hide the control only briefly; keep its slot so the toolbar
    // does not reinsert the item around every selection gesture.
    private var installsPrimaryControl: Bool {
        page == .tools || showsPrimaryControl || player.lasso.hidesControls
    }

    private var canvasProtectedControls: [CanvasToolbarControl: CGRect] {
        guard page == .canvas else { return [:] }
        // Retain measurements for stable toolbar items across lessons. A frame
        // may not be reported again when only the button's label changes.
        let eraserControl = player.practiceEraserSlot.map { CustomCanvasControls.anchors[$0] }
        return controls.filter { control, _ in
            if control == eraserControl { return true }
            switch control {
            case .morph, .contentMorph, .custom: return false
            case .canvasToolsMorph: return tutorial.permits([.openLasso, .openLayers])
            case .tools: return showsPrimaryControl
            case .more: return tutorial.permits([.openMenu])
            case .undo, .redo: return tutorial.permits([.history])
            case .save: return tutorial.permits([.saveDrawing])
            case .clear: return tutorial.permits([.clearCanvas])
            }
        }
    }

    // Four targets must also fit the narrower 40 mm watches without overlap.
    /// Full-screen pages that sit on black; the drawing must never show between them.
    private var coversCanvasWithBackdrop: Bool {
        switch page {
        case .canvas, .menu, .tools: false
        case .gallery, .layers, .layerSettings, .canvasSettings, .canvasSize, .perspective, .crop,
             .drawingSettings, .colorBlending, .canvasEditor: true
        }
    }

    private var showsTutorialBottomControls: Bool {
        page == .canvas && tutorial.permits([.history, .saveDrawing])
    }

    @ViewBuilder private func tutorialBottomControls(hitDiameter: CGFloat) -> some View {
        if showsTutorialBottomControls {
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
            .transition(.opacity)
        }
        if let slot = player.practiceEraserSlot {
            // The circle the lesson's canvas editor filled, in the same bottom slot.
            HStack {
                ForEach(1...4, id: \.self) { index in
                    if index > 1 { Spacer(minLength: 0) }
                    if index == slot {
                        Button { player.toggleEraser() } label: {
                            CanvasQuickActionIcon(action: .eraserToggle, instrument: controller.pencilStyle.instrument)
                                .tutorialHint(tutorial, steps: [.toggleEraser])
                        }
                        .buttonStyle(TutorialOverlayButtonStyle(hitDiameter: hitDiameter))
                        .disabled(!tutorial.permits([.toggleEraser, .eraseStroke]))
                        .accessibilityLabel(L10n.text("Eraser ↔ tool"))
                        .trackCanvasControl(CustomCanvasControls.anchors[index], frames: $controls)
                    } else {
                        // Keeps the four slots of the canvas toolbar.
                        Button {} label: { BroomIcon() }
                            .buttonStyle(TutorialOverlayButtonStyle(hitDiameter: hitDiameter))
                            .hidden()
                            .disabled(true)
                            .accessibilityHidden(true)
                    }
                }
            }
            .transition(.opacity)
        }
        if page == .canvas && tutorial.step == .openLasso {
            HStack {
                Button {
                    isMovingCanvas = false
                    player.openLasso()
                } label: {
                    Image(systemName: "lasso").tutorialHint(tutorial, steps: [.openLasso])
                }
                .buttonStyle(TutorialOverlayButtonStyle(hitDiameter: hitDiameter))
                .disabled(!tutorial.permits([.openLasso]))
                .accessibilityLabel(L10n.text("Lasso"))
                .trackCanvasControl(.canvasToolsMorph, frames: $controls)
                Spacer()
            }
        }
        if page == .canvas && tutorial.step == .openLayers {
            HStack {
                Button {
                    isMovingCanvas = false
                    withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3)) {
                        player.openLayers()
                    }
                } label: {
                    Image(systemName: "square.3.layers.3d").tutorialHint(tutorial, steps: [.openLayers])
                }
                .buttonStyle(TutorialOverlayButtonStyle(hitDiameter: hitDiameter))
                .disabled(!tutorial.permits([.openLayers]))
                .accessibilityLabel(L10n.text("Layers"))
                .trackCanvasControl(.canvasToolsMorph, frames: $controls)
                Spacer()
            }
        }
        if page == .canvas && tutorial.step == .clearCanvas {
            Group {
                HStack {
                    Button {
                        player.requestClear()
                    } label: { BroomIcon().tutorialHint(tutorial, steps: [.clearCanvas]) }
                    .buttonStyle(TutorialOverlayButtonStyle(diameter: GalleryMorphState.buttonDiameter,
                                                           hitDiameter: hitDiameter))
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
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(startedAt))
            let phase = elapsed.truncatingRemainder(dividingBy: 4.4)
            let drawn = min(1, max(0, (phase - 0.4) / 1.8))
            // Match the real recognizer's half-second hold before straightening.
            let straightened = min(1, max(0, (phase - 2.7) / 0.25))
            let visibility = min(1, max(0, (4.4 - phase) / 0.4))
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
                if phase >= 0.4 && phase < 3.15 {
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

/// The guide is separate from the document and disappears when the user touches the canvas.
private struct TutorialLassoPresentation: View {
    let guideHeight: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var paperOpacity = 0.0
    @State private var showsGuide = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.white.opacity(paperOpacity)
            if showsGuide {
                TutorialLassoGuide()
                    .frame(height: guideHeight)
                    .transition(.opacity)
            }
        }
        .task {
            do {
                try await Task.sleep(for: .milliseconds(20))
                withAnimation(.easeInOut(duration: 0.25)) { paperOpacity = 0.6 }
                try await Task.sleep(for: .milliseconds(250))
                try Task.checkCancellation()
                withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3)) { showsGuide = true }
            } catch {}
        }
    }
}

private struct TutorialLassoGuide: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = Date()

    private func eased(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let phase = max(0, timeline.date.timeIntervalSince(startedAt)).truncatingRemainder(dividingBy: 6)
            let drawn = eased((phase - 0.5) / 1.8)
            let selected = eased((phase - 2.5) / 0.3)
            let moved = eased((phase - 3.2) / 1.2)
            let visibility = eased(phase / 0.3) * (1 - eased((phase - 5.3) / 0.7))
            Canvas { context, size in
                let top = min(50.0, size.height * 0.5)
                let availableHeight = max(0, size.height - top - 16)
                let radiusX = min(size.width * 0.24, availableHeight * 0.65)
                let radiusY = min(radiusX * 0.7, availableHeight * 0.34)
                let center = CGPoint(x: size.width * 0.43, y: top + availableHeight * 0.55)
                let translation = CGAffineTransform(translationX: moved * size.width * 0.17,
                                                    y: -moved * availableHeight * 0.16)
                let ink = Color(red: 0.20, green: 0.43, blue: 1)
                context.opacity = visibility

                // A small wave is the imaginary artwork being selected and moved.
                var artwork = Path()
                for index in 0...60 {
                    let t = CGFloat(index) / 60
                    let point = CGPoint(x: center.x + (t - 0.5) * radiusX * 1.3,
                                        y: center.y + sin(t * .pi * 3) * radiusY * 0.35)
                    if index == 0 { artwork.move(to: point) } else { artwork.addLine(to: point) }
                }
                context.stroke(artwork.applying(translation), with: .color(ink),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

                var loop = Path()
                for index in 0...120 {
                    let fraction = min(drawn, Double(index) / 120)
                    let angle = fraction * .pi * 2 - .pi / 2
                    let wobble = 1 + 0.035 * sin(angle * 3)
                    let point = CGPoint(x: center.x + cos(angle) * radiusX * wobble,
                                        y: center.y + sin(angle) * radiusY * wobble)
                    if index == 0 { loop.move(to: point) } else { loop.addLine(to: point) }
                    if fraction == drawn { break }
                }
                var outlineContext = context
                outlineContext.opacity *= 1 - selected
                // Match the real lasso's dotted white underlay and gray trail.
                outlineContext.stroke(loop, with: .color(.white.opacity(0.8)),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round, dash: [0.1, 4]))
                outlineContext.stroke(loop, with: .color(.gray),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [0.1, 4]))

                let bounds = CGRect(x: center.x - radiusX * 0.72, y: center.y - radiusY * 0.5,
                                    width: radiusX * 1.44, height: radiusY).applying(translation)
                var selectionContext = context
                selectionContext.opacity *= selected
                selectionContext.stroke(Path(bounds), with: .color(ink), lineWidth: 1)
                for point in WatchLassoGeometry.handles(bounds) {
                    let handle = Path(ellipseIn: CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5))
                    selectionContext.fill(handle, with: .color(Color(red: 0.16, green: 0.67, blue: 0.87)))
                    selectionContext.stroke(handle, with: .color(.white), lineWidth: 1)
                }
                if phase >= 3.2 && phase < 4.6 {
                    let finger = center.applying(translation)
                    let marker = Path(ellipseIn: CGRect(x: finger.x - 7, y: finger.y - 7, width: 14, height: 14))
                    context.fill(marker, with: .color(.white.opacity(0.5)))
                    context.stroke(marker, with: .color(.gray.opacity(0.7)), lineWidth: 1.5)
                }
            }
            .onChange(of: phase >= 3.2 && phase < 4.6) { _, isGrabbing in
                guard isGrabbing, !reduceMotion else { return }
                WKInterfaceDevice.current().play(.click)
            }
        }
        .onAppear { startedAt = Date() }
    }
}

private extension TutorialPlayerView {
    /// A full-screen question or confirmation hides the lesson and its toolbars.
    var coversLesson: Bool { confirmsFinish || offersContinuation }

    /// Split out of `body`: inline, the optional closures and the height ternary
    /// exceed the type checker's time limit.
    func lessonCard(width: CGFloat, screenHeight: CGFloat) -> TutorialLessonView {
        // Reserve the tool chrome, carousel, and a readable
        // three-item control. The card already scrolls overflow.
        var maximumCardHeight: CGFloat? = nil
        if page == .tools && !tutorial.isPaletteLesson {
            let reserved: CGFloat = 40 + 30 + ToolValueControl.minimumHeight + 12
            maximumCardHeight = max(32, screenHeight - reserved)
        }
        var onShowContinuation: (() -> Void)? = nil
        if awaitsContinuation { onShowContinuation = { showContinuationOffer() } }
        let continuation: TutorialContinuationActions? = offersContinuation ? continuationActions : nil
        let preserveAndFinish: () -> Void = {
            if player.preserveDrawing() { onFinish() }
        }
        return TutorialLessonView(tutorial: tutorial, onFinish: preserveAndFinish,
                                  screenWidth: width, screenHeight: screenHeight,
                                  maximumCardHeight: maximumCardHeight,
                                  confirmsFinish: $confirmsFinish,
                                  onShowContinuation: onShowContinuation,
                                  continuation: continuation)
    }

    /// The first chapter's result of a run that asks before the rest: its card shows a
    /// checkmark, not Next, and grows into the question.
    var awaitsContinuation: Bool {
        offersRemainingChapters && !hasOfferedContinuation && tutorial.step == .chapterComplete
            && tutorial.chapter == chapters.first && !remainingChapters.isEmpty
    }

    func showContinuationOffer() {
        guard awaitsContinuation, !confirmsFinish else { return }
        hasOfferedContinuation = true
        tutorial.pauseReminders()
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.55, bounce: 0)) {
            offersContinuation = true
        }
    }

    var continuationActions: TutorialContinuationActions {
        TutorialContinuationActions(completedChapter: tutorial.chapter) {
            guard !answeredContinuation else { return }
            guard player.preserveDrawing() else {
                // The save error alert is shown; return to the result, where Next still works.
                withAnimation(.easeInOut(duration: 0.3)) { offersContinuation = false }
                return
            }
            answeredContinuation = true
            onFinish()
        } onContinue: {
            guard !answeredContinuation else { return }
            answeredContinuation = true
            tutorial.resumeReminders()
            // One transaction: the compact card measures the next chapter's first instruction,
            // so the card shrinks straight to that hint's height, not to the result's.
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.5, bounce: 0)) {
                offersContinuation = false
                tutorial.continueToNext()
            }
        }
    }

    /// Chapters of this run that follow the one just completed.
    var remainingChapters: [TutorialChapter] {
        guard let chapter = tutorial.chapter, let index = chapters.firstIndex(of: chapter) else { return [] }
        return Array(chapters[(index + 1)...])
    }
}

// MARK: - Tutorial chrome fade

/// Native toolbar items are inserted and removed without animation. In the tutorial a
/// page's top buttons fade in when the page appears and fade out before it leaves:
/// the player sets `tutorialChromeHidden`, waits for the fade, then changes the page.
struct TutorialChromeFade: ViewModifier {
    @Environment(\.tutorialChromeHidden) private var isHidden
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isRevealed = false

    func body(content: Content) -> some View {
        content
            .opacity(isRevealed && !isHidden ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : TutorialChromeFade.duration)) {
                    isRevealed = true
                }
            }
            .onDisappear { isRevealed = false }
    }

    /// Matches the page crossfade, so buttons and page arrive and leave together.
    static let duration: Double = 0.25
}

extension View {
    /// Applies only in the tutorial; the editor's toolbar keeps its own behavior.
    @ViewBuilder func tutorialChromeFade(_ isActive: Bool = true) -> some View {
        if isActive { modifier(TutorialChromeFade()) } else { self }
    }
}

private struct TutorialChromeHiddenKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The tutorial page is leaving; its top buttons fade out with it.
    var tutorialChromeHidden: Bool {
        get { self[TutorialChromeHiddenKey.self] }
        set { self[TutorialChromeHiddenKey.self] = newValue }
    }
}
