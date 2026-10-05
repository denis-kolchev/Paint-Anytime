import Combine
import Foundation

@main
struct ArchitectureChecks {
    @MainActor static func main() throws {
        try checkOpacity()
        try checkShapeHistory()
        let white = SIMD4<Float>(1, 1, 1, 1)
        var whiteStyle = PencilStyle()
        whiteStyle.color = white
        for version in ["1.0", "1.1.0", "2.0"] {
            precondition(AppReleaseFeatures(version: version).availableStyle(whiteStyle).color == white,
                         "White must remain selectable regardless of tool release restrictions")
        }
        for (version, enabled) in [("1", false), ("1.0", false), ("1.0.9", false),
                                   ("1.1", true), ("1.1.0", true), ("1.1.9", true), ("1.2", true),
                                   ("1.2.0", true),
                                   ("1.10", true), ("2.0", true), ("0.9", false)] {
            let features = AppReleaseFeatures(version: version)
            precondition(features.showsPhotoTransferControls == enabled, "Photo transfer threshold: \(version)")
            precondition(features.allows(.watercolor) == enabled, "Watercolor threshold: \(version)")
            let dryToolsEnabled = ["1.2", "1.2.0", "1.10", "2.0"].contains(version)
            for tool in [DrawingInstrument.pencil, .crayon] {
                precondition(features.allows(tool) == dryToolsEnabled, "Tool threshold: \(version), \(tool)")
                let restored = features.availableStyle(PencilStyle.initial(for: tool))
                precondition(restored.instrument == (dryToolsEnabled ? tool : .monoline),
                             "Saved tool must respect release availability: \(version), \(tool)")
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
        let strokeID = canvas.activeStroke!.id
        canvas.endStroke(at: end)
        precondition(canvas.document.strokes.first?.id == strokeID)
        precondition(canvas.document.strokes.count == 1 && canvas.canUndo)
        precondition(canvas.document.strokes.first?.style.color == white)
        // Legacy documents migrate IDs once; subsequent saves retain them.
        struct LegacyStroke: Encodable { let points: [PointerSample]; let style: PencilStyle }
        struct LegacyDocument: Encodable { let strokes: [LegacyStroke] }
        let legacy = LegacyDocument(strokes: [LegacyStroke(points: [start, end], style: whiteStyle),
                                              LegacyStroke(points: [start], style: whiteStyle)])
        let migrated = try JSONDecoder().decode(CanvasDocument.self, from: JSONEncoder().encode(legacy))
        precondition(Set(migrated.strokes.map(\.id)).count == 2)
        let roundTrip = try JSONDecoder().decode(CanvasDocument.self, from: JSONEncoder().encode(migrated))
        precondition(roundTrip == migrated)
        precondition(roundTrip.strokes.map(\.id) == migrated.strokes.map(\.id))
        let document = canvas.document
        canvas.undo()
        precondition(canvas.document.strokes.isEmpty && canvas.canRedo)
        canvas.redo()
        precondition(canvas.document == document)
        let revisions = CanvasController(defaults: defaults, persistsPreferences: false)
        revisions.selectInstrument(.monoline)
        let initialRevision = revisions.documentRevision
        let initialActive = revisions.activeStrokeRevision
        let initialGesture = revisions.activeStrokeID
        revisions.beginStroke(at: start)
        let firstGesture = revisions.activeStrokeID
        revisions.continueStroke(at: end)
        precondition(firstGesture != initialGesture && revisions.activeStrokeID == firstGesture,
                     "Gesture identity must remain stable while appending")
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
        precondition(revisions.activeStrokeID != firstGesture, "A new gesture needs a new coverage cache")
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
        let blendSuite = "BlendChecks.\(UUID().uuidString)"
        let blendDefaults = UserDefaults(suiteName: blendSuite)!
        defer { blendDefaults.removePersistentDomain(forName: blendSuite) }
        let blending = CanvasController(defaults: blendDefaults)
        precondition(blending.blendingMode == .hybrid)
        blending.selectInstrument(.marker)
        blending.beginStroke(at: start)
        blending.endStroke(at: end)
        blending.setBlendingMode(.multiply)
        precondition(blending.document.strokes[0].style.blendingMode == .hybrid)
        blending.beginStroke(at: start)
        blending.endStroke(at: end)
        precondition(blending.document.strokes[1].style.blendingMode == .multiply)
        blending.selectInstrument(.watercolor)
        precondition(blending.pencilStyle.blendingMode == .multiply)
        precondition(CanvasController(defaults: blendDefaults).blendingMode == .multiply)
        precondition(CanvasController(defaults: blendDefaults, persistsPreferences: false).blendingMode == .hybrid)
        let blendData = try JSONEncoder().encode(blending.document)
        let blendRoundTrip = try JSONDecoder().decode(CanvasDocument.self, from: blendData)
        precondition(blendRoundTrip == blending.document)
        let legacyStyle = try JSONDecoder().decode(PencilStyle.self, from: Data("{}".utf8))
        precondition(legacyStyle.blendingMode == .hybrid)
        withExtendedLifetime(subscription) {}
        print("Architecture checks passed: observation, preferences, tutorial isolation, undo/redo, document storage.")
    }
    @MainActor static func checkOpacity() throws {
        let suite = "OpacityChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let tools = CanvasController(defaults: defaults)
        precondition(tools.synchronization.opacity && tools.pencilStyle.opacity == 1)
        tools.pencilStyle.opacity = 0.35
        tools.selectInstrument(.marker)
        precondition(tools.pencilStyle.opacity == 0.35)
        tools.pencilStyle.color = SIMD4(1, 0, 0, 1)
        precondition(tools.pencilStyle.opacity == 0.35, "Color changes must preserve opacity")
        tools.selectInstrument(.eraser)
        precondition(tools.pencilStyle.effectiveOpacity == 1)
        tools.pencilStyle.width = 16
        tools.selectInstrument(.pen)
        precondition(tools.pencilStyle.opacity == 0.35, "Eraser must not overwrite shared opacity")
        tools.setSynchronizeOpacity(false)
        tools.pencilStyle.opacity = 0.8
        tools.selectInstrument(.marker)
        precondition(tools.pencilStyle.opacity == 0.35)
        tools.pencilStyle.opacity = 0.2
        tools.selectInstrument(.pen)
        precondition(tools.pencilStyle.opacity == 0.8, "Each tool must retain its own opacity")
        tools.flushStylePreferences()
        let restored = CanvasController(defaults: defaults)
        precondition(!restored.synchronization.opacity && restored.pencilStyle.opacity == 0.8)
        restored.selectInstrument(.marker)
        precondition(restored.pencilStyle.opacity == 0.2)
        restored.setSynchronizeOpacity(true)
        restored.selectInstrument(.pen)
        precondition(restored.pencilStyle.opacity == 0.2)
        restored.flushStylePreferences()
        precondition(CanvasController(defaults: defaults).synchronization.sharedOpacity == 0.2)
        let tutorial = CanvasController(defaults: defaults, persistsPreferences: false)
        tutorial.pencilStyle.opacity = 0.7
        tutorial.flushStylePreferences()
        precondition(CanvasController(defaults: defaults).pencilStyle.opacity == 0.2)
        let point = PointerSample(position: SIMD2(20, 20), pressure: 1, timestamp: 0)
        restored.beginStroke(at: point)
        restored.endStroke(at: point)
        restored.pencilStyle.opacity = 0.9
        precondition(restored.document.strokes[0].style.opacity == 0.2)
        let data = try JSONEncoder().encode(restored.document)
        let document = try JSONDecoder().decode(CanvasDocument.self, from: data)
        precondition(document == restored.document)
        let legacyStyle = try JSONDecoder().decode(PencilStyle.self, from: Data("{}".utf8))
        precondition(legacyStyle.opacity == 1)
        let legacyJSON = #"{"width":false,"color":false,"sharedWidth":17,"sharedColor":[1,0,0,1]}"#
        defaults.set(Data(legacyJSON.utf8), forKey: "drawing.synchronization.v1")
        let migrated = CanvasController(defaults: defaults).synchronization
        precondition(!migrated.width && !migrated.color && migrated.sharedWidth == 17)
        precondition(migrated.sharedColor == SIMD4(1, 0, 0, 1))
        precondition(migrated.opacity && migrated.sharedOpacity == 1,
                     "New opacity preference must not reset existing width/color preferences")
        for (raw, expected): (Float, Float) in [(-1, 0), (2, 1), (0.5, 0.5)] {
            let decoded = try JSONDecoder().decode(PencilStyle.self,
                from: Data("{\"opacity\":\(raw)}".utf8))
            precondition(decoded.opacity == expected)
        }
    }

    @MainActor private static func checkShapeHistory() throws {
        let suite = "PaintShapeHistoryChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let canvas = CanvasController(defaults: defaults, persistsPreferences: false)
        canvas.selectInstrument(.monoline)
        let points = (0...30).map { index in
            PointerSample(position: SIMD2<Float>(10 + Float(index) * 2, 40 + Float(index % 2) * 0.4),
                          pressure: 1, timestamp: Double(index) / 60)
        }
        canvas.beginStroke(at: points[0])
        points.dropFirst().forEach { canvas.continueStroke(at: $0) }
        let oldRevision = canvas.activeStrokeRevision
        precondition(canvas.recognizeActiveShape())
        precondition(canvas.isShapeSnapped && canvas.activeStrokeRevision > oldRevision)
        precondition(canvas.document.strokes.isEmpty, "Recognition must not commit the gesture early")
        canvas.endStroke(at: points.last!)
        let completed = canvas.document
        precondition(completed.strokes.count == 1 && canvas.canUndo)
        let encoded = try JSONEncoder().encode(completed)
        let decoded = try JSONDecoder().decode(CanvasDocument.self, from: encoded)
        precondition(decoded == completed)
        canvas.undo()
        precondition(canvas.document.strokes.isEmpty && !canvas.canUndo)
        canvas.redo()
        precondition(canvas.document == completed)
        canvas.beginStroke(at: points[0])
        points.dropFirst().forEach { canvas.continueStroke(at: $0) }
        precondition(canvas.recognizeActiveShape())
        canvas.cancelStroke()
        precondition(canvas.document == completed && !canvas.isShapeSnapped)
    }

}
