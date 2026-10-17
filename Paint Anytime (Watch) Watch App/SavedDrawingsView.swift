import SwiftUI
import WatchKit

struct SavedDrawingsView: View {
    @Environment(\.tutorialHintReservedHeight) private var tutorialHintReservedHeight
    @ObservedObject var tutorial = TutorialSession.inactive
    var galleryFolder: URL? = nil
    var initialArtworkFilename: String? = nil
    var initialBitmap: GalleryBitmap? = nil
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    var onClose: () -> Void
    var onEditDrawing: (CanvasDocument) -> Void
    @StateObject private var controller = GalleryController()
    private var drawings: [CanvasExport] { controller.drawings }
    @State private var zoomLevel = 0
    @State private var crownPosition = 0.0
    @State private var selectedDrawing: CanvasExport?
    @State private var focusedDrawing: CanvasExport?
    @State private var pendingDeletion: CanvasExport?
    @State private var confirmedDeletion: CanvasExport?
    @State private var showsFullscreen = false
    @State private var morphState = GalleryMorphState()
    @State private var pageVisibility: [URL: Double] = [:]
    @State private var galleryScrollTarget: URL?
    @State private var thumbnailFrames: [URL: CGRect] = [:]
    @State private var transitionRequest: GalleryTransitionDirection?
    @State private var imageTransition: GalleryImageTransition?
    @State private var transitionExpanded = false
    @State private var transitionBitmap: GalleryBitmap?
    @FocusState private var crownFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    private var columnCount: Int { zoomLevel == 0 ? 5 : 3 }
    private var isTransitioning: Bool { transitionRequest != nil || imageTransition != nil }

