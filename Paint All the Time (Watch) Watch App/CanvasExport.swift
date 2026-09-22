import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import WatchKit

struct CanvasExport: Identifiable {
    var id: URL { url }
    let url: URL
}

enum CanvasExportStore {
    static func directory() throws -> URL {
        let folder = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
            .appendingPathComponent("Drawings", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func all() throws -> [CanvasExport] {
        try FileManager.default.contentsOfDirectory(at: directory(), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { CanvasExport(url: $0) }
    }

    static func loadDocument(for drawing: CanvasExport) throws -> CanvasDocument {
        let url = drawing.url.deletingPathExtension().appendingPathExtension("json")
        return try JSONDecoder().decode(CanvasDocument.self, from: Data(contentsOf: url))
    }

    static func delete(_ drawing: CanvasExport) throws {
        let folder = try directory().resolvingSymlinksInPath().standardizedFileURL
        let file = drawing.url.resolvingSymlinksInPath().standardizedFileURL
        guard file.deletingLastPathComponent() == folder, file.pathExtension.lowercased() == "png"
        else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.removeItem(at: file)
        let source = file.deletingPathExtension().appendingPathExtension("json")
        if FileManager.default.fileExists(atPath: source.path) {
            try FileManager.default.removeItem(at: source)
        }
    }

    @MainActor
    static func save(strokes: [Stroke], size: CGSize, scale: CGFloat) throws -> CanvasExport {
        guard size.width > 0, size.height > 0 else { throw ExportError.render }
        let renderer = ImageRenderer(content: WatchCanvasArtwork(strokes: strokes)
            .frame(width: size.width, height: size.height))
        renderer.scale = scale
        renderer.isOpaque = true
        guard let image = renderer.cgImage else { throw ExportError.render }
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss_SSS"
        let name = "Paint All the Time_\(formatter.string(from: now))_\(UUID().uuidString.prefix(8))"
        let url = try directory().appendingPathComponent(name).appendingPathExtension("png")
        let device = WKInterfaceDevice.current()
        let details: [String: Any] = [
            "application": "Paint All the Time",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "createdAt": ISO8601DateFormatter().string(from: now),
            "timeZone": TimeZone.current.identifier,
            "utcOffsetSeconds": TimeZone.current.secondsFromGMT(for: now),
            "deviceModel": device.model,
            "systemVersion": device.systemVersion,
            "pixelWidth": image.width, "pixelHeight": image.height,
            "canvasWidthPoints": size.width, "canvasHeightPoints": size.height,
            "scale": scale, "strokeCount": strokes.count,
            "instruments": Array(Set(strokes.map { $0.style.instrument.title })).sorted()
        ]
        let metadata = try JSONSerialization.data(withJSONObject: details, options: [.sortedKeys])
        let properties: [CFString: Any] = [
            kCGImagePropertyPNGDictionary: [
                kCGImagePropertyPNGTitle: name,
                kCGImagePropertyPNGSoftware: "Paint All the Time",
                kCGImagePropertyPNGCreationTime: ISO8601DateFormatter().string(from: now),
                kCGImagePropertyPNGDescription: String(decoding: metadata, as: UTF8.self)
            ]
        ]
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw ExportError.encoding }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.encoding }
        let documentData = try JSONEncoder().encode(CanvasDocument(strokes: strokes))
        try documentData.write(to: url.deletingPathExtension().appendingPathExtension("json"), options: .atomic)
        do { try (data as Data).write(to: url, options: .atomic) }
        catch {
            try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("json"))
            throw error
        }
        return CanvasExport(url: url)
    }

    enum ExportError: LocalizedError {
        case render, encoding
        var errorDescription: String? { "Не удалось сохранить изображение холста. Попробуйте ещё раз." }
    }
}

struct SavedDrawingView: View {
    let drawing: CanvasExport
    @State var photoTransferStatus: String
    @State var canRetryPhotoTransfer: Bool
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let image = UIImage(contentsOfFile: drawing.url.path) {
                    Image(uiImage: image).resizable().scaledToFit()
                }
                ShareLink(item: drawing.url, preview: SharePreview("Paint All the Time", image: Image(systemName: "photo"))) {
                    Label("Поделиться", systemImage: "square.and.arrow.up")
                }
                Text(photoTransferStatus).font(.caption2)
                if canRetryPhotoTransfer {
                    Button("Повторить отправку на iPhone") {
                        let queued = WatchPhotoTransfer.shared.queue(drawing.url)
                        canRetryPhotoTransfer = !queued
                        photoTransferStatus = queued
                        ? "Рисунок отправляется в Фото на iPhone."
                        : "Приложение на iPhone пока недоступно."
                    }
                }
                Text(drawing.url.lastPathComponent).font(.caption2)
            }
            .padding(.horizontal)
        }
        .navigationTitle("Сохранено")
    }
}

