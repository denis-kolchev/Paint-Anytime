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

    static func displaySize(for drawing: CanvasExport, image: UIImage) -> CGSize {
        if let source = CGImageSourceCreateWithURL(drawing.url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any],
           let description = png[kCGImagePropertyPNGDescription] as? String,
           let data = description.data(using: .utf8),
           let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let width = metadata["canvasWidthPoints"] as? NSNumber,
           let height = metadata["canvasHeightPoints"] as? NSNumber,
           width.doubleValue.isFinite, height.doubleValue.isFinite,
           width.doubleValue > 0, height.doubleValue > 0 {
            return CGSize(width: width.doubleValue, height: height.doubleValue)
        }
        let scale = WKInterfaceDevice.current().screenScale
        return CGSize(width: image.size.width / scale, height: image.size.height / scale)
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
    @FocusState private var crownFocused: Bool

    private var columnCount: Int { zoomLevel == 0 ? 5 : 3 }

    var body: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = zoomLevel == 0 ? 2 : 4
            let width = (geometry.size.width - spacing * CGFloat(columnCount - 1) - 6) / CGFloat(columnCount)
            let navigationHeight: CGFloat = max(60, geometry.safeAreaInsets.top + 38)
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
                                    if let image = UIImage(contentsOfFile: drawing.url.path) {
                                        Image(uiImage: image)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: width, height: width)
                                            .clipped()
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
                            }
                            .padding(.horizontal, 3)
                            .padding(.bottom, 12)
                        }
                    }
                    .contentMargins(.top, navigationHeight + 4, for: .scrollContent)
                    .scrollIndicators(.hidden)
                    .scrollDisabled(selectedDrawing != nil)
                    .onChange(of: zoomLevel) { _, level in
                        if level < 2, let drawing = focusedDrawing {
                            withAnimation(.smooth(duration: 0.25)) {
                                scrollProxy.scrollTo(drawing.id, anchor: .center)
                            }
                        }
                    }
                }

                if let selectedDrawing {
                    fullscreenDrawing(selectedDrawing, size: geometry.size)
                        .transition(.opacity)
                        .zIndex(1)
                } else {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .frame(height: navigationHeight)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(.white.opacity(0.12)).frame(height: 0.5)
                        }
                        .allowsHitTesting(false)
                }

            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: goBack) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.automatic)
                .accessibilityLabel("Назад")
            }
            if let selectedDrawing {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button(role: .destructive) {
                        crownFocused = false
                        pendingDeletion = selectedDrawing
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Удалить рисунок")
                    Spacer()
                    Button { editDrawing(selectedDrawing) } label: {
                        Image(systemName: "pencil")
                    }
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
            guard pendingDeletion == nil else { return }
            let next = min(2, max(0, Int(position.rounded())))
            guard next != zoomLevel else { return }
            if next == 2, let drawing = focusedDrawing ?? drawings.first { open(drawing) }
            else { setZoom(next) }
        }
        .fullScreenCover(item: $pendingDeletion, onDismiss: {
            crownFocused = true
            // Delete after dismissal so any error can appear over the gallery.
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
        if zoomLevel == 0 { onClose() }
        else { setZoom(zoomLevel - 1) }
    }

    private func setZoom(_ level: Int) {
        withAnimation(.smooth(duration: 0.25)) { zoomLevel = level }
        crownPosition = Double(level)
        if level < 2 { selectedDrawing = nil }
        WKInterfaceDevice.current().play(.click)
    }

    private func open(_ drawing: CanvasExport) {
        focusedDrawing = drawing
        zoomLevel = 2
        crownPosition = 2
        WKInterfaceDevice.current().play(.click)
        selectedDrawing = drawing
    }

    private func fullscreenDrawing(_ drawing: CanvasExport, size: CGSize) -> some View {
        ZStack {
            Color.black
            if let image = UIImage(contentsOfFile: drawing.url.path) {
                let originalSize = CanvasExportStore.displaySize(for: drawing, image: image)
                Image(uiImage: image)
                    .resizable()
                    .frame(width: originalSize.width, height: originalSize.height)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private func deleteDrawing(_ drawing: CanvasExport) {
        do {
            try CanvasExportStore.delete(drawing)
            drawings.removeAll { $0.id == drawing.id }
            focusedDrawing = nil
            setZoom(1)
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
