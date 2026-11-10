import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct PhoneHomeView: View {
    @ObservedObject var photoInbox: WatchPhotoInbox

    @AppStorage("phoneGalleryColumnCount") private var storedColumnCount = 5
    @State private var previewCache = PhoneGalleryPreviewCache()
    @State private var zoom = PhoneGalleryZoomController()
    @State private var imageLayout = GalleryImageLayout()
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme
    @State private var galleryHeaderBottom: CGFloat = 0
    // The header's material fade extends 40 pt below its bottom edge.
    private var galleryScrollTopInset: CGFloat { galleryHeaderBottom + 40 }
    @GestureState private var isPinching = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var selectedDrawing: URL?
    @State private var navigationPath: [URL] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var importingProject = false
    @State private var importingPhoto = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var preparingPhoto = false
    @State private var showingInboxError = false
    @State private var projectMessage: String?
    @State private var watchDestination: PaintDeepLink?
    private var columnOptions: [Int] { PhoneGalleryZoomController.columnOptions }
    private var columnCount: Int { columnOptions.contains(storedColumnCount) ? storedColumnCount : 5 }

    /// Current gallery values for the zoom controller's entry points.
    private var zoomContext: PhoneGalleryZoomContext {
        PhoneGalleryZoomContext(
            images: photoInbox.images, columnCount: columnCount, imageLayout: imageLayout,
            previewCache: previewCache, displayScale: displayScale, colorScheme: colorScheme,
            reduceMotion: reduceMotion, topInset: galleryScrollTopInset,
            setColumnCount: { storedColumnCount = $0 })
    }

    var body: some View {
        GeometryReader { container in
            let divisionX = bookDivisionX(in: container)
            let showsBook = divisionX != nil
            let showsDrawing = showsBook && selectedDrawing != nil
            // Keep both panes in one stable container while the gallery width
            // changes. The detail pane slides independently from the right edge.
            ZStack(alignment: .leading) {
                NavigationStack(path: $navigationPath) {
                    galleryViewport(showsBook: showsBook)
            // Artwork may extend beneath every system safe area; the header
            // keeps its own safe-area placement and material backdrop.
            .ignoresSafeArea(.container, edges: .all)
            .onChange(of: selectedDrawing != nil) { _, _ in
                resetGalleryZoom()
            }
            .navigationDestination(for: URL.self) { url in
                PhoneDrawingView(url: url, inbox: photoInbox)
            }
            .onReceive(photoInbox.$images) { images in
                // A sync can replace PNG contents without changing its URL.
                if let selectedDrawing, !images.contains(selectedDrawing) {
                    self.selectedDrawing = nil
                }
                imageLayout = GalleryImageLayout(images: images)
                previewCache.invalidate()
                previewCache = PhoneGalleryPreviewCache()
                if zoom.pinchTarget != nil, images != zoom.zoomSnapshot { resetGalleryZoom() }
                previewCache.preparationPaused = zoom.pinchTarget != nil
            }
            .onDisappear { resetGalleryZoom() }
            .navigationTitle("Watch Gallery")
            .toolbar(.hidden, for: .navigationBar)
            // Keep artwork beneath the status area and header. An inset
            // reserves a separate top region and shifts the gallery viewport.
            .overlay(alignment: .top) {
                PhoneGalleryHeader(
                    importPhoto: { importingPhoto = true },
                    importProject: { importingProject = true },
                    synchronize: { photoInbox.synchronize() },
                    isPreparingPhoto: preparingPhoto)
                    .padding(.top, container.safeAreaInsets.top)
                    .background {
                        // The header's bottom edge in window space, which includes
                        // the status bar; the gallery viewport starts at the window top.
                        GeometryReader { header in
                            Color.clear.preference(key: PhoneGalleryHeaderHeightKey.self,
                                                   value: header.frame(in: .global).maxY)
                        }
                    }
            }
            .onPreferenceChange(PhoneGalleryHeaderHeightKey.self) { bottom in
                if galleryHeaderBottom != bottom { galleryHeaderBottom = bottom }
            }
            .refreshable { photoInbox.synchronize() }
            .fileImporter(isPresented: $importingProject, allowedContentTypes: [.paintAnytimeProject]) { result in
                switch result {
                case .success(let url): importProject(url)
                case .failure(let error): projectMessage = error.localizedDescription
                }
            }
            .photosPicker(isPresented: $importingPhoto, selection: $pickedPhoto, matching: .images)
            .task(id: pickedPhoto) { await importPickedPhoto() }
            .alert("Project", isPresented: Binding(get: { projectMessage != nil }, set: { if !$0 { projectMessage = nil } })) {
                Button("OK") { projectMessage = nil }
            } message: { Text(projectMessage ?? "") }
            // Alert bindings only update local presentation state. Clear the model
            // from onChange, outside SwiftUI's presentation binding update.
            .onChange(of: photoInbox.errorMessage, initial: true) { _, error in
                showingInboxError = error != nil
            }
            .onChange(of: showingInboxError) { _, presented in
                if !presented { photoInbox.clearError() }
            }
            .alert("Could not complete action", isPresented: $showingInboxError) {
                if photoInbox.photoPermissionRequiresSettings {
                    Button("Open Settings", action: openSettings)
                }
                Button("OK", role: .cancel) { showingInboxError = false }
            } message: { Text(photoInbox.errorMessage ?? "") }
                }
                .frame(width: showsDrawing ? (divisionX ?? container.size.width) : container.size.width)
                .ignoresSafeArea(.container, edges: .vertical)
                .clipped()
                if let divisionX, let url = selectedDrawing {
                    NavigationStack {
                        PhoneDrawingView(url: url, inbox: photoInbox, closeDrawing: closeSelectedDrawing)
                        .id(url)
                    }
                    .frame(width: container.size.width - divisionX)
                    .ignoresSafeArea(.container, edges: .bottom)
                    .clipped()
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color(uiColor: .separator))
                            .frame(width: 1 / displayScale)
                            .allowsHitTesting(false)
                    }
                    .offset(x: divisionX)
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing))
                    .zIndex(1)
                }
            }
            .frame(width: container.size.width, height: container.size.height, alignment: .leading)
            .clipped()
            .onChange(of: showsBook) { _, expanded in
                moveSelection(toBook: expanded)
            }
            .onChange(of: container.size) { _, _ in
                resetGalleryZoom()
            }
        }
        // The clipped panes must include the status-bar region as well as the
        // home-indicator region; otherwise their top edge leaves a blank strip.
        .ignoresSafeArea(.container, edges: .all)
        .onOpenURL(perform: openURL)
        .accessibilityHidden(watchDestination != nil)
        .overlay {
            if let watchDestination {
                PhoneWatchDestinationView(destination: watchDestination) {
                    self.watchDestination = nil
                }
            }
        }
    }

    /// The scrolling grid, its zoom overlay and the gestures that drive it.
    /// Kept in this view because `isPinching` and the scroll proxy live here.
    private func galleryViewport(showsBook: Bool) -> some View {
            GeometryReader { geometry in
                let width = geometry.size.width
                let height = geometry.size.height
                ScrollViewReader { scrollProxy in
                ZStack {
                ScrollView {
                    if photoInbox.images.isEmpty {
                        PhoneGalleryEmptyState { photoInbox.synchronize() }
                    } else {
                        PhoneGalleryGrid(
                            images: photoInbox.images, columnCount: columnCount,
                            leadingSlots: zoom.leadingSlots, width: width,
                            previewCache: previewCache, imageLayout: imageLayout,
                            isZooming: zoom.pinchTarget != nil,
                            pendingZoomTarget: zoom.pendingZoomTarget) { url in
                            openDrawing(url, besideGallery: showsBook)
                        }
                    }
                }
                // Rest the grid below the header and its blur fade, so the first
                // row is never covered by the title, buttons or material.
                // Tile coordinates remain relative to the unpadded grid.
                .contentMargins(.top, galleryScrollTopInset, for: .scrollContent)
                // While Canvas is visible it owns both scale and translation.
                // Raw one-finger movement below pans it immediately; the hidden
                // native grid must not scroll in a different coordinate system.
                .scrollDisabled(zoom.pinchTarget != nil || zoom.hasTwoFingerContact || isPinching)
                // Let scrolling artwork remain visible through the header material.
                .scrollClipDisabled()
                }
                .overlay(alignment: .topLeading) {
                    if zoom.pinchTarget != nil {
                        PhoneGalleryZoomOverlay(
                            presentation: zoom.zoomPresentation, slots: zoom.zoomSlots,
                            previews: zoom.zoomPreviews,
                            sideBackdrops: zoom.zoomSideBackdrops, sideBackdropFrame: zoom.zoomSideBackdropFrame,
                            viewportInsets: geometry.safeAreaInsets)
                    }
                }
                .highPriorityGesture(
                    MagnifyGesture(minimumScaleDelta: 0)
                        .updating($isPinching) { _, active, _ in active = true }
                        .onChanged { value in
                            zoom.magnifyChanged(startAnchor: value.startAnchor, magnification: value.magnification,
                                                width: width, viewportHeight: height, context: zoomContext)
                        }
                        .onEnded { value in
                            zoom.magnifyEnded(startAnchor: value.startAnchor, magnification: value.magnification,
                                              width: width, viewportHeight: height, context: zoomContext)
                        }
                )
                .onChange(of: isPinching) { _, active in
                    guard !active else { return }
                    zoom.pinchEnded(width: width, viewportHeight: height,
                                    isPinching: { isPinching }, context: zoomContext)
                }
                .overlay {
                    PhoneGalleryTouchOverlay(onMovement: { positions in
                        zoom.touchesMoved(positions, width: width, viewportHeight: height, context: zoomContext)
                    }) { positions in
                        zoom.touchContactsChanged(positions, width: width, viewportHeight: height,
                                                  isPinching: { isPinching }, context: zoomContext)
                    }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                #if DEBUG
                .overlay(alignment: .topTrailing) {
                    if PhoneGalleryDebug.showsDiagnostics {
                    PhoneGalleryFPSOverlay()
                        .frame(width: 140, height: 48)
                        .padding(8)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if PhoneGalleryDebug.showsDiagnostics {
                    PhoneGalleryGeometryDebugOverlay {
                        zoom.debugOverlayText(width: width, isPinching: isPinching)
                    }
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 6))
                        .padding(8)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
                .task(id: zoom.gridFrame.minY) { await zoom.settleDebugScroll() }
                #endif
                .coordinateSpace(name: "phoneGalleryViewport")
                .task(id: zoom.zoomSessionID) {
                    guard let sessionID = zoom.zoomSessionID else { return }
                    await zoom.prepareZoomSideBackdrop(width: width, viewportHeight: height, sessionID: sessionID)
                }
                .task(id: zoom.zoomSessionID) {
                    guard let sessionID = zoom.zoomSessionID else { return }
                    await zoom.loadMissingPreviews(sessionID: sessionID)
                }
                .task(id: zoom.pendingZoomColumns) {
                    await zoom.restorePendingPosition(viewportHeight: height) { target, anchor in
                        scrollProxy.scrollTo(target, anchor: anchor)
                    }
                }
                .onPreferenceChange(PhoneGalleryMeasuredTilesKey.self) { frames in
                    zoom.updateMeasuredTiles(frames)
                }
                .onPreferenceChange(PhoneGalleryTargetFrameKey.self) { layout in
                    zoom.pendingZoomMeasuredFrame = layout
                }
                .onPreferenceChange(PhoneGalleryFrameKey.self) { layout in
                    zoom.updateGridLayout(layout, isPinching: isPinching)
                }
                }
            }
    }

    private func bookDivisionX(in geometry: GeometryProxy) -> CGFloat? {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return nil }
        if #available(iOS 27.1, *) {
            // The active division remains authoritative when partially folded.
            let divisions = geometry.reservedRegions(kind: .division)
            if let fold = divisions.first(where: {
                $0.isActive && $0.frame.height > $0.frame.width
            }) {
                let middle = fold.frame.midX
                if middle > 0, middle < geometry.size.width { return middle }
            }
            // A horizontal hinge is not the requested book arrangement.
            if divisions.contains(where: { $0.isActive }) { return nil }
        }
        guard horizontalSizeClass == .regular, verticalSizeClass == .regular,
              geometry.size.width > geometry.size.height else { return nil }
        return geometry.size.width / 2
    }

    private var drawingPresentationAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.18) : .smooth(duration: 0.38)
    }

    private func resetGalleryZoom() {
        zoom.resetGalleryZoom(context: zoomContext)
    }

    private func openDrawing(_ url: URL, besideGallery: Bool) {
        // A recognized pinch owns the touch sequence, including release events.
        // A single route also prevents multiple tiles from opening together.
        guard !isPinching, !zoom.settlingZoom, Date() >= zoom.suppressOpeningUntil,
              navigationPath.isEmpty, photoInbox.images.contains(url) else { return }
        if besideGallery {
            withAnimation(drawingPresentationAnimation) {
                selectedDrawing = url
            }
        } else {
            navigationPath = [url]
        }
    }

    private func closeSelectedDrawing() {
        withAnimation(drawingPresentationAnimation) {
            selectedDrawing = nil
        }
    }

    private func moveSelection(toBook expanded: Bool) {
        resetGalleryZoom()
        // Moving an existing selection between layouts is not a new
        // presentation. Suppress inherited navigation animations too.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if expanded {
                selectedDrawing = navigationPath.last
                navigationPath = []
            } else {
                navigationPath = selectedDrawing.map { [$0] } ?? []
                selectedDrawing = nil
            }
        }
    }

    private func openURL(_ url: URL) {
        if url.isFileURL {
            importProject(url)
            return
        }
        guard let destination = PaintDeepLink(url: url), destination != .app else { return }
        importingProject = false
        projectMessage = nil
        showingInboxError = false
        navigationPath = []
        selectedDrawing = nil
        resetGalleryZoom()
        watchDestination = destination == .gallery ? nil : destination
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    private func importPickedPhoto() async {
        guard let item = pickedPhoto else { return }
        preparingPhoto = true
        defer {
            preparingPhoto = false
            pickedPhoto = nil
        }
        do {
            let message = try await PhonePhotoImport.importPhoto(item)
            // Shows the photo the import just added to the phone gallery.
            photoInbox.refresh()
            projectMessage = message
        } catch {
            guard !Task.isCancelled else { return }
            projectMessage = error.localizedDescription
        }
    }

    private func importProject(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let project = try PaintProject.read(url)
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(PaintProject.fileExtension)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try project.write(to: temporary)
            try IncomingDrawingStore().receive(temporary, name: "Imported_" + UUID().uuidString + "." + PaintProject.fileExtension)
            photoInbox.refresh()
            projectMessage = String(localized: "Project imported. Open it in the gallery and tap Send to Apple Watch to continue editing on your watch.")
        } catch { projectMessage = error.localizedDescription }
    }
}
