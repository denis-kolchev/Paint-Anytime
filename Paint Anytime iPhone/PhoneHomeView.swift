import SwiftUI
import UniformTypeIdentifiers
import ImageIO
import WatchConnectivity

extension UTType {
    static let paintAnytimeProject = UTType(exportedAs: PaintProject.typeIdentifier)
}

@MainActor
struct PhoneHomeView: View {
    @ObservedObject var photoInbox: WatchPhotoInbox

    @AppStorage("phoneGalleryColumnCount") private var storedColumnCount = 5
    @State private var previewCache = PhoneGalleryPreviewCache()
    @State private var zoomPresentation = PhoneGalleryZoomPresentation()
    @State private var zoomAnchorIndex: Int?
    @State private var zoomSnapshot: [URL] = []
    @State private var zoomSessionID: UUID?
    @State private var zoomMissingPreviews: [URL] = []
    @State private var measuredGridColumns = 0
    @State private var zoomSlots: [PhoneGalleryZoomSlot] = []
    @State private var zoomPreviews: [URL: UIImage] = [:]
    @State private var zoomPreviewSize = 640
    @State private var zoomSideBackdrops: [Int: UIImage] = [:]
    @State private var zoomSideBackdropFrame: CGRect = .zero
    @State private var imageLayout = PhoneGalleryImageLayout()
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme
    @State private var zoomBaseColumns = 5
    @State private var zoomGestureBaseSide: CGFloat?
    @State private var zoomBaseLeadingSlots = 0
    @State private var zoomBaseFrame: CGRect = .zero
    @State private var pendingZoomViewportTop: CGFloat?
    @State private var pendingZoomMeasuredFrame: PhoneGalleryLayout?
    @State private var zoomPanLastY: CGFloat?
    @State private var zoomSettledColumns: Int?
    @State private var zoomAnchorTops: [Int: CGFloat] = [:]
    @State private var zoomPreparedPanRange: CGFloat = 0
    // Leading slots change row alignment without changing document order.
    @State private var leadingSlots = 0
    @State private var zoomLeadingSlots: [Int: Int] = [:]
    @State private var settlingZoom = false
    @State private var zoomSettlementID: UUID?
    @State private var gridFrame: CGRect = .zero
    @State private var pinchTarget: URL?
    @State private var pinchTargetFractionY: CGFloat = 0.5
    @State private var pinchViewportY: CGFloat = 0
    @State private var pendingZoomAnchor: UnitPoint?
    @State private var pendingZoomTarget: URL?
    @State private var pendingZoomColumns: Int?
    @State private var hasTwoFingerContact = false
    @GestureState private var isPinching = false
    #if DEBUG
    @State private var debugScrollMoving = false
    @State private var zoomDiagnostics = PhoneGalleryZoomDiagnostics()

