import SwiftUI

struct ContentView: View {
    @StateObject private var controller = CanvasController()
    @State private var showsToolSettings = false
    @State private var isMovingCanvas = false
    @State private var showsAppSettings = false
    @State private var showsGallery = false
    @State private var canvasSize: CGSize = .zero
    @State private var savedDrawing: CanvasExport?
    @State private var photoTransferStatus = ""
    @State private var photoTransferCanRetry = false
    @State private var exportError: String?
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        NavigationStack {
        GeometryReader { geometry in
            ZStack {
                Color.black

                drawingPage
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .background(.white)
                    .opacity(showsToolSettings || showsGallery ? 0 : 1)
                    .allowsHitTesting(!showsToolSettings && !showsGallery)
                    .accessibilityHidden(showsToolSettings)
                    .zIndex(0)

                if showsGallery {
                    SavedDrawingsView(onClose: { showsGallery = false }) { document in
                        controller.load(document)
                        isMovingCanvas = false
                        showsToolSettings = false
                        showsGallery = false
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .zIndex(2)
                }

                if showsToolSettings {
                    WatchToolSettingsView(controller: controller) {
                        showsToolSettings = false
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .background(.black)
                    .transition(.identity)
                    .zIndex(1)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .onAppear { canvasSize = geometry.size }
            .onChange(of: geometry.size) { _, size in canvasSize = size }
        }
        // Establish full-screen bounds before applying any presentation effects.
        .ignoresSafeArea()
        .toolbar {
            if !showsGallery && !showsToolSettings && !isMovingCanvas && controller.activeStroke == nil {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button(role: .destructive) { controller.clear() } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Очистить холст")
                    Spacer(minLength: 0)
                    Button { controller.undo() } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .disabled(!controller.canUndo)
                    .accessibilityLabel("Отменить")
                    Spacer(minLength: 0)
                    Button { controller.redo() } label: {
                        Image(systemName: "arrow.uturn.forward")
                    }
                    .disabled(!controller.canRedo)
                    .accessibilityLabel("Повторить")
                    Spacer(minLength: 0)
                    Button {
                        do {
                            let drawing = try CanvasExportStore.save(
                                strokes: controller.document.strokes, size: canvasSize, scale: displayScale)
                            let queued = WatchPhotoTransfer.shared.queue(drawing.url)
                            photoTransferCanRetry = !queued
                            photoTransferStatus = queued
                                ? "Рисунок отправляется в Фото на iPhone."
                                : "Рисунок сохранён на часах. Для отправки в Фото откройте приложение на iPhone."
                            savedDrawing = drawing
                        } catch { exportError = error.localizedDescription }
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .accessibilityLabel("Сохранить рисунок")
                }
            }

            if !showsGallery && showsToolSettings {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showsToolSettings = false
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.automatic)
                    .accessibilityLabel("Закрыть настройки")
                }
            } else if !showsGallery && !isMovingCanvas && controller.activeStroke == nil {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        controller.cancelStroke()
                        showsAppSettings = true
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .buttonStyle(.automatic)
                    .accessibilityLabel("Дополнительно")
                }
            }
            if !showsGallery && (showsToolSettings || controller.activeStroke == nil) {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    controller.cancelStroke()
                    if isMovingCanvas { isMovingCanvas = false }
                    else { showsToolSettings.toggle() }
                } label: {
                    Group {
                        if showsToolSettings || isMovingCanvas {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.green)
                        } else {
                            ToolIcon(instrument: controller.pencilStyle.instrument)
                                .frame(width: 18, height: 18)
                        }
                    }
                }
                .buttonStyle(.automatic)
                .accessibilityLabel(showsToolSettings || isMovingCanvas ? "Готово" : "Настройки инструмента")
            }
            }
        }
        }
        .sheet(isPresented: $showsAppSettings) {
            WatchAppSettingsView(controller: controller) {
                showsAppSettings = false
                showsGallery = true
            }
        }
        .sheet(item: $savedDrawing) { drawing in
            NavigationStack {
                SavedDrawingView(drawing: drawing, photoTransferStatus: photoTransferStatus,
                                 canRetryPhotoTransfer: photoTransferCanRetry)
            }
        }
        .alert("Не удалось сохранить", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } }
        )) {
            Button("ОК", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { controller.cancelStroke() }
        }
    }

    private var drawingPage: some View {
        WatchCanvasView(controller: controller, acceptsInput: !showsToolSettings && !showsAppSettings && !showsGallery && savedDrawing == nil, isMovingCanvas: $isMovingCanvas)
    }
}
