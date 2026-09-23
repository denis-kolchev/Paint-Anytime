import Combine
import Foundation

final class CanvasController: ObservableObject {
    @Published var pencilStyle: PencilStyle {
        didSet {
            let availableStyle = AppReleaseFeatures.current.availableStyle(pencilStyle)
            if pencilStyle != availableStyle { pencilStyle = availableStyle }
            guard pencilStyle != oldValue else { return }
            savedStyles[pencilStyle.instrument.rawValue] = pencilStyle
            propagateSynchronizedStyle()
            scheduleStylePersistence()
        }
    }
    @Published private(set) var synchronization = ToolSynchronization()

    var maximumWidth: Float { pencilStyle.instrument.maximumWidth }

    func setSynchronizeWidth(_ enabled: Bool) {
        guard synchronization.width != enabled else { return }
        synchronization.width = enabled
        synchronizationChanged()
    }

    func setSynchronizeColor(_ enabled: Bool) {
        guard synchronization.color != enabled else { return }
        synchronization.color = enabled
        synchronizationChanged()
    }

    private func synchronizationChanged() {
        // Enabling synchronization uses the current tool as the starting value.
        propagateSynchronizedStyle()
        scheduleStylePersistence()
    }

    private func propagateSynchronizedStyle() {
        guard synchronization.width || synchronization.color else { return }
        var updated = synchronization
        if updated.width { updated.sharedWidth = pencilStyle.width }
        if updated.color && pencilStyle.instrument != .eraser {
            updated.sharedColor = pencilStyle.color
        }
        // Publish once, and only if shared values actually changed.
        if updated != synchronization { synchronization = updated }
        for instrument in DrawingInstrument.allCases {
            var style = savedStyles[instrument.rawValue] ?? .initial(for: instrument)
            if synchronization.width { style.width = synchronization.sharedWidth }
            if synchronization.color && instrument != .eraser { style.color = synchronization.sharedColor }
            savedStyles[instrument.rawValue] = style
        }
    }

    private var pendingStyleSave: Task<Void, Never>?
    private var stylePreferencesDirty = false

    private func scheduleStylePersistence() {
        guard persistsPreferences else { return }
        stylePreferencesDirty = true
        pendingStyleSave?.cancel()
        pendingStyleSave = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.flushStylePreferences()
        }
    }

    /// Flush when leaving settings or going inactive, even during a Crown gesture.
    func flushStylePreferences() {
        pendingStyleSave?.cancel()
        pendingStyleSave = nil
        guard stylePreferencesDirty,
              let stylesData = try? JSONEncoder().encode(savedStyles),
              let synchronizationData = try? JSONEncoder().encode(synchronization) else { return }
        defaults.set(stylesData, forKey: "drawing.styles.v1")
        defaults.set(synchronizationData, forKey: "drawing.synchronization.v1")
        defaults.set(pencilStyle.instrument.rawValue, forKey: "drawing.instrument.v1")
        stylePreferencesDirty = false
    }

    private(set) var document = CanvasDocument()
    private var savedDocument = CanvasDocument()
    var hasUnsavedChanges: Bool { document != savedDocument }
    var needsDiscardConfirmation: Bool { !document.strokes.isEmpty && hasUnsavedChanges }
    private let pencil = PencilTool()
    private let defaults: UserDefaults
    private let persistsPreferences: Bool
    private var savedStyles: [Int: PencilStyle]
    private var documentBeforeErasing: CanvasDocument?
    private var documentAtStrokeStart: CanvasDocument?
    private var undoStack: [CanvasDocument] = []
    private var redoStack: [CanvasDocument] = []
    private let historyLimit = 30
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var onNeedsDisplay: (() -> Void)?

    init(defaults: UserDefaults = .standard, persistsPreferences: Bool = true) {
        self.defaults = defaults
        self.persistsPreferences = persistsPreferences
        if !persistsPreferences {
            savedStyles = [:]
            pencilStyle = .initial(for: .monoline)
            return
        }
        let data = defaults.data(forKey: "drawing.styles.v1")
        let decoded = data.flatMap { try? JSONDecoder().decode([Int: PencilStyle].self, from: $0) } ?? [:]
        savedStyles = decoded
        var restoredSynchronization = defaults.data(forKey: "drawing.synchronization.v1")
            .flatMap { try? JSONDecoder().decode(ToolSynchronization.self, from: $0) } ?? ToolSynchronization()
        restoredSynchronization.sharedColor = AppReleaseFeatures.current.availableColor(restoredSynchronization.sharedColor)
        let savedInstrument = DrawingInstrument(rawValue: defaults.integer(forKey: "drawing.instrument.v1")) ?? .monoline
        let instrument = AppReleaseFeatures.current.allows(savedInstrument) ? savedInstrument : .monoline
        var restored = decoded[instrument.rawValue] ?? .initial(for: instrument)
        if !restored.width.isFinite { restored.width = instrument.defaultWidth }
        restored.width = min(instrument.maximumWidth, max(1, restored.width))
        if restoredSynchronization.width { restored.width = restoredSynchronization.sharedWidth }
        if restoredSynchronization.color && instrument != .eraser { restored.color = restoredSynchronization.sharedColor }
        synchronization = restoredSynchronization
        pencilStyle = AppReleaseFeatures.current.availableStyle(restored)
    }

    var activeStroke: Stroke? { pencil.activeStroke }

    func selectInstrument(_ instrument: DrawingInstrument) {
        guard AppReleaseFeatures.current.allows(instrument), instrument != pencilStyle.instrument else { return }
        var style = savedStyles[instrument.rawValue] ?? .initial(for: instrument)
        if synchronization.width { style.width = synchronization.sharedWidth }
        else { style.width = min(instrument.maximumWidth, max(1, style.width)) }
        if synchronization.color && instrument != .eraser { style.color = synchronization.sharedColor }
        pencilStyle = AppReleaseFeatures.current.availableStyle(style)
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

struct ToolSynchronization: Codable, Equatable {
    var width = false
    var color = false
    var sharedWidth: Float = 4
    var sharedColor = SIMD4<Float>(0, 0, 0, 1)
}
