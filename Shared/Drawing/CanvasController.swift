import Combine
import CoreGraphics
import Foundation

/// Publishes live-stroke samples without invalidating every observer of the canvas.
final class LiveStrokeChanges: ObservableObject {}

final class CanvasController: ObservableObject {
    let tools: ToolSettings
    private var toolChanges: AnyCancellable?
    var pencilStyle: PencilStyle {
        get { tools.pencilStyle }
        set { tools.pencilStyle = newValue }
    }
    var synchronization: ToolSynchronization { tools.synchronization }
    var blendingMode: ColorBlendingMode { tools.blendingMode }
    func setBlendingMode(_ mode: ColorBlendingMode) { tools.setBlendingMode(mode) }
    var maximumWidth: Float { tools.maximumWidth }
    func selectInstrument(_ instrument: DrawingInstrument) { tools.selectInstrument(instrument) }
    func style(for instrument: DrawingInstrument) -> PencilStyle { tools.style(for: instrument) }
    func toggleEraser() { tools.toggleEraser() }
    var drawingColor: SIMD4<Float> { tools.drawingColor }
    func setDrawingColor(_ color: SIMD4<Float>) { tools.setDrawingColor(color) }
    func setSynchronizeWidth(_ enabled: Bool) { tools.setSynchronizeWidth(enabled) }
    func setSynchronizeColor(_ enabled: Bool) { tools.setSynchronizeColor(enabled) }
    func setSynchronizeOpacity(_ enabled: Bool) { tools.setSynchronizeOpacity(enabled) }
    func flushStylePreferences() { tools.flushStylePreferences() }

    // Revisions make raster invalidation independent of the number of saved points.
    private(set) var documentRevision: UInt64 = 0
    /// The revision the raster view cross-fades into from its previous frame:
    /// clearing, and changes to the paper's color or visibility.
    private(set) var clearDocumentRevision: UInt64?
    private(set) var activeStrokeRevision: UInt64 = 0
    private(set) var activeStrokeID: UInt64 = 0
    private(set) var document = CanvasDocument() {
        didSet {
            documentRevision &+= 1
            noteActivity()
        }
    }
    /// The drawing's metadata, kept out of `document` so Undo/Redo never rewinds it.
    /// Edits to the document update it; `documentForSaving()` attaches it.
    private(set) var metadata = ProjectMetadata()
    private var savedEditableMetadata = ProjectMetadata().editableFields
    /// Edits closer together than this count as continuous work; a longer pause counts as this much.
    static let idleGap: TimeInterval = 30
    private var lastActivity: ContinuousClock.Instant?
    private var transparencyLockCache: (revision: UInt64, value: Bool)?
    /// Whether any committed stroke clips to transparency. Scans every stroke once
    /// per document revision instead of on every view update.
    var containsTransparencyLockedStrokes: Bool {
        if let cache = transparencyLockCache, cache.revision == documentRevision { return cache.value }
        let value = document.layers.contains { layer in layer.strokes.contains { $0.locksTransparency } }
        transparencyLockCache = (documentRevision, value)
        return value
    }
    private var savedDocument = CanvasDocument()
    var hasUnsavedChanges: Bool {
        document != savedDocument || metadata.editableFields != savedEditableMetadata
    }
    // Clearing can differ from the saved snapshot, but leaves nothing to discard.
    // Use the same empty-canvas condition as the Clear button.
    var needsDiscardConfirmation: Bool { canClear && hasUnsavedChanges }
    private let pencil = PencilTool()
    private var documentBeforeErasing: CanvasDocument?
    private var documentAtStrokeStart: CanvasDocument?
    private var strokeBeforeRecognition: Stroke?
    private var undoStack: [CanvasDocument] = []
    private var redoStack: [CanvasDocument] = []
    /// Estimated bytes `undoStack[i]` keeps beyond `undoStack[i + 1]`; one shorter than the stack.
    private var undoCosts: [Int] = []
    private var undoBytes = 0
    let historyLimit = 256
    /// The byte budget never trims history below this many steps.
    let minimumHistory = 30
    private let historyByteBudget = 24 * 1024 * 1024
    var undoCount: Int { undoStack.count }
    var canClear: Bool {
        document.layers.count != 1
            || document.layers.first.map { $0 != CanvasLayer(id: $0.id) } == true
            || document.backgroundColor != SIMD4<Float>(1, 1, 1, 1)
            || !document.backgroundIsVisible
    }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var onNeedsDisplay: (() -> Void)?
    /// Fires for every appended live-stroke sample, separately from `objectWillChange`.
    let liveStroke = LiveStrokeChanges()

