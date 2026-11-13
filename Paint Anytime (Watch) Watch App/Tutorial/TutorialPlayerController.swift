import Combine
import Foundation
import CoreGraphics

@MainActor
final class TutorialPlayerController: ObservableObject {
    /// Canvas setting pages are the tutorial's own, like the layer pages: the menu's
    /// NavigationStack is nested in the host's, so its links would push over the whole lesson.
    enum Page {
        case canvas, tools, menu, gallery, layers, layerSettings, canvasSettings, canvasSize, perspective, crop
        case drawingSettings, colorBlending
    }

    let tutorial = TutorialSession()
    let lasso = WatchLassoController()
    let canvas = CanvasController(persistsPreferences: false)
    /// Practice guides in a disposable domain, so the lesson never changes the editor's guides.
    let guides: PerspectiveGuides
    @Published private(set) var page: Page = .canvas
    @Published private(set) var savedDrawing: CanvasExport?
    /// Bumped on every tutorial save so the view can show the saved notice on the canvas.
    @Published private(set) var saveRevision = 0
    @Published var confirmsClear = false
    @Published private(set) var saveError: String?
    @Published private(set) var editedLayerID: UUID?
    /// The lesson draws or erases on the canvas itself; the user's input waits.
    @Published private(set) var isDemonstrating = false
    private var demonstration: Task<Void, Never>?
    /// Identifies the running demonstration, so a cancelled one never unlocks input early.
    private var demonstrationID = UUID()
    private var didConfirmClear = false
    private let folder: URL
    private let chapters: [TutorialChapter]
    private var initialStyle = PencilStyle()
    private var subscriptions: Set<AnyCancellable> = []

    private static let guidesSuite = "PaintAnytimeTutorial.perspectiveGuides"

    init(folder: URL, chapters: [TutorialChapter] = TutorialChapter.allCases) {
        self.folder = folder
        self.chapters = chapters
        // Never nil: the name is neither the app's bundle identifier nor the global domain.
        let guideDefaults = UserDefaults(suiteName: Self.guidesSuite)!
        guideDefaults.removePersistentDomain(forName: Self.guidesSuite)
        guides = PerspectiveGuides(defaults: guideDefaults)
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
        stopDemonstration()
        tutorial.markerLineStrokeID = nil
        canvas.cancelStroke()
        lasso.deactivate()
        canvas.clear()
        // A blending lesson must not carry its mode into later chapters.
        canvas.setBlendingMode(initialStyle.blendingMode)
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
    func openCanvasSettings() {
        guard page == .menu, tutorial.permits([.openCanvasSettings]) else { return }
        page = .canvasSettings
        tutorial.record(.openedCanvasSettings)
    }
    func openPerspective() {
        guard page == .canvasSettings, tutorial.permits([.openPerspective]) else { return }
        page = .perspective
        tutorial.record(.openedPerspective)
    }
    func openCanvasSize() {
        guard page == .canvasSettings, tutorial.permits([.openCanvasSize]) else { return }
        page = .canvasSize
        tutorial.record(.openedCanvasSize)
    }
    func openCrop() {
        guard page == .canvasSize, tutorial.permits([.openCrop]) else { return }
        page = .crop
        tutorial.record(.openedCrop)
    }
    func openDrawingSettings() {
        guard page == .menu, tutorial.permits([.openDrawingSettings]) else { return }
        page = .drawingSettings
        tutorial.record(.openedDrawingSettings)
    }
    func openColorBlending() {
        guard page == .drawingSettings, tutorial.permits([.openColorBlending]) else { return }
        page = .colorBlending
        tutorial.record(.openedColorBlending)
    }

    /// Setting lessons leave their pages once the setting is applied.
    func returnToCanvasAfterSetting() {
        guard [.menu, .canvasSettings, .perspective, .canvasSize, .crop,
               .drawingSettings, .colorBlending].contains(page),
              tutorial.teachesPerspective || tutorial.teachesCrop || tutorial.teachesBlending,
              [.perspectiveStroke, .history, .redrawMarkerLine].contains(tutorial.step) else { return }
        page = .canvas
    }

    /// Clears the canvas, draws a yellow marker line as if by hand, then hands the
    /// user a light blue marker that builds up color over it.
    func demonstrateMarkerLine(viewportSize: CGSize, reduceMotion: Bool) {
        stopDemonstration()
        isDemonstrating = true
        canvas.cancelStroke()
        lasso.deactivate()
        canvas.clear()
        canvas.setBlendingMode(.hybrid)
        var yellow = PencilStyle.initial(for: .marker)
        yellow.width = 20
        yellow.opacity = 1
        yellow.blendingMode = .hybrid
        canvas.pencilStyle = yellow
        let lineStyle = yellow
        let id = demonstrationID
        demonstration = Task { [weak self] in
            guard let self else { return }
            defer { if demonstrationID == id { isDemonstrating = false } }
            do {
                // Let the cleared paper settle before the line appears.
                try await Task.sleep(for: .milliseconds(reduceMotion ? 200 : 600))
                let paper = canvas.document.size(fallback: viewportSize)
                let steps = 36
                var time = Date().timeIntervalSinceReferenceDate
                for index in 0...steps {
                    try Task.checkCancellation()
                    let t = Float(index) / Float(steps)
                    // A gentle wave above the lesson card, wide enough to cross easily.
                    let position = SIMD2(Float(paper.width) * (0.14 + 0.72 * t),
                                         Float(paper.height) * (0.36 + 0.04 * sin(t * 2 * .pi)))
                    let sample = PointerSample(position: position, pressure: 1, timestamp: time)
                    switch index {
                    case 0: canvas.beginStroke(at: sample)
                    case steps: canvas.endStroke(at: sample)
                    default: canvas.continueStroke(at: sample)
                    }
                    time += 1.0 / 30
                    if !reduceMotion && index < steps { try await Task.sleep(for: .milliseconds(33)) }
                }
            } catch {
                if demonstrationID == id { canvas.cancelStroke() }
                return
            }
            tutorial.markerLineStrokeID = canvas.selectedLayer.strokes.last?.id
            var blue = lineStyle
            blue.color = InkPreset.all.first { $0.nameKey == "Light blue" }?.rgba ?? SIMD4(0.15, 0.7, 0.9, 1)
            canvas.pencilStyle = blue
        }
    }

    /// Back on the canvas, the user's strokes are removed from the yellow line in view,
    /// so it can be crossed again with the new blending mode.
    func removeUserMarkerStrokes(reduceMotion: Bool) {
        stopDemonstration()
        isDemonstrating = true
        let id = demonstrationID
        demonstration = Task { [weak self] in
            guard let self else { return }
            defer { if demonstrationID == id { isDemonstrating = false } }
            // Wait until the page has returned, so the strokes disappear in view.
            do { try await Task.sleep(for: .milliseconds(reduceMotion ? 300 : 800)) } catch { return }
            let layer = canvas.selectedLayer
            let lineID = tutorial.markerLineStrokeID
            let kept = layer.strokes.filter { $0.id == lineID }
            guard !kept.isEmpty else { return }
            canvas.replaceLayerStrokes(kept, in: layer.id, animatesClear: true)
        }
    }

    private func stopDemonstration() {
        demonstration?.cancel()
        demonstration = nil
        demonstrationID = UUID()
        isDemonstrating = false
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
            saveRevision += 1
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
