import Combine
import Foundation

final class CanvasController: ObservableObject {
    let tools: ToolSettings
    private var toolChanges: AnyCancellable?
    var pencilStyle: PencilStyle {
        get { tools.pencilStyle }
        set { tools.pencilStyle = newValue }
    }
    var synchronization: ToolSynchronization { tools.synchronization }
    var maximumWidth: Float { tools.maximumWidth }
    func selectInstrument(_ instrument: DrawingInstrument) { tools.selectInstrument(instrument) }
    func setSynchronizeWidth(_ enabled: Bool) { tools.setSynchronizeWidth(enabled) }
    func setSynchronizeColor(_ enabled: Bool) { tools.setSynchronizeColor(enabled) }
    func flushStylePreferences() { tools.flushStylePreferences() }

    // Revisions make raster invalidation independent of the number of saved points.
    private(set) var documentRevision: UInt64 = 0
    private(set) var activeStrokeRevision: UInt64 = 0
    private(set) var document = CanvasDocument() {
        didSet { documentRevision &+= 1 }
    }
    private var savedDocument = CanvasDocument()
    var hasUnsavedChanges: Bool { document != savedDocument }
    var needsDiscardConfirmation: Bool { !document.strokes.isEmpty && hasUnsavedChanges }
    private let pencil = PencilTool()
    private var documentBeforeErasing: CanvasDocument?
    private var documentAtStrokeStart: CanvasDocument?
    private var undoStack: [CanvasDocument] = []
    private var redoStack: [CanvasDocument] = []
    private let historyLimit = 30
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var onNeedsDisplay: (() -> Void)?

    init(defaults: UserDefaults = .standard, persistsPreferences: Bool = true) {
        tools = ToolSettings(defaults: defaults, persistsPreferences: persistsPreferences)
        toolChanges = tools.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var activeStroke: Stroke? { pencil.activeStroke }

    func beginStroke(at sample: PointerSample) {
        objectWillChange.send()
        documentAtStrokeStart = document
        if pencilStyle.instrument == .eraser && pencilStyle.eraserMode == .objects {
            documentBeforeErasing = document
        }
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
        guard let stroke = pencil.end(at: sample) else {
            if let original = documentBeforeErasing { document = original }
            documentBeforeErasing = nil
            documentAtStrokeStart = nil
            onNeedsDisplay?()
            return
        }
        if stroke.style.instrument != .eraser || stroke.style.eraserMode == .pixels {
            document.strokes.append(stroke)
        }
        documentBeforeErasing = nil
        if let before = documentAtStrokeStart,
           before.strokes.count != document.strokes.count {
            recordUndo(before)
        }
        documentAtStrokeStart = nil
        onNeedsDisplay?()
    }

    func cancelStroke() {
        objectWillChange.send()
        pencil.cancel()
        activeStrokeRevision &+= 1
        if let original = documentBeforeErasing { document = original }
        documentBeforeErasing = nil
        documentAtStrokeStart = nil
        onNeedsDisplay?()
    }

    func load(_ savedDocument: CanvasDocument) {
        objectWillChange.send()
        pencil.cancel()
        activeStrokeRevision &+= 1
        documentBeforeErasing = nil
        documentAtStrokeStart = nil
        undoStack.removeAll()
        redoStack.removeAll()
        document = savedDocument
        self.savedDocument = savedDocument
        onNeedsDisplay?()
    }

    func markSaved() {
        objectWillChange.send()
        savedDocument = document
    }

    func clear() {
        guard !document.strokes.isEmpty else { return }
        objectWillChange.send()
        pencil.cancel()
        activeStrokeRevision &+= 1
        documentBeforeErasing = nil
        documentAtStrokeStart = nil
        recordUndo(document)
        document.strokes.removeAll()
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
        let remaining = document.strokes.filter { stroke in
            !(stroke.style.instrument != .eraser && BrushGeometry.touches(stroke, from: a, to: b, radius: style.width / 2))
        }
        if remaining.count != document.strokes.count { document.strokes = remaining }
    }
}