    init(defaults: UserDefaults = .standard, persistsPreferences: Bool = true) {
        savedDocument = document
        tools = ToolSettings(defaults: defaults, persistsPreferences: persistsPreferences)
        toolChanges = tools.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    @Published private(set) var selectedLayerID: UUID?
    var selectedLayerIndex: Int { document.layers.firstIndex { $0.id == selectedLayerID } ?? 0 }
    var selectedLayer: CanvasLayer { document.layers[selectedLayerIndex] }
    var activeStroke: Stroke? {
        guard var stroke = pencil.activeStroke else { return nil }
        stroke.locksTransparency = selectedLayer.locksTransparency
        return stroke
    }

    func selectLayer(_ id: UUID) {
        cancelStroke()
        selectedLayerID = id
    }

    private func editLayers(_ edit: (inout CanvasDocument) -> Void) {
        cancelStroke()
        recordUndo(document)
        edit(&document)
        onNeedsDisplay?()
    }

    func addLayer() {
        let usedNumbers = document.layers.compactMap { Int($0.name.replacingOccurrences(of: "Layer ", with: "")) }
        let layer = CanvasLayer(name: "Layer \((usedNumbers.max() ?? 0) + 1)")
        let index = selectedLayerIndex + 1
        editLayers { $0.layers.insert(layer, at: index) }
        selectedLayerID = layer.id
    }

    func deleteLayer(_ id: UUID) {
        guard document.layers.count > 1, document.layers.contains(where: { $0.id == id }) else { return }
        editLayers {
            $0.layers.removeAll { $0.id == id }
            if $0.layers.isEmpty { $0.layers = [CanvasLayer()] }
        }
        if selectedLayerID == id { selectedLayerID = document.layers.last?.id }
    }

    func moveLayer(_ id: UUID, to target: UUID) {
        guard let from = document.layers.firstIndex(where: { $0.id == id }),
              let to = document.layers.firstIndex(where: { $0.id == target }), from != to else { return }
        editLayers {
            let layer = $0.layers.remove(at: from)
            $0.layers.insert(layer, at: to)
        }
    }

    func updateLayer(_ id: UUID, _ edit: (inout CanvasLayer) -> Void) {
        guard let index = document.layers.firstIndex(where: { $0.id == id }) else { return }
        editLayers { edit(&$0.layers[index]) }
    }

    /// A complete selection drag is one undoable edit, independent of preview frames.
    func replaceLayerStrokes(_ strokes: [Stroke], in layerID: UUID, animatesClear: Bool = false) {
        guard let index = document.layers.firstIndex(where: { $0.id == layerID }),
              document.layers[index].strokes != strokes else { return }
        editLayers { $0.layers[index].strokes = strokes }
        // The raster view cross-fades from its previous frame, as a full clear does.
        if animatesClear { clearDocumentRevision = documentRevision }
    }

    /// Transfers a prepared selection (including area cutouts) as one history edit.
    func moveSelection(strokes: [Stroke], selectedIDs: Set<UUID>, from sourceID: UUID, to targetID: UUID) {
        guard sourceID != targetID,
              let source = document.layers.firstIndex(where: { $0.id == sourceID }),
              let target = document.layers.firstIndex(where: { $0.id == targetID }) else { return }
        let moved = strokes.filter { selectedIDs.contains($0.id) }
        guard !moved.isEmpty else { return }
        editLayers {
            $0.layers[source].strokes = strokes.filter { !selectedIDs.contains($0.id) }
            $0.layers[target].strokes.append(contentsOf: moved)
        }
        selectedLayerID = targetID
    }

    func setBackgroundColor(_ color: SIMD4<Float>) {
        editLayers { $0.backgroundColor = color }
        // The paper tints the interface behind menus; fade it instead of cutting.
        clearDocumentRevision = documentRevision
    }
    func setBackgroundVisible(_ visible: Bool) {
        editLayers { $0.backgroundIsVisible = visible }
        clearDocumentRevision = documentRevision
    }

    /// Geometry stays editable; the complete document participates in history.
    /// The canvas turns clockwise by `quarterTurns` first; `origin` and resampling then
    /// apply to the turned canvas, so one change can rotate, resize and place the drawing.
    func adjustCanvas(from oldSize: CGSize, to newSize: CGSize, resample: Bool,
                      origin: CGPoint = .zero, quarterTurns: Int = 0, resolution: Double? = nil) {
        guard oldSize.width > 0, oldSize.height > 0,
              newSize.width.isFinite, newSize.height.isFinite,
              newSize.width > 0, newSize.height > 0, newSize.width <= 2048, newSize.height <= 2048,
              resolution == nil || (resolution!.isFinite && resolution! > 0) else { return }
        let turns = ((quarterTurns % 4) + 4) % 4
        let turnedSize = turns % 2 == 0 ? oldSize : CGSize(width: oldSize.height, height: oldSize.width)
        let sx = Float(resample ? newSize.width / turnedSize.width : 1)
        let sy = Float(resample ? newSize.height / turnedSize.height : 1)
        func transform(_ point: SIMD2<Float>) -> SIMD2<Float> {
            let turned: SIMD2<Float>
            switch turns {
            case 1: turned = SIMD2(Float(oldSize.height) - point.y, point.x)
            case 2: turned = SIMD2(Float(oldSize.width) - point.x, Float(oldSize.height) - point.y)
            case 3: turned = SIMD2(point.y, Float(oldSize.width) - point.x)
            default: turned = point
            }
            return (turned - SIMD2(Float(origin.x), Float(origin.y))) * SIMD2(sx, sy)
        }
        editLayers { document in
            document.canvasSize = newSize
            if let resolution { document.resolution = resolution }
            for layer in document.layers.indices {
                document.layers[layer].strokes = document.layers[layer].strokes.map { original in
                    if original.transform != .identity || original.raster != nil || !original.excludedAreas.isEmpty || !original.erasures.isEmpty {
                        let origin = transform(.zero)
                        let x = transform(SIMD2(1, 0)) - origin
                        let y = transform(SIMD2(0, 1)) - origin
                        let adjustment = CGAffineTransform(a: CGFloat(x.x), b: CGFloat(x.y),
                            c: CGFloat(y.x), d: CGFloat(y.y), tx: CGFloat(origin.x), ty: CGFloat(origin.y))
                        var stroke = original
                        stroke.transform = StrokeTransform(original.transform.affine.concatenating(adjustment))
                        return stroke
                    }
                    var style = original.style
                    style.width *= sqrt(sx * sy)
                    style.reedAngle = (style.reedAngle + Float(turns * 90) + 270).truncatingRemainder(dividingBy: 180) - 90
                    var stroke = Stroke(points: original.points.map { sample in
                        var sample = sample
                        sample.position = transform(sample.position)
                        return sample
                    }, style: style, id: original.id)
                    stroke.locksTransparency = original.locksTransparency
                    stroke.fillRects = original.fillRects?.map { rect in
                        let a = transform(SIMD2(rect.x, rect.y))
                        let b = transform(SIMD2(rect.x + rect.z, rect.y + rect.w))
                        return SIMD4(min(a.x, b.x), min(a.y, b.y), abs(b.x - a.x), abs(b.y - a.y))
                    }
                    return stroke
                }
            }
        }
    }

    var isShapeSnapped: Bool { pencil.shapeState != .drawing }
    var recognizedShapeKind: ShapeRecognizer.Kind? { pencil.recognizedShapeKind }

    @discardableResult
    func recognizeActiveShape(adjustmentTolerance: Float = 2) -> Bool {
        guard let original = pencil.activeStroke, !isShapeSnapped else { return false }
        objectWillChange.send()
        guard pencil.recognizeShape(adjustmentTolerance: adjustmentTolerance) else { return false }
        strokeBeforeRecognition = original
        activeStrokeRevision &+= 1
        onNeedsDisplay?()
        return true
    }

    func commitFill(_ stroke: Stroke) {
        guard stroke.style.instrument == .fill, !(stroke.fillRects ?? []).isEmpty,
              selectedLayer.isVisible else { return }
        cancelStroke()
        recordUndo(document)
        var fill = stroke
        fill.locksTransparency = selectedLayer.locksTransparency
        document.layers[selectedLayerIndex].strokes.append(fill)
        onNeedsDisplay?()
    }

    func beginStroke(at sample: PointerSample) {
        guard pencilStyle.instrument != .fill else { return }
        guard selectedLayer.isVisible, !(selectedLayer.locksTransparency && pencilStyle.instrument == .eraser) else { return }
        objectWillChange.send()
        strokeBeforeRecognition = nil
        documentAtStrokeStart = document
        if pencilStyle.instrument == .eraser && pencilStyle.eraserMode == .objects {
            documentBeforeErasing = document
        }
        activeStrokeID &+= 1
        // Time only: a stroke that is cancelled does not edit the drawing.
        noteActivity(recordsEdit: false)
        pencil.begin(at: sample, style: pencilStyle)
        activeStrokeRevision &+= 1
        eraseObjects(from: sample.position, to: sample.position)
        onNeedsDisplay?()
    }

    func continueStroke(at sample: PointerSample) {
        // Per-sample updates reach only views that draw the live stroke. The rest
        // of the UI depends on whether a stroke exists, published by begin/end/cancel.
        // Object erasing edits the committed document, so it still notifies everyone.
        if let style = pencil.activeStroke?.style, style.instrument == .eraser, style.eraserMode == .objects {
            objectWillChange.send()
        }
        liveStroke.objectWillChange.send()
        let previous = pencil.activeStroke?.points.last?.position ?? sample.position
        pencil.update(with: sample)
        activeStrokeRevision &+= 1
        eraseObjects(from: previous, to: sample.position)
        onNeedsDisplay?()
    }

    func endStroke(at sample: PointerSample) {
        objectWillChange.send()
        let previous = pencil.activeStroke?.points.last?.position ?? sample.position
        eraseObjects(from: previous, to: sample.position)
        activeStrokeRevision &+= 1
        guard var stroke = pencil.end(at: sample) else {
            if let original = documentBeforeErasing { document = original }
            documentBeforeErasing = nil
            documentAtStrokeStart = nil
            strokeBeforeRecognition = nil
            onNeedsDisplay?()
            return
        }
        if stroke.style.instrument != .eraser || stroke.style.eraserMode == .pixels {
            stroke.locksTransparency = selectedLayer.locksTransparency
            document.layers[selectedLayerIndex].strokes.append(stroke)
        }
        documentBeforeErasing = nil
        if let before = documentAtStrokeStart,
           before.strokes.count != document.strokes.count {
            recordUndo(before)
            if let original = strokeBeforeRecognition {
                // Drawing and shape correction are separate committed edits.
                var freehand = before
                var original = original
                original.locksTransparency = selectedLayer.locksTransparency
                freehand.layers[selectedLayerIndex].strokes.append(original)
                recordUndo(freehand)
            }
        }
        documentAtStrokeStart = nil
        strokeBeforeRecognition = nil
        onNeedsDisplay?()
    }

    func cancelStroke() {
        objectWillChange.send()
        pencil.cancel()
        activeStrokeRevision &+= 1
        if let original = documentBeforeErasing { document = original }
        documentBeforeErasing = nil
        documentAtStrokeStart = nil
        strokeBeforeRecognition = nil
        onNeedsDisplay?()
    }

    func load(_ savedDocument: CanvasDocument) {
        objectWillChange.send()
        var savedDocument = savedDocument
        let loadedMetadata = savedDocument.metadata ?? ProjectMetadata()
        savedDocument.metadata = nil
        pencil.cancel()
        activeStrokeRevision &+= 1
        documentBeforeErasing = nil
        documentAtStrokeStart = nil
        strokeBeforeRecognition = nil
        undoStack.removeAll()
        redoStack.removeAll()
        undoCosts.removeAll()
        undoBytes = 0
        document = savedDocument
        // After the assignment, which counted as an edit of the previous drawing.
        resetMetadata(to: loadedMetadata)
        selectedLayerID = document.layers.last?.id
        self.savedDocument = savedDocument
        onNeedsDisplay?()
    }

    func markSaved() {
        markSaved(document)
    }

    /// Marks a snapshot taken before a background save; edits made while it was
    /// writing stay unsaved.
    /// The snapshot may come from `documentForSaving()`; its metadata is compared separately.
    func markSaved(_ snapshot: CanvasDocument) {
        objectWillChange.send()
        var snapshot = snapshot
        savedEditableMetadata = (snapshot.metadata ?? metadata).editableFields
        snapshot.metadata = nil
        savedDocument = snapshot
    }

    /// The document with its metadata, as it should be written to disk.
    func documentForSaving() -> CanvasDocument {
        var saved = document
        saved.metadata = metadata
        return saved
    }

    /// Edits the user-facing title and author; empty text removes them.
    func updateMetadata(title: String?? = nil, author: String?? = nil) {
        func cleaned(_ text: String?) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return String(text.prefix(ProjectMetadata.maximumTextLength))
        }
        objectWillChange.send()
        if let title { metadata.title = cleaned(title) }
        if let author { metadata.author = cleaned(author) }
    }