struct SavedDrawingsView: View {
    var onClose: () -> Void
    var onEditDrawing: (CanvasDocument) -> Void
    @State private var drawings: [CanvasExport] = []
    @State private var errorMessage: String?
    @State private var zoomLevel = 0
    @State private var crownPosition = 0.0
    @State private var selectedDrawing: CanvasExport?
    @State private var focusedDrawing: CanvasExport?
    @State private var pendingDeletion: CanvasExport?
    @State private var confirmedDeletion: CanvasExport?
    @State private var showsFullscreen = false
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
                        if let errorMessage {
                            Text(errorMessage).foregroundStyle(.red).padding()
                        } else if drawings.isEmpty {
                            ContentUnavailableView("Нет рисунков", systemImage: "photo.on.rectangle")
                        } else {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnCount), spacing: spacing) {
                                ForEach(drawings) { drawing in
                                    GalleryThumbnailView(request: GalleryImageRequest(
                                        url: drawing.url, shortSidePixels: thumbnailPixels, displayScale: displayScale),
                                        loadsImage: imageTransition == nil)
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
                                        .onTapGesture {
                                            focusedDrawing = drawing
                                            if zoomLevel == 0 { setZoom(1) }
                                            else { open(drawing) }
                                        }
                                        .accessibilityLabel("Открыть рисунок")
                                        .id(drawing.id)
                                }
                            }
                            .padding(.horizontal, 3)
                            .padding(.bottom, 12)
                        }
                    }
                    .contentMargins(.top, navigationHeight + 4, for: .scrollContent)
                    .scrollIndicators(.hidden)
                    .allowsHitTesting(!showsFullscreen && !isTransitioning)
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
                    fullscreenGallery(size: geometry.size, canvasOriginY: geometry.frame(in: .global).minY,
                                      thumbnailPixels: thumbnailPixels)
                        .opacity(imageTransition == nil && transitionRequest != .opening ? 1 : 0)
                        .allowsHitTesting(!isTransitioning)
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
            .coordinateSpace(name: "drawingGallery")
            .task(id: transitionImageRequest) {
                guard let request = transitionImageRequest else { return }
                let bitmap = await GalleryImageCache.shared.load(request)
                guard !Task.isCancelled, selectedDrawing?.url == request.url else { return }
                guard let bitmap else {
                    returnToGrid()
                    errorMessage = "Не удалось открыть изображение."
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
        .ignoresSafeArea()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: goBack) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.automatic)
                .disabled(isTransitioning)
                .accessibilityLabel("Назад")
            }
            if showsFullscreen && !isTransitioning, let selectedDrawing {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button(role: .destructive) {
                        crownFocused = false
                        pendingDeletion = selectedDrawing
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(isTransitioning)
                    .accessibilityLabel("Удалить рисунок")
                    Spacer()
                    Button { editDrawing(selectedDrawing) } label: {
                        Image(systemName: "pencil")
                    }
                    .disabled(isTransitioning)
                    .accessibilityLabel("Изменить рисунок")
                }
            }
        }
        .focusable(pendingDeletion == nil)
        .focused($crownFocused)
        .digitalCrownRotation($crownPosition, from: 0, through: 2, by: 1,
                              sensitivity: .low, isContinuous: false,
                              isHapticFeedbackEnabled: false)
        .onChange(of: crownPosition) { _, position in
            guard pendingDeletion == nil, !isTransitioning else { return }
            let next = min(2, max(0, Int(position.rounded())))
            guard next != zoomLevel else { return }
            if next == 2 {
                if let drawing = focusedDrawing ?? drawings.first { open(drawing) }
                else { crownPosition = Double(zoomLevel) }
            } else { setZoom(next) }
        }
        .fullScreenCover(item: $pendingDeletion, onDismiss: {
            crownFocused = true
            if let drawing = confirmedDeletion {
                confirmedDeletion = nil
                deleteDrawing(drawing)
            }
        }) { drawing in
            DestructiveConfirmationView(title: "Удалить изображение?", confirmTitle: "Удалить") {
                pendingDeletion = nil
            } onConfirm: {
                confirmedDeletion = drawing
                pendingDeletion = nil
            }
        }
        .alert("Ошибка", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("ОК", role: .cancel) { errorMessage = nil } }
        message: { Text(errorMessage ?? "") }
        .onAppear { crownFocused = true; reload() }
    }

    private func goBack() {
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

    private func fullscreenGallery(size: CGSize, canvasOriginY: CGFloat, thumbnailPixels: Int) -> some View {
        let selectedIndex = drawings.firstIndex(where: { $0.id == selectedDrawing?.id }) ?? 0
        return TabView(selection: Binding<URL?>(
            get: { selectedDrawing?.id },
            set: { id in
                guard !isTransitioning, id != selectedDrawing?.id,
                      let drawing = drawings.first(where: { $0.id == id }) else { return }
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
                                      fallback: transitionBitmap?.url == drawing.url ? transitionBitmap : nil)
                    .tag(Optional(drawing.id))
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea(.container, edges: .all)
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
        do {
            try CanvasExportStore.delete(drawing)
            Task { await GalleryImageCache.shared.remove(drawing.url) }
            drawings.removeAll { $0.id == drawing.id }
            focusedDrawing = nil
            returnToGrid()
            WKInterfaceDevice.current().play(.click)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func editDrawing(_ drawing: CanvasExport) {
        do {
            onEditDrawing(try CanvasExportStore.loadDocument(for: drawing))
        } catch {
            errorMessage = "Этот рисунок сохранён без данных штрихов и не может быть восстановлен для редактирования."
        }
    }

    private func reload() {
        do { drawings = try CanvasExportStore.all(); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
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
