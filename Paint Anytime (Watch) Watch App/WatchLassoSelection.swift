import SwiftUI
import Combine
import ImageIO
import WatchKit

nonisolated enum WatchLassoMode: CaseIterable, Hashable, Sendable {
    case strokes, area

    var title: String { self == .strokes ? "Select whole strokes" : "Select area" }
    var symbol: String { self == .strokes ? "scribble" : "square.dashed" }
}

nonisolated struct WatchLassoSelection {
    var document: CanvasDocument
    let layerID: UUID
    var strokes: [Stroke]
    let selectedIDs: Set<UUID>
    var bounds: CGRect
}

@MainActor
final class WatchLassoController: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var mode: WatchLassoMode = .strokes
    @Published private(set) var outline: [CGPoint] = []
    @Published private(set) var bounds: CGRect?
    @Published private(set) var previewState: WatchSelectionPreview?
    @Published private(set) var isPreparing = false
    @Published var errorMessage: String?
    private var selection: WatchLassoSelection?
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
            strokes: controller.selectedLayer.strokes, selectedIDs: selection.selectedIDs, bounds: selection.bounds)
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
        bounds = state.selection?.bounds
        mode = state.mode
    }
    private var preparation: Task<Void, Never>?
    private let builder = WatchLassoBuilder()
    private var generation = UUID()
    private enum Drag { case outline, move, resize(Int) }
    @Published private var drag: Drag?
    var hidesControls: Bool { isActive && (drag != nil || isPreparing) }
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
            let handles = WatchLassoGeometry.handles(bounds)
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
        case .resize(let handle):
            let delta = CGSize(width: point.x - dragStart.x, height: point.y - dragStart.y)
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
        if previewState == nil {
            var document = selection.document
            guard let index = document.layers.firstIndex(where: { $0.id == selection.layerID }) else { return }
            // Attach erasures / area cutouts once, before the first interactive frame.
            document.layers[index].strokes = selection.strokes
            previewState = WatchSelectionPreview(sessionID: generation, document: document,
                layerID: selection.layerID, selectedIDs: selection.selectedIDs, bounds: selection.bounds)
        }
        let old = selection.bounds
        let sx = rect.width / old.width, sy = rect.height / old.height
        previewState?.transform = CGAffineTransform(a: sx, b: 0, c: 0, d: sy,
            tx: rect.minX - old.minX * sx, ty: rect.minY - old.minY * sy)
        bounds = rect
    }

    func end(at point: CGPoint, controller: CanvasController, size: CGSize, scale: CGFloat) {
        guard let drag else { return }
        update(at: point, pointSpacing: 0)
        self.drag = nil
        switch drag {
        case .outline:
            guard outline.count >= 3 else { outline = []; return }
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
                } catch {
                    guard !Task.isCancelled, generation == token else { return }
                    isPreparing = false
                    outline = []
                    errorMessage = "Could not create selection"
                }
            }
        case .move, .resize:
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
            strokes: strokes, selectedIDs: Set(copies.map(\.id)), bounds: selection.bounds.offsetBy(dx: 8, dy: 8))
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
    }
}

