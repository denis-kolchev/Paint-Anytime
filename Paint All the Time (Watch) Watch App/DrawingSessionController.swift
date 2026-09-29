import Combine
import SwiftUI

@MainActor
final class DrawingSessionController: ObservableObject {
    let canvas: CanvasController
    private var canvasChanges: AnyCancellable?
    @Published var canvasSessionID = UUID()
    @Published var savedDrawing: CanvasExport?
    @Published var pendingCanvasAction: PendingCanvasAction?
    @Published var photoTransferStatus = ""
    @Published var photoTransferCanRetry = false
    @Published var exportError: String?

    init(canvas: CanvasController? = nil) {
        self.canvas = canvas ?? CanvasController()
        canvasChanges = self.canvas.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func saveDrawing(size: CGSize, scale: CGFloat) {
        do {
            let drawing = try CanvasExporter.save(
                strokes: canvas.document.strokes, size: size, scale: scale)
            canvas.markSaved()
            let queued = WatchPhotoTransfer.shared.queue(drawing.url)
            photoTransferCanRetry = !queued
            photoTransferStatus = queued
                ? L10n.text("Your drawing is being sent to Photos on iPhone.")
                : L10n.text("Your drawing is saved on your watch. Open the iPhone app to send it to Photos.")
            savedDrawing = drawing
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
        switch action {
        case .clear:
            canvas.clear()
        case .open(let document):
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
