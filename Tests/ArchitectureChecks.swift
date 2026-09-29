import Combine
import Foundation

@main
struct ArchitectureChecks {
    @MainActor static func main() throws {
        let suite = "PaintArchitectureChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let canvas = CanvasController(defaults: defaults)
        var notifications = 0
        let subscription = canvas.objectWillChange.sink { notifications += 1 }
        canvas.pencilStyle.width = 17
        canvas.setSynchronizeWidth(true)
        canvas.selectInstrument(.eraser)
        precondition(canvas.pencilStyle.width == 17)
        precondition(notifications > 0, "Tool changes must reach canvas observers")
        canvas.flushStylePreferences()
        let restored = CanvasController(defaults: defaults)
        precondition(restored.pencilStyle == canvas.pencilStyle)
        precondition(restored.synchronization == canvas.synchronization)
        let tutorial = CanvasController(defaults: defaults, persistsPreferences: false)
        tutorial.pencilStyle.width = 23
        tutorial.flushStylePreferences()
        precondition(CanvasController(defaults: defaults).pencilStyle == canvas.pencilStyle)
        canvas.selectInstrument(.monoline)
        let start = PointerSample(position: SIMD2(10, 10), pressure: 1, timestamp: 0)
        let end = PointerSample(position: SIMD2(30, 30), pressure: 1, timestamp: 1)
        canvas.beginStroke(at: start)
        canvas.endStroke(at: end)
        precondition(canvas.document.strokes.count == 1 && canvas.canUndo)
        let document = canvas.document
        canvas.undo()
        precondition(canvas.document.strokes.isEmpty && canvas.canRedo)
        canvas.redo()
        precondition(canvas.document == document)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let drawing = try CanvasExportStore.save(document: document, imageData: Data([1, 2, 3]),
                                                name: "Paint-Anytime_2026-09-28", in: folder)
        let loaded = try CanvasExportStore.loadDocument(for: drawing)
        precondition(loaded == document)
        let all = try CanvasExportStore.all(in: folder)
        precondition(all.map { $0.id.resolvingSymlinksInPath() } == [drawing.id.resolvingSymlinksInPath()])
        try CanvasExportStore.delete(drawing, in: folder)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        precondition(remaining.isEmpty)
        withExtendedLifetime(subscription) {}
        print("Architecture checks passed: observation, preferences, tutorial isolation, undo/redo, document storage.")
    }
}
