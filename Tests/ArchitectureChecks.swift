import Combine
import Foundation

@main
struct ArchitectureChecks {
    @MainActor static func main() throws {
        let white = SIMD4<Float>(1, 1, 1, 1)
        var whiteStyle = PencilStyle()
        whiteStyle.color = white
        for version in ["1.0", "1.1.0", "2.0"] {
            precondition(AppReleaseFeatures(version: version).availableStyle(whiteStyle).color == white,
                         "White must remain selectable regardless of tool release restrictions")
        }
        for (version, enabled) in [("1", false), ("1.0", false), ("1.0.9", false),
                                   ("1.1", true), ("1.1.0", true), ("1.2", true),
                                   ("1.10", true), ("2.0", true), ("0.9", false)] {
            let features = AppReleaseFeatures(version: version)
            precondition(features.showsPhotoTransferControls == enabled, "Photo transfer threshold: \(version)")
            for tool in [DrawingInstrument.pencil, .crayon, .watercolor] {
                precondition(features.allows(tool) == enabled, "Tool threshold: \(version), \(tool)")
            }
            precondition(features.allows(.monoline) && features.allows(.eraser))
        }
        let suite = "PaintArchitectureChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let canvas = CanvasController(defaults: defaults)
        var notifications = 0
        let subscription = canvas.objectWillChange.sink { notifications += 1 }
        canvas.pencilStyle.color = white
        canvas.setSynchronizeColor(true)
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
        precondition(canvas.pencilStyle.color == white, "White must survive tool switching and synchronization")
        let start = PointerSample(position: SIMD2(10, 10), pressure: 1, timestamp: 0)
        let end = PointerSample(position: SIMD2(30, 30), pressure: 1, timestamp: 1)
        canvas.beginStroke(at: start)
        canvas.endStroke(at: end)
        precondition(canvas.document.strokes.count == 1 && canvas.canUndo)
        precondition(canvas.document.strokes.first?.style.color == white)
        let document = canvas.document
        canvas.undo()
        precondition(canvas.document.strokes.isEmpty && canvas.canRedo)
        canvas.redo()
        precondition(canvas.document == document)
        let revisions = CanvasController(defaults: defaults, persistsPreferences: false)
        revisions.selectInstrument(.monoline)
        let initialRevision = revisions.documentRevision
        let initialActive = revisions.activeStrokeRevision
        revisions.beginStroke(at: start)
        revisions.continueStroke(at: end)
        precondition(revisions.documentRevision == initialRevision,
                     "Active drawing must not invalidate committed artwork")
        precondition(revisions.activeStrokeRevision > initialActive)
        revisions.endStroke(at: end)
        precondition(revisions.documentRevision > initialRevision)
        func checkDocumentRevision(_ action: () -> Void) {
            let before = revisions.documentRevision
            action()
            precondition(revisions.documentRevision > before, "Committed mutation must invalidate cache")
        }
        checkDocumentRevision { revisions.undo() }
        checkDocumentRevision { revisions.redo() }
        let unchanged = revisions.documentRevision
        revisions.markSaved()
        revisions.pencilStyle.width = 20
        revisions.beginStroke(at: start)
        let activeBeforeCancel = revisions.activeStrokeRevision
        revisions.cancelStroke()
        precondition(revisions.documentRevision == unchanged)
        precondition(revisions.activeStrokeRevision > activeBeforeCancel)
        checkDocumentRevision { revisions.load(document) }
        revisions.selectInstrument(.eraser)
        revisions.pencilStyle.eraserMode = .objects
        let far = PointerSample(position: SIMD2(500, 500), pressure: 1, timestamp: 2)
        let beforeMiss = revisions.documentRevision
        revisions.beginStroke(at: far)
        revisions.continueStroke(at: far)
        precondition(revisions.documentRevision == beforeMiss, "Object eraser misses must reuse the cache")
        checkDocumentRevision { revisions.continueStroke(at: start) }
        checkDocumentRevision { revisions.cancelStroke() }
        precondition(revisions.document == document, "Cancel object erasing must restore the document")
        checkDocumentRevision { revisions.clear() }
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
