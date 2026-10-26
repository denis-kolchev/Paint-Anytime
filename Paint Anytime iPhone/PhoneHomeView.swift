import SwiftUI
import UniformTypeIdentifiers
import ImageIO
import WatchConnectivity

extension UTType {
    static let paintAnytimeProject = UTType(exportedAs: PaintProject.typeIdentifier)
}

struct PhoneHomeView: View {
    @ObservedObject var photoInbox: WatchPhotoInbox

    @AppStorage("phoneGalleryColumnCount") private var storedColumnCount = 5
    @State private var pinchScale: CGFloat = 1
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
                    } else {
                        let spacing: CGFloat = 2
                        let tileSize = max(1, (geometry.size.width - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount))
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnCount), spacing: spacing) {
                            ForEach(photoInbox.images, id: \.self) { url in
                                Button {
                                    openDrawing(url)
                                } label: {
                                    DrawingPreview(url: url, maximumSize: 1600, fillsFrame: true)
                                        .frame(width: tileSize, height: tileSize)
                                        .background(.quaternary)
                                        .clipped()
                                }
                                .buttonStyle(.plain)
                                .id(url)
                                .accessibilityLabel(Text(url.deletingPathExtension().lastPathComponent))
                            }
                        }
                        .background {
                            GeometryReader { grid in
                                Color.clear.preference(key: PhoneGalleryFrameKey.self,
                                    value: PhoneGalleryLayout(columns: columnCount,
                                        frame: grid.frame(in: .named("phoneGalleryViewport"))))
                            }
                        }
                        .scaleEffect(pinchScale, anchor: pinchAnchor)
                        .highPriorityGesture(
                            MagnifyGesture()
                                .updating($isPinching) { _, active, _ in active = true }
                                .onChanged { value in
                                    suppressOpeningUntil = .distantFuture
                                    if pinchTarget == nil {
                                        beginGalleryZoom(anchor: value.startAnchor, width: geometry.size.width)
                                    }
                                    updateGalleryZoom(value.magnification, width: geometry.size.width)
                                }
                                .onEnded { value in
                                    suppressOpeningUntil = Date().addingTimeInterval(0.3)
                                    if pinchTarget == nil {
                                        beginGalleryZoom(anchor: value.startAnchor, width: geometry.size.width)
                                    }
                                    finishGalleryZoom(value.magnification, width: geometry.size.width,
                                                      viewportHeight: geometry.size.height)
                                }
                        )
                        .onChange(of: isPinching) { _, active in
                            if !active {
                                suppressOpeningUntil = Date().addingTimeInterval(0.3)
                                if pendingZoomAnchor == nil { pinchTarget = nil }
                            }
                            // Cancellation restores the saved layout as well.
                            if !active && pinchScale != 1 {
                                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                                    pinchScale = 1
                                }
                            }
                        }
                        Text("Deleting a drawing removes it from both Apple Watch and iPhone. Save a copy to Photos, Files, or another app before deleting.")
                            .font(.footnote).foregroundStyle(.secondary).padding()
                    }
                }
                .coordinateSpace(name: "phoneGalleryViewport")
                .scrollDisabled(isPinching)
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
            .navigationTitle("Watch Gallery")
            .toolbar {
                Button { importingProject = true } label: { Label("Import Project", systemImage: "square.and.arrow.down") }
                Button { photoInbox.synchronize() } label: { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
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
        guard !isPinching, Date() >= suppressOpeningUntil,
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
        max(1, (width - 2 * CGFloat(columns - 1)) / CGFloat(columns))
    }

    private func clampedGalleryScale(_ magnification: CGFloat, width: CGFloat) -> CGFloat {
        let initialSide = tileSide(columns: columnCount, width: width)
        return min(tileSide(columns: 1, width: width) / initialSide,
                   max(tileSide(columns: 5, width: width) / initialSide, magnification))
    }

    private func beginGalleryZoom(anchor: UnitPoint, width: CGFloat) {
        guard !photoInbox.images.isEmpty, gridFrame.height > 0 else { return }
        pinchAnchor = anchor
        let side = tileSide(columns: columnCount, width: width)
        let stride = side + 2
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

    private func updateGalleryZoom(_ magnification: CGFloat, width: CGFloat) {
        // Keep the layout fixed until release. Preview size tracks the original
        // finger distance directly, without repeated thresholds or timed animation.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            pinchScale = clampedGalleryScale(magnification, width: width)
        }
    }

    private func finishGalleryZoom(_ magnification: CGFloat, width: CGFloat, viewportHeight: CGFloat) {
        let side = tileSide(columns: columnCount, width: width)
            * clampedGalleryScale(magnification, width: width)
        // Compare proportional distances so zooming in and out are symmetric.
        let nearest = columnOptions.min {
            abs(log(tileSide(columns: $0, width: width) / side))
                < abs(log(tileSide(columns: $1, width: width) / side))
        } ?? columnCount
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
        pinchTarget = nil
        if nearest != columnCount {
            // Commit reflow without an implicit animation that would continue
            // moving item frames after the anchored scroll has been calculated.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                storedColumnCount = nearest
                pinchScale = 1
            }
        } else {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { pinchScale = 1 }
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

private struct DrawingPreview: View {
    let url: URL
    let maximumSize: Int
    var fillsFrame = false
    @State private var preview: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let preview { Image(uiImage: preview).resizable().aspectRatio(contentMode: fillsFrame ? .fill : .fit) }
            else if failed { Label("Preview unavailable", systemImage: "photo") }
            else { ProgressView() }
        }
        .task(id: url) {
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
