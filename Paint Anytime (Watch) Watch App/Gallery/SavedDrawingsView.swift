import SwiftUI
import WatchKit

struct SavedDrawingsView: View {
    @Environment(\.tutorialHintReservedHeight) private var tutorialHintReservedHeight
    @ObservedObject var tutorial = TutorialSession.inactive
    var galleryFolder: URL? = nil
    var initialArtworkFilename: String? = nil
    var initialBitmap: GalleryBitmap? = nil
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    var needsDiscardConfirmation = false
    var isPreparingCanvas = false
    var preparationError: String? = nil
    @State private var drawingToEdit: CanvasExport?
    @State private var pendingEdit: CanvasExport?
    @State private var confirmedEdit: CanvasExport?
    private var isLoading: Bool { drawingToEdit != nil || isPreparingCanvas }
    var onClose: () -> Void
    var onEditDrawing: (CanvasDocument) -> Void
    @StateObject private var controller = GalleryController()
    private var drawings: [CanvasExport] { controller.drawings }
    @State private var zoomLevel = 0
    @State private var returnGridLevel = 1
    @State private var crownPosition = 0.0
    @State private var selectedDrawing: CanvasExport?
    private var focusedDrawing: CanvasExport? {
        get { gridStorage.focusedDrawing }
        nonmutating set { gridStorage.focusedDrawing = newValue }
    }
    @State private var pendingDeletion: CanvasExport?
    @State private var showsFullscreen = false
    @State private var isCleanViewing = false
    @State private var showsFullscreenActions = false
    @State private var morphState = GalleryMorphState()
    @State private var pageVisibility: [URL: Double] = [:]
    @State private var galleryScrollTarget: URL?
    @State private var gridStorage = GalleryGridStorage()
    private var thumbnailFrames: [URL: CGRect] { gridStorage.frames }
    private var thumbnailBitmaps: [URL: GalleryBitmap] {
        get { gridStorage.bitmaps }
        nonmutating set { gridStorage.bitmaps = newValue }
    }
    @State private var gridZoom = GalleryGridZoom()
    @State private var galleryViewport: CGSize = .zero
    @State private var galleryTopInset: CGFloat = 0
    @State private var leadingSlots = 0
    @State private var imageLayout = GalleryImageLayout()
    @State private var suppressOpeningUntil = Date.distantPast
    @State private var transitionBitmap: GalleryBitmap?
    @State private var displayedBitmap: GalleryBitmap?
    @FocusState private var crownTarget: GalleryCrownInput.Target?
    private var crownFocused: Bool {
        get { crownTarget != nil }
        nonmutating set {
            crownTarget = newValue ? (isTransitioning || showsFullscreen ? .presentation : .grid) : nil
        }
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    private enum FullscreenControlsPhase: Hashable { case hidden, visible }
    private var fullscreenControlsPhase: FullscreenControlsPhase {
        guard showsFullscreen, selectedDrawing != nil else { return .hidden }
        return isTransitioning ? .hidden : .visible
    }

    // Taps replace the phone's pinch: 5 → 3 → the existing photo screen.
    // The final zoom step uses its morph actions rather than a one-column grid.
    private let fullscreenLevel = 2
    private var gridLevel: Int { showsFullscreen ? returnGridLevel : zoomLevel }
    private var columnCount: Int { gridLevel == 0 ? 5 : 3 }
    private var isTransitioning: Bool { gridZoom.active }

    private var galleryContent: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 2
            let width = (geometry.size.width - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount)
            let navigationHeight: CGFloat = max(60, geometry.safeAreaInsets.top + 38)
            // The first row starts below the back button and clock. This is a
            // scroll-content inset, so subsequent rows can pass behind the header.
            // Share it with zoom geometry to keep both layouts aligned.
            let contentTopInset: CGFloat = navigationHeight + 4
            let thumbnailPixels = Int(ceil(width * displayScale / 32)) * 32
            ZStack(alignment: .topLeading) {
                Color.black
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        galleryGrid(spacing: spacing, width: width, thumbnailPixels: thumbnailPixels)
                            .reportLegacyScrollPosition()
                    }
                    .modifier(crownInput(for: .grid))
                    // Let photos scroll behind the tutorial card while allowing
                    // the final row to scroll fully above it.
                    .contentMargins(.bottom, tutorialHintReservedHeight, for: .scrollContent)
                    .contentMargins(.top, contentTopInset, for: .scrollContent)
                    .scrollIndicators(.hidden)
                    .galleryCustomHeaderEdge()
                    .scrollDisabled(gridZoom.active || showsFullscreen)
                    // Observe native scrolling without competing with its swipe gesture.
                    .onTutorialScrollActivity { tutorial.activity() }
                    .galleryInputScrollDiagnostics()
                    .allowsHitTesting(!showsFullscreen && !isTransitioning && tutorial.allowsGalleryZoom)
                    .accessibilityHidden(showsFullscreen || gridZoom.active)
                    .onChange(of: zoomLevel) { previousLevel, level in
                        if !gridZoom.active, previousLevel != fullscreenLevel, level < fullscreenLevel, let drawing = focusedDrawing {
                            withoutAnimation {
                                scrollProxy.scrollTo(drawing.id, anchor: .center)
                            }
                        }
                    }
                    .onChange(of: galleryScrollTarget) { _, id in
                        guard !gridZoom.active, showsFullscreen, let id else { return }
                        withoutAnimation { scrollProxy.scrollTo(id, anchor: .center) }
                    }
                    .task(id: gridZoom.pendingCommit?.id) {
                        await restoreGridZoom(using: scrollProxy, size: geometry.size, navigationHeight: navigationHeight)

                    }

                }
                // Keep native layout mounted underneath the captured zoom slots.
                .opacity(gridZoom.active || showsFullscreen ? 0 : 1)

