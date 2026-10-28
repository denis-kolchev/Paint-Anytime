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
    @State private var zoomBaseColumns = 5
    @State private var zoomBaseLeadingSlots = 0
    @State private var zoomBaseFrame: CGRect = .zero
    @State private var pendingZoomOriginY: CGFloat?
    @State private var pinchScale: CGFloat = 1
    // Leading slots change row alignment without changing document order.
    @State private var leadingSlots = 0
    @State private var zoomLeadingSlots: [Int: Int] = [:]
    @State private var zoomColumns = 5
    @State private var zoomFromColumns = 5
    @State private var zoomBlend: Double = 0
    @State private var zoomOffsetX: CGFloat = 0
    @State private var zoomOffsetY: CGFloat = 0
    @State private var settlingZoom = false
    @State private var zoomSettlementID: UUID?
    @State private var pinchAnchor: UnitPoint = .center
    @State private var gridFrame: CGRect = .zero
    @State private var pinchTarget: URL?
    @State private var pinchTargetFractionY: CGFloat = 0.5
    @State private var pinchViewportY: CGFloat = 0
    @State private var pendingZoomAnchor: UnitPoint?
    @State private var pendingZoomTarget: URL?
    @State private var pendingZoomColumns: Int?
    @GestureState private var isPinching = false
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
                // Disable only the scrolling child. The pinch recognizer lives
                // on the stable wrapper, outside the disabled scroll environment.
                .scrollDisabled(isPinching || pinchTarget != nil || settlingZoom)
                // Let scrolling artwork remain visible through the header material.
                .scrollClipDisabled()
                }
                .overlay(alignment: .topLeading) {
                            if pinchTarget != nil {
                                let tileSize = tileSide(columns: zoomBaseColumns, width: geometry.size.width)
                                let spacing = gallerySpacing
                                ZStack(alignment: .topLeading) {
                                    ForEach(zoomRows(viewportHeight: geometry.size.height,
                                                    width: geometry.size.width), id: \.self) { row in
                                        ForEach(-4..<(zoomBaseColumns + 4), id: \.self) { column in
                                            PhoneGalleryZoomTile(
                                                source: zoomImage(row: row, column: column, density: zoomFromColumns),
                                                destination: zoomImage(row: row, column: column, density: zoomColumns),
                                                blend: zoomBlend, side: tileSize, cache: previewCache,
                                                renderedScale: pinchScale)
                                                .scaleEffect(pinchScale)
                                                .offset(zoomTileOffset(row: row, column: column, side: tileSize))
                                                .offset(x: CGFloat(column) * (tileSize + spacing),
                                                        y: CGFloat(row) * (tileSize + spacing))
                                        }
                                    }
                                }
                                .frame(width: geometry.size.width, height: zoomBaseFrame.height, alignment: .topLeading)
                                .offset(x: zoomOffsetX, y: zoomBaseFrame.minY + zoomOffsetY)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                            }
                        }
                .highPriorityGesture(
                    MagnifyGesture()
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
                .coordinateSpace(name: "phoneGalleryViewport")
                .onPreferenceChange(PhoneGalleryFrameKey.self) { layout in
                    guard layout.columns > 0 else { return }
                    gridFrame = layout.frame
                    guard layout.columns == pendingZoomColumns,
                          let target = pendingZoomTarget,
                          let anchor = pendingZoomAnchor else { return }
                    // Keep the viewport overlay until layout reports the actual
                    // restored offset, including the case where no scroll is needed.
                    if let originY = pendingZoomOriginY,
                       abs(layout.frame.minY - originY) < 0.5 {
                        completeGalleryZoom()
                        return
                    }
                    // The new column layout must exist before scrollTo can use it.
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { scrollProxy.scrollTo(target, anchor: anchor) }
                }
                }
            }
            .navigationDestination(for: URL.self) { url in
                PhoneDrawingView(url: url, inbox: photoInbox)
            }
            .onReceive(photoInbox.$images) { _ in
                // A sync can replace PNG contents without changing its URL.
                previewCache.invalidate()
                previewCache = PhoneGalleryPreviewCache()
                if let target = pinchTarget, !photoInbox.images.contains(target) {
                    resetGalleryZoom()
                }
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
        pinchAnchor = anchor
        zoomColumns = columnCount
        zoomFromColumns = columnCount
        zoomBlend = 0
        zoomOffsetX = 0
        zoomOffsetY = 0
        let side = tileSide(columns: columnCount, width: width)
        let stride = side + gallerySpacing
        let point = CGPoint(x: anchor.x * gridFrame.width, y: anchor.y * gridFrame.height)
        // Choose the nearest tile if the midpoint falls in the spacing or the
        // empty cells of the last row. Keep that identity for the entire gesture.
        let row = max(0, Int(((point.y - side / 2) / stride).rounded()))
        let column = min(columnCount - 1, max(0, Int(((point.x - side / 2) / stride).rounded())))
        let index = min(photoInbox.images.count - 1, max(0, row * columnCount + column - leadingSlots))
        pinchTarget = photoInbox.images[index]
        let tileTop = CGFloat((index + leadingSlots) / columnCount) * stride
        pinchTargetFractionY = min(1, max(0, (point.y - tileTop) / side))
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
            let targetTop = CGFloat((index + slots) / density) * (destinationSide + gallerySpacing)
            if let placement = settledGalleryPlacement(columns: density, width: width,
                                                       viewportHeight: viewportHeight),
               targetTop - placement.viewportTop <= destinationSide + gallerySpacing {
                // Only regroup when the incomplete first row is offscreen.
                zoomLeadingSlots[density] = 0
            }
        }
    }

    private func zoomRows(viewportHeight: CGFloat, width: CGFloat) -> Range<Int> {
        guard let target = pinchTarget,
              let anchorIndex = photoInbox.images.firstIndex(of: target) else { return 0..<0 }
        let anchorRow = (anchorIndex + zoomBaseLeadingSlots) / zoomBaseColumns
        // Reserve the entire possible viewport at the smallest tile size, so
        // the range stays stable during both the gesture and its spring tail.
        let radius = Int(ceil(viewportHeight / (tileSide(columns: 5, width: width) + gallerySpacing))) + 2
        // Virtual source rows may be negative or beyond the source grid:
        // another density can still have valid images in those slots.
        // zoomImage handles the actual document boundaries.
        return (anchorRow - radius)..<(anchorRow + radius + 1)
    }

    private func zoomTileOffset(row: Int, column: Int, side: CGFloat) -> CGSize {
        guard let target = pinchTarget,
              let anchorIndex = photoInbox.images.firstIndex(of: target) else { return .zero }
        let center = CGPoint(x: CGFloat(column) * (side + gallerySpacing) + side / 2,
                             y: CGFloat(row) * (side + gallerySpacing) + side / 2)
        let anchor = CGPoint(x: pinchAnchor.x * zoomBaseFrame.width,
                             y: pinchAnchor.y * zoomBaseFrame.height)
        // Scale each image, not the grid's gutters. Subtract the scaled
        // spacing relative to the focal tile: adjacent centers are always
        // side * scale + gallerySpacing apart. Both terms are linear in
        // scale, so the same invariant holds throughout spring settlement.
        let delta = pinchScale - 1
        return CGSize(
            width: delta * (center.x - anchor.x - gallerySpacing * CGFloat(column - (anchorIndex + zoomBaseLeadingSlots) % zoomBaseColumns)),
            height: delta * (center.y - anchor.y - gallerySpacing * CGFloat(row - (anchorIndex + zoomBaseLeadingSlots) / zoomBaseColumns)))
    }

    private func zoomImage(row: Int, column: Int, density: Int) -> URL? {
        guard let target = pinchTarget,
              let anchorIndex = photoInbox.images.firstIndex(of: target) else { return nil }
        let destinationColumn = (anchorIndex + slots(for: density)) % density
            + column - (anchorIndex + zoomBaseLeadingSlots) % zoomBaseColumns
        let relativeRow = row - (anchorIndex + zoomBaseLeadingSlots) / zoomBaseColumns
        let relativeColumn = column - (anchorIndex + zoomBaseLeadingSlots) % zoomBaseColumns
        let index = anchorIndex + relativeRow * density + relativeColumn
        guard (0..<density).contains(destinationColumn),
              photoInbox.images.indices.contains(index) else { return nil }
        return photoInbox.images[index]
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
            zoomFromColumns = side <= middleSide ? 5 : 3
            zoomColumns = side <= middleSide ? 3 : 1
            pinchScale = side / initialSide
            let fromSide = tileSide(columns: zoomFromColumns, width: width)
            let toSide = tileSide(columns: zoomColumns, width: width)
            let progress = (side - fromSide) / (toSide - fromSide)
            let blend = min(1, max(0, (progress - 0.45) / 0.4))
            zoomBlend = Double(blend * blend * (3 - 2 * blend))
            // Align each density while fingers move, not in a second animation
            // after release. The shared 3-column endpoint also allows reversal.
            let fromOffset = galleryZoomOffset(columns: zoomFromColumns, width: width,
                                               viewportHeight: viewportHeight)
            let toOffset = galleryZoomOffset(columns: zoomColumns, width: width,
                                             viewportHeight: viewportHeight)
            let positionProgress = min(1, max(0, progress))
            zoomOffsetX = fromOffset.width + (toOffset.width - fromOffset.width) * positionProgress
            zoomOffsetY = fromOffset.height + (toOffset.height - fromOffset.height) * positionProgress
        }
    }

    private func slots(for columns: Int) -> Int {
        zoomLeadingSlots[columns] ?? 0
    }

    private func galleryZoomOffset(columns: Int, width: CGFloat, viewportHeight: CGFloat) -> CGSize {
        guard columns != zoomBaseColumns, let target = pinchTarget,
              let index = photoInbox.images.firstIndex(of: target) else { return .zero }
        let initialSide = tileSide(columns: zoomBaseColumns, width: width)
        let side = tileSide(columns: columns, width: width)
        let oldCenter = CGFloat((index + zoomBaseLeadingSlots) % zoomBaseColumns) * (initialSide + gallerySpacing)
            + initialSide / 2
        let newCenter = CGFloat((index + slots(for: columns)) % columns) * (side + gallerySpacing)
            + side / 2
        let scaledCenter = pinchAnchor.x * width + (oldCenter - pinchAnchor.x * width) * side / initialSide
        let anchoredTop = pinchViewportY - pinchTargetFractionY * side
        let placement = settledGalleryPlacement(columns: columns, width: width, viewportHeight: viewportHeight)
        return CGSize(width: newCenter - scaledCenter,
                      height: (placement?.viewportTop ?? anchoredTop) - anchoredTop)
    }

    private func finishGalleryZoom(width: CGFloat, viewportHeight: CGFloat) {
        let side = tileSide(columns: zoomBaseColumns, width: width) * pinchScale
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
        let offset = galleryZoomOffset(columns: nearest, width: width, viewportHeight: viewportHeight)
        let offsetX = offset.width
        let offsetY = offset.height
        // m*x'' = -k*x - b*x'; b = 2*sqrt(m*k) gives critical damping.
        let animation: Animation? = reduceMotion ? nil
            : .interpolatingSpring(mass: 1, stiffness: 225, damping: 30)
        // A no-op or reduced-motion settlement needs no animation callback.
        if animation == nil || (pinchScale == finalScale &&
            zoomBlend == (nearest == zoomColumns ? 1 : 0) &&
            zoomOffsetX == offsetX && zoomOffsetY == offsetY) {
            commitGalleryZoom(columns: nearest, width: width, viewportHeight: viewportHeight)
            return
        }
        withAnimation(animation, completionCriteria: .removed) {
            pinchScale = finalScale
            zoomBlend = nearest == zoomColumns ? 1 : 0
            zoomOffsetX = offsetX
            zoomOffsetY = offsetY
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
            settlingZoom = false
            pinchTarget = nil
            pinchScale = 1
            zoomBlend = 0
            zoomOffsetX = 0
            zoomOffsetY = 0
            pendingZoomAnchor = nil
            pendingZoomTarget = nil
            pendingZoomColumns = nil
            pendingZoomOriginY = nil
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
        let targetTop = CGFloat((index + slots(for: columns)) / columns) * (side + gallerySpacing)
        let rows = (photoInbox.images.count + slots(for: columns) + columns - 1) / columns
        let contentHeight = CGFloat(rows) * side + CGFloat(max(0, rows - 1)) * gallerySpacing
        let denominator = viewportHeight - side
        let anchorY = abs(denominator) > 1
            ? min(1, max(0, (pinchViewportY - pinchTargetFractionY * side) / denominator))
            : 0.5
        let desiredScroll = targetTop - anchorY * denominator
        let scroll = min(max(0, contentHeight - viewportHeight), max(0, desiredScroll))
        return (UnitPoint(x: 0.5, y: anchorY), targetTop - scroll)
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
                let side = tileSide(columns: nearest, width: width)
                let targetTop = CGFloat((index + slots(for: nearest)) / nearest) * (side + gallerySpacing)
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
    @State private var previewOwner = UUID()
    @State private var preview: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image = cache?.image(for: url, maximumSize: maximumSize)
                ?? preview ?? cache?.availableImage(for: url, maximumSize: maximumSize) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: fillsFrame ? .fill : .fit)
                    .background {
                        if isTransitionDestination { Color(uiColor: .systemBackground) }
                    }
                    #if DEBUG
                    .overlay {
                        if let cache, let pixels = image.cgImage {
                            let tier = PhoneGalleryPreviewCache.sizes.first {
                                cache.image(for: url, maximumSize: $0) === image
                            }
                            VStack(spacing: 2) {
                                Text(verbatim: "cache \(tier.map(String.init) ?? "held") / req \(maximumSize)")
                                Text(verbatim: "\(pixels.width)×\(pixels.height) · \(pixels.bytesPerRow * pixels.height / 1024) KB")
                            }
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        }
                    }
                    #endif
            }
            else if isTransitionDestination { Color.clear }
            else if failed { Label("Preview unavailable", systemImage: "photo") }
            else { ProgressView() }
        }
        .onAppear {
            if let cache, let image = cache.availableImage(for: url, maximumSize: maximumSize) ?? preview {
                preview = image
                cache.retainDisplayed(image, for: url, owner: previewOwner)
            }
        }
        .onDisappear { cache?.releaseDisplayed(owner: previewOwner) }
        .task(id: "\(url.absoluteString)|\(maximumSize)|\(cache?.id.uuidString ?? "detail")|\(preparesOtherSizes)") {
            failed = false
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
