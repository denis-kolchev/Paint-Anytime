import Combine
import SwiftUI

@MainActor
final class DrawingSessionController: ObservableObject {
    let canvas: CanvasController
    private var canvasChanges: AnyCancellable?
    private var autosavedDrawing: CanvasExport?
    @Published var isPreparingCanvas = false
    @Published var canvasPreparationError: String?
    @Published var canvasSessionID = UUID()
    @Published var savedDrawing: CanvasExport?
    @Published private(set) var autosaveNoticeID: UUID?
    @Published var pendingCanvasAction: PendingCanvasAction?
    @Published var exportError: String?
    /// Explicit Save in progress; shows the same loading overlay as opening from the gallery.
    @Published private(set) var isSavingDrawing = false
    private var savingStartedAt = ContinuousClock.now

    init(canvas: CanvasController? = nil) {
        self.canvas = canvas ?? CanvasController()
        canvasChanges = self.canvas.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// Explicit Save, step 1: show the gallery's loading overlay right away.
    /// Returns false when a save is already running.
    func beginSavingDrawing() -> Bool {
        guard !isSavingDrawing else { return false }
        canvas.cancelStroke()
        savingStartedAt = .now
        isSavingDrawing = true
        return true
    }

    /// Explicit Save, step 2: call after interface animations (the morph collapse)
    /// have finished. The exporter is synchronous on the main thread and would
    /// freeze any running animation. Toolbar-hosted morphs are not always tracked by
    /// animation completion, so also wait out the collapse spring from the tap.
    func completeSavingDrawing(size: CGSize, scale: CGFloat) {
        guard isSavingDrawing else { return }
        let earliest = savingStartedAt.advanced(by: .milliseconds(600))
        Task { @MainActor [weak self] in
            let minimum = ContinuousClock.now.advanced(by: .milliseconds(100))
            try? await Task.sleep(until: max(earliest, minimum), clock: .continuous)
            guard let self else { return }
            self.saveDrawing(size: size, scale: scale)
            self.isSavingDrawing = false
        }
    }

    func saveDrawing(size: CGSize, scale: CGFloat, automatically: Bool = false) {
        if automatically {
            // Autosave is periodic even when the previous tick marked this canvas saved.
            // Keep updating the same working copy until the user explicitly saves it.
            guard canvas.activeStroke == nil, canvas.canClear,
                  !isPreparingCanvas, !isSavingDrawing, pendingCanvasAction == nil,
                  savedDrawing == nil, exportError == nil else { return }
        }
        do {
            // A deleted autosave must not be recreated under a tombstoned filename.
            if let previous = autosavedDrawing,
               !FileManager.default.fileExists(atPath: previous.url.path) {
                autosavedDrawing = nil
            }
            let drawing = try CanvasExporter.save(
                document: canvas.document, size: size, scale: scale,
                replacing: autosavedDrawing)
            canvas.markSaved()
            GalleryFavoriteThumbnailRenderer.remove(drawing.url)
            Task { await GalleryImageCache.shared.remove(drawing.url) }
            NotificationCenter.default.post(name: .galleryDrawingSaved, object: drawing.url)
            _ = WatchPhotoTransfer.shared.queue(drawing.url, replacingPending: autosavedDrawing != nil)
            if automatically {
                autosavedDrawing = drawing
                autosaveNoticeID = UUID()
            } else {
                // Explicit Save finalizes this copy. Future autosaves get a new filename.
                autosavedDrawing = nil
                savedDrawing = drawing
            }
        } catch { exportError = error.localizedDescription }
    }

    func requestCanvasAction(_ action: PendingCanvasAction) {
        canvas.cancelStroke()
        if canvas.needsDiscardConfirmation {
            pendingCanvasAction = action
        } else {
            performCanvasAction(action)
        }
    }

    func performCanvasAction(_ action: PendingCanvasAction) {
        autosavedDrawing = nil
        switch action {
        case .clear:
            canvas.clear()
        case .open(let document):
            canvasPreparationError = nil
            isPreparingCanvas = true
            canvas.load(document)
            // Reset zoom, offset, and gesture state whenever a saved drawing opens.
            canvasSessionID = UUID()
        }
    }

    enum PendingCanvasAction: Identifiable {
        case clear
        case open(CanvasDocument)

        var id: Int {
            switch self {
            case .clear: 0
            case .open: 1
            }
        }

        var title: String {
            switch self {
            case .clear: L10n.text("Clear the canvas?")
            case .open: L10n.text("Discard the previous unsaved canvas?")
            }
        }
    }
}