    private var debugInteraction: String {
        if pendingZoomColumns != nil { return "Zoom: restoring position" }
        if settlingZoom { return "Zoom: settling" }
        if isPinching { return "Gesture: pinch" }
        if hasTwoFingerContact { return "Zoom: two fingers" }
        if pinchTarget != nil { return "Zoom: finishing" }
        if debugScrollMoving { return "Scroll: moving" }
        return "Gesture: idle"
    }
    #endif
    @State private var navigationPath: [URL] = []
    @State private var suppressOpeningUntil = Date.distantPast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var importingProject = false
    @State private var showingInboxError = false
    @State private var projectMessage: String?
    private let columnOptions = [1, 3, 5]
    private let gallerySpacing: CGFloat = 2
    private var columnCount: Int { columnOptions.contains(storedColumnCount) ? storedColumnCount : 5 }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            GeometryReader { geometry in
                ScrollViewReader { scrollProxy in
                ZStack {
                ScrollView {
                    if photoInbox.images.isEmpty {
                        ContentUnavailableView {
                            Label("Your Watch Gallery", systemImage: "applewatch")
                        } description: {
                            Text("Save a drawing in Paint Anytime on your Apple Watch. Open the watch app to sync your existing drawings. Transfers may take a few minutes.")
                        } actions: {
                            Button("Sync with Apple Watch") { photoInbox.synchronize() }
                        }
                        .padding(.top, 80)
                        Text("Deleting a drawing removes it from both Apple Watch and iPhone. Save a copy to Photos, Files, or another app before deleting.")
                            .font(.footnote).foregroundStyle(.secondary).padding()
                    } else {
                        let spacing = gallerySpacing
                        let tileSize = max(1, (geometry.size.width - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount))
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnCount), spacing: spacing) {
                            ForEach(0..<leadingSlots, id: \.self) { _ in
                                Color(uiColor: .systemBackground).frame(height: tileSize).accessibilityHidden(true)
                            }
                            ForEach(photoInbox.images, id: \.self) { url in
                                Button {
                                    openDrawing(url)
                                } label: {
                                    PhoneGalleryZoomTile(source: url, destination: nil,
                                                         blend: 0, side: tileSize, cache: previewCache,
                                                         height: columnCount == 1 ? imageLayout.height(for: url, width: tileSize) : tileSize,
                                                         preparesOtherSizes: pinchTarget == nil)
                                }
                                .buttonStyle(.plain)
                                .id(url)
                                .background {
                                    if url == pendingZoomTarget {
                                        GeometryReader { tile in
                                            Color.clear.preference(key: PhoneGalleryTargetFrameKey.self,
                                                value: PhoneGalleryLayout(columns: columnCount,
                                                    frame: tile.frame(in: .named("phoneGalleryViewport"))))
                                        }
                                    }
                                }
                                .accessibilityLabel(Text(url.deletingPathExtension().lastPathComponent))
                            }
                            let trailingSlots = (columnCount - (leadingSlots + photoInbox.images.count) % columnCount) % columnCount
                            ForEach(0..<trailingSlots, id: \.self) { _ in
                                Color(uiColor: .systemBackground)
                                    .frame(height: tileSize)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                        // Keep the scroll layout and gesture host alive, but draw
                        // the zoom independently of LazyVGrid's source-row culling.
                        .opacity(pinchTarget == nil ? 1 : 0)
                        .background {
                            GeometryReader { grid in
                                Color.clear.preference(key: PhoneGalleryFrameKey.self,
                                    value: PhoneGalleryLayout(columns: columnCount,
                                        frame: grid.frame(in: .named("phoneGalleryViewport"))))
                            }
                        }

                    }
                }
                // While Canvas is visible it owns both scale and translation.
                // Raw one-finger movement below pans it immediately; the hidden
                // native grid must not scroll in a different coordinate system.
                .scrollDisabled(pinchTarget != nil || hasTwoFingerContact || isPinching)
                // Let scrolling artwork remain visible through the header material.
                .scrollClipDisabled()
                }
                .overlay(alignment: .topLeading) {
                            if pinchTarget != nil {
                                PhoneGalleryZoomOverlay(
                                    presentation: zoomPresentation, slots: zoomSlots,
                                    previews: zoomPreviews,
                                    sideBackdrops: zoomSideBackdrops, sideBackdropFrame: zoomSideBackdropFrame,
                                    viewportInsets: geometry.safeAreaInsets)
                            }
                        }
                .highPriorityGesture(
                    MagnifyGesture(minimumScaleDelta: 0)
                        .updating($isPinching) { _, active, _ in active = true }
                        .onChanged { value in
                            #if DEBUG
                            if zoomDiagnostics.startedAt == nil { zoomDiagnostics.begin() }
                            if zoomDiagnostics.recognizedMS == nil {
                                zoomDiagnostics.recognizedMS = zoomDiagnostics.elapsedMS()
                            }
                            #endif
                            if settlingZoom, pendingZoomColumns == nil {
                                interruptGalleryZoom(width: geometry.size.width)
                            }
                            guard pendingZoomColumns == nil else { return }
                            suppressOpeningUntil = .distantFuture
                            if pinchTarget == nil {
                                beginGalleryZoom(anchor: value.startAnchor, width: geometry.size.width,
                                                 viewportHeight: geometry.size.height)
                            }
                            updateGalleryZoom(value.magnification, width: geometry.size.width,
                                              viewportHeight: geometry.size.height)
                        }
                        .onEnded { value in
                            guard !settlingZoom else { return }
                            suppressOpeningUntil = Date().addingTimeInterval(0.3)
                            if pinchTarget == nil {
                                beginGalleryZoom(anchor: value.startAnchor, width: geometry.size.width,
                                                 viewportHeight: geometry.size.height)
                            }
                            updateGalleryZoom(value.magnification, width: geometry.size.width,
                                              viewportHeight: geometry.size.height)
                            finishGalleryZoom(width: geometry.size.width,
                                              viewportHeight: geometry.size.height)
                        }
                )
                .onChange(of: isPinching) { _, active in
                    guard !active else { return }
                    // onEnded must get a chance to start its settlement first.
                    DispatchQueue.main.async {
                        guard !isPinching, !settlingZoom else { return }
                        guard pinchTarget != nil else {
                            suppressOpeningUntil = Date().addingTimeInterval(0.3)
                            return
                        }
                        finishGalleryZoom(width: geometry.size.width,
                                          viewportHeight: geometry.size.height)
                    }
                }
                .overlay {
                    PhoneGalleryTouchOverlay(onMovement: { positions in
                        #if DEBUG
                        if positions.count >= 2, zoomDiagnostics.movementMS == nil {
                            zoomDiagnostics.movementMS = zoomDiagnostics.elapsedMS()
                        }
                        #endif
                        guard positions.count == 1, pinchTarget != nil else { return }
                        moveGalleryZoomPan(to: positions[0].y, width: geometry.size.width,
                                           viewportHeight: geometry.size.height)
                    }) { positions in
                        #if DEBUG
                        if positions.count >= 2, !hasTwoFingerContact { zoomDiagnostics.begin() }
                        #endif
                        if positions.count == 1, pinchTarget != nil {
                            beginGalleryZoomPan(at: positions[0].y)
                        } else {
                            zoomPanLastY = nil
                        }
                        if pendingZoomColumns != nil, positions.count >= 2 {
                            // Reuse the prepared overlay while the hidden grid is
                            // being restored. A second pinch must not rebuild from
                            // a grid frame that may still belong to the old layout.
                            pendingZoomColumns = nil
                            pendingZoomTarget = nil
                            pendingZoomAnchor = nil
                            pendingZoomViewportTop = nil
                            pendingZoomMeasuredFrame = nil
                            interruptGalleryZoom(width: geometry.size.width)
                        }
                        hasTwoFingerContact = positions.count >= 2
                        if positions.isEmpty, let columns = zoomSettledColumns {
                            commitGalleryZoom(columns: columns, width: geometry.size.width,
                                              viewportHeight: geometry.size.height)
                        }
                        if hasTwoFingerContact, settlingZoom, pendingZoomColumns == nil {
                            interruptGalleryZoom(width: geometry.size.width)
                        }
                        if hasTwoFingerContact {
                            guard !settlingZoom, pinchTarget == nil,
                                  geometry.size.width > 0, geometry.size.height > 0 else { return }
                            let center = positions.reduce(CGPoint.zero) {
                                CGPoint(x: $0.x + $1.x, y: $0.y + $1.y)
                            }
                            let count = CGFloat(positions.count)
                            suppressOpeningUntil = .distantFuture
                            beginGalleryZoom(
                                anchor: UnitPoint(x: center.x / count / geometry.size.width,
                                                  y: center.y / count / geometry.size.height),
                                width: geometry.size.width, viewportHeight: geometry.size.height)
                        } else {
                            // Give MagnifyGesture.onEnded priority if scale was
                            // recognized. Also finish two-finger taps with no zoom.
                            DispatchQueue.main.async {
                                guard !hasTwoFingerContact, !isPinching, !settlingZoom,
                                      pinchTarget != nil else { return }
                                if zoomPresentation.scale == 1,
                                   zoomPresentation.position == PhoneGalleryZoomPresentation.position(for: zoomBaseColumns),
                                   zoomPresentation.offsetY == 0, zoomPanLastY == nil {
                                    completeGalleryZoom()
                                    return
                                }
                                finishGalleryZoom(width: geometry.size.width,
                                                  viewportHeight: geometry.size.height)
                            }
                        }
                    }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                #if DEBUG
                .overlay(alignment: .topTrailing) {
                    PhoneGalleryFPSOverlay()
                        .frame(width: 140, height: 48)
                        .padding(8)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .overlay(alignment: .bottomTrailing) {
                    Text(verbatim: debugInteraction + "\n" + zoomDiagnostics.text)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 6))
                        .padding(8)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .task(id: gridFrame.minY) {
                    guard debugScrollMoving else { return }
                    do {
                        try await Task.sleep(for: .milliseconds(150))
                        guard !Task.isCancelled else { return }
                        debugScrollMoving = false
                    } catch { /* A newer scroll position restarts the idle delay. */ }
                }
                #endif
                .coordinateSpace(name: "phoneGalleryViewport")
                .task(id: zoomSessionID) {
                    guard let sessionID = zoomSessionID else { return }
                    await prepareZoomSideBackdrop(width: geometry.size.width,
                        viewportHeight: geometry.size.height, sessionID: sessionID)
                }
                .task(id: zoomSessionID) {
                    guard let sessionID = zoomSessionID else { return }
                    #if DEBUG
                    let loadingStarted = CACurrentMediaTime()
                    let diagnosticSession = zoomDiagnostics.session
                    #endif
                    let cache = previewCache
                    for url in zoomMissingPreviews {
                        guard !Task.isCancelled, zoomSessionID == sessionID else { return }
                        let image = await cache.load(url, maximumSize: 320)
                        guard !Task.isCancelled, zoomSessionID == sessionID else { return }
                        if let image { zoomPreviews[url] = image }
                    }
                    #if DEBUG
                    if zoomDiagnostics.session == diagnosticSession {
                        zoomDiagnostics.loadingMS = (CACurrentMediaTime() - loadingStarted) * 1000
                    }
                    #endif
                }
                .task(id: pendingZoomColumns) {
                    guard let columns = pendingZoomColumns,
                          let target = pendingZoomTarget,
                          let anchor = pendingZoomAnchor,
                          let viewportTop = pendingZoomViewportTop else { return }
                    let settlementID = zoomSettlementID
                    var attempts = 0
                    // Scroll only after layout has returned to the run loop.
                    // Lazy rows may need a second pass after materialization.
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .milliseconds(32)) }
                        catch { return }
                        guard !Task.isCancelled, zoomSettlementID == settlementID,
                              pendingZoomColumns == columns, pendingZoomTarget == target else { return }
                        guard measuredGridColumns == columns else { continue }
                        if let measured = pendingZoomMeasuredFrame, measured.columns == columns,
                           abs(measured.frame.minY - viewportTop) < 1 {
                            completeGalleryZoom()
                            return
                        }
                        // If exact alignment is unavailable (for example at a
                        // content edge), retain the focal photo rather than
                        // exposing an unconfirmed grid at its initial offset.
                        if attempts >= 4, let measured = pendingZoomMeasuredFrame,
                           measured.columns == columns,
                           measured.frame.maxY > 0, measured.frame.minY < geometry.size.height {
                            completeGalleryZoom()
                            return
                        }
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            scrollProxy.scrollTo(target, anchor: attempts < 4 ? anchor : .center)
                        }
                        attempts += 1
                    }
                }
                .onPreferenceChange(PhoneGalleryTargetFrameKey.self) { layout in
                    pendingZoomMeasuredFrame = layout
                }
                .onPreferenceChange(PhoneGalleryFrameKey.self) { layout in
                    guard layout.columns > 0 else { return }
                    #if DEBUG
                    // Observe movement without adding a competing drag recognizer.
                    // This includes inertial scrolling, not just finger dragging.
                    if gridFrame != .zero, gridFrame.minY != layout.frame.minY,
                       pinchTarget == nil, !isPinching, !settlingZoom {
                        debugScrollMoving = true
                    }
                    #endif
                    gridFrame = layout.frame
                    measuredGridColumns = layout.columns
                }
                }
            }
            // Measure the full screen width for both grid tiles and zoom geometry.
            .ignoresSafeArea(.container, edges: .horizontal)
            .navigationDestination(for: URL.self) { url in
                PhoneDrawingView(url: url, inbox: photoInbox)
            }
            .onReceive(photoInbox.$images) { images in
                // A sync can replace PNG contents without changing its URL.
                imageLayout = PhoneGalleryImageLayout(images: images)
                previewCache.invalidate()
                previewCache = PhoneGalleryPreviewCache()
                if pinchTarget != nil, images != zoomSnapshot { resetGalleryZoom() }
                previewCache.preparationPaused = pinchTarget != nil
            }
            .onDisappear { resetGalleryZoom() }
            .navigationTitle("Watch Gallery")
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                PhoneGalleryHeader(
                    importProject: { importingProject = true },
                    synchronize: { photoInbox.synchronize() })
            }
            .refreshable { photoInbox.synchronize() }
            .fileImporter(isPresented: $importingProject, allowedContentTypes: [.paintAnytimeProject]) { result in
                switch result {
                case .success(let url): importProject(url)
                case .failure(let error): projectMessage = error.localizedDescription
                }
            }
            .onOpenURL { importProject($0) }
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
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                Button("OK", role: .cancel) { showingInboxError = false }
            } message: { Text(photoInbox.errorMessage ?? "") }
        }
    }

    private func openDrawing(_ url: URL) {
        // A recognized pinch owns the touch sequence, including release events.
        // A single route also prevents multiple tiles from opening together.
        guard !isPinching, !settlingZoom, Date() >= suppressOpeningUntil,
              navigationPath.isEmpty, photoInbox.images.contains(url) else { return }
        navigationPath = [url]
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
            projectMessage = "Project imported. Open it in the gallery and tap Send to Apple Watch to continue editing on your watch."
        } catch { projectMessage = error.localizedDescription }
    }

    private func tileSide(columns: Int, width: CGFloat) -> CGFloat {
        max(1, (width - gallerySpacing * CGFloat(columns - 1)) / CGFloat(columns))
    }

    private func beginGalleryZoom(anchor viewportAnchor: UnitPoint, width: CGFloat,
                                  viewportHeight: CGFloat) {
        guard !photoInbox.images.isEmpty, gridFrame.height > 0 else { return }
        #if DEBUG
        let preparationStarted = CACurrentMediaTime()
        defer { zoomDiagnostics.preparationMS = (CACurrentMediaTime() - preparationStarted) * 1000 }
        #endif
        zoomPresentation.stopAnimation()
        zoomGestureBaseSide = nil
        zoomBaseColumns = columnCount
        zoomBaseLeadingSlots = leadingSlots
        zoomBaseFrame = gridFrame
        zoomAnchorTops = [:]
        zoomPreparedPanRange = 0
        zoomSettledColumns = nil
        zoomPanLastY = nil
        // The recognizer lives on the viewport, not on the disappearing grid.
        let anchor = UnitPoint(
            x: viewportAnchor.x,
            y: (viewportAnchor.y * viewportHeight - gridFrame.minY) / gridFrame.height)
        zoomPresentation.position = PhoneGalleryZoomPresentation.position(for: columnCount)
        zoomPresentation.offsetY = 0
        zoomPresentation.elasticAnchor = CGPoint(
            x: viewportAnchor.x * width, y: viewportAnchor.y * viewportHeight)
        let side = tileSide(columns: columnCount, width: width)
        let stride = side + gallerySpacing
        let point = CGPoint(x: anchor.x * gridFrame.width, y: anchor.y * gridFrame.height)
        // Choose the nearest tile if the midpoint falls in the spacing or the
        // empty cells of the last row. Keep that identity for the entire gesture.
        let row = max(0, Int(((point.y - side / 2) / stride).rounded()))
        let column = min(columnCount - 1, max(0, Int(((point.x - side / 2) / stride).rounded())))
        let index: Int
        if columnCount == 1 {
            // Use the containing tile, not its center: a tall portrait can
            // contain the touch even when a neighboring short tile is nearer.
            index = photoInbox.images.indices.first {
                imageLayout.top(at: $0 + 1, width: side, spacing: gallerySpacing)
                    - gallerySpacing / 2 > point.y
            } ?? (photoInbox.images.count - 1)
        } else {
            index = min(photoInbox.images.count - 1, max(0, row * columnCount + column - leadingSlots))
        }
        zoomAnchorIndex = index
        zoomSnapshot = photoInbox.images
        previewCache.preparationPaused = true
        pinchTarget = photoInbox.images[index]
        let tileTop = galleryItemTop(index: index, columns: columnCount, width: width, leading: leadingSlots)
        let tileHeight = galleryItemHeight(index: index, columns: columnCount, width: width)
        pinchTargetFractionY = min(1, max(0, (point.y - tileTop) / tileHeight))
        pinchViewportY = gridFrame.minY + point.y
        zoomLeadingSlots = [columnCount: leadingSlots]
        for density in columnOptions where density != columnCount {
            // Zooming out reveals neighbors around the focal tile. Zooming in
            // keeps its approximate horizontal position until it fills the width.
            let sourceColumn = (index + leadingSlots) % columnCount
            let fraction = (CGFloat(sourceColumn) + 0.5) / CGFloat(columnCount)
            let destinationColumn = density > columnCount ? density / 2
                : min(density - 1, Int(fraction * CGFloat(density)))
            let slots = (destinationColumn - index % density + density) % density
            zoomLeadingSlots[density] = slots
            let destinationSide = tileSide(columns: density, width: width)
            let targetTop = galleryItemTop(index: index, columns: density, width: width, leading: slots)
            if let placement = settledGalleryPlacement(columns: density, width: width,
                                                       viewportHeight: viewportHeight),
               targetTop - placement.viewportTop <= destinationSide + gallerySpacing {
                // Only regroup when the incomplete first row is offscreen.
                zoomLeadingSlots[density] = 0
            }
        }
        prepareZoomSlots(width: width, viewportHeight: viewportHeight)
    }

    private func prepareZoomSlots(width: CGFloat, viewportHeight: CGFloat) {
        guard let index = zoomAnchorIndex else { return }
        #if DEBUG
        let slotsStarted = CACurrentMediaTime()
        defer {
            zoomDiagnostics.slotsMS = (CACurrentMediaTime() - slotsStarted) * 1000
            zoomDiagnostics.slotCount = zoomSlots.count
            zoomDiagnostics.missingCount = zoomMissingPreviews.count
        }
        #endif
        let side = tileSide(columns: zoomBaseColumns, width: width)
        let anchorRow = (index + zoomBaseLeadingSlots) / zoomBaseColumns
        let anchorColumn = (index + zoomBaseLeadingSlots) % zoomBaseColumns
        var radius = Int(ceil((viewportHeight + zoomPreparedPanRange) / (tileSide(columns: 5, width: width) + gallerySpacing))) + 2
        let anchorTops = zoomAnchorTops.isEmpty ? Dictionary(uniqueKeysWithValues: columnOptions.map { density in
            let top = density == zoomBaseColumns
                ? zoomBaseFrame.minY + galleryItemTop(index: index, columns: density, width: width, leading: zoomBaseLeadingSlots)
                : settledGalleryPlacement(columns: density, width: width, viewportHeight: viewportHeight)?.viewportTop ?? 0
            return (density, top)
        }) : zoomAnchorTops
        zoomAnchorTops = anchorTops
        // Very wide images can expose more rows than the square grid would.
        let singleAnchorTop = imageLayout.top(at: index, width: width, spacing: gallerySpacing)
        for candidate in zoomSnapshot.indices {
            let top = (anchorTops[1] ?? 0)
                + imageLayout.top(at: candidate, width: width, spacing: gallerySpacing) - singleAnchorTop
            let bottom = top + imageLayout.height(for: zoomSnapshot[candidate], width: width)
            if top <= viewportHeight + zoomPreparedPanRange, bottom >= -zoomPreparedPanRange {
                radius = max(radius, abs(candidate - index) + 2)
            }
        }
        var prepared: [PhoneGalleryZoomSlot] = []
        var urls = Set<URL>()
        for row in (anchorRow - radius)...(anchorRow + radius) {
            for column in -4..<(zoomBaseColumns + 4) {
                var images: [Int: URL] = [:]
                var columns: [Int: Int] = [:]
                var frames: [Int: CGRect] = [:]
                for density in columnOptions {
                    let mappedColumn = (index + slots(for: density)) % density + column - anchorColumn
                    columns[density] = mappedColumn
                    let tileWidth = tileSide(columns: density, width: width)
                    let rowIndex = index + row - anchorRow
                    let relativeTop: CGFloat
                    let tileHeight: CGFloat
                    if density == 1 {
                        relativeTop = imageLayout.top(at: rowIndex, width: tileWidth, spacing: gallerySpacing)
                            - imageLayout.top(at: index, width: tileWidth, spacing: gallerySpacing)
                        tileHeight = zoomSnapshot.indices.contains(rowIndex)
                            ? imageLayout.height(for: zoomSnapshot[rowIndex], width: tileWidth) : tileWidth
                    } else {
                        relativeTop = CGFloat(row - anchorRow) * (tileWidth + gallerySpacing)
                        tileHeight = tileWidth
                    }
                    // Side columns share the focal column's row boundaries as
                    // it unfolds to original proportions in the one-column view.
                    frames[density] = CGRect(x: CGFloat(mappedColumn) * (tileWidth + gallerySpacing),
                        y: (anchorTops[density] ?? 0) + relativeTop, width: tileWidth, height: tileHeight)
                    let mappedIndex = index + (row - anchorRow) * density + column - anchorColumn
                    if (0..<density).contains(mappedColumn), zoomSnapshot.indices.contains(mappedIndex) {
                        images[density] = zoomSnapshot[mappedIndex]
                        urls.insert(zoomSnapshot[mappedIndex])
                    }
                }
                prepared.append(PhoneGalleryZoomSlot(id: prepared.count, frames: frames,
                    images: images, columns: columns))
            }
        }
        zoomPreviewSize = PhoneGalleryPreviewCache.size(for: side * displayScale)
        zoomPreviews = urls.reduce(into: [:]) { result, url in
            // Hold the best prepared copy through the entire gesture, including
            // changes between density pairs. Never evict a displayed transition.
            if let image = previewCache.availableImage(for: url, maximumSize: 1600) {
                result[url] = image
            }
        }
        zoomSlots = prepared
        // Load only absent snapshots, once per session, through the serial decoder.
        // The render loop itself never starts requests or changes image tiers.
        zoomMissingPreviews = urls.filter { zoomPreviews[$0] == nil }.sorted {
            let left = zoomSnapshot.firstIndex(of: $0) ?? 0
            let right = zoomSnapshot.firstIndex(of: $1) ?? 0
            return abs(left - index) < abs(right - index)
        }
        zoomSessionID = UUID()
    }

    /// Capture prepared previews on the main actor, then rasterize independently
    /// of gesture delivery and missing-preview loading.
    private func prepareZoomSideBackdrop(width: CGFloat, viewportHeight: CGFloat, sessionID: UUID) async {
        guard !Task.isCancelled, zoomSessionID == sessionID else { return }
        #if DEBUG
        let backdropStarted = CACurrentMediaTime()
        let diagnosticSession = zoomDiagnostics.session
        #endif
        let side = tileSide(columns: 5, width: width)
        let stride = side + gallerySpacing
        let leading = slots(for: 5)
        guard let anchorIndex = zoomAnchorIndex,
              let anchorFrame = zoomSlots.first(where: { $0.images[5] == zoomSnapshot[anchorIndex] })?.frames[5] else {
            zoomSideBackdrops = [:]
            return
        }
        let originY = anchorFrame.minY - CGFloat((anchorIndex + leading) / 5) * stride
        // Bound destination rows, not source rows: partial rows still need
        // side copies, but nothing may extend vertically beyond real content.
        let rowCount = (zoomSnapshot.count + leading + 4) / 5
        let tiles = zoomSlots.filter { slot in
            guard let column = slot.columns[5], let rect = slot.frames[5] else { return false }
            return (0..<5).contains(column) && rect.maxY >= -3 * stride
                && rect.minY <= viewportHeight + 3 * stride
        }
        guard let top = tiles.compactMap({ $0.frames[5]?.minY }).min(),
              let bottom = tiles.compactMap({ $0.frames[5]?.maxY }).max() else {
            zoomSideBackdrops = [:]
            return
        }
        // Five full column strides keep the seam identical to internal spacing.
        let bounds = CGRect(x: 0, y: top, width: width + gallerySpacing, height: bottom - top)
        var drawTiles: [Int: [PhoneGalleryBackdropRenderer.Tile]] = [:]
        for direction in [-1, 1] {
                for slot in tiles {
                    guard let rect = slot.frames[5], let column = slot.columns[5] else { continue }
                    let destinationRow = Int(((rect.minY - originY) / stride).rounded())
                    guard (0..<rowCount).contains(destinationRow) else { continue }
                    // A partial final row ends at its last real photo; do not
                    // restart that row in the decorative strip on the right.
                    if direction > 0, destinationRow == rowCount - 1,
                       (zoomSnapshot.count + leading) % 5 != 0 { continue }
                    // Repeat the same row horizontally: ... 4 5 | 1 2 3 4 5 | 1 2 ...
                    let sourceRow = destinationRow
                    let firstIndex = max(0, sourceRow * 5 - leading)
                    let endIndex = min(zoomSnapshot.count, (sourceRow + 1) * 5 - leading)
                    guard firstIndex < endIndex else { continue }
                    // Repeat the available photos of a partial source row only
                    // in the decorative copies; real empty cells stay empty.
                    let count = endIndex - firstIndex
                    let repeatedColumn = direction < 0 ? column - 5 : column
                    let wrappedColumn = (repeatedColumn % count + count) % count
                    let url = zoomSnapshot[firstIndex + wrappedColumn]
                    guard let image = zoomPreviews[url] ?? previewCache.availableImage(for: url, maximumSize: zoomPreviewSize),
                          image.size.width > 0, image.size.height > 0 else { continue }
                    let tile = rect.offsetBy(dx: 0, dy: -top)
                    drawTiles[direction, default: []].append(.init(image: image, rect: tile))
                }
        }
        // Resolve dynamic colors here: a background actor has no view trait environment.
        let background = UIColor.systemBackground.resolvedColor(with:
            UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light))
        guard let backdrops = await PhoneGalleryBackdropRenderer.shared.render(
            tiles: drawTiles, size: bounds.size, scale: min(displayScale, 2), background: background),
            !Task.isCancelled, zoomSessionID == sessionID else { return }
        zoomSideBackdrops = backdrops
        zoomSideBackdropFrame = bounds
        #if DEBUG
        if zoomDiagnostics.session == diagnosticSession {
            zoomDiagnostics.backdropMS = (CACurrentMediaTime() - backdropStarted) * 1000
        }
        #endif
    }

    private func updateGalleryZoom(_ magnification: CGFloat, width: CGFloat, viewportHeight: CGFloat) {
        #if DEBUG
        defer {
            if zoomDiagnostics.appliedMS == nil {
                zoomDiagnostics.appliedMS = zoomDiagnostics.elapsedMS()
            }
        }
        #endif
        let initialSide = tileSide(columns: zoomBaseColumns, width: width)
        let minimumSide = tileSide(columns: 5, width: width)
        let maximumSide = tileSide(columns: 1, width: width)
        let requestedSide = (zoomGestureBaseSide ?? initialSide) * magnification
        let side = min(maximumSide, max(minimumSide, requestedSide))
        let middleSide = tileSide(columns: 3, width: width)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            // One continuous value owns the entire 5 ↔ 3 ↔ 1 transition.
            // Crossing three columns cannot pair a new grid with old progress.
            zoomPresentation.scale = side / initialSide
            // Convert rubber-band distance back to a relative scale, keeping
            // resistance and normal zoom on the same animation coordinate.
            if requestedSide < minimumSide {
                let offset = galleryRubberBandOffset(minimumSide - requestedSide, dimension: width)
                zoomPresentation.position = -offset / minimumSide / 5
            } else if requestedSide > maximumSide {
                let offset = galleryRubberBandOffset(requestedSide - maximumSide, dimension: width)
                zoomPresentation.position = 2 + offset / maximumSide
            } else if side <= middleSide {
                let smallSide = tileSide(columns: 5, width: width)
                zoomPresentation.position = (side - smallSide) / (middleSide - smallSide)
            } else {
                let largeSide = tileSide(columns: 1, width: width)
                zoomPresentation.position = 1 + (side - middleSide) / (largeSide - middleSide)
            }
        }
    }

    private func galleryRubberBandOffset(_ distance: CGFloat, dimension: CGFloat) -> CGFloat {
        let x = max(0, distance)
        let d = max(1, dimension)
        let c: CGFloat = 0.55
        // Pinch changes tile width, so d is the gallery viewport width.
        return (1 - 1 / (c * x / d + 1)) * d
    }

    private func slots(for columns: Int) -> Int {
        zoomLeadingSlots[columns] ?? 0
    }

    private func galleryItemHeight(index: Int, columns: Int, width: CGFloat) -> CGFloat {
        let side = tileSide(columns: columns, width: width)
        return columns == 1 ? imageLayout.height(for: photoInbox.images[index], width: side) : side
    }

    private func galleryItemTop(index: Int, columns: Int, width: CGFloat, leading: Int) -> CGFloat {
        let side = tileSide(columns: columns, width: width)
        return columns == 1 ? imageLayout.top(at: index, width: side, spacing: gallerySpacing)
            : CGFloat((index + leading) / columns) * (side + gallerySpacing)
    }

    private func beginGalleryZoomPan(at y: CGFloat) {
        zoomPanLastY = y
        // Cancels the restoration task without stopping the scale animation.
        pendingZoomColumns = nil
        pendingZoomTarget = nil
        pendingZoomAnchor = nil
        pendingZoomViewportTop = nil
        pendingZoomMeasuredFrame = nil
    }

    private func moveGalleryZoomPan(to y: CGFloat, width: CGFloat, viewportHeight: CGFloat) {
        guard let previousY = zoomPanLastY else {
            beginGalleryZoomPan(at: y)
            return
        }
        zoomPanLastY = y
        guard let index = zoomAnchorIndex else { return }
        let bounded = min(2, max(0, zoomPresentation.position))
        let from = bounded <= 1 ? 5 : 3
        let to = bounded <= 1 ? 3 : 1
        let progress = bounded <= 1 ? bounded : bounded - 1
        func bounds(for columns: Int) -> (top: CGFloat, bottom: CGFloat) {
            let side = tileSide(columns: columns, width: width)
            let top = (zoomAnchorTops[columns] ?? 0)
                - galleryItemTop(index: index, columns: columns, width: width, leading: slots(for: columns))
            let rows = (zoomSnapshot.count + slots(for: columns) + columns - 1) / columns
            let height = columns == 1
                ? imageLayout.top(at: zoomSnapshot.count, width: side, spacing: gallerySpacing) - gallerySpacing
                : CGFloat(rows) * side + CGFloat(max(0, rows - 1)) * gallerySpacing
            return (top, top + height)
        }
        let start = bounds(for: from)
        let end = bounds(for: to)
        let scale = 1 + zoomPresentation.position - bounded
        let anchorY = zoomPresentation.elasticAnchor.y
        let top = anchorY + (start.top + (end.top - start.top) * progress - anchorY) * scale
        let bottom = anchorY + (start.bottom + (end.bottom - start.bottom) * progress - anchorY) * scale
        guard bottom - top > viewportHeight else { return }
        zoomPresentation.offsetY = min(-top, max(viewportHeight - bottom,
            zoomPresentation.offsetY + y - previousY))
        // Keep enough prepared rows for a long drag while scale is settling.
        if abs(zoomPresentation.offsetY) > zoomPreparedPanRange {
            zoomPreparedPanRange = abs(zoomPresentation.offsetY) + viewportHeight
            prepareZoomSlots(width: width, viewportHeight: viewportHeight)
        }
    }

    private func finishGalleryZoom(width: CGFloat, viewportHeight: CGFloat) {
        let side = tileSide(columns: zoomBaseColumns, width: width) * zoomPresentation.scale
        // Compare proportional distances so zooming in and out are symmetric.
        let nearest = columnOptions.min {
            abs(log(tileSide(columns: $0, width: width) / side))
                < abs(log(tileSide(columns: $1, width: width) / side))
        } ?? zoomBaseColumns
        let basePosition = PhoneGalleryZoomPresentation.position(for: zoomBaseColumns)
        let position = min(2, max(0, zoomPresentation.position))
        let nearestPosition = PhoneGalleryZoomPresentation.position(for: nearest)
        var destination = nearest
        if nearest != zoomBaseColumns {
            // Once the gesture qualifies for a new grid, settlement must not
            // reverse it. If that grid is already behind the rendered scale,
            // continue to the next grid in the same direction instead.
            if position > basePosition, nearestPosition < position {
                let forwardPosition = Int(position.rounded(.up))
                destination = [5, 3, 1][forwardPosition]
            } else if position < basePosition, nearestPosition > position {
                let forwardPosition = Int(position.rounded(.down))
                destination = [5, 3, 1][forwardPosition]
            }
        }
        settleGalleryZoom(columns: destination, width: width, viewportHeight: viewportHeight)
    }

    private func settleGalleryZoom(columns nearest: Int, width: CGFloat, viewportHeight: CGFloat) {
        guard !settlingZoom else { return }
        settlingZoom = true
        let settlementID = UUID()
        zoomSettlementID = settlementID
        suppressOpeningUntil = .distantFuture
        let finalScale = tileSide(columns: nearest, width: width) / tileSide(columns: zoomBaseColumns, width: width)
        let finalPosition = PhoneGalleryZoomPresentation.position(for: nearest)
        // Preserve the finite spring-like deceleration while scrolling can run
        // independently of the scale animation.
        let isRubberBanding = zoomPresentation.position < 0 || zoomPresentation.position > 2
        let baseDuration = isRubberBanding ? 0.24 : 0.18
        // Slow only a return to the starting grid; grid-to-grid settlement
        // retains its existing timing. Lower speed means longer duration.
        let isBeyondFiveColumns = zoomPresentation.position < 0
        let returnDurationMultiplier = nearest == zoomBaseColumns && !isBeyondFiveColumns
            ? Double(nearest) : 1
        let gridTransition = nearest != zoomBaseColumns && !isRubberBanding
        let remainingDistance = min(2, abs(finalPosition - zoomPresentation.position))
        let duration = reduceMotion ? 0 : (gridTransition
            ? 0.28 + 0.16 * Double(remainingDistance)
            : baseDuration * returnDurationMultiplier)
        zoomPresentation.animate(to: finalPosition, duration: duration,
                                 gridTransition: gridTransition) {
            guard zoomSettlementID == settlementID else { return }
            zoomPresentation.scale = finalScale
            zoomSettledColumns = nearest
            commitGalleryZoom(columns: nearest, width: width, viewportHeight: viewportHeight)
        }
    }

    private func interruptGalleryZoom(width: CGFloat) {
        // Keep the current drawing and its focal image. Rebase the new gesture
        // from the displayed size, not the previous animation's endpoint.
        zoomPresentation.stopAnimation()
        zoomSettledColumns = nil
        zoomSettlementID = nil
        settlingZoom = false
        let position = zoomPresentation.position
        let small = tileSide(columns: 5, width: width)
        let middle = tileSide(columns: 3, width: width)
        let large = tileSide(columns: 1, width: width)
        let side: CGFloat
        if position < 0 {
            // Invert the five-column rubber band (including its 1/5 strength).
            let offset = min(width * 0.999, -position * small * 5)
            side = max(0.001, small - offset / (0.55 * (1 - offset / width)))
        } else if position > 2 {
            let offset = min(width * 0.999, (position - 2) * large)
            side = large + offset / (0.55 * (1 - offset / width))
        } else if position <= 1 {
            side = small + (middle - small) * position
        } else {
            side = middle + (large - middle) * (position - 1)
        }
        zoomGestureBaseSide = side
        zoomPresentation.scale = min(large, max(small, side)) / tileSide(columns: zoomBaseColumns, width: width)
    }

    private func resetGalleryZoom() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            zoomPresentation.stopAnimation()
            zoomGestureBaseSide = nil
            zoomSettlementID = nil
            zoomPanLastY = nil
            zoomSettledColumns = nil
            zoomAnchorTops = [:]
            zoomPreparedPanRange = 0
            previewCache.preparationPaused = false
            zoomSessionID = nil
            zoomMissingPreviews = []
            zoomSlots = []
            zoomPreviews = [:]
            zoomSideBackdrops = [:]
            zoomSideBackdropFrame = .zero
            zoomSnapshot = []
            zoomAnchorIndex = nil
            hasTwoFingerContact = false
            settlingZoom = false
            pinchTarget = nil
            zoomPresentation.scale = 1
            zoomPresentation.position = PhoneGalleryZoomPresentation.position(for: columnCount)
            zoomPresentation.offsetY = 0
            pendingZoomAnchor = nil
            pendingZoomTarget = nil
            pendingZoomColumns = nil
            pendingZoomViewportTop = nil
            pendingZoomMeasuredFrame = nil
            suppressOpeningUntil = .distantPast
        }
    }

    /// Predict the same bounded scroll position used by the committed grid.
    /// Near either end, the focal image must move because there are no more rows.
    private func settledGalleryPlacement(columns: Int, width: CGFloat,
                                         viewportHeight: CGFloat) -> (anchor: UnitPoint, viewportTop: CGFloat)? {
        guard let target = pinchTarget,
              let index = photoInbox.images.firstIndex(of: target) else { return nil }
        let side = tileSide(columns: columns, width: width)
        let targetTop = galleryItemTop(index: index, columns: columns, width: width, leading: slots(for: columns))
        let height = galleryItemHeight(index: index, columns: columns, width: width)
        let rows = (photoInbox.images.count + slots(for: columns) + columns - 1) / columns
        let contentHeight = columns == 1
            ? imageLayout.top(at: photoInbox.images.count, width: side, spacing: gallerySpacing) - gallerySpacing
            : CGFloat(rows) * side + CGFloat(max(0, rows - 1)) * gallerySpacing
        let denominator = viewportHeight - height
        let anchorY = abs(denominator) > 1
            ? min(1, max(0, (pinchViewportY - pinchTargetFractionY * height) / denominator))
            : 0.5
        let maximumScroll = max(0, contentHeight - viewportHeight)
        // The overlay's destination was already bounded when its slots were
        // captured. Apply subsequent scrolling to that same bounded position.
        let capturedTop = zoomAnchorTops[columns] ?? (anchorY * denominator)
        let settledScroll = min(maximumScroll, max(0, targetTop - capturedTop))
        let scroll = min(maximumScroll, max(0, settledScroll - zoomPresentation.offsetY))
        let viewportTop = targetTop - scroll
        // scrollTo must request the same bounded position as the zoom overlay.
        // Reusing the finger's anchor after clamping the scroll offset can place
        // short content below the viewport top; re-enabling scrolling then
        // bounces it back, creating a second movement after the pinch settles.
        let settledAnchorY = abs(denominator) > 1 ? viewportTop / denominator : anchorY
        return (UnitPoint(x: 0.5, y: settledAnchorY), viewportTop)
    }

    private func commitGalleryZoom(columns nearest: Int, width: CGFloat, viewportHeight: CGFloat) {
        // A finger always owns the visible position. Defer only the invisible
        // grid handoff, never movement of the images under that finger.
        guard zoomPanLastY == nil else { return }
        // An unchanged layout with no Canvas pan already has the right offset.
        // Once Canvas has moved, even this layout needs a position handoff.
        if zoomPresentation.offsetY == 0, nearest == zoomBaseColumns, columnCount == nearest,
           leadingSlots == slots(for: nearest) {
            completeGalleryZoom()
            return
        }
        let placement = settledGalleryPlacement(columns: nearest, width: width, viewportHeight: viewportHeight)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if let placement, let original = pinchTarget,
               let originalIndex = photoInbox.images.firstIndex(of: original) {
                let scroll = galleryItemTop(index: originalIndex, columns: nearest,
                    width: width, leading: slots(for: nearest)) - placement.viewportTop
                let center = scroll + viewportHeight / 2
                let side = tileSide(columns: nearest, width: width)
                let index: Int
                if nearest == 1 {
                    index = photoInbox.images.indices.first {
                        imageLayout.top(at: $0 + 1, width: side, spacing: gallerySpacing) > center
                    } ?? (photoInbox.images.count - 1)
                } else {
                    let row = max(0, Int(center / (side + gallerySpacing)))
                    index = min(photoInbox.images.count - 1, max(0, row * nearest - slots(for: nearest)))
                }
                let top = galleryItemTop(index: index, columns: nearest, width: width,
                                         leading: slots(for: nearest)) - scroll
                let denominator = viewportHeight - galleryItemHeight(index: index, columns: nearest, width: width)
                pendingZoomAnchor = UnitPoint(x: 0.5, y: abs(denominator) > 1 ? top / denominator : 0.5)
                pendingZoomTarget = photoInbox.images[index]
                pendingZoomColumns = nearest
                pendingZoomViewportTop = top
                pendingZoomMeasuredFrame = nil
                leadingSlots = slots(for: nearest)
                storedColumnCount = nearest
                // The overlay still uses the captured source geometry. Relayout
                // and scroll correction underneath cannot move it or expose a frame.
            } else {
                completeGalleryZoom()
            }
        }
    }

    private func completeGalleryZoom() {
        resetGalleryZoom()
        suppressOpeningUntil = Date().addingTimeInterval(0.3)
    }

}

