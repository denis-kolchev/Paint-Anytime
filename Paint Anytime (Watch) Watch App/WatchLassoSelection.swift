import SwiftUI
import Combine
import ImageIO

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
    @Published private(set) var previewDocument: CanvasDocument?
    @Published private(set) var isPreparing = false
    @Published var errorMessage: String?
    private(set) var previewRevision: UInt64 = 0
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
    var previewSessionID: UUID? { previewDocument == nil ? nil : generation }

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
        previewDocument = nil
        previewRevision &+= 1
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
                return
            }
            if bounds.contains(point) { drag = .move; return }
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
        guard let selection, rect != selection.bounds else {
            previewDocument = nil
            bounds = selection?.bounds
            previewRevision &+= 1
            return
        }
        let old = selection.bounds
        let sx = rect.width / old.width, sy = rect.height / old.height
        let transform = CGAffineTransform(a: sx, b: 0, c: 0, d: sy,
            tx: rect.minX - old.minX * sx, ty: rect.minY - old.minY * sy)
        var document = selection.document
        guard let index = document.layers.firstIndex(where: { $0.id == selection.layerID }) else { return }
        document.layers[index].strokes = selection.strokes.map { source in
            guard selection.selectedIDs.contains(source.id) else { return source }
            var stroke = source
            stroke.transform = StrokeTransform(source.transform.affine.concatenating(transform))
            return stroke
        }
        previewRevision &+= 1
        previewDocument = document
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
            guard var selection, let previewDocument,
                  selection.document == controller.document,
                  let layer = previewDocument.layers.first(where: { $0.id == selection.layerID }) else {
                cancelGesture()
                return
            }
            let before = state(controller)
            // Update our snapshot before publishing the controller's document change.
            selection.document = previewDocument
            selection.strokes = layer.strokes
            selection.bounds = bounds ?? selection.bounds
            self.selection = selection
            controller.replaceLayerStrokes(layer.strokes, in: selection.layerID)
            record(before, controller: controller)
            self.previewDocument = nil
            previewRevision &+= 1
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
        guard drag != nil || previewDocument != nil else { return }
        drag = nil
        outline = []
        previewDocument = nil
        bounds = selection?.bounds
        previewRevision &+= 1
    }
}

/// Brush geometry and pixel cuts run away from the UI actor.
private actor WatchLassoBuilder {
    nonisolated enum SelectionError: Error { case rendering }

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
        var selected = Set<UUID>()
        var bounds = CGRect.null
        for stroke in layer.strokes where stroke.style.instrument != .eraser {
            try Task.checkCancellation()
            let geometry = try WatchBitmapRenderer.StrokeGeometry(stroke)
            guard geometry.bounds.intersects(path.boundingBoxOfPath), geometry.bounds.intersects(paper) else { continue }
            // Evaluate each stroke's occupied area, not its centerline or
            // bounding rectangle. A small intersection is no longer enough.
            guard let visibleBounds = try majorityAreaBounds(stroke, bounds: geometry.bounds, path: path,
                size: size, scale: scale) else { continue }
            selected.insert(stroke.id)
            let selectionBounds = stroke.raster != nil || !stroke.excludedAreas.isEmpty || !stroke.erasures.isEmpty
                ? visibleBounds : geometry.bounds
            bounds = bounds.union(selectionBounds)
        }
        guard !selected.isEmpty, !bounds.isNull, !bounds.isEmpty else { return nil }
        return WatchLassoSelection(document: document, layerID: layerID, strokes: layer.strokes,
                                   selectedIDs: selected, bounds: bounds)
    }

    private func attachingErasers(in strokes: [Stroke]) throws -> [Stroke] {
        guard strokes.contains(where: { $0.style.instrument == .eraser }) else { return strokes }
        var objects: [Stroke] = []
        var bounds: [CGRect] = []
        for stroke in strokes {
            try Task.checkCancellation()
            let geometry = try WatchBitmapRenderer.StrokeGeometry(stroke)
            if stroke.style.instrument == .eraser {
                guard stroke.style.eraserMode == .pixels, !stroke.locksTransparency else { continue }
                // Only earlier objects were affected by this eraser. Keep a
                // separate local mask for each, so shared erasures can separate.
                for index in objects.indices where bounds[index].intersects(geometry.bounds) {
                    var eraser = stroke
                    eraser.transform = StrokeTransform(stroke.transform.affine.concatenating(
                        objects[index].transform.affine.inverted()))
                    objects[index].erasures.append(eraser)
                }
            } else {
                objects.append(stroke)
                bounds.append(geometry.bounds)
            }
        }
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
                    let handle = Path(ellipseIn: CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7))
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