    private func resetMetadata(to value: ProjectMetadata) {
        metadata = value
        savedEditableMetadata = value.editableFields
        lastActivity = nil
    }

    /// Called for every change of the document: strokes, fills, layers, Undo/Redo.
    /// Counts the time since the previous edit, up to `idleGap`.
    private func noteActivity(recordsEdit: Bool = true) {
        let now = ContinuousClock.now
        if let lastActivity {
            let gap = now - lastActivity
            let seconds = Double(gap.components.seconds) + Double(gap.components.attoseconds) * 1e-18
            metadata.activeDuration += min(max(0, seconds), Self.idleGap)
        }
        lastActivity = now
        if recordsEdit { metadata.recordEdit(at: Date()) }
    }

    func clear() {
        guard canClear else { return }
        objectWillChange.send()
        pencil.cancel()
        activeStrokeRevision &+= 1
        documentBeforeErasing = nil
        documentAtStrokeStart = nil
        strokeBeforeRecognition = nil
        recordUndo(document)
        let firstLayer = CanvasLayer(id: document.layers[0].id)
        document.layers = [firstLayer]
        document.backgroundColor = SIMD4(1, 1, 1, 1)
        document.backgroundIsVisible = true
        clearDocumentRevision = documentRevision
        // A cleared canvas starts a new drawing; its first stroke sets the start time.
        resetMetadata(to: ProjectMetadata())
        selectedLayerID = firstLayer.id
        onNeedsDisplay?()
    }