/// Brush geometry and pixel cuts run away from the UI actor.
private actor WatchLassoBuilder {
    nonisolated enum SelectionError: Error { case rendering }

    private struct GeometryKey: Hashable {
        let id: UUID
        let revision: UUID
    }
    private struct OccupiedMask {
        let size: CGSize
        let scale: CGFloat
        let area: CGRect // Integer pixel coordinates, clipped to the paper.
        let columns: Int
        let rows: Int
        let counts: [Int]
        let total: Int
        let visibleBounds: CGRect?
    }
    private struct CachedGeometry {
        let bounds: CGRect
        var mask: OccupiedMask?
        var access: UInt64
    }
    // Up to 2,048 bounds and 64 masks of 64 * 64 Ints (~2 MiB).
    // No full-resolution images or brush command arrays survive a lookup.
    private var geometryCache: [GeometryKey: CachedGeometry] = [:]
    private var access: UInt64 = 0
    private var eraserVersions: [GeometryKey] = []
    private var eraserLocks: [Bool] = []
    private var attachedStrokes: [Stroke]?

    private func cachedBounds(_ stroke: Stroke) throws -> CGRect {
        let key = GeometryKey(id: stroke.id, revision: stroke.geometryRevision)
        access &+= 1
        if var entry = geometryCache[key] {
            entry.access = access
            geometryCache[key] = entry
            return entry.bounds
        }
        let bounds = try WatchBitmapRenderer.StrokeGeometry(stroke).bounds
        if geometryCache.count >= 2_048,
           let oldest = geometryCache.min(by: { $0.value.access < $1.value.access })?.key {
            geometryCache.removeValue(forKey: oldest)
        }
        geometryCache[key] = CachedGeometry(bounds: bounds, access: access)
        return bounds
    }

    private func occupiedMask(_ stroke: Stroke, bounds: CGRect, size: CGSize, scale: CGFloat) throws -> OccupiedMask {
        let key = GeometryKey(id: stroke.id, revision: stroke.geometryRevision)
        if let mask = geometryCache[key]?.mask, mask.size == size, mask.scale == scale { return mask }
        var ink = stroke
        ink.locksTransparency = false
        guard let image = WatchBitmapRenderer.layerThumbnail(strokes: [ink], size: size, scale: scale),
              let context = pixelContext(image), let data = context.data else { throw SelectionError.rendering }
        let area = bounds.applying(CGAffineTransform(scaleX: scale, y: scale)).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !area.isNull, !area.isEmpty else {
            return OccupiedMask(size: size, scale: scale, area: .zero, columns: 0, rows: 0,
                                counts: [], total: 0, visibleBounds: nil)
        }
        let width = Int(area.width), height = Int(area.height)
        let columns = min(64, width), rows = min(64, height)
        var counts = [Int](repeating: 0, count: columns * rows)
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        var total = 0
        var minX = image.width, minY = image.height, maxX = -1, maxY = -1
        for y in 0..<height {
            try Task.checkCancellation()
            let py = y + Int(area.minY)
            for x in 0..<width {
                let px = x + Int(area.minX)
                guard pixels[py * context.bytesPerRow + px * 4 + 3] > 0 else { continue }
                counts[(y * rows / height) * columns + x * columns / width] += 1
                total += 1
                minX = min(minX, px); minY = min(minY, py)
                maxX = max(maxX, px); maxY = max(maxY, py)
            }
        }
        let visible = total == 0 ? nil : CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
            width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
        let mask = OccupiedMask(size: size, scale: scale, area: area, columns: columns, rows: rows,
                               counts: counts, total: total, visibleBounds: visible)
        if geometryCache[key]?.mask == nil {
            let masks = geometryCache.filter { $0.value.mask != nil }
            if masks.count >= 64, let oldest = masks.min(by: { $0.value.access < $1.value.access })?.key {
                geometryCache[oldest]?.mask = nil
            }
        }
        geometryCache[key]?.mask = mask
        return mask
    }

    /// Each cell stores the exact occupied-pixel count, not downsampled alpha.
    /// Only cells untouched by the polygon boundary can decide membership.
    /// This gives rigorous bounds on the majority and keeps thin/textured ink exact.
    private func majorityBounds(_ stroke: Stroke, bounds: CGRect, path: CGPath,
                                edges: [CGRect], size: CGSize, scale: CGFloat) throws -> CGRect? {
        let mask = try occupiedMask(stroke, bounds: bounds, size: size, scale: scale)
        guard mask.total > 0 else { return nil }
        var inside = 0, uncertain = 0
        for row in 0..<mask.rows {
            try Task.checkCancellation()
            for column in 0..<mask.columns {
                let count = mask.counts[row * mask.columns + column]
                guard count > 0 else { continue }
                // Integer ceil divisions match the binning above exactly.
                let width = Int(mask.area.width), height = Int(mask.area.height)
                let x0 = (column * width + mask.columns - 1) / mask.columns
                let x1 = ((column + 1) * width + mask.columns - 1) / mask.columns
                let y0 = (row * height + mask.rows - 1) / mask.rows
                let y1 = ((row + 1) * height + mask.rows - 1) / mask.rows
                let cell = CGRect(x: (mask.area.minX + CGFloat(x0)) / scale,
                                  y: (mask.area.minY + CGFloat(y0)) / scale,
                                  width: CGFloat(x1 - x0) / scale, height: CGFloat(y1 - y0) / scale)
                if edges.contains(where: { $0.intersects(cell) }) { uncertain += count }
                else if path.contains(CGPoint(x: cell.midX, y: cell.midY), using: .evenOdd) { inside += count }
            }
        }
        if inside * 2 >= mask.total { return mask.visibleBounds }
        if (inside + uncertain) * 2 < mask.total { return nil }
        return try majorityAreaBounds(stroke, bounds: bounds, path: path, size: size, scale: scale)
    }

    func prepare(document: CanvasDocument, layerID: UUID, polygon: [CGPoint], mode: WatchLassoMode,
                 size: CGSize, scale: CGFloat) throws -> WatchLassoSelection? {
        guard var layer = document.layers.first(where: { $0.id == layerID }),
              layer.isVisible, layer.opacity > 0 else { return nil }
        let path = WatchLassoGeometry.path(polygon)
        let paper = CGRect(origin: .zero, size: size)
        guard path.boundingBoxOfPath.intersects(paper) else { return nil }
        layer.strokes = try attachingErasers(in: layer.strokes)
        if mode == .area {
            return try cutArea(document: document, layer: layer, polygon: polygon, path: path, size: size, scale: scale)
        }
        // Conservative edge boxes include horizontal/vertical edges and vertices.
        let edges = polygon.indices.map { index in
            let a = polygon[index], b = polygon[(index + 1) % polygon.count]
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                          width: abs(a.x - b.x), height: abs(a.y - b.y))
                .insetBy(dx: -0.0001, dy: -0.0001)
        }
        var selected = Set<UUID>()
        var bounds = CGRect.null
        for stroke in layer.strokes where stroke.style.instrument != .eraser {
            try Task.checkCancellation()
            let strokeBounds = try cachedBounds(stroke)
            guard strokeBounds.intersects(path.boundingBoxOfPath), strokeBounds.intersects(paper) else { continue }
            // Evaluate each stroke's occupied area, not its centerline or
            // bounding rectangle. A small intersection is no longer enough.
            guard let visibleBounds = try majorityBounds(stroke, bounds: strokeBounds, path: path,
                edges: edges, size: size, scale: scale) else { continue }
            selected.insert(stroke.id)
            let selectionBounds = stroke.raster != nil || !stroke.excludedAreas.isEmpty || !stroke.erasures.isEmpty
                ? visibleBounds : strokeBounds
            bounds = bounds.union(selectionBounds)
        }
        guard !selected.isEmpty, !bounds.isNull, !bounds.isEmpty else { return nil }
        return WatchLassoSelection(document: document, layerID: layerID, strokes: layer.strokes,
                                   selectedIDs: selected, bounds: bounds)
    }

    private func attachingErasers(in strokes: [Stroke]) throws -> [Stroke] {
        guard strokes.contains(where: { $0.style.instrument == .eraser }) else {
            attachedStrokes = nil
            eraserVersions = []
            eraserLocks = []
            return strokes
        }
        let versions = strokes.map { GeometryKey(id: $0.id, revision: $0.geometryRevision) }
        let locks = strokes.map(\.locksTransparency)
        if versions == eraserVersions, locks == eraserLocks, let attachedStrokes { return attachedStrokes }
        var objects: [Stroke] = []
        var bounds: [CGRect] = []
        for stroke in strokes {
            try Task.checkCancellation()
            let strokeBounds = try cachedBounds(stroke)
            if stroke.style.instrument == .eraser {
                guard stroke.style.eraserMode == .pixels, !stroke.locksTransparency else { continue }
                // Only earlier objects were affected by this eraser. Keep a
                // separate local mask for each, so shared erasures can separate.
                for index in objects.indices where bounds[index].intersects(strokeBounds) {
                    var eraser = stroke
                    eraser.transform = StrokeTransform(stroke.transform.affine.concatenating(
                        objects[index].transform.affine.inverted()))
                    objects[index].erasures.append(eraser)
                }
            } else {
                objects.append(stroke)
                bounds.append(strokeBounds)
            }
        }
        eraserVersions = versions
        eraserLocks = locks
        attachedStrokes = objects
        return objects
    }

    private func majorityAreaBounds(_ stroke: Stroke, bounds: CGRect, path: CGPath,
                                    size: CGSize, scale: CGFloat) throws -> CGRect? {
        var ink = stroke
        ink.locksTransparency = false
        guard let image = WatchBitmapRenderer.layerThumbnail(strokes: [ink], size: size, scale: scale),
              let context = pixelContext(image), let data = context.data else { throw SelectionError.rendering }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        let area = bounds
            .applying(CGAffineTransform(scaleX: scale, y: scale)).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !area.isNull, !area.isEmpty else { return nil }
        var totalPixels = 0
        var enclosedPixels = 0
        var minX = image.width, minY = image.height, maxX = -1, maxY = -1
        for y in Int(area.minY)..<Int(area.maxY) {
            try Task.checkCancellation()
            for x in Int(area.minX)..<Int(area.maxX) where pixels[y * context.bytesPerRow + x * 4 + 3] > 0 {
                minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                totalPixels += 1
                let point = CGPoint(x: (CGFloat(x) + 0.5) / scale, y: (CGFloat(y) + 0.5) / scale)
                if path.contains(point, using: .evenOdd) { enclosedPixels += 1 }
            }
        }
        // Count occupied pixels equally: opacity must not make one part of a
        // textured stroke count more than another. Exactly half is included.
        guard totalPixels > 0, enclosedPixels * 2 >= totalPixels else { return nil }
        return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }

    private func cutArea(document: CanvasDocument, layer: CanvasLayer, polygon: [CGPoint], path: CGPath,
                         size: CGSize, scale: CGFloat) throws -> WatchLassoSelection? {
        guard let image = WatchBitmapRenderer.layerThumbnail(strokes: layer.strokes, size: size, scale: scale) else {
            throw SelectionError.rendering
        }
        let region = path.boundingBoxOfPath.applying(CGAffineTransform(scaleX: scale, y: scale)).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !region.isNull, !region.isEmpty else { return nil }
        guard let cropped = image.cropping(to: region), let inside = pixelContext(cropped),
              let insideData = inside.data else { throw SelectionError.rendering }
        let cut = insideData.assumingMemoryBound(to: UInt8.self)
        var minX = cropped.width, minY = cropped.height, maxX = -1, maxY = -1
        // Both bitmap rows and the lasso have a top-left origin. Crop before
        // masking to keep small selections on a large canvas inexpensive.
        for y in 0..<cropped.height {
            try Task.checkCancellation()
            for x in 0..<cropped.width {
                let i = y * inside.bytesPerRow + x * 4
                let point = CGPoint(x: (region.minX + CGFloat(x) + 0.5) / scale,
                                    y: (region.minY + CGFloat(y) + 0.5) / scale)
                if cut[i + 3] > 0 && path.contains(point, using: .evenOdd) {
                    minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                } else {
                    for c in 0..<4 { cut[i + c] = 0 }
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let crop = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        guard let selectedImage = inside.makeImage()?.cropping(to: crop) else { throw SelectionError.rendering }
        let bounds = crop.offsetBy(dx: region.minX, dy: region.minY)
            .applying(CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
        let selected = try rasterStroke(selectedImage, bounds: bounds)
        // Keep each remaining stroke editable instead of flattening the rest
        // of the layer. The cutout travels with it in later object selections.
        let remaining = layer.strokes.map { original in
            var stroke = original
            let inverse = original.transform.affine.inverted()
            stroke.excludedAreas.append(polygon.map { point in
                let local = point.applying(inverse)
                return SIMD2(Float(local.x), Float(local.y))
            })
            return stroke
        }
        return WatchLassoSelection(document: document, layerID: layer.id, strokes: remaining + [selected],
                                   selectedIDs: [selected.id], bounds: bounds)
    }

    private func pixelContext(_ image: CGImage) -> CGContext? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context
    }

    private func rasterStroke(_ image: CGImage, bounds: CGRect) throws -> Stroke {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw SelectionError.rendering
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw SelectionError.rendering }
        var style = PencilStyle()
        style.blendingMode = .normal
        var stroke = Stroke(points: [], style: style)
        stroke.raster = StrokeRaster(png: data as Data, bounds: bounds)
        return stroke
    }
}

nonisolated enum WatchLassoGeometry {
    // Screen-point sizes stay constant as the artwork zooms.
    static let handleRadius: CGFloat = 6
    static let handleHitRadius: CGFloat = 22

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    static func path(_ points: [CGPoint], closed: Bool = true) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        if closed { path.closeSubpath() }
        return path
    }

    static func handles(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY),
         CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY)]
    }

}

