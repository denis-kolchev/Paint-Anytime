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
    @State private var pinchScale: CGFloat = 1
    @State private var zoomColumns = 5
    @State private var zoomFromColumns = 5
    @State private var zoomBlend: Double = 0
    @State private var zoomOffsetX: CGFloat = 0
    @State private var settlingZoom = false
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
                            ForEach(photoInbox.images, id: \.self) { url in
                                Button {
                                    openDrawing(url)
                                } label: {
                                    PhoneGalleryZoomTile(source: url, destination: nil,
                                                         blend: 0, side: tileSize, cache: previewCache)
                                }
                                .buttonStyle(.plain)
                                .id(url)
                                .accessibilityLabel(Text(url.deletingPathExtension().lastPathComponent))
                            }
                        }
                        // Keep the scroll layout and gesture host alive, but draw
                        // the zoom independently of LazyVGrid's source-row culling.
                        .opacity(pinchTarget == nil ? 1 : 0)
                        .overlay(alignment: .topLeading) {
                            if pinchTarget != nil {
                                ZStack(alignment: .topLeading) {
                                    ForEach(zoomRows(viewportHeight: geometry.size.height,
                                                    width: geometry.size.width), id: \.self) { row in
                                        ForEach(-4..<(columnCount + 4), id: \.self) { column in
                                            PhoneGalleryZoomTile(
                                                source: zoomImage(row: row, column: column, density: zoomFromColumns),
                                                destination: zoomImage(row: row, column: column, density: zoomColumns),
                                                blend: zoomBlend, side: tileSize, cache: previewCache)
                                                .scaleEffect(pinchScale)
                                                .offset(zoomTileOffset(row: row, column: column, side: tileSize))
                                                .offset(x: CGFloat(column) * (tileSize + spacing),
                                                        y: CGFloat(row) * (tileSize + spacing))
                                        }
                                    }
                                }
                                .frame(width: geometry.size.width, height: gridFrame.height, alignment: .topLeading)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                            }
                        }
                        .background {
                            GeometryReader { grid in
                                Color.clear.preference(key: PhoneGalleryFrameKey.self,
                                    value: PhoneGalleryLayout(columns: columnCount,
                                        frame: grid.frame(in: .named("phoneGalleryViewport"))))
                            }
                        }
                        .offset(x: zoomOffsetX)
                        .highPriorityGesture(
                            MagnifyGesture()
                                .updating($isPinching) { _, active, _ in active = true }
                                .onChanged { value in
                                    guard !settlingZoom else { return }
                                    suppressOpeningUntil = .distantFuture
                                    if pinchTarget == nil {
                                        beginGalleryZoom(anchor: value.startAnchor, width: geometry.size.width)
                                    }
                                    updateGalleryZoom(value.magnification, width: geometry.size.width)
                                }
                                .onEnded { value in
                                    guard !settlingZoom else { return }
                                    suppressOpeningUntil = Date().addingTimeInterval(0.3)
                                    if pinchTarget == nil {
                                        beginGalleryZoom(anchor: value.startAnchor, width: geometry.size.width)
                                    }
                                    updateGalleryZoom(value.magnification, width: geometry.size.width)
                                    finishGalleryZoom(width: geometry.size.width,
                                                      viewportHeight: geometry.size.height)
                                }
                        )
                        .onChange(of: isPinching) { _, active in
                            guard !active else { return }
                            // onEnded must get a chance to start its settlement first.
                            DispatchQueue.main.async {
                                guard !isPinching, !settlingZoom, pinchTarget != nil else { return }
                                finishGalleryZoom(width: geometry.size.width,
                                                  viewportHeight: geometry.size.height)
                            }
                        }
                    }
                }
                .coordinateSpace(name: "phoneGalleryViewport")
                // Let scrolling artwork remain visible through the header material.
                .scrollClipDisabled()
                .scrollDisabled(isPinching || settlingZoom)
                .onPreferenceChange(PhoneGalleryFrameKey.self) { layout in
                    guard layout.columns > 0 else { return }
                    gridFrame = layout.frame
                    guard layout.columns == pendingZoomColumns,
                          let target = pendingZoomTarget,
                          let anchor = pendingZoomAnchor else { return }
                    // The preference is emitted by the newly laid-out grid. A
                    // column-state onChange runs too early for scrollTo's geometry.
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { scrollProxy.scrollTo(target, anchor: anchor) }
                    pendingZoomAnchor = nil
                    pendingZoomTarget = nil
                    pendingZoomColumns = nil
                }
                }
            }
            .navigationDestination(for: URL.self) { url in
                PhoneDrawingView(url: url, inbox: photoInbox)
            }
            .onReceive(photoInbox.$images) { _ in
                // A sync can replace PNG contents without changing its URL.
                previewCache = PhoneGalleryPreviewCache()
            }
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

    private func beginGalleryZoom(anchor: UnitPoint, width: CGFloat) {
        guard !photoInbox.images.isEmpty, gridFrame.height > 0 else { return }
        pinchAnchor = anchor
        zoomColumns = columnCount
        zoomFromColumns = columnCount
        zoomBlend = 0
        zoomOffsetX = 0
        let side = tileSide(columns: columnCount, width: width)
        let stride = side + gallerySpacing
        let point = CGPoint(x: anchor.x * gridFrame.width, y: anchor.y * gridFrame.height)
        // Choose the nearest tile if the midpoint falls in the spacing or the
        // empty cells of the last row. Keep that identity for the entire gesture.
        let row = max(0, Int(((point.y - side / 2) / stride).rounded()))
        let column = min(columnCount - 1, max(0, Int(((point.x - side / 2) / stride).rounded())))
        let index = min(photoInbox.images.count - 1, row * columnCount + column)
        pinchTarget = photoInbox.images[index]
        let tileTop = CGFloat(index / columnCount) * stride
        pinchTargetFractionY = min(1, max(0, (point.y - tileTop) / side))
        pinchViewportY = gridFrame.minY + point.y
    }

    private func zoomRows(viewportHeight: CGFloat, width: CGFloat) -> Range<Int> {
        guard let target = pinchTarget,
              let anchorIndex = photoInbox.images.firstIndex(of: target) else { return 0..<0 }
        let anchorRow = anchorIndex / columnCount
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
        let anchor = CGPoint(x: pinchAnchor.x * gridFrame.width,
                             y: pinchAnchor.y * gridFrame.height)
        // Scale each image, not the grid's gutters. Subtract the scaled
        // spacing relative to the focal tile: adjacent centers are always
        // side * scale + gallerySpacing apart. Both terms are linear in
        // scale, so the same invariant holds throughout spring settlement.
        let delta = pinchScale - 1
        return CGSize(
            width: delta * (center.x - anchor.x - gallerySpacing * CGFloat(column - anchorIndex % columnCount)),
            height: delta * (center.y - anchor.y - gallerySpacing * CGFloat(row - anchorIndex / columnCount)))
    }

    private func zoomImage(row: Int, column: Int, density: Int) -> URL? {
        guard let target = pinchTarget,
              let anchorIndex = photoInbox.images.firstIndex(of: target) else { return nil }
        let destinationColumn = anchorIndex % density + column - anchorIndex % columnCount
        let destinationRow = anchorIndex / density + row - anchorIndex / columnCount
        let index = destinationRow * density + destinationColumn
        guard (0..<density).contains(destinationColumn), destinationRow >= 0,
              photoInbox.images.indices.contains(index) else { return nil }
        return photoInbox.images[index]
    }

    private func updateGalleryZoom(_ magnification: CGFloat, width: CGFloat) {
        let initialSide = tileSide(columns: columnCount, width: width)
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
        }
    }

    private func finishGalleryZoom(width: CGFloat, viewportHeight: CGFloat) {
        let side = tileSide(columns: columnCount, width: width) * pinchScale
        // Compare proportional distances so zooming in and out are symmetric.
        let nearest = columnOptions.min {
            abs(log(tileSide(columns: $0, width: width) / side))
                < abs(log(tileSide(columns: $1, width: width) / side))
        } ?? columnCount
        settleGalleryZoom(columns: nearest, width: width, viewportHeight: viewportHeight)
    }

    private func settleGalleryZoom(columns nearest: Int, width: CGFloat, viewportHeight: CGFloat) {
        guard !settlingZoom else { return }
        settlingZoom = true
        suppressOpeningUntil = .distantFuture
        let finalScale = tileSide(columns: nearest, width: width) / tileSide(columns: columnCount, width: width)
        var offsetX: CGFloat = 0
        if let target = pinchTarget, let index = photoInbox.images.firstIndex(of: target) {
            let oldCenter = CGFloat(index % columnCount) * (tileSide(columns: columnCount, width: width) + gallerySpacing)
                + tileSide(columns: columnCount, width: width) / 2
            let newCenter = CGFloat(index % nearest) * (tileSide(columns: nearest, width: width) + gallerySpacing)
                + tileSide(columns: nearest, width: width) / 2
            offsetX = newCenter - (pinchAnchor.x * width + (oldCenter - pinchAnchor.x * width) * finalScale)
        }
        // m*x'' = -k*x - b*x'; b = 2*sqrt(m*k) gives critical damping.
        let animation: Animation? = reduceMotion ? nil
            : .interpolatingSpring(mass: 1, stiffness: 225, damping: 30)
        withAnimation(animation, completionCriteria: .removed) {
            pinchScale = finalScale
            zoomBlend = nearest == zoomColumns ? 1 : 0
            zoomOffsetX = offsetX
        } completion: {
            commitGalleryZoom(columns: nearest, width: width, viewportHeight: viewportHeight)
        }
    }

    private func commitGalleryZoom(columns nearest: Int, width: CGFloat, viewportHeight: CGFloat) {
        if nearest != columnCount, pinchTarget != nil {
            let newSide = tileSide(columns: nearest, width: width)
            // scrollTo aligns the same fractional point in the item and viewport.
            // Solve for that fraction to preserve the point between the fingers.
            let denominator = viewportHeight - newSide
            let anchorY = abs(denominator) > 1
                ? (pinchViewportY - pinchTargetFractionY * newSide) / denominator
                : 0.5
            pendingZoomAnchor = UnitPoint(x: 0.5, y: min(1, max(0, anchorY)))
            pendingZoomTarget = pinchTarget
            pendingZoomColumns = nearest
        } else {
            pendingZoomAnchor = nil
            pendingZoomTarget = nil
            pendingZoomColumns = nil
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            storedColumnCount = nearest
            pinchScale = 1
            zoomBlend = 0
            zoomOffsetX = 0
            pinchTarget = nil
            settlingZoom = false
            suppressOpeningUntil = Date().addingTimeInterval(0.3)
        }
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
    @State private var preview: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image = preview ?? cache?.image(for: url, maximumSize: maximumSize) { Image(uiImage: image).resizable().aspectRatio(contentMode: fillsFrame ? .fill : .fit) }
            else if failed { Label("Preview unavailable", systemImage: "photo") }
            else { ProgressView() }
        }
        .task(id: "\(url.absoluteString)|\(maximumSize)|\(cache?.id.uuidString ?? "detail")") {
            failed = false
            if let cache {
                let image = await cache.load(url, maximumSize: maximumSize)
                guard !Task.isCancelled else { return }
                preview = image
                failed = image == nil
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