    var body: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = zoomLevel == 0 ? 2 : 4
            let width = (geometry.size.width - spacing * CGFloat(columnCount - 1) - 6) / CGFloat(columnCount)
            let navigationHeight: CGFloat = max(60, geometry.safeAreaInsets.top + 38)
            let thumbnailPixels = Int(ceil(width * displayScale / 32)) * 32
            let transitionImageRequest = transitionRequest == nil ? nil : selectedDrawing.map {
                GalleryImageRequest(url: $0.url, shortSidePixels: thumbnailPixels, displayScale: displayScale)
            }
            ZStack(alignment: .topLeading) {
                Color.black
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        galleryGrid(spacing: spacing, width: width, thumbnailPixels: thumbnailPixels)
                            .reportLegacyScrollPosition()
                    }
                    // Let photos scroll behind the tutorial card while allowing
                    // the final row to scroll fully above it.
                    .contentMargins(.bottom, tutorialHintReservedHeight, for: .scrollContent)
                    .contentMargins(.top, navigationHeight + 4, for: .scrollContent)
                    .scrollIndicators(.hidden)
                    // Observe native scrolling without competing with its swipe gesture.
                    .onTutorialScrollActivity { tutorial.activity() }
                    .allowsHitTesting(!showsFullscreen && !isTransitioning && tutorial.allowsGalleryZoom)
                    .accessibilityHidden(showsFullscreen)
                    .onChange(of: zoomLevel) { previousLevel, level in
                        if previousLevel != 2, level < 2, let drawing = focusedDrawing {
                            withAnimation(.smooth(duration: 0.25)) {
                                scrollProxy.scrollTo(drawing.id, anchor: .center)
                            }
                        }
                    }
                    .onChange(of: galleryScrollTarget) { _, id in
                        guard showsFullscreen, let id else { return }
                        withoutAnimation { scrollProxy.scrollTo(id, anchor: .center) }
                    }
                    .onChange(of: transitionRequest) { _, request in
                        guard request != nil, let drawing = selectedDrawing else { return }
                        // Lay out an offscreen destination before revealing the grid.
                        if !hasVisibleTile(for: drawing, size: geometry.size, topInset: navigationHeight) {
                            withoutAnimation { scrollProxy.scrollTo(drawing.id, anchor: .center) }
                        }
                        prepareImageTransition(size: geometry.size, topInset: navigationHeight)
                    }
                }

                Rectangle()
                    .fill(.ultraThinMaterial)
                    .frame(height: navigationHeight + 24)
                    .mask {
                        LinearGradient(stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.5),
                            .init(color: .black.opacity(0.75), location: 0.7),
                            .init(color: .clear, location: 1)
                        ], startPoint: .top, endPoint: .bottom)
                    }
                    .allowsHitTesting(false)

                if showsFullscreen {
                    Color.black
                        .opacity(imageTransition != nil ? (transitionExpanded ? 1 : 0)
                                 : (transitionRequest == .opening ? 0 : 1))
                        .allowsHitTesting(false)
                    // Prepare the pager before the transition; image loading stays suspended.
                    // This avoids constructing the page controller at the animation handoff.
                    fullscreenGallery(size: geometry.size, canvasOriginX: geometry.frame(in: .global).minX, canvasOriginY: geometry.frame(in: .global).minY,
                                      thumbnailPixels: thumbnailPixels)
                        .opacity(imageTransition == nil && transitionRequest != .opening ? 1 : 0)
                        .allowsHitTesting(!isTransitioning && tutorial.allowsGalleryPaging)
                        .accessibilityHidden(isTransitioning)
                }

                if let imageTransition {
                    let frame = transitionExpanded ? imageTransition.fullFrame : imageTransition.tileFrame
                    Image(decorative: imageTransition.image, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: frame.width, height: frame.height)
                        .clipped()
                        .position(x: frame.midX, y: frame.midY)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .task(id: imageTransition.id) {
                            // Give the initial image rectangle its own layout pass.
                            await Task.yield()
                            guard !Task.isCancelled else { return }
                            animateImageTransition(imageTransition)
                        }
                }
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
                }
            }
            .coordinateSpace(name: "drawingGallery")
            .task(id: transitionImageRequest) {
                guard let request = transitionImageRequest else { return }
                let bitmap = await GalleryImageCache.shared.load(request)
                guard !Task.isCancelled, selectedDrawing?.url == request.url else { return }
                guard let bitmap else {
                    returnToGrid()
                    controller.errorMessage = L10n.text("Could not open the image.")
                    return
                }
                transitionBitmap = bitmap
                prepareImageTransition(size: geometry.size, topInset: navigationHeight)
            }
            .onPreferenceChange(GalleryThumbnailFramesKey.self) { frames in
                thumbnailFrames = frames
                prepareImageTransition(size: geometry.size, topInset: navigationHeight)
            }
        }
        .ignoresSafeArea(.container, edges: tutorial.isActive ? [] : .all)
        .toolbar {
            if showsFullscreen && !isTransitioning && !tutorial.isActive {
                ToolbarItemGroup(placement: .bottomBar) {
                    GalleryMorphToolbarButton(state: morphState)
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
                    .disabled(isTransitioning)
                    .watchToolbarButtonStyle(diameter: GalleryMorphState.toolbarDiameter, hidesNativeChrome: true)
                    .overlay {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: GalleryMorphState.buttonDiameter,
                                   height: GalleryMorphState.buttonDiameter)
                            .modifier(CanvasMorphGlass())
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    .accessibilityLabel(L10n.text("Back"))
                    .onGeometryChange(for: CGRect.self) { geometry in
                        geometry.frame(in: .global)
                    } action: { frame in
                        if morphState.backButtonFrame != frame { morphState.backButtonFrame = frame }
                    }
                }
            }
        }

        .overlay(alignment: .bottom) {
            if tutorial.isActive && showsFullscreen && !isTransitioning,
               tutorial.allowsGalleryDelete, let selectedDrawing {
                HStack {
                    Button(role: .destructive) {
                        crownFocused = false
                        tutorial.pauseReminders()
                        pendingDeletion = selectedDrawing
                    } label: {
                        Image(systemName: "trash")
                            .tutorialHint(tutorial, steps: [.deleteDrawing])
                    }
                    // This button overlays the pager rather than living in a
                    // native toolbar. Give its label a complete touch target.
                    .buttonStyle(TutorialOverlayButtonStyle())
                    .accessibilityLabel(L10n.text("Delete drawing"))
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.bottom, tutorialHintReservedHeight)
            }
        }
        .focusable(pendingDeletion == nil && tutorial.allowsGalleryZoom)
        .focused($crownFocused)
        .digitalCrownRotation(detent: Binding(get: { crownPosition }, set: { value in
            guard tutorial.allowsGalleryZoom else { return }
            tutorial.activity()
            crownPosition = value
        }), from: 0, through: 2, by: 1,
                              sensitivity: .low, isContinuous: false,
                              isHapticFeedbackEnabled: false,
                              onChange: { [step = tutorial.step] event in
                tutorial.usedCrown(in: step, velocity: event.velocity)
            })
        .onChange(of: crownPosition) { _, position in
            guard pendingDeletion == nil, !isTransitioning, tutorial.allowsGalleryZoom else { return }
            let next = min(2, max(0, Int(position.rounded())))
            guard next != zoomLevel else { return }
            if next == 2 {
                if let drawing = focusedDrawing ?? drawings.first { open(drawing) }
                else { crownPosition = Double(zoomLevel) }
            } else { setZoom(next) }
        }
        .fullScreenCover(item: $pendingDeletion, onDismiss: {
            tutorial.resumeReminders()
            crownFocused = tutorial.allowsGalleryZoom
            if let drawing = confirmedDeletion {
                confirmedDeletion = nil
                deleteDrawing(drawing)
            }
        }) { drawing in
            DestructiveConfirmationView(title: L10n.text("Delete the image?"), confirmTitle: L10n.text("Delete")) {
                pendingDeletion = nil
            } onConfirm: {
                confirmedDeletion = drawing
                pendingDeletion = nil
            }
        }
        .alert(L10n.text("Error"), isPresented: Binding(
            get: { controller.errorMessage != nil }, set: { if !$0 { controller.errorMessage = nil } }
        )) { Button(L10n.text("OK"), role: .cancel) { controller.errorMessage = nil } }
        message: { Text(controller.errorMessage ?? "") }
         .onAppear {
            crownFocused = tutorial.allowsGalleryZoom
            controller.reload(in: galleryFolder)
            if let filename = initialArtworkFilename,
               let drawing = drawings.first(where: { $0.url.lastPathComponent == filename }) {
                // Direct launches open at 1:1 without a transition from a grid tile.
                transitionBitmap = initialBitmap?.url == drawing.url ? initialBitmap : nil
                focusedDrawing = drawing
                selectedDrawing = drawing
                zoomLevel = 2
                crownPosition = 2
                showsFullscreen = true
                galleryScrollTarget = drawing.id
            }
        }
        .onChange(of: tutorial.showsInstruction) { _, showing in
            crownFocused = !showing && tutorial.allowsGalleryZoom && pendingDeletion == nil
            if !showing && showsFullscreen && !isTransitioning { tutorial.record(.galleryFullscreen) }
        }
        .onChange(of: showsFullscreen) { _, fullscreen in
            morphState.isExpanded = false
            if !fullscreen { pageVisibility = [:] }
            tutorial.galleryIsFullscreen = fullscreen
        }
        .onChange(of: isTransitioning) { _, transitioning in
            if transitioning { morphState.isExpanded = false }
            if !transitioning && showsFullscreen { tutorial.record(.galleryFullscreen) }
        }
    }

    @ViewBuilder
    private func galleryGrid(spacing: CGFloat, width: CGFloat, thumbnailPixels: Int) -> some View {
        if let errorMessage = controller.errorMessage {
            Text(errorMessage).foregroundStyle(.red).padding()
        } else if drawings.isEmpty {
            ContentUnavailableView(L10n.text("No drawings"), systemImage: "photo.on.rectangle")
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnCount), spacing: spacing) {
                ForEach(drawings) { drawing in
                    Button {
                        tutorial.activity()
                        focusedDrawing = drawing
                        if zoomLevel == 0 { setZoom(1) }
                        else { open(drawing) }
                    } label: {
                        GalleryThumbnailView(request: GalleryImageRequest(
                            url: drawing.url, shortSidePixels: thumbnailPixels, displayScale: displayScale),
                            loadsImage: imageTransition == nil, isFavorite: drawing.isFavorite)
                            .frame(width: width, height: width)
                            .clipped()
                            .opacity(hidesThumbnail(drawing) ? 0 : 1)
                            .background {
                                GeometryReader { tileGeometry in
                                    Color.clear.preference(key: GalleryThumbnailFramesKey.self,
                                        value: [drawing.id: tileGeometry.frame(in: .named("drawingGallery"))])
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(!tutorial.allowsGalleryZoom)
                    .accessibilityLabel(L10n.text("Open drawing"))
                    .id(drawing.id)
                }
            }
            .padding(.horizontal, 3)
            .padding(.bottom, 12)
        }
    }

    private func goBack() {
        guard tutorial.allowsGalleryBack else { return }
        tutorial.activity()
        guard !isTransitioning else { return }
        if zoomLevel == 0 { onClose() }
        else { setZoom(zoomLevel - 1) }
    }

    private func setZoom(_ level: Int) {
        guard !isTransitioning else { return }
        if showsFullscreen && level < 2 {
            transitionBitmap = nil
            transitionRequest = .closing
        } else {
            withAnimation(.smooth(duration: 0.25)) { zoomLevel = level }
            crownPosition = Double(level)
        }
        WKInterfaceDevice.current().play(.click)
    }

    private func open(_ drawing: CanvasExport) {
        guard !isTransitioning else { return }
        galleryScrollTarget = nil
        transitionBitmap = nil
        focusedDrawing = drawing
        selectedDrawing = drawing
        zoomLevel = 2
        crownPosition = 2
        showsFullscreen = true
        transitionRequest = .opening
        WKInterfaceDevice.current().play(.click)
    }

    private func hidesThumbnail(_ drawing: CanvasExport) -> Bool {
        selectedDrawing?.id == drawing.id && (imageTransition != nil ||
            (showsFullscreen && transitionRequest != .opening))
    }

    private func hasVisibleTile(for drawing: CanvasExport, size: CGSize, topInset: CGFloat) -> Bool {
        guard let frame = thumbnailFrames[drawing.id], !frame.isEmpty else { return false }
        let expectedWidth = (size.width - 14) / 3
        return abs(frame.width - expectedWidth) < 1 && frame.minY >= topInset && frame.maxY <= size.height
    }

    private func prepareImageTransition(size: CGSize, topInset: CGFloat) {
        guard imageTransition == nil, let direction = transitionRequest,
              let drawing = selectedDrawing,
              let bitmap = transitionBitmap, bitmap.url == drawing.url,
              hasVisibleTile(for: drawing, size: size, topInset: topInset),
              let tileFrame = thumbnailFrames[drawing.id] else { return }
        let originalSize = bitmap.originalSize
        let fullFrame = CGRect(x: (size.width - originalSize.width) / 2,
                               y: (size.height - originalSize.height) / 2,
                               width: originalSize.width, height: originalSize.height)
        withoutAnimation {
            transitionExpanded = direction == .closing
            imageTransition = GalleryImageTransition(image: bitmap.image, tileFrame: tileFrame,
                                                     fullFrame: fullFrame, direction: direction)
        }
    }

    private func animateImageTransition(_ transition: GalleryImageTransition) {
        guard imageTransition?.id == transition.id else { return }
        // A fixed-duration curve has no settling tail after the image reaches its destination.
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.32), completionCriteria: .logicallyComplete) {
            transitionExpanded = transition.direction == .opening
        } completion: {
            guard imageTransition?.id == transition.id else { return }
            withoutAnimation {
                if transition.direction == .closing { returnToGrid() }
                else {
                    imageTransition = nil
                    transitionRequest = nil
                    crownPosition = 2
                }
            }
        }
    }

    private func returnToGrid() {
        showsFullscreen = false
        selectedDrawing = nil
        transitionBitmap = nil
        imageTransition = nil
        transitionRequest = nil
        zoomLevel = 1
        crownPosition = 1
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
                                      isNearby: abs(index - selectedIndex) <= 1 && !isTransitioning,
                                      loadsOriginal: abs(index - selectedIndex) <= 1 && !isTransitioning,
                                      fallback: transitionBitmap?.url == drawing.url ? transitionBitmap : nil,
                                      respectsSafeArea: tutorial.isActive)
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
        guard let document = controller.loadDocument(for: drawing) else { return }
        onEditDrawing(document)
    }

}

private enum GalleryTransitionDirection {
    case opening, closing
}

private struct GalleryImageTransition: Identifiable {
    let id = UUID()
    let image: CGImage
    let tileFrame: CGRect
    let fullFrame: CGRect
    let direction: GalleryTransitionDirection
}

private struct GalleryThumbnailFramesKey: PreferenceKey {
    static var defaultValue: [URL: CGRect] { [:] }

    static func reduce(value: inout [URL: CGRect], nextValue: () -> [URL: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}
