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
    @State private var zoomSlots: [PhoneGalleryZoomSlot] = []
    @State private var zoomPreviews: [URL: UIImage] = [:]
    @State private var zoomPreviewSize = 640
    @State private var imageLayout = PhoneGalleryImageLayout()
    @Environment(\.displayScale) private var displayScale
    @State private var zoomBaseColumns = 5
    @State private var zoomBaseLeadingSlots = 0
    @State private var zoomBaseFrame: CGRect = .zero
    @State private var pendingZoomOriginY: CGFloat?
    @State private var pendingScrollIssued = false
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
                // Keep scrolling available during position restoration so a new
                // touch can start a pan instead of losing the entire sequence.
                .scrollDisabled(hasTwoFingerContact || isPinching ||
                                (pendingZoomColumns == nil && (pinchTarget != nil || settlingZoom)))
                // Let scrolling artwork remain visible through the header material.
                .scrollClipDisabled()
                }
                .overlay(alignment: .topLeading) {
                            if pinchTarget != nil {
                                PhoneGalleryZoomOverlay(
                                    presentation: zoomPresentation, slots: zoomSlots,
                                    frame: zoomBaseFrame, cache: previewCache,
                                    previews: zoomPreviews, previewSize: zoomPreviewSize)
                            }
                        }
                .highPriorityGesture(
                    MagnifyGesture(minimumScaleDelta: 0)
                        .updating($isPinching) { _, active, _ in active = true }
                        .onChanged { value in
                            guard !settlingZoom else { return }
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
                    PhoneGalleryTouchOverlay { positions in
                        if pendingZoomColumns != nil, !positions.isEmpty {
                            // User input takes precedence over a pending scrollTo.
                            // Reset cancels restoration and prevents late callbacks
                            // from changing the position during the new gesture.
                            completeGalleryZoom()
                        }
                        hasTwoFingerContact = positions.count >= 2
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
                                if zoomPresentation.fromColumns == zoomPresentation.toColumns, zoomPresentation.scale == 1 {
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
                        .frame(width: 80, height: 28)
                        .padding(8)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .overlay(alignment: .bottomTrailing) {
                    Text(verbatim: debugInteraction)
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
                .task(id: pendingZoomColumns) {
                    guard pendingZoomColumns != nil else { return }
                    let settlementID = zoomSettlementID
                    // Geometry feedback normally completes the handoff. A no-op
                    // scrollTo may emit no preference, so retain a short fallback
                    // without polling or blocking a new scroll gesture.
                    do { try await Task.sleep(for: .milliseconds(120)) }
                    catch { return }
                    guard !Task.isCancelled, zoomSettlementID == settlementID,
                          pendingZoomColumns != nil else { return }
                    completeGalleryZoom()
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
                    guard layout.columns == pendingZoomColumns,
                          let target = pendingZoomTarget,
                          let anchor = pendingZoomAnchor else { return }
                    // The first geometry update after scrollTo is the accepted
                    // position, including offsets clamped by ScrollView. Do not
                    // wait for repeated identical samples or animate a correction.
                    if pendingScrollIssued {
                        completeGalleryZoom()
                        return
                    }
                    // No scroll is needed when layout already matches the target.
                    if let originY = pendingZoomOriginY,
                       abs(layout.frame.minY - originY) < 0.5 {
                        completeGalleryZoom()
                        return
                    }
                    // Issue once after the destination layout exists. Repeating
                    // scrollTo from its own geometry feedback can prevent settling.
                    pendingScrollIssued = true
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { scrollProxy.scrollTo(target, anchor: anchor) }
                }
                }
            }
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
        zoomBaseColumns = columnCount
        zoomBaseLeadingSlots = leadingSlots
        zoomBaseFrame = gridFrame
        // The recognizer lives on the viewport, not on the disappearing grid.
        let anchor = UnitPoint(
            x: viewportAnchor.x,
            y: (viewportAnchor.y * viewportHeight - gridFrame.minY) / gridFrame.height)
        zoomPresentation.toColumns = columnCount
        zoomPresentation.fromColumns = columnCount
        zoomPresentation.blend = 0
        zoomPresentation.geometryProgress = 0
        zoomPresentation.offsetY = 0
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
        let side = tileSide(columns: zoomBaseColumns, width: width)
        let anchorRow = (index + zoomBaseLeadingSlots) / zoomBaseColumns
        let anchorColumn = (index + zoomBaseLeadingSlots) % zoomBaseColumns
        var radius = Int(ceil(viewportHeight / (tileSide(columns: 5, width: width) + gallerySpacing))) + 2
        let anchorTops = Dictionary(uniqueKeysWithValues: columnOptions.map { density in
            let top = density == zoomBaseColumns
                ? zoomBaseFrame.minY + galleryItemTop(index: index, columns: density, width: width, leading: zoomBaseLeadingSlots)
                : settledGalleryPlacement(columns: density, width: width, viewportHeight: viewportHeight)?.viewportTop ?? 0
            return (density, top)
        })
        // Very wide images can expose more rows than the square grid would.
        let singleAnchorTop = imageLayout.top(at: index, width: width, spacing: gallerySpacing)
        for candidate in zoomSnapshot.indices {
            let top = (anchorTops[1] ?? 0)
                + imageLayout.top(at: candidate, width: width, spacing: gallerySpacing) - singleAnchorTop
            let bottom = top + imageLayout.height(for: zoomSnapshot[candidate], width: width)
            if top <= viewportHeight, bottom >= 0 {
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
    }

    private func updateGalleryZoom(_ magnification: CGFloat, width: CGFloat, viewportHeight: CGFloat) {
        let initialSide = tileSide(columns: zoomBaseColumns, width: width)
        let side = min(tileSide(columns: 1, width: width),
                       max(tileSide(columns: 5, width: width), initialSide * magnification))
        let middleSide = tileSide(columns: 3, width: width)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            // Magnification always refers to the original finger distance.
            // Only the content pair changes at 3 columns, never the geometry
            // or focal image, so crossing the boundary needs no rebase.
            zoomPresentation.fromColumns = side <= middleSide ? 5 : 3
            zoomPresentation.toColumns = side <= middleSide ? 3 : 1
            zoomPresentation.scale = side / initialSide
            let fromSide = tileSide(columns: zoomPresentation.fromColumns, width: width)
            let toSide = tileSide(columns: zoomPresentation.toColumns, width: width)
            let progress = (side - fromSide) / (toSide - fromSide)
            let blend = min(1, max(0, progress))
            zoomPresentation.blend = Double(blend * blend * (3 - 2 * blend))
            zoomPresentation.geometryProgress = blend
        }
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

    private func finishGalleryZoom(width: CGFloat, viewportHeight: CGFloat) {
        let side = tileSide(columns: zoomBaseColumns, width: width) * zoomPresentation.scale
        // Compare proportional distances so zooming in and out are symmetric.
        let nearest = columnOptions.min {
            abs(log(tileSide(columns: $0, width: width) / side))
                < abs(log(tileSide(columns: $1, width: width) / side))
        } ?? zoomBaseColumns
        settleGalleryZoom(columns: nearest, width: width, viewportHeight: viewportHeight)
    }

    private func settleGalleryZoom(columns nearest: Int, width: CGFloat, viewportHeight: CGFloat) {
        guard !settlingZoom else { return }
        settlingZoom = true
        let settlementID = UUID()
        zoomSettlementID = settlementID
        suppressOpeningUntil = .distantFuture
        let finalScale = tileSide(columns: nearest, width: width) / tileSide(columns: zoomBaseColumns, width: width)
        let finalProgress: CGFloat = nearest == zoomPresentation.toColumns ? 1 : 0
        // Scrolling stays locked until the overlay hands off to the real grid.
        // Use a finite ease-out so a spring's imperceptible tail cannot prolong
        // that lock after the visible zoom has already stopped.
        let animation: Animation? = reduceMotion ? nil : .easeOut(duration: 0.18)
        // A no-op or reduced-motion settlement needs no animation callback.
        if animation == nil || (zoomPresentation.scale == finalScale &&
            zoomPresentation.blend == (nearest == zoomPresentation.toColumns ? 1 : 0) &&
            zoomPresentation.geometryProgress == finalProgress) {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                zoomPresentation.scale = finalScale
                zoomPresentation.blend = Double(finalProgress)
                zoomPresentation.geometryProgress = finalProgress
                commitGalleryZoom(columns: nearest, width: width, viewportHeight: viewportHeight)
            }
            return
        }
        withAnimation(animation, completionCriteria: .removed) {
            zoomPresentation.scale = finalScale
            zoomPresentation.blend = nearest == zoomPresentation.toColumns ? 1 : 0
            zoomPresentation.geometryProgress = finalProgress
        } completion: {
            guard zoomSettlementID == settlementID else { return }
            commitGalleryZoom(columns: nearest, width: width, viewportHeight: viewportHeight)
        }
    }

    private func resetGalleryZoom() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            zoomSettlementID = nil
            previewCache.preparationPaused = false
            zoomSlots = []
            zoomPreviews = [:]
            zoomSnapshot = []
            zoomAnchorIndex = nil
            hasTwoFingerContact = false
            settlingZoom = false
            pinchTarget = nil
            zoomPresentation.scale = 1
            zoomPresentation.blend = 0
            zoomPresentation.geometryProgress = 0
            zoomPresentation.offsetY = 0
            pendingZoomAnchor = nil
            pendingZoomTarget = nil
            pendingZoomColumns = nil
            pendingZoomOriginY = nil
            pendingScrollIssued = false
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
        let desiredScroll = targetTop - anchorY * denominator
        let scroll = min(max(0, contentHeight - viewportHeight), max(0, desiredScroll))
        let viewportTop = targetTop - scroll
        // scrollTo must request the same bounded position as the zoom overlay.
        // Reusing the finger's anchor after clamping the scroll offset can place
        // short content below the viewport top; re-enabling scrolling then
        // bounces it back, creating a second movement after the pinch settles.
        let settledAnchorY = abs(denominator) > 1 ? viewportTop / denominator : anchorY
        return (UnitPoint(x: 0.5, y: settledAnchorY), viewportTop)
    }

    private func commitGalleryZoom(columns nearest: Int, width: CGFloat, viewportHeight: CGFloat) {
        let placement = nearest != columnCount
            ? settledGalleryPlacement(columns: nearest, width: width, viewportHeight: viewportHeight)
            : nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if let placement, let target = pinchTarget,
               let index = photoInbox.images.firstIndex(of: target) {
                let targetTop = galleryItemTop(index: index, columns: nearest, width: width, leading: slots(for: nearest))
                pendingScrollIssued = false
                pendingZoomAnchor = placement.anchor
                pendingZoomTarget = target
                pendingZoomColumns = nearest
                pendingZoomOriginY = placement.viewportTop - targetTop
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