struct WatchLassoOverlay: View {
    @ObservedObject var lasso: WatchLassoController
    let canvasToScreen: CGAffineTransform

    var body: some View {
        Canvas { context, _ in
            if !lasso.outline.isEmpty {
                // Only show the finger's trail. Selection calculation closes
                // the contour separately, without drawing a line to its start.
                let path = Path(WatchLassoGeometry.path(lasso.outline, closed: false)).applying(canvasToScreen)
                context.stroke(path, with: .color(.white.opacity(0.8)),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round, dash: [0.1, 4]))
                context.stroke(path, with: .color(.gray),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [0.1, 4]))
            }
            if let bounds = lasso.bounds, !lasso.hidesControls {
                let rect = bounds.applying(canvasToScreen)
                let borderColor = Color(red: 0.20, green: 0.43, blue: 1)
                let handleColor = Color(red: 0.16, green: 0.67, blue: 0.87)
                context.stroke(Path(rect), with: .color(borderColor), lineWidth: 1)
                for point in WatchLassoGeometry.handles(rect) {
                    let radius = WatchLassoGeometry.handleRadius
                    let handle = Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                                                      width: radius * 2, height: radius * 2))
                    context.fill(handle, with: .color(handleColor))
                    context.stroke(handle, with: .color(.white), lineWidth: 1)
                }
            }
        }
        .overlay { if lasso.isPreparing { ProgressView().tint(.cyan) } }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