private struct PhoneDrawingView: View {
    let url: URL
    @ObservedObject var inbox: WatchPhotoInbox
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDeletion = false
    @State private var exporting = false
    @State private var showingPhotoConfirmation = false
    @State private var exportingProject = false
    @State private var transferMessage: String?
    private var projectURL: URL { url.deletingPathExtension().appendingPathExtension(PaintProject.fileExtension) }
    private var hasProject: Bool { FileManager.default.fileExists(atPath: projectURL.path) }
    @State private var exportError: String?

    var body: some View {
        VStack(spacing: 20) {
            DrawingPreview(url: url, maximumSize: 2400)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 24) {
                Menu {
                    ShareLink(item: url) { Label("Image (.png)", systemImage: "photo") }
                    ShareLink(item: projectURL) { Label("Project (.paintanytime)", systemImage: "doc") }
                        .disabled(!hasProject)
                    if !hasProject {
                        Button("Sync project from Apple Watch") { inbox.synchronize() }
                    }
                } label: { Label("Share", systemImage: "square.and.arrow.up") }
                Button { inbox.saveToPhotos(url) } label: { Label("Photos", systemImage: "photo.badge.plus") }
                    .disabled(inbox.isSaving)
                Menu {
                    Button("Image (.png)") { exporting = true }
                    Button("Project (.paintanytime)") { exportingProject = true }
                        .disabled(!hasProject)
                    if !hasProject {
                        Button("Sync project from Apple Watch") { inbox.synchronize() }
                    }
                } label: { Label("Save File", systemImage: "folder") }
            }
            .labelStyle(.titleAndIcon).font(.subheadline)
            if hasProject {
                Menu {
                    ShareLink(item: projectURL) { Label("Share Project", systemImage: "square.and.arrow.up") }
                    Button("Save Project to Files") { exportingProject = true }
                    Button("Send to Apple Watch") {
                        let session = WCSession.default
                        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else {
                            exportError = "Connect your Apple Watch and install Paint Anytime before sending a project."
                            return
                        }
                        session.transferFile(projectURL, metadata: ["project": true])
                        transferMessage = "Project queued. It will appear in your watch gallery when the transfer finishes. Open it there to edit."
                    }
                } label: { Label("Project", systemImage: "doc.badge.gearshape") }
            } else {
                VStack(spacing: 8) {
                    Text("Only the PNG preview is on this iPhone. Open the updated Paint Anytime app on your Apple Watch, then sync to receive the editable project.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Sync project from Apple Watch") { inbox.synchronize() }
                }
            }
            Button(role: .destructive) { confirmingDeletion = true } label: {
                Label("Delete", systemImage: "trash")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(inbox.isSaving)
            if inbox.isSaving { ProgressView("Saving…") }
        }
        .padding()
        .navigationTitle("Drawing")
        .toolbar(.visible, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete from Apple Watch and iPhone?", isPresented: $confirmingDeletion, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if inbox.delete(url) { dismiss() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Save a copy to Photos, Files, or another app first. Deletion will sync when your devices reconnect.")
        }
        .onChange(of: inbox.images) { _, images in
            if !images.contains(url) { dismiss() }
        }
        .fileExporter(isPresented: $exporting, document: DrawingFile(url: url), contentType: .png,
                      defaultFilename: url.deletingPathExtension().lastPathComponent) { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
        .fileExporter(isPresented: $exportingProject, document: DrawingFile(url: projectURL), contentType: .paintAnytimeProject,
                      defaultFilename: projectURL.deletingPathExtension().lastPathComponent) { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
        .alert("Project queued", isPresented: Binding(get: { transferMessage != nil }, set: { if !$0 { transferMessage = nil } })) {
            Button("OK") { transferMessage = nil }
        } message: { Text(transferMessage ?? "") }
        .onChange(of: inbox.savedToPhotos, initial: true) { _, saved in
            showingPhotoConfirmation = saved
        }
        .onChange(of: showingPhotoConfirmation) { _, presented in
            if !presented { inbox.clearConfirmation() }
        }
        .alert("Saved to Photos", isPresented: $showingPhotoConfirmation) {
            Button("OK") { showingPhotoConfirmation = false }
        }
        .alert("Could not export", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") { exportError = nil }
        } message: { Text(exportError ?? "") }
    }
}

private struct DrawingFile: FileDocument {
    static var readableContentTypes: [UTType] { [.png, .paintAnytimeProject] }
    let url: URL?
    let data: Data?
    init(url: URL) { self.url = url; data = nil }
    init(configuration: ReadConfiguration) throws { url = nil; data = configuration.file.regularFileContents }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        if let url { return try FileWrapper(url: url, options: .immediate) }
        return FileWrapper(regularFileWithContents: data ?? Data())
    }
}

