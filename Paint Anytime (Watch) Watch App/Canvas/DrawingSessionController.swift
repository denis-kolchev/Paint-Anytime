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
    /// The quiet autosave writing off the main thread, if any.
    private var autosaveTask: Task<Bool, Never>?
    /// Changes when the canvas is cleared, opened or explicitly saved, so a background
    /// save finishing later does not adopt the new canvas as its working copy.
    private var autosaveGeneration = 0

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
            // A quiet autosave may be writing the same file; let it finish first.
            _ = await self.autosaveTask?.value
            self.saveDrawing(size: size, scale: scale)
            self.isSavingDrawing = false
        }
    }

    func saveDrawing(size: CGSize, scale: CGFloat) {
        do {
            dropDeletedAutosave()
            let drawing = try CanvasExporter.save(
                document: canvas.document, size: size, scale: scale,
                replacing: autosavedDrawing)
            canvas.markSaved()
            didWrite(drawing, replacingPending: autosavedDrawing != nil)
            // Explicit Save finalizes this copy. Future autosaves get a new filename.
            autosaveGeneration += 1
            autosavedDrawing = nil
            savedDrawing = drawing
        } catch { exportError = error.localizedDescription }
    }

    /// Whether a quiet autosave can take a snapshot now: no stroke in progress and
    /// no canvas transition or save result waiting.
    var canAutosave: Bool {
        autosaveTask == nil && canvas.activeStroke == nil && canvas.canClear
            && !isPreparingCanvas && !isSavingDrawing && pendingCanvasAction == nil
            && savedDrawing == nil && exportError == nil
    }

    /// Autosave without blocking the canvas: the document is copied on the main actor,
    /// rendered and written in the background. The write continues when the wrist
    /// drops or the app leaves the foreground, and watchOS is asked for time to
    /// finish it. Returns true once the working copy was written.
    ///
    /// - Parameter onlyIfChanged: Skip when the canvas matches its last save
    ///   (used on wrist-down); timer ticks keep refreshing the working copy.
    @discardableResult
    func autosaveQuietly(size: CGSize, scale: CGFloat, onlyIfChanged: Bool = false) async -> Bool {
        guard canAutosave, !onlyIfChanged || canvas.hasUnsavedChanges else { return false }
        dropDeletedAutosave()
        let snapshot = canvas.document
        let previous = autosavedDrawing
        let generation = autosaveGeneration
        let now = Date()
        let name = previous.map(CanvasExporter.fileStem(of:)) ?? CanvasExporter.newFileStem(at: now)
        let info = CanvasExporter.ExportInfo.current(for: snapshot)
        let url: URL
        do {
            url = try CanvasExportStore.directory().appendingPathComponent(name).appendingPathExtension("png")
        } catch {
            exportError = error.localizedDescription
            return false
        }
        let work = Task.detached(priority: .utility) { () -> Result<CanvasExporter.EncodedDrawing, Error> in
            let activity = ExpiringActivity(reason: "Autosave drawing")
            defer { activity.end() }
            return Result {
                let encoded = try CanvasExporter.encode(document: snapshot, size: size, scale: scale,
                                                        name: name, info: info, at: now)
                try CanvasExportStore.write(document: encoded.document, imageData: encoded.png, to: url)
                return encoded
            }
        }
        let task = Task { @MainActor [weak self] () -> Bool in
            let result = await work.value
            guard let self else { return false }
            defer { self.autosaveTask = nil }
            switch result {
            case .failure(let error):
                self.exportError = error.localizedDescription
                return false
            case .success(let encoded):
                let drawing = CanvasExport(url: url)
                CanvasExportStore.refreshWidgets()
                GalleryPreviewStore.shared.store(image: encoded.image,
                                                 originalSize: encoded.document.canvasSize ?? size, for: url)
                self.didWrite(drawing, replacingPending: previous != nil)
                // The canvas was cleared, replaced or saved meanwhile: the file keeps the
                // earlier picture, but it is no longer this canvas's working copy.
                guard generation == self.autosaveGeneration else { return true }
                self.canvas.markSaved(snapshot)
                self.autosavedDrawing = drawing
                self.autosaveNoticeID = UUID()
                return true
            }
        }
        autosaveTask = task
        return await task.value
    }

    /// A deleted autosave must not be recreated under a tombstoned filename.
    private func dropDeletedAutosave() {
        if let previous = autosavedDrawing,
           !FileManager.default.fileExists(atPath: previous.url.path) {
            autosavedDrawing = nil
        }
    }

    private func didWrite(_ drawing: CanvasExport, replacingPending: Bool) {
        GalleryFavoriteThumbnailRenderer.remove(drawing.url)
        Task { await GalleryImageCache.shared.remove(drawing.url) }
        NotificationCenter.default.post(name: .galleryDrawingSaved, object: drawing.url)
        _ = WatchPhotoTransfer.shared.queue(drawing.url, replacingPending: replacingPending)
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
        autosaveGeneration += 1
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

/// Asks watchOS for time to finish a background write when the app leaves the
/// foreground. The work itself is never interrupted; on expiry the request just ends.
private nonisolated final class ExpiringActivity: @unchecked Sendable {
    private let finished = DispatchSemaphore(value: 0)

    init(reason: String) {
        ProcessInfo.processInfo.performExpiringActivity(withReason: reason) { [finished] expired in
            // The first call holds the assertion until the work ends; an expiry call
            // releases it so the system can suspend the app.
            if expired { finished.signal() } else { finished.wait() }
        }
    }

    func end() { finished.signal() }
}