    func undo() {
        guard !undoStack.isEmpty else { return }
        objectWillChange.send()
        let previous = undoStack.removeLast()
        if let cost = undoCosts.popLast() { undoBytes -= cost }
        pencil.cancel()
        activeStrokeRevision &+= 1
        documentBeforeErasing = nil
        documentAtStrokeStart = nil
        strokeBeforeRecognition = nil
        redoStack.append(document)
        document = previous
        onNeedsDisplay?()
    }

    func redo() {
        guard !redoStack.isEmpty else { return }
        objectWillChange.send()
        let next = redoStack.removeLast()
        pencil.cancel()
        activeStrokeRevision &+= 1
        documentBeforeErasing = nil
        documentAtStrokeStart = nil
        strokeBeforeRecognition = nil
        pushUndo(document)
        document = next
        onNeedsDisplay?()
    }

    private func recordUndo(_ previous: CanvasDocument) {
        pushUndo(previous)
        // Trim by step count, then by estimated bytes down to `minimumHistory`.
        while undoStack.count > historyLimit
                || (undoStack.count > minimumHistory && undoBytes > historyByteBudget) {
            undoStack.removeFirst()
            if !undoCosts.isEmpty { undoBytes -= undoCosts.removeFirst() }
        }
        redoStack.removeAll()
    }

