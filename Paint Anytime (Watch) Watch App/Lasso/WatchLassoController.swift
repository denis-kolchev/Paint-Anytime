import SwiftUI
import Combine
import WatchKit

@MainActor
final class WatchLassoController: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var mode: WatchLassoMode = .area
    @Published private(set) var outline: [CGPoint] = []
    @Published private(set) var rotation: CGFloat = 0
    @Published private(set) var bounds: CGRect?
    @Published private(set) var previewState: WatchSelectionPreview?
    @Published private(set) var isPreparing = false
    @Published var errorMessage: String?
    @Published private(set) var selectionSeed: WatchSelectionPreview?
    private var selection: WatchLassoSelection? {
        didSet {
            guard let selection,
                  let index = selection.document.layers.firstIndex(where: { $0.id == selection.layerID }) else {
                selectionSeed = nil
                return
            }
            var document = selection.document
            document.layers[index].strokes = selection.strokes
            selectionSeed = WatchSelectionPreview(sessionID: UUID(), document: document,
                layerID: selection.layerID, selectedIDs: selection.selectedIDs,
                bounds: selection.bounds.applying(WatchLassoGeometry.rotation(selection.rotation, around: selection.bounds)))
        }
    }
    private struct HistoryState {
        let document: CanvasDocument
        let layerID: UUID
        let selection: WatchLassoSelection?
        let mode: WatchLassoMode
    }
    private struct HistoryStep {
        let before: HistoryState
        let after: HistoryState
    }
    @Published private var undoSteps: [HistoryStep] = []
    @Published private var redoSteps: [HistoryStep] = []
    var canUndo: Bool { isActive && !hidesControls && !undoSteps.isEmpty }
    var canRedo: Bool { isActive && !hidesControls && !redoSteps.isEmpty }

    private func state(_ controller: CanvasController) -> HistoryState {
        HistoryState(document: controller.document, layerID: controller.selectedLayer.id,
                     selection: selection, mode: mode)
    }

    private func record(_ before: HistoryState, controller: CanvasController) {
        guard before.document != controller.document else { return }
        undoSteps.append(HistoryStep(before: before, after: state(controller)))
        // Never retain more document edits than the canvas can restore.
        if undoSteps.count > controller.historyLimit { undoSteps.removeFirst() }
        redoSteps.removeAll()
    }

    private func clearHistory() {
        undoSteps.removeAll()
        redoSteps.removeAll()
    }

    func canMoveLayer(_ offset: Int, controller: CanvasController) -> Bool {
        guard isActive, !hidesControls, let selection,
              selection.document == controller.document,
              selection.layerID == controller.selectedLayer.id,
              let index = controller.document.layers.firstIndex(where: { $0.id == selection.layerID }) else { return false }
        return controller.document.layers.indices.contains(index + offset)
    }

    func moveLayer(_ offset: Int, controller: CanvasController) -> String? {
        guard canMoveLayer(offset, controller: controller), let selection else { return nil }
        let before = state(controller)
        let target = controller.document.layers[controller.selectedLayerIndex + offset]
        controller.moveSelection(strokes: selection.strokes, selectedIDs: selection.selectedIDs,
                                 from: selection.layerID, to: target.id)
        self.selection = WatchLassoSelection(document: controller.document, layerID: target.id,
            strokes: controller.selectedLayer.strokes, selectedIDs: selection.selectedIDs, bounds: selection.bounds, rotation: selection.rotation)
        record(before, controller: controller)
        return target.displayName
    }

    func undo(_ controller: CanvasController) {
        guard canUndo, let step = undoSteps.last else { return }
        guard controller.document == step.after.document,
              controller.selectedLayer.id == step.after.layerID else {
            resetSelection(); clearHistory(); return
        }
        undoSteps.removeLast()
        restore(step.before, controller: controller, undo: true)
        redoSteps.append(step)
    }

    func redo(_ controller: CanvasController) {
        guard canRedo, let step = redoSteps.last else { return }
        guard controller.document == step.before.document,
              controller.selectedLayer.id == step.before.layerID else {
            resetSelection(); clearHistory(); return
        }
        redoSteps.removeLast()
        restore(step.after, controller: controller, undo: false)
        undoSteps.append(step)
    }

    private func restore(_ state: HistoryState, controller: CanvasController, undo: Bool) {
        resetSelection()
        // Each history step represents a committed object edit; creating a
        // selection or choosing its mode does not add an undo step.
        if controller.document != state.document {
            if undo { controller.undo() } else { controller.redo() }
        }
        controller.selectLayer(state.layerID)
        selection = state.selection
        rotation = state.selection?.rotation ?? 0
        bounds = state.selection?.bounds
        mode = state.mode
    }
    private var preparation: Task<Void, Never>?
    private let builder = WatchLassoBuilder()
    private var generation = UUID()
    private enum Drag { case outline, move, resize(Int), rotate }
    @Published private var drag: Drag?
    var isRotating: Bool {
        guard let drag, case .rotate = drag else { return false }
        return true
    }
    var rotationHandleBounds: CGRect? { bounds }
    var hidesControls: Bool { isActive && (drag != nil || isPreparing) }
    var activeResizeHandle: Int? {
        guard let drag, case let .resize(handle) = drag else { return nil }
        return handle
    }
    private var dragStart = CGPoint.zero
    private var dragBounds = CGRect.zero

    func activate() { resetSelection(); clearHistory(); isActive = true }
    func deactivate() { resetSelection(); clearHistory(); isActive = false }
    func setMode(_ value: WatchLassoMode) {
        guard mode != value else { return }
        resetSelection()
        mode = value
    }

    func resetSelection() {
        preparation?.cancel()
        preparation = nil
        generation = UUID()
        isPreparing = false
        errorMessage = nil
        selection = nil
        outline = []
        bounds = nil
        rotation = 0
        previewState = nil
        drag = nil
    }

    func documentChanged(_ controller: CanvasController) {
        guard let selection else { return }
        if selection.document != controller.document || selection.layerID != controller.selectedLayer.id {
            resetSelection()
            clearHistory()
        }
    }

    func begin(at point: CGPoint, tolerance: CGFloat, controller: CanvasController) {
        guard isActive, !isPreparing, controller.selectedLayer.isVisible,
              controller.selectedLayer.opacity > 0 else { return }
        documentChanged(controller)
        dragStart = point
        if let bounds {
            generation = UUID()
            dragBounds = bounds
            let inverse = WatchLassoGeometry.rotation(selection?.rotation ?? 0, around: bounds).inverted()
            let point = point.applying(inverse)
            let handles = WatchLassoGeometry.handles(bounds)
            let rotationHandle = WatchLassoGeometry.rotationHandle(bounds,
                offset: tolerance * WatchLassoGeometry.rotationHandleOffset / WatchLassoGeometry.handleHitRadius)
            let rotationDistance = WatchLassoGeometry.distance(rotationHandle, point)
            if rotationDistance <= tolerance,
               handles.allSatisfy({ WatchLassoGeometry.distance($0, point) > rotationDistance }) {
                drag = .rotate
                // Confirm the initial grab once, without repeating during rotation.
                WKInterfaceDevice.current().play(.click)
                return
            }
            // The nearest handle wins when the selection is small on a watch screen.
            if let nearest = handles.indices.min(by: {
                WatchLassoGeometry.distance(handles[$0], point) < WatchLassoGeometry.distance(handles[$1], point)
            }), WatchLassoGeometry.distance(handles[nearest], point) <= tolerance,
               WatchLassoGeometry.distance(CGPoint(x: bounds.midX, y: bounds.midY), point) > min(tolerance, min(bounds.width, bounds.height) / 4) {
                drag = .resize(nearest)
                WKInterfaceDevice.current().play(.click)
                return
            }
            if bounds.contains(point) {
                drag = .move
                WKInterfaceDevice.current().play(.click)
                return
            }
        }
        resetSelection()
        dragStart = point
        drag = .outline
        outline = [point]
    }

    func update(at point: CGPoint, pointSpacing: CGFloat) {
        guard let drag else { return }
        switch drag {
        case .outline:
            if let last = outline.last, WatchLassoGeometry.distance(last, point) < pointSpacing { return }
            outline.append(point)
        case .move:
            preview(in: dragBounds.offsetBy(dx: point.x - dragStart.x, dy: point.y - dragStart.y))
        case .rotate:
            guard let selection else { return }
            let center = CGPoint(x: dragBounds.midX, y: dragBounds.midY)
            // Ignore points at the pivot, where the finger has no meaningful angle.
            guard WatchLassoGeometry.distance(center, point) > pointSpacing else { return }
            let angle = atan2(point.y - center.y, point.x - center.x)
                - atan2(dragStart.y - center.y, dragStart.x - center.x)
            let cosine = cos(angle), sine = sin(angle)
            let transform = CGAffineTransform(a: cosine, b: sine, c: -sine, d: cosine,
                tx: center.x - cosine * center.x + sine * center.y,
                ty: center.y - sine * center.x - cosine * center.y)
            if previewState == nil { previewState = selectionSeed }
            previewState?.transform = transform
            rotation = selection.rotation + angle
            bounds = selection.bounds
        case .resize(let handle):
            let inverse = WatchLassoGeometry.rotation(selection?.rotation ?? 0, around: dragBounds).inverted()
            let localPoint = point.applying(inverse), localStart = dragStart.applying(inverse)
            let delta = CGSize(width: localPoint.x - localStart.x, height: localPoint.y - localStart.y)
            if [0, 2, 4, 6].contains(handle) {
                let handles = WatchLassoGeometry.handles(dragBounds)
                let anchor = handles[(handle + 4) % handles.count]
                let corner = handles[handle]
                let dx = corner.x - anchor.x, dy = corner.y - anchor.y
                // Project the drag onto the original diagonal, keeping the
                // opposite corner fixed and using one scale for both axes.
                let minimumScale = max(min(1, dragBounds.width) / dragBounds.width,
                                       min(1, dragBounds.height) / dragBounds.height)
                let scale = max(minimumScale, 1 + (delta.width * dx + delta.height * dy) / (dx * dx + dy * dy))
                let width = dragBounds.width * scale, height = dragBounds.height * scale
                preview(in: CGRect(x: dx < 0 ? anchor.x - width : anchor.x,
                                   y: dy < 0 ? anchor.y - height : anchor.y,
                                   width: width, height: height))
                return
            }
            var left = dragBounds.minX, right = dragBounds.maxX
            var top = dragBounds.minY, bottom = dragBounds.maxY
            let minimumWidth = min(1, dragBounds.width), minimumHeight = min(1, dragBounds.height)
            if [0, 6, 7].contains(handle) { left = min(right - minimumWidth, left + delta.width) }
            if [2, 3, 4].contains(handle) { right = max(left + minimumWidth, right + delta.width) }
            if [0, 1, 2].contains(handle) { top = min(bottom - minimumHeight, top + delta.height) }
            if [4, 5, 6].contains(handle) { bottom = max(top + minimumHeight, bottom + delta.height) }
            preview(in: CGRect(x: left, y: top, width: right - left, height: bottom - top))
        }
    }

    private func preview(in rect: CGRect) {
        guard let selection else { return }
        if previewState == nil { previewState = selectionSeed }
        let old = selection.bounds
        let sx = rect.width / old.width, sy = rect.height / old.height
        let scaling = CGAffineTransform(a: sx, b: 0, c: 0, d: sy,
            tx: rect.minX - old.minX * sx, ty: rect.minY - old.minY * sy)
        if let drag, case .resize = drag {
            let orientation = WatchLassoGeometry.rotation(selection.rotation, around: old)
            previewState?.transform = orientation.inverted().concatenating(scaling).concatenating(orientation)
            let center = CGPoint(x: rect.midX, y: rect.midY).applying(orientation)
            bounds = CGRect(x: center.x - rect.width / 2, y: center.y - rect.height / 2,
                            width: rect.width, height: rect.height)
        } else {
            previewState?.transform = scaling
            bounds = rect
        }
    }

    func end(at point: CGPoint, controller: CanvasController, size: CGSize, scale: CGFloat,
             onSelectionFinished: @escaping (Bool) -> Void = { _ in }) {
        guard let drag else { return }
        update(at: point, pointSpacing: 0)
        self.drag = nil
        switch drag {
        case .outline:
            guard outline.count >= 3 else {
                outline = []
                onSelectionFinished(false)
                return
            }
            let polygon = outline
            let document = controller.document
            let layerID = controller.selectedLayer.id
            let mode = mode
            let token = generation
            isPreparing = true
            preparation = Task {
                do {
                    let result = try await builder.prepare(document: document, layerID: layerID,
                        polygon: polygon, mode: mode, size: size, scale: scale)
                    guard !Task.isCancelled, generation == token else { return }
                    isPreparing = false
                    outline = []
                    guard controller.document == document, controller.selectedLayer.id == layerID else { return }
                    selection = result
                    bounds = result?.bounds
                    onSelectionFinished(result != nil)
                } catch {
                    guard !Task.isCancelled, generation == token else { return }
                    isPreparing = false
                    outline = []
                    errorMessage = "Could not create selection"
                    onSelectionFinished(false)
                }
            }
        case .move, .resize, .rotate:
            guard var selection, let previewState,
                  !previewState.transform.isIdentity,
                  selection.document == controller.document,
                  let index = selection.document.layers.firstIndex(where: { $0.id == selection.layerID }) else {
                cancelGesture()
                return
            }
            let before = state(controller)
            selection.strokes = selection.strokes.map { source in
                guard selection.selectedIDs.contains(source.id) else { return source }
                var stroke = source
                stroke.transform = StrokeTransform(source.transform.affine.concatenating(previewState.transform))
                return stroke
            }
            selection.document.layers[index].strokes = selection.strokes
            selection.bounds = bounds ?? selection.bounds
            selection.rotation = rotation
            self.selection = selection
            controller.replaceLayerStrokes(selection.strokes, in: selection.layerID)
            record(before, controller: controller)
            self.previewState = nil
        }
    }

    func duplicate(_ controller: CanvasController) {
        documentChanged(controller)
        guard var selection else { return }
        let before = state(controller)
        let copies = selection.strokes.filter { selection.selectedIDs.contains($0.id) }.map { source in
            var copy = Stroke(points: source.points, style: source.style)
            copy.locksTransparency = source.locksTransparency
            copy.transform = StrokeTransform(source.transform.affine.concatenating(
                CGAffineTransform(translationX: 8, y: 8)))
            copy.raster = source.raster
            copy.excludedAreas = source.excludedAreas
            copy.erasures = source.erasures
            copy.fillRects = source.fillRects
            return copy
        }
        let strokes = selection.strokes + copies
        guard let index = selection.document.layers.firstIndex(where: { $0.id == selection.layerID }) else { return }
        selection.document.layers[index].strokes = strokes
        self.selection = WatchLassoSelection(document: selection.document, layerID: selection.layerID,
            strokes: strokes, selectedIDs: Set(copies.map(\.id)), bounds: selection.bounds.offsetBy(dx: 8, dy: 8), rotation: selection.rotation)
        bounds = self.selection?.bounds
        controller.replaceLayerStrokes(strokes, in: selection.layerID)
        record(before, controller: controller)
    }

    func delete(_ controller: CanvasController) {
        documentChanged(controller)
        guard let selection else { return }
        let before = state(controller)
        let remaining = selection.strokes.filter { !selection.selectedIDs.contains($0.id) }
        resetSelection()
        controller.replaceLayerStrokes(remaining, in: selection.layerID)
        record(before, controller: controller)
    }

    func cancelGesture() {
        guard drag != nil || previewState != nil else { return }
        drag = nil
        outline = []
        previewState = nil
        bounds = selection?.bounds
        rotation = selection?.rotation ?? 0
    }
}
