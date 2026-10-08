import Combine
import CoreGraphics
import Foundation

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
    func setSynchronizeWidth(_ enabled: Bool) { tools.setSynchronizeWidth(enabled) }
    func setSynchronizeColor(_ enabled: Bool) { tools.setSynchronizeColor(enabled) }
    func setSynchronizeOpacity(_ enabled: Bool) { tools.setSynchronizeOpacity(enabled) }
    func flushStylePreferences() { tools.flushStylePreferences() }

    // Revisions make raster invalidation independent of the number of saved points.
    private(set) var documentRevision: UInt64 = 0
    private(set) var activeStrokeRevision: UInt64 = 0
    private(set) var activeStrokeID: UInt64 = 0
    private(set) var document = CanvasDocument() {
        didSet { documentRevision &+= 1 }
    }
    private var savedDocument = CanvasDocument()
    var hasUnsavedChanges: Bool { document != savedDocument }
    var needsDiscardConfirmation: Bool { hasUnsavedChanges }
    private let pencil = PencilTool()
    private var documentBeforeErasing: CanvasDocument?
    private var documentAtStrokeStart: CanvasDocument?
    private var strokeBeforeRecognition: Stroke?
    private var undoStack: [CanvasDocument] = []
    private var redoStack: [CanvasDocument] = []
    private let historyLimit = 30
    var canClear: Bool { !document.strokes.isEmpty }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var onNeedsDisplay: (() -> Void)?

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

    func setBackgroundColor(_ color: SIMD4<Float>) {
        editLayers { $0.backgroundColor = color }
    }
    /// Geometry stays editable; the complete document participates in history.
    func adjustCanvas(from oldSize: CGSize, to newSize: CGSize, resample: Bool,
                      origin: CGPoint = .zero, quarterTurns: Int = 0, resolution: Double? = nil) {
        guard oldSize.width > 0, oldSize.height > 0,
              newSize.width.isFinite, newSize.height.isFinite,
              newSize.width > 0, newSize.height > 0, newSize.width <= 2048, newSize.height <= 2048,
              resolution == nil || (resolution!.isFinite && resolution! > 0) else { return }
        let turns = ((quarterTurns % 4) + 4) % 4
        let sx = Float(resample ? newSize.width / oldSize.width : 1)
        let sy = Float(resample ? newSize.height / oldSize.height : 1)
        func transform(_ point: SIMD2<Float>) -> SIMD2<Float> {
            let p = point - SIMD2(Float(origin.x), Float(origin.y))
            switch turns {
            case 1: return SIMD2(Float(oldSize.height) - p.y, p.x)
            case 2: return SIMD2(Float(oldSize.width) - p.x, Float(oldSize.height) - p.y)
            case 3: return SIMD2(p.y, Float(oldSize.width) - p.x)
            default: return p * SIMD2(sx, sy)
            }
        }
        editLayers { document in
            document.canvasSize = newSize
            if let resolution { document.resolution = resolution }
            for layer in document.layers.indices {
                document.layers[layer].strokes = document.layers[layer].strokes.map { original in
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
        pencil.begin(at: sample, style: pencilStyle)
        activeStrokeRevision &+= 1
        eraseObjects(from: sample.position, to: sample.position)
        onNeedsDisplay?()
    }

    func continueStroke(at sample: PointerSample) {
        objectWillChange.send()
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
        pencil.cancel()
        activeStrokeRevision &+= 1
        documentBeforeErasing = nil
        documentAtStrokeStart = nil
        strokeBeforeRecognition = nil
        undoStack.removeAll()
        redoStack.removeAll()
        document = savedDocument
        selectedLayerID = document.layers.last?.id
        self.savedDocument = savedDocument
        onNeedsDisplay?()
    }

    func markSaved() {
        objectWillChange.send()
        savedDocument = document
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
        for index in document.layers.indices { document.layers[index].strokes.removeAll() }
        onNeedsDisplay?()
    }

    func undo() {
        guard !undoStack.isEmpty else { return }
        objectWillChange.send()
        let previous = undoStack.removeLast()
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
        undoStack.append(document)
        document = next
        onNeedsDisplay?()
    }

    private func recordUndo(_ previous: CanvasDocument) {
        undoStack.append(previous)
        if undoStack.count > historyLimit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func eraseObjects(from a: SIMD2<Float>, to b: SIMD2<Float>) {
        guard let style = pencil.activeStroke?.style,
              style.instrument == .eraser, style.eraserMode == .objects else { return }
        let remaining = selectedLayer.strokes.filter { stroke in
            !(stroke.style.instrument != .eraser && BrushGeometry.touches(stroke, from: a, to: b, radius: style.width / 2))
        }
        if remaining.count != selectedLayer.strokes.count { document.layers[selectedLayerIndex].strokes = remaining }
    }
}
