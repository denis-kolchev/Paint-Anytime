import Combine
import Foundation

final class CanvasController: ObservableObject {
    @Published var pencilStyle: PencilStyle {
        didSet {
            savedStyles[pencilStyle.instrument.rawValue] = pencilStyle
            propagateSynchronizedStyle()
            if let data = try? JSONEncoder().encode(savedStyles) {
                defaults.set(data, forKey: "drawing.styles.v1")
            }
            defaults.set(pencilStyle.instrument.rawValue, forKey: "drawing.instrument.v1")
        }
    }
    @Published private(set) var synchronization = ToolSynchronization()

    var maximumWidth: Float { pencilStyle.instrument.maximumWidth }

    func setSynchronizeWidth(_ enabled: Bool) {
        synchronization.width = enabled
        synchronizationChanged()
    }

    func setSynchronizeColor(_ enabled: Bool) {
        synchronization.color = enabled
        synchronizationChanged()
    }

    private func synchronizationChanged() {
        // Enabling synchronization uses the current tool as the starting value.
        propagateSynchronizedStyle()
        if let data = try? JSONEncoder().encode(savedStyles) {
            defaults.set(data, forKey: "drawing.styles.v1")
        }
    }

    private func propagateSynchronizedStyle() {
        if synchronization.width { synchronization.sharedWidth = pencilStyle.width }
        if synchronization.color && pencilStyle.instrument != .eraser {
            synchronization.sharedColor = pencilStyle.color
        }
        for instrument in DrawingInstrument.allCases {
            var style = savedStyles[instrument.rawValue] ?? .initial(for: instrument)
            if synchronization.width { style.width = synchronization.sharedWidth }
            if synchronization.color && instrument != .eraser { style.color = synchronization.sharedColor }
            savedStyles[instrument.rawValue] = style
        }
        if let data = try? JSONEncoder().encode(synchronization) {
            defaults.set(data, forKey: "drawing.synchronization.v1")
        }
    }

    private(set) var document = CanvasDocument()
    private let pencil = PencilTool()
    private let defaults: UserDefaults
    private var savedStyles: [Int: PencilStyle]
    private var documentBeforeErasing: CanvasDocument?
    private var documentAtStrokeStart: CanvasDocument?
    private var undoStack: [CanvasDocument] = []
    private var redoStack: [CanvasDocument] = []
    private let historyLimit = 30
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var onNeedsDisplay: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let data = defaults.data(forKey: "drawing.styles.v1")
        let decoded = data.flatMap { try? JSONDecoder().decode([Int: PencilStyle].self, from: $0) } ?? [:]
        savedStyles = decoded
        let restoredSynchronization = defaults.data(forKey: "drawing.synchronization.v1")
            .flatMap { try? JSONDecoder().decode(ToolSynchronization.self, from: $0) } ?? ToolSynchronization()
        let instrument = DrawingInstrument(rawValue: defaults.integer(forKey: "drawing.instrument.v1")) ?? .monoline
        var restored = decoded[instrument.rawValue] ?? .initial(for: instrument)
        if !restored.width.isFinite { restored.width = instrument.defaultWidth }
        restored.width = min(instrument.maximumWidth, max(1, restored.width))
        if restoredSynchronization.width { restored.width = restoredSynchronization.sharedWidth }
        if restoredSynchronization.color && instrument != .eraser { restored.color = restoredSynchronization.sharedColor }
        synchronization = restoredSynchronization
        pencilStyle = restored
    }

    var activeStroke: Stroke? { pencil.activeStroke }

    func selectInstrument(_ instrument: DrawingInstrument) {
        guard instrument != pencilStyle.instrument else { return }
        var style = savedStyles[instrument.rawValue] ?? .initial(for: instrument)
        if synchronization.width { style.width = synchronization.sharedWidth }
        else { style.width = min(instrument.maximumWidth, max(1, style.width)) }
        if synchronization.color && instrument != .eraser { style.color = synchronization.sharedColor }
        pencilStyle = style
    }

    func beginStroke(at sample: PointerSample) {
        objectWillChange.send()
        documentAtStrokeStart = document
        if pencilStyle.instrument == .eraser && pencilStyle.eraserMode == .objects {
            documentBeforeErasing = document
        }
        pencil.begin(at: sample, style: pencilStyle)
        eraseObjects(from: sample.position, to: sample.position)
        onNeedsDisplay?()
    }

    func continueStroke(at sample: PointerSample) {
        objectWillChange.send()
        let previous = pencil.activeStroke?.points.last?.position ?? sample.position
        pencil.update(with: sample)
        eraseObjects(from: previous, to: sample.position)
        onNeedsDisplay?()
    }

    func endStroke(at sample: PointerSample) {
        objectWillChange.send()
        let previous = pencil.activeStroke?.points.last?.position ?? sample.position
        eraseObjects(from: previous, to: sample.position)
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
        if let original = documentBeforeErasing { document = original }
        documentBeforeErasing = nil
        documentAtStrokeStart = nil
        onNeedsDisplay?()
    }

    func load(_ savedDocument: CanvasDocument) {
        objectWillChange.send()
        pencil.cancel()
        documentBeforeErasing = nil
        documentAtStrokeStart = nil
        undoStack.removeAll()
        redoStack.removeAll()
        document = savedDocument
        onNeedsDisplay?()
    }

    func clear() {
        guard !document.strokes.isEmpty else { return }
        objectWillChange.send()
        pencil.cancel()
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
        document.strokes.removeAll { stroke in
            stroke.style.instrument != .eraser && BrushGeometry.touches(stroke, from: a, to: b, radius: style.width / 2)
        }
    }
}

struct ToolSynchronization: Codable {
    var width = false
    var color = false
    var sharedWidth: Float = 4
    var sharedColor = SIMD4<Float>(0, 0, 0, 1)
}
