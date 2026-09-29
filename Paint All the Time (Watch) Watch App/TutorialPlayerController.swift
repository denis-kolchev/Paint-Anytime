import Combine
import Foundation
import CoreGraphics

@MainActor
final class TutorialPlayerController: ObservableObject {
    enum Page { case canvas, tools, saved, menu, gallery }

    let tutorial = TutorialSession()
    let canvas = CanvasController(persistsPreferences: false)
    @Published private(set) var page: Page = .canvas
    @Published private(set) var savedDrawing: CanvasExport?
    @Published var confirmsClear = false
    @Published private(set) var saveError: String?
    private var didConfirmClear = false
    private let folder: URL
    private var subscriptions: Set<AnyCancellable> = []

    init(folder: URL) {
        self.folder = folder
        // The view observes this controller; nested objects still drive all UI updates.
        tutorial.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        canvas.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
    }

    func startOrResume() {
        if !tutorial.isActive {
            // Carry the taught color and width into the new brush without changing user preferences.
            canvas.setSynchronizeWidth(true)
            canvas.setSynchronizeColor(true)
            tutorial.start()
        } else { tutorial.resumeReminders() }
    }

    func setActive(_ active: Bool) {
        if active { tutorial.resumeReminders() }
        else { tutorial.pauseReminders(); canvas.cancelStroke() }
    }

    func openTools() { page = .tools; tutorial.record(.openedTools) }
    func closeTools() { page = .canvas; tutorial.record(.closedTools) }
    func openMenu() { page = .menu; tutorial.activity() }
    func openGallery() { page = .gallery; tutorial.record(.openedGallery) }
    func closeGallery() { page = .canvas; tutorial.record(.returnedToCanvas) }
    func closeSavedDrawing() { page = .canvas; tutorial.record(.closedSave) }
    func undo() { canvas.undo(); tutorial.record(.history) }
    func redo() { canvas.redo(); tutorial.record(.history) }

    func requestClear() {
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
        canvas.clear()
        tutorial.record(.cleared)
    }

    func save(size: CGSize, scale: CGFloat) {
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

    func dismissSaveError() {
        saveError = nil
        tutorial.resumeReminders()
    }
}