                if showsFullscreen {
                    Color.black.allowsHitTesting(false)
                    fullscreenGallery(size: geometry.size, canvasOriginX: geometry.frame(in: .global).minX, canvasOriginY: geometry.frame(in: .global).minY,
                                      thumbnailPixels: thumbnailPixels)
                        .allowsHitTesting(!isTransitioning && tutorial.allowsGalleryPaging)
                        .accessibilityHidden(isTransitioning)
                }

                if gridZoom.active {
                    GalleryGridZoomOverlay(zoom: gridZoom)
                }
                GalleryHeaderBackdrop(height: navigationHeight + 24,
                                      zoom: gridZoom, showsFullscreen: showsFullscreen)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if showsFullscreen && !isTransitioning && !tutorial.isActive,
                   let selectedDrawing {
                    GalleryMorphActions(state: morphState,
                                        canvasOrigin: geometry.frame(in: .global).origin,
                                        drawing: selectedDrawing, size: geometry.size,
                                        isFavorite: drawings.first(where: { $0.id == selectedDrawing.id })?.isFavorite ?? false,
                                        favoriteProgress: favoriteProgress,
                                        onEdit: { editDrawing(selectedDrawing) },
                                        onFavorite: { favorite in
                                            controller.setFavorite(favorite, for: selectedDrawing, in: galleryFolder)
                                        }, onDelete: {
                                            crownFocused = false
                                            pendingDeletion = selectedDrawing
                                        })
                        .opacity(isCleanViewing || !showsFullscreenActions ? 0 : 1)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: isCleanViewing)
                        .allowsHitTesting(!isCleanViewing && showsFullscreenActions && !isTransitioning)
                        .accessibilityHidden(isCleanViewing || !showsFullscreenActions || isTransitioning)

                }
            }
            .overlay {
                if isLoading {
                    ZStack {
                        Color.black.opacity(0.3)
                        ProgressView().tint(.white)
                    }
                    .contentShape(Rectangle())
                }
            }
            #if DEBUG
            .overlay(alignment: .bottomTrailing) {
                if GalleryDebug.isEnabled {
                    WatchGalleryDebugOverlay {
                        WatchGalleryDiagnostics.shared.inputText(zoom: gridZoom,
                            focus: crownTarget.map { $0 == .grid ? "grid" : "zoom" } ?? "none", dragging: gridZoom.isPanning) + "\n" +
                        WatchGalleryDiagnostics.shared.gridText(zoom: gridZoom,
                            urls: drawings.map(\.url), selected: selectedDrawing?.url,
                            focused: focusedDrawing?.url, displayed: displayedBitmap?.url,
                            frames: thumbnailFrames, columns: columnCount,
                            leading: leadingSlots, topInset: galleryTopInset)
                    }
                        .padding(.trailing, 4)
                        .padding(.bottom, max(4, tutorialHintReservedHeight))
                }
            }
            #endif
            .allowsHitTesting(!isLoading)
            .coordinateSpace(name: "drawingGallery")
            .onAppear {
                galleryViewport = geometry.size
                galleryTopInset = contentTopInset
            }
            .onChange(of: contentTopInset) { _, inset in
                galleryTopInset = inset
                gridZoom.reset()
            }
            .onChange(of: geometry.size) { _, size in
                galleryViewport = size
                galleryTopInset = contentTopInset
                gridZoom.reset()
            }
            .onDisappear {
                gridZoom.reset()
                gridStorage.clearBitmaps()
            }
            .task(id: gridZoom.loadingID) {
                await gridZoom.loadImages(scale: displayScale)
            }
            .onChange(of: gridZoom.errorMessage) { _, message in
                if let message { controller.errorMessage = message }
            }
            .onPreferenceChange(GalleryThumbnailFramesKey.self) { frames in
                #if DEBUG
                let debugStarted = GalleryDebug.isEnabled ? ProcessInfo.processInfo.systemUptime : 0
                defer {
                    if GalleryDebug.isEnabled {
                        let elapsed = (ProcessInfo.processInfo.systemUptime - debugStarted) * 1000
                        WatchGalleryDiagnostics.shared.geometry(elapsedMS: elapsed, frames: frames,
                            viewport: geometry.size, bitmaps: thumbnailBitmaps,
                            columns: columnCount, zooming: gridZoom.active)
                    }
                }
                #endif
                gridStorage.update(frames: frames, viewport: geometry.size)
                if !showsFullscreen && !isTransitioning,
                   let nearest = frames.filter({ $0.value.maxY > navigationHeight && $0.value.minY < geometry.size.height })
                    .min(by: {
                        hypot($0.value.midX - geometry.size.width / 2, $0.value.midY - geometry.size.height / 2)
                            < hypot($1.value.midX - geometry.size.width / 2, $1.value.midY - geometry.size.height / 2)
                    }) {
                    focusedDrawing = drawings.first { $0.id == nearest.key }
                }
            }
        }
        .task(id: drawingToEdit?.id) {
            guard let drawing = drawingToEdit else { return }
            defer { drawingToEdit = nil }
            guard let document = await controller.loadDocument(for: drawing), !Task.isCancelled else { return }
            onEditDrawing(document)
        }
        .onChange(of: preparationError) { _, error in
            if let error { controller.errorMessage = error }
        }
        .onChange(of: isLoading) { _, loading in
            crownFocused = !loading && pendingDeletion == nil && tutorial.allowsGalleryZoom
        }
        .disabled(isLoading)
        .ignoresSafeArea(.container, edges: tutorial.isActive ? [] : .all)
        // watchOS keeps its clock visible with persistentSystemOverlays(.hidden).
        // Its SDK exposes status-bar visibility through this underscored modifier.
        ._statusBarHidden(isCleanViewing)
        .toolbar {
            if showsFullscreen && !isTransitioning && !tutorial.isActive {
                ToolbarItemGroup(placement: .bottomBar) {
                    GalleryMorphToolbarButton(state: morphState)
                        .disabled(isCleanViewing || isLoading || isTransitioning)
                        .accessibilityHidden(isCleanViewing || isTransitioning)
                    Spacer(minLength: 0)
                }
            }
            if tutorial.allowsGalleryBack {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: goBack) {
                        Image(systemName: "chevron.left")
                            .opacity(0)
                            .tutorialHint(tutorial, steps: [.returnToCanvas])
                    }
                    .disabled(isTransitioning || isCleanViewing || isLoading)
                    .watchToolbarButtonStyle(diameter: GalleryMorphState.toolbarDiameter, hidesNativeChrome: true)
                    .overlay {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: GalleryMorphState.buttonDiameter,
                                   height: GalleryMorphState.buttonDiameter)
                            .modifier(CanvasMorphGlass(adaptsToCanvas: true))
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    .opacity(isCleanViewing ? 0 : 1)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: isCleanViewing)
                    .allowsHitTesting(!isCleanViewing)
                    .accessibilityHidden(isCleanViewing)
                    .accessibilityLabel(L10n.text("Back"))
                    .onGeometryChange(for: CGRect.self) { geometry in
                        geometry.frame(in: .global)
                    } action: { frame in
                        if morphState.backButtonFrame != frame { morphState.backButtonFrame = frame }
                    }
                }
            }
        }

        .overlay {
            if tutorial.isActive && showsFullscreen,
               !isTransitioning,
               tutorial.allowsGalleryDelete, let selectedDrawing {
                GeometryReader { geometry in
                    let centerX = morphState.backButtonFrame.map {
                        $0.midX - geometry.frame(in: .global).minX
                    } ?? 30
                    Button(role: .destructive) {
                        crownFocused = false
                        tutorial.pauseReminders()
                        pendingDeletion = selectedDrawing
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: GalleryMorphState.buttonDiameter,
                                   height: GalleryMorphState.buttonDiameter)
                            .modifier(CanvasMorphGlass(adaptsToCanvas: true))
                            .tutorialHint(tutorial, steps: [.deleteDrawing])
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .position(x: centerX,
                              y: max(22, geometry.size.height - tutorialHintReservedHeight - 22))
                    .opacity(showsFullscreenActions ? 1 : 0)
                    .disabled(!showsFullscreenActions || isTransitioning || isLoading)
                    .allowsHitTesting(showsFullscreenActions && !isTransitioning)
                    .accessibilityHidden(!showsFullscreenActions || isTransitioning)
                    .accessibilityLabel(L10n.text("Delete drawing"))
                }
            }
        }
        .task(id: fullscreenControlsPhase) {
            switch fullscreenControlsPhase {
            case .hidden:
                showsFullscreenActions = false
            case .visible:
                // Photo transitions finish with animations disabled; fade the
                // controls in a separate update, including in the tutorial.
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.25)) {
                    showsFullscreenActions = true
                }

            }
        }
    }

    private func crownInput(for target: GalleryCrownInput.Target) -> GalleryCrownInput {
        let owner: GalleryCrownInput.Target = isTransitioning || showsFullscreen ? .presentation : .grid
        return GalleryCrownInput(target: target,
            enabled: owner == target && !isLoading && pendingDeletion == nil && tutorial.allowsGalleryZoom,
            focus: $crownTarget,
            position: Binding(get: { crownPosition }, set: { value in
                // A disabled host can still deliver a queued event at handoff.
                let current: GalleryCrownInput.Target = isTransitioning || showsFullscreen ? .presentation : .grid
                guard current == target else { return }
                gridStorage.lastCrownInputTarget = target
                updateCrownZoom(value)
            }),
            onChange: { [step = tutorial.step] event in
                tutorial.usedCrown(in: step, velocity: event.velocity)
                #if DEBUG
                if GalleryDebug.isEnabled { WatchGalleryDiagnostics.shared.crownVelocity = event.velocity }
                #endif
            }, onIdle: {
                // A short turn may end immediately after changing focus. Its
                // original host must still settle unless newer input superseded it.
                guard gridStorage.lastCrownInputTarget == target else { return }
                settleCrownZoom()
            })
    }

    private var galleryWithConfirmations: some View {
        galleryContent
        .disabled(isLoading)
        .modifier(crownInput(for: .presentation))
        .onChange(of: isTransitioning || showsFullscreen) { _, _ in
            // Transfer ownership only when the presentation changes, never on
            // drag samples or scroll phases (which can interrupt native inertia).
            crownFocused = !isLoading && pendingDeletion == nil && tutorial.allowsGalleryZoom
        }
        .fullScreenCover(item: $pendingEdit, onDismiss: {
            // Start file loading only after Yes and dismissal of the confirmation.
            if let drawing = confirmedEdit {
                confirmedEdit = nil
                drawingToEdit = drawing
            } else {
                crownFocused = tutorial.allowsGalleryZoom
            }
        }) { drawing in
            DestructiveConfirmationView(
                title: L10n.text("Discard the previous unsaved canvas?"),
                confirmTitle: L10n.text("Yes")) {
                confirmedEdit = nil
                pendingEdit = nil
            } onConfirm: {
                confirmedEdit = drawing
                pendingEdit = nil
            }
        }
        .fullScreenCover(item: $pendingDeletion, onDismiss: {
            tutorial.resumeReminders()
            crownFocused = tutorial.allowsGalleryZoom
        }) { drawing in
            DestructiveConfirmationView(title: deletionConfirmationTitle, confirmTitle: L10n.text("Delete")) {
                pendingDeletion = nil
            } onConfirm: {
                // Prepare the updated grid while confirmation still
                // covers the pager. Its dismissal then reveals the grid directly.
                withoutAnimation { deleteDrawing(drawing) }
                withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3)) {
                    pendingDeletion = nil
                }
            }
        }
    }

    var body: some View {
        galleryWithConfirmations
        .alert(L10n.text("Error"), isPresented: Binding(
            get: { controller.errorMessage != nil }, set: { if !$0 { controller.errorMessage = nil } }
        )) { Button(L10n.text("OK"), role: .cancel) { controller.errorMessage = nil } }
        message: { Text(controller.errorMessage ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: .galleryDrawingsDeleted)) { _ in
            handleRemoteDeletions()
        }
        .onReceive(NotificationCenter.default.publisher(for: .paintProjectImported)) { _ in
            controller.reload(in: galleryFolder)
        }
         .onAppear {
            crownFocused = tutorial.allowsGalleryZoom
            controller.reload(in: galleryFolder)
            if let filename = initialArtworkFilename,
               let drawing = drawings.first(where: { $0.url.lastPathComponent == filename }) {
                // Direct launches open at 1:1 without a transition from a grid tile.
                transitionBitmap = initialBitmap?.url == drawing.url ? initialBitmap : nil
                focusedDrawing = drawing
                selectedDrawing = drawing
                zoomLevel = fullscreenLevel
                crownPosition = Double(fullscreenLevel)
                showsFullscreen = true
                galleryScrollTarget = drawing.id
            }
        }
        .onChange(of: drawings.map(\.url), initial: true) { _, urls in
            imageLayout = GalleryImageLayout(images: urls)
            if gridZoom.active, urls != gridZoom.snapshot { gridZoom.reset() }
            leadingSlots = 0
            gridStorage.retain(urls: Set(urls))
        }
        .onChange(of: tutorial.showsInstruction) { _, showing in
            crownFocused = !showing && tutorial.allowsGalleryZoom && pendingDeletion == nil
            if !showing && showsFullscreen && !isTransitioning { tutorial.record(.galleryFullscreen) }
        }
        .onChange(of: showsFullscreen) { _, fullscreen in
            morphState.isExpanded = false
            if !fullscreen { pageVisibility = [:] }
            tutorial.galleryIsFullscreen = fullscreen
            // Reduce Motion opens directly, so isTransitioning never changes.
            // Record the ready fullscreen state even without an animation callback.
            if fullscreen && !isTransitioning { tutorial.record(.galleryFullscreen) }
        }
        .onChange(of: isTransitioning) { _, transitioning in
            if transitioning { morphState.isExpanded = false }
            if !transitioning && showsFullscreen { tutorial.record(.galleryFullscreen) }
        }
    }

    private var deletionConfirmationTitle: String {
        let key = galleryFolder == nil
            ? "Delete from Apple Watch and iPhone? Export it first to keep a copy."
            : "Delete the image?"
        return L10n.text(key)
    }

    private func handleRemoteDeletions() {
        guard galleryFolder == nil else { return }
        controller.reload()
        if let pendingDeletion, !drawings.contains(where: { $0.id == pendingDeletion.id }) {
            self.pendingDeletion = nil
        }
        if let focusedDrawing, !drawings.contains(where: { $0.id == focusedDrawing.id }) {
            self.focusedDrawing = nil
            returnToGrid()
        }
    }

    @ViewBuilder
    private func galleryGrid(spacing: CGFloat, width: CGFloat, thumbnailPixels: Int) -> some View {
        if let errorMessage = controller.errorMessage {
            Text(errorMessage).foregroundStyle(.red).padding()
        } else if drawings.isEmpty {
            ContentUnavailableView(L10n.text("No drawings"), systemImage: "photo.on.rectangle")
        } else {
            GalleryThumbnailGrid(columns: columnCount, spacing: spacing, side: width, leading: leadingSlots) {
                ForEach(drawings) { drawing in
                    Button {
                        guard Date() >= suppressOpeningUntil else { return }
                        tutorial.activity()
                        focusedDrawing = drawing
                        if zoomLevel == 0 { setZoom(1) }
                        else { open(drawing) }
                    } label: {
                        GalleryThumbnailView(request: GalleryImageRequest(
                            url: drawing.url, shortSidePixels: thumbnailPixels, displayScale: displayScale),
                            loadsImage: !gridZoom.active || gridZoom.pendingCommit != nil,
                            visibility: gridStorage.visibility(for: drawing.id),
                            isFavorite: drawing.isFavorite,
                            onDisplayedBitmap: { bitmap in
                                thumbnailBitmaps[drawing.id] = bitmap
                            })
                            .frame(width: width, height: width)
                            .clipped()
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!tutorial.allowsGalleryZoom)
                    .accessibilityLabel(L10n.text("Open drawing"))
                    .id(drawing.id)
                }
            }
            .background {
                GeometryReader { gridGeometry in
                    // The layout is regular: one measured origin is enough for
                    // every tile, including offscreen zoom destinations.
                    let origin = gridGeometry.frame(in: .named("drawingGallery")).origin
                    Color.clear.preference(key: GalleryThumbnailFramesKey.self,
                        value: Dictionary(uniqueKeysWithValues: drawings.enumerated().map { index, drawing in
                            let slot = index + leadingSlots
                            return (drawing.id, CGRect(
                                x: origin.x + CGFloat(slot % columnCount) * (width + spacing),
                                y: origin.y + CGFloat(slot / columnCount) * (width + spacing),
                                width: width, height: width))
                        }))
                }
            }
            .padding(.bottom, 12)
        }
    }

    private func goBack() {
        guard !isLoading else { return }
        guard tutorial.allowsGalleryBack else { return }
        tutorial.activity()
        guard !isTransitioning else { return }
        if showsFullscreen { setZoom(returnGridLevel) }
        else if zoomLevel > 0 { setZoom(zoomLevel - 1) }
        else { onClose() }
    }

    @MainActor
    private func restoreGridZoom(using proxy: ScrollViewProxy, size: CGSize, navigationHeight: CGFloat) async {
        guard let commit = gridZoom.pendingCommit else { return }
        #if DEBUG
        if GalleryDebug.isEnabled {
            WatchGalleryDiagnostics.shared.restoreAt = ProcessInfo.processInfo.systemUptime
            WatchGalleryDiagnostics.shared.restoreAttempts = 0
            WatchGalleryDiagnostics.shared.restoreReady = false
            WatchGalleryDiagnostics.shared.restoreError = 0
        }
        #endif
        if commit.columns == 1 {
            guard let drawing = drawings.first(where: { $0.id == gridZoom.target }) else {
                gridZoom.reset()
                return
            }
            let alreadyDisplayed = showsFullscreen && selectedDrawing?.url == drawing.url && displayedBitmap != nil
            withoutAnimation {
                returnGridLevel = gridZoom.baseColumns == 5 ? 0 : 1
                focusedDrawing = drawing
                selectedDrawing = drawing
                transitionBitmap = gridZoom.bitmaps[drawing.url]
                zoomLevel = fullscreenLevel
                showsFullscreen = true
            }
            if alreadyDisplayed { completeGridZoom() }
            // The pager acknowledges its displayed bitmap before
            // the overlay releases the fitted-photo endpoint.
            return
        }
        if commit.anchorY != -1 { gridZoom.nativeLayoutWillChange() }
        withoutAnimation {
            showsFullscreen = false
            selectedDrawing = nil
            zoomLevel = commit.columns == 5 ? 0 : 1
            returnGridLevel = zoomLevel
            leadingSlots = commit.leading
            if let target = gridZoom.target {
                focusedDrawing = drawings.first { $0.url == target }
            }
        }
        if commit.anchorY == -1 {
            completeGridZoom()
            return
        }
        var anchorY = commit.anchorY
        var attempt = 0
        while !Task.isCancelled {
            guard !Task.isCancelled, gridZoom.pendingCommit?.id == commit.id else { return }
            withoutAnimation { proxy.scrollTo(commit.target, anchor: UnitPoint(x: 0.5, y: attempt < 4 ? anchorY : 0.5)) }
            attempt += 1
            #if DEBUG
            if GalleryDebug.isEnabled { WatchGalleryDiagnostics.shared.restoreAttempts = attempt }
            #endif
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            guard gridZoom.pendingCommit?.id == commit.id,
                  let frame = thumbnailFrames[commit.target] else { continue }
            let side = GalleryZoomRules.side(commit.columns, width: size.width)
            guard abs(frame.width - side) < 1 else { continue }
            let visible = thumbnailFrames.filter {
                $0.value.maxY > 0 && $0.value.minY < size.height
            }
            let prepared = gridZoom.loadingComplete || visible.keys.allSatisfy { thumbnailBitmaps[$0] != nil }
            #if DEBUG
            if GalleryDebug.isEnabled {
                WatchGalleryDiagnostics.shared.restoreError = frame.minY - commit.viewportTop
                WatchGalleryDiagnostics.shared.restoreReady = prepared
            }
            #endif
            if abs(frame.minY - commit.viewportTop) < 1, prepared {
                completeGridZoom()
                return
            }
            // Compensate for the system scroll view's inset handling.
            anchorY += (commit.viewportTop - frame.minY) / max(1, size.height - side)
            if attempt >= 4, prepared, frame.maxY > navigationHeight, frame.minY < size.height {
                completeGridZoom()
                return
            }
        }
    }

    private func beginGridZoom(target: CanvasExport) {
        guard !gridZoom.active else { return }
        var cached = thumbnailBitmaps
        if let displayedBitmap, displayedBitmap.url == target.url { cached[target.url] = displayedBitmap }
        let frame = thumbnailFrames[target.id] ?? .zero
        gridZoom.begin(images: drawings.map(\.url), target: target.url,
            baseColumns: showsFullscreen ? 1 : columnCount, baseLeading: showsFullscreen ? 0 : leadingSlots,
            sourceFrame: frame, viewport: galleryViewport, topInset: galleryTopInset,
            bottomInset: tutorialHintReservedHeight + 12, layout: imageLayout,
            cached: cached, favorites: Set(drawings.filter(\.isFavorite).map(\.url)), crown: crownPosition)
        isCleanViewing = false
        morphState.isExpanded = false
    }

    private func setZoom(_ level: Int) {
        guard !isTransitioning, let target = selectedDrawing ?? focusedDrawing ?? drawings.first else { return }
        beginGridZoom(target: target)
        gridZoom.settle(to: level == 0 ? 5 : 3, reduceMotion: reduceMotion)
        WKInterfaceDevice.current().play(.click)
    }

    private func updateCrownZoom(_ value: Double) {
        #if DEBUG
        if GalleryDebug.isEnabled {
            let reason = isLoading ? "loading" : pendingDeletion != nil ? "delete" :
                !tutorial.allowsGalleryZoom ? "tutorial" : "accepted"
            WatchGalleryDiagnostics.shared.crown(value, result: reason)
        }
        #endif
        guard !isLoading, pendingDeletion == nil, tutorial.allowsGalleryZoom else { return }
        tutorial.activity()
        if !gridZoom.active {
            guard let target = selectedDrawing ?? focusedDrawing ?? drawings.first else { return }
            beginGridZoom(target: target)
        }
        gridZoom.updateCrown(value)
        crownPosition = value
    }

    private func settleCrownZoom() {
        #if DEBUG
        if GalleryDebug.isEnabled { WatchGalleryDiagnostics.shared.crownIdleEvents += 1 }
        #endif
        gridZoom.settle(reduceMotion: reduceMotion)
    }

    private func completeGridZoom() {
        gridZoom.reset()
        crownPosition = Double(zoomLevel)
        suppressOpeningUntil = Date().addingTimeInterval(0.3)
    }

    private func open(_ drawing: CanvasExport) {
        guard !isTransitioning else { return }
        focusedDrawing = drawing
        beginGridZoom(target: drawing)
        gridZoom.settle(to: 1, reduceMotion: reduceMotion)
        WKInterfaceDevice.current().play(.click)
    }

    private func returnToGrid() {
        gridZoom.reset()
        isCleanViewing = false
        showsFullscreen = false
        selectedDrawing = nil
        displayedBitmap = nil
        transitionBitmap = nil
        zoomLevel = returnGridLevel
        crownPosition = Double(returnGridLevel)
    }

    private func withoutAnimation(_ action: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, action)
    }

    private var favoriteProgress: Double {
        let visible = drawings.map { ($0, pageVisibility[$0.id] ?? 0) }
        let total = visible.reduce(0.0) { $0 + $1.1 }
        guard total > 0 else {
            return drawings.first(where: { $0.id == selectedDrawing?.id })?.isFavorite == true ? 1 : 0
        }
        return visible.reduce(0.0) { $0 + ($1.0.isFavorite ? $1.1 : 0) } / total
    }

    private func fullscreenGallery(size: CGSize, canvasOriginX: CGFloat, canvasOriginY: CGFloat, thumbnailPixels: Int) -> some View {
        let selectedIndex = drawings.firstIndex(where: { $0.id == selectedDrawing?.id }) ?? 0
        return TabView(selection: Binding<URL?>(
            get: { selectedDrawing?.id },
            set: { id in
                guard tutorial.allowsGalleryPaging, !isTransitioning, id != selectedDrawing?.id,
                      let drawing = drawings.first(where: { $0.id == id }) else { return }
                tutorial.activity()
                selectedDrawing = drawing
                focusedDrawing = drawing
                galleryScrollTarget = drawing.id
            }
        )) {
            ForEach(Array(drawings.enumerated()), id: \.element.id) { index, drawing in
                GalleryFullscreenPage(url: drawing.url, size: size, canvasOriginY: canvasOriginY,
                                      thumbnailPixels: thumbnailPixels,
                                      displayScale: displayScale,
                                      isNearby: abs(index - selectedIndex) <= 1 && (!gridZoom.active || gridZoom.pendingCommit?.columns == 1),
                                      loadsOriginal: abs(index - selectedIndex) <= 1 && (!gridZoom.active || gridZoom.pendingCommit?.columns == 1),
                                      fallback: transitionBitmap?.url == drawing.url ? transitionBitmap : nil,
                                      respectsSafeArea: tutorial.isActive,
                                      fitsViewport: true,
                                      isSelected: drawing.id == selectedDrawing?.id,
                                      onDisplayedBitmap: { bitmap in
                                          guard drawing.id == selectedDrawing?.id else { return }
                                          if gridZoom.pendingCommit?.columns == 1 {
                                              displayedBitmap = bitmap
                                              completeGridZoom()
                                          } else if !isTransitioning {
                                              displayedBitmap = bitmap
                                          }
                                      })
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard showsFullscreen, zoomLevel == fullscreenLevel, !isTransitioning,
                              !tutorial.isActive else { return }
                        morphState.isExpanded = false
                        isCleanViewing.toggle()
                    }
                    .onGeometryChange(for: Double.self) { page in
                        let distance = abs(page.frame(in: .global).minX - canvasOriginX)
                        return max(0, 1 - Double(distance / max(size.width, 1)))
                    } action: { visibility in
                        // Read each native page directly; no preference propagation through TabView.
                        // Geometry supplies the animation progress, so do not ease these updates.
                        withoutAnimation { pageVisibility[drawing.id] = visibility }
                    }
                    .onDisappear {
                        withoutAnimation { pageVisibility.removeValue(forKey: drawing.id) }
                    }
                    .tag(Optional(drawing.id))
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea(.container, edges: tutorial.isActive ? [] : .all)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .position(x: size.width / 2, y: size.height / 2)
        .task(id: isTransitioning ? nil : selectedDrawing?.id) {
            // Warm adjacent originals even if TabView has not mounted those pages yet.
            for index in [selectedIndex, selectedIndex - 1, selectedIndex + 1] {
                guard !Task.isCancelled, !isTransitioning else { return }
                guard drawings.indices.contains(index) else { continue }
                _ = await GalleryImageCache.shared.load(GalleryImageRequest(
                    url: drawings[index].url, shortSidePixels: nil, displayScale: displayScale))
            }
        }
    }

    private func deleteDrawing(_ drawing: CanvasExport) {
        guard controller.delete(drawing, in: galleryFolder) else { return }
        focusedDrawing = nil
        returnToGrid()
        WKInterfaceDevice.current().play(.click)
        tutorial.record(.deleted)
    }

    private func editDrawing(_ drawing: CanvasExport) {
        guard !isLoading else { return }
        crownFocused = false
        if needsDiscardConfirmation {
            confirmedEdit = nil
            pendingEdit = drawing
        } else {
            drawingToEdit = drawing
        }
    }

}

/// Keep tile identities and offscreen positions alive across column changes.
/// Bitmap loading remains limited to the viewport and its prefetch margin.
private struct GalleryThumbnailGrid: Layout {
    let columns: Int
    let spacing: CGFloat
    let side: CGFloat
    let leading: Int

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = (subviews.count + leading + columns - 1) / columns
        return CGSize(width: CGFloat(columns) * side + CGFloat(columns - 1) * spacing,
                      height: CGFloat(rows) * side + CGFloat(max(0, rows - 1)) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + CGFloat((index + leading) % columns) * (side + spacing),
                                     y: bounds.minY + CGFloat((index + leading) / columns) * (side + spacing)),
                          anchor: .topLeading,
                          proposal: ProposedViewSize(width: side, height: side))
        }
    }
}

private struct GalleryThumbnailFramesKey: PreferenceKey {
    static var defaultValue: [URL: CGRect] { [:] }

    static func reduce(value: inout [URL: CGRect], nextValue: () -> [URL: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}