@MainActor
struct DrawingPreview: View {
    let url: URL
    let maximumSize: Int
    var fillsFrame = false
    var cache: PhoneGalleryPreviewCache? = nil
    var preparesOtherSizes = false
    var isTransitionDestination = false
    var frozenPreview: UIImage? = nil
    var viewportSize: CGSize? = nil
    @State private var previewOwner = UUID()
    @State private var preview: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image = frozenPreview ?? cache?.image(for: url, maximumSize: maximumSize)
                ?? preview ?? cache?.availableImage(for: url, maximumSize: maximumSize) {
                if let viewportSize {
                    // Use the same dimensions as the tile's clip. A fixed inner
                    // frame also prevents an oversized aspect-fill image from
                    // changing the ZStack's layout and centering during a pinch.
                    let scale = max(viewportSize.width / max(image.size.width, 1),
                                    viewportSize.height / max(image.size.height, 1))
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: image.size.width * scale, height: image.size.height * scale)
                        .frame(width: viewportSize.width, height: viewportSize.height)
                        .background {
                            if isTransitionDestination { Color(uiColor: .systemBackground) }
                        }
                        .clipped()
                } else {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: fillsFrame ? .fill : .fit)
                        .background {
                            if isTransitionDestination { Color(uiColor: .systemBackground) }
                        }
                }
            }
            else if isTransitionDestination { Color.clear }
            else if failed { Label("Preview unavailable", systemImage: "photo") }
            else { ProgressView() }
        }
        .onAppear {
            if let cache, let image = frozenPreview ?? cache.availableImage(for: url, maximumSize: maximumSize) ?? preview {
                preview = image
                cache.retainDisplayed(image, for: url, owner: previewOwner)
            }
        }
        .onDisappear { cache?.releaseDisplayed(owner: previewOwner) }
        .task(id: "\(url.absoluteString)|\(maximumSize)|\(cache?.id.uuidString ?? "detail")|\(preparesOtherSizes)") {
            failed = false
            if let frozenPreview {
                preview = frozenPreview
                cache?.retainDisplayed(frozenPreview, for: url, owner: previewOwner)
                return
            }
            if let cache {
                let image = await cache.load(url, maximumSize: maximumSize)
                guard !Task.isCancelled else { return }
                if let image {
                    cache.retainDisplayed(image, for: url, owner: previewOwner)
                    preview = image
                }
                failed = image == nil
                if preparesOtherSizes, image != nil {
                    await cache.prepareOtherSizes(for: url, excluding: maximumSize)
                }
                return
            }
            let sourceURL = url
            let size = maximumSize
            let image = await Task.detached(priority: .userInitiated) {
                guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else { return Optional<CGImage>.none }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: size
                ] as CFDictionary)
            }.value
            if !Task.isCancelled {
                if let image { preview = UIImage(cgImage: image) }
                else { failed = true }
            }
        }
    }
}