    private func pushUndo(_ state: CanvasDocument) {
        if let newest = undoStack.last {
            let cost = HistoryCost.retainedBytes(newest, beyond: state)
            undoCosts.append(cost)
            undoBytes += cost
        }
        undoStack.append(state)
    }

    private func eraseObjects(from a: SIMD2<Float>, to b: SIMD2<Float>) {
        guard let style = pencil.activeStroke?.style,
              style.instrument == .eraser, style.eraserMode == .objects else { return }
        let remaining = selectedLayer.strokes.filter { stroke in
            // Like erasers, blurs are effects on other strokes, not objects to remove.
            !(stroke.style.instrument != .eraser && stroke.style.instrument != .blur && BrushGeometry.touches(stroke, from: a, to: b, radius: style.width / 2))
        }
        if remaining.count != selectedLayer.strokes.count { document.layers[selectedLayerIndex].strokes = remaining }
    }
}

/// Approximates the memory a history snapshot holds that a newer state does not
/// share. Snapshots are copy-on-write: unchanged buffers (points, PNG data) are
/// shared, so only buffers with a different storage address count.
private nonisolated enum HistoryCost {
    static func retainedBytes(_ older: CanvasDocument, beyond newer: CanvasDocument) -> Int {
        var bytes = 0
        if !shares(older.layers, newer.layers) {
            bytes += older.layers.count * MemoryLayout<CanvasLayer>.stride
        }
        let newerLayers = Dictionary(newer.layers.map { ($0.id, $0.strokes) }, uniquingKeysWith: { first, _ in first })
        var newerStrokes: [UUID: Stroke]?
        for layer in older.layers where !shares(layer.strokes, newerLayers[layer.id] ?? []) {
            bytes += layer.strokes.count * MemoryLayout<Stroke>.stride
            // Strokes can move between layers; match them across the whole document.
            if newerStrokes == nil {
                newerStrokes = Dictionary(newer.layers.flatMap(\.strokes).map { ($0.id, $0) },
                                          uniquingKeysWith: { first, _ in first })
            }
            for stroke in layer.strokes {
                bytes += retainedBytes(stroke, beyond: newerStrokes?[stroke.id])
            }
        }
        return bytes
    }

    private static func retainedBytes(_ stroke: Stroke, beyond newer: Stroke?) -> Int {
        var bytes = 0
        if newer.map({ !shares(stroke.points, $0.points) }) ?? true {
            bytes += stroke.points.count * MemoryLayout<PointerSample>.stride
        }
        if let png = stroke.raster?.png, newer?.raster.map({ !shares(png, $0.png) }) ?? true {
            bytes += png.count
        }
        if newer.map({ !shares(stroke.excludedAreas, $0.excludedAreas) }) ?? true {
            bytes += stroke.excludedAreas.reduce(0) { $0 + $1.count * MemoryLayout<SIMD2<Float>>.stride }
        }
        if let rects = stroke.fillRects, newer?.fillRects.map({ !shares(rects, $0) }) ?? true {
            bytes += rects.count * MemoryLayout<SIMD4<Float>>.stride
        }
        if newer.map({ !shares(stroke.erasures, $0.erasures) }) ?? true {
            let previous = Dictionary((newer?.erasures ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            bytes += stroke.erasures.count * MemoryLayout<Stroke>.stride
            for eraser in stroke.erasures {
                bytes += retainedBytes(eraser, beyond: previous[eraser.id])
            }
        }
        return bytes
    }

    private static func shares<Element>(_ a: [Element], _ b: [Element]) -> Bool {
        if a.isEmpty && b.isEmpty { return true }
        guard a.count == b.count else { return false }
        return a.withUnsafeBufferPointer { a in b.withUnsafeBufferPointer { a.baseAddress == $0.baseAddress } }
    }

    private static func shares(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return a.withUnsafeBytes { a in b.withUnsafeBytes { a.baseAddress == $0.baseAddress } }
    }
}
