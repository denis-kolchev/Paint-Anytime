import Combine
import Foundation
import CoreGraphics

@MainActor
final class TutorialPlayerController: ObservableObject {
    enum Page { case canvas, tools, saved, menu, gallery, layers, layerSettings }

    let tutorial = TutorialSession()
    let lasso = WatchLassoController()
    let canvas = CanvasController(persistsPreferences: false)
    @Published private(set) var page: Page = .canvas
    @Published private(set) var savedDrawing: CanvasExport?
    @Published var confirmsClear = false
    @Published private(set) var saveError: String?
    @Published private(set) var editedLayerID: UUID?
    private var didConfirmClear = false
    private let folder: URL
    private let chapters: [TutorialChapter]
    private var initialStyle = PencilStyle()
    private var subscriptions: Set<AnyCancellable> = []

    init(folder: URL, chapters: [TutorialChapter] = TutorialChapter.allCases) {
        self.folder = folder
        self.chapters = chapters
        // The view observes this controller; nested objects still drive all UI updates.
        tutorial.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        lasso.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        canvas.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        // Read on demand; retaining a copy would make every stroke commit copy the layers.
        tutorial.canvasDocument = { [weak canvas = self.canvas] in canvas?.document }
    }

    func startOrResume() {
        if !tutorial.isActive {
            // Carry the taught color, width, and opacity into the new brush without changing user preferences.
            canvas.setSynchronizeWidth(true)
            canvas.setSynchronizeColor(true)
            canvas.setSynchronizeOpacity(true)
            initialStyle = canvas.pencilStyle
            tutorial.start(chapters: chapters)
        } else { tutorial.resumeReminders() }
    }

    func setActive(_ active: Bool) {
        if active { tutorial.resumeReminders() }
        else { tutorial.pauseReminders(); canvas.cancelStroke() }
    }

    /// Chapters stay independent: each one starts on a clean canvas with the default brush.
    func beginChapter() {
        canvas.cancelStroke()
        lasso.deactivate()
        canvas.clear()
        canvas.pencilStyle = initialStyle
        page = .canvas
    }

    func openLasso() {
        guard page == .canvas, tutorial.permits([.openLasso]) else { return }
        canvas.cancelStroke()
        lasso.setMode(.area)
        lasso.activate()
        tutorial.record(.openedLasso)
    }

    func finishLasso() {
        guard page == .canvas, tutorial.permits([.finishLasso]) else { return }
        lasso.deactivate()
        tutorial.record(.finishedLasso)
    }

    func openTools() {
        guard page == .canvas, tutorial.permits([.openTools]) else { return }
        canvas.cancelStroke()
        page = .tools
        tutorial.record(.openedTools)
    }
    func openLayers() {
        guard page == .canvas, tutorial.permits([.openLayers]) else { return }
        canvas.cancelStroke()
        page = .layers
        tutorial.record(.openedLayers)
    }
    func openLayerSettings(_ id: UUID) {
        guard page == .layers, tutorial.permits([.openLayerSettings]) else { return }
        editedLayerID = id
        page = .layerSettings
        tutorial.record(.openedLayerSettings)
    }
    func closeLayerSettings() {
        guard page == .layerSettings, tutorial.permits([.closeLayerSettings]) else { return }
        page = .layers
        tutorial.record(.closedLayerSettings)
    }
    func closeLayers() {
        guard page == .layers, tutorial.permits([.closeLayers]) else { return }
        page = .canvas
        tutorial.record(.closedLayers)
    }
    func closeTools() {
        guard page == .tools, tutorial.permits([.closeTools]) else { return }
        page = .canvas
        tutorial.record(.closedTools)
    }
    func openMenu() {
        guard page == .canvas, tutorial.permits([.openMenu]) else { return }
        canvas.cancelStroke()
        page = .menu
        tutorial.record(.openedMenu)
    }
    func openGallery() { page = .gallery; tutorial.galleryIsOpen = true; tutorial.record(.openedGallery) }
    func closeGallery() {
        tutorial.galleryIsOpen = false
        tutorial.galleryIsFullscreen = false
        if tutorial.step == .returnToCanvas {
            page = .canvas
            tutorial.record(.returnedToCanvas)
        } else {
            page = .menu
        }
    }
    func closeSavedDrawing() {
        guard page == .saved, tutorial.permits([.shareDrawing]) else { return }
        page = .canvas
        tutorial.record(.closedSave)
    }
    func undo() {
        guard page == .canvas, tutorial.permits([.history]), canvas.canUndo else { return }
        canvas.undo()
        tutorial.record(.history)
    }
    func redo() {
        guard page == .canvas, tutorial.permits([.history]), canvas.canRedo else { return }
        canvas.redo()
        tutorial.record(.history)
    }

    func requestClear() {
        guard page == .canvas, tutorial.permits([.clearCanvas]) else { return }
        tutorial.pauseReminders()
        confirmsClear = true
    }

    func confirmClear() {
        didConfirmClear = true
        confirmsClear = false
    }

    func didDismissClearConfirmation() {
        tutorial.resumeReminders()
        guard didConfirmClear else { return }
        didConfirmClear = false
        guard preserveDrawing() else { return }
        canvas.clear()
        tutorial.record(.cleared)
    }

    func save(size: CGSize, scale: CGFloat) {
        guard page == .canvas, tutorial.permits([.saveDrawing]) else { return }
        do {
            savedDrawing = try CanvasExporter.save(strokes: canvas.document.strokes,
                                                  size: size, scale: scale, in: folder)
            canvas.markSaved()
            // Training never queues files to the real iPhone photo library.
            page = .saved
            tutorial.record(.saved)
        } catch {
            tutorial.pauseReminders()
            saveError = error.localizedDescription
        }
    }

    /// Keep only the user's saved artwork; deleted work and bundled practice pictures stay out.
    @discardableResult
    func preserveDrawing() -> Bool {
        guard let drawing = savedDrawing,
              FileManager.default.fileExists(atPath: drawing.url.path) else { return true }
        do {
            let document = try CanvasExportStore.loadDocument(for: drawing)
            let image = try Data(contentsOf: drawing.url)
            _ = try CanvasExportStore.save(document: document, imageData: image,
                                           name: drawing.url.deletingPathExtension().lastPathComponent)
            return true
        } catch {
            tutorial.pauseReminders()
            saveError = error.localizedDescription
            return false
        }
    }

    func dismissSaveError() {
        saveError = nil
        tutorial.resumeReminders()
    }
}
