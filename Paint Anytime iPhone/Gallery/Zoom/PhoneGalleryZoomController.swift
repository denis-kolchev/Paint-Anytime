import Observation
import QuartzCore
import SwiftUI
import UIKit

/// Gallery values the zoom reads at the moment of a call. The view rebuilds
/// it for each entry point, so the controller never holds stale view state.
@MainActor
struct PhoneGalleryZoomContext {
    var images: [URL]
    var columnCount: Int
    var imageLayout: GalleryImageLayout
    var previewCache: PhoneGalleryPreviewCache
    var displayScale: CGFloat
    var colorScheme: ColorScheme
    var reduceMotion: Bool
    /// The grid's top content margin below the header and its fade.
    var topInset: CGFloat
    /// Persists the density the zoom settled on.
    var setColumnCount: (Int) -> Void
}

/// Pinch-to-zoom between 5, 3 and 1 columns: gesture session, prepared overlay
/// slots, settlement and the handoff back to the hidden native grid.
@MainActor
@Observable
final class PhoneGalleryZoomController {
    static let columnOptions = [1, 3, 5]
    static let spacing: CGFloat = 2

    let zoomPresentation = PhoneGalleryZoomPresentation()
    var zoomAnchorIndex: Int?
    var zoomSnapshot: [URL] = []
    var zoomSessionID: UUID?
    var zoomMissingPreviews: [URL] = []
    var measuredGridColumns = 0
    var zoomSlots: [PhoneGalleryZoomSlot] = []
    var zoomPreviews: [URL: UIImage] = [:]
    var zoomPreviewSize = 640
    var zoomSideBackdrops: [Int: UIImage] = [:]
    var zoomSideBackdropFrame: CGRect = .zero
    var zoomBaseColumns = 5
    var zoomGestureBaseSide: CGFloat?
    var zoomBaseLeadingSlots = 0
    var zoomBaseFrame: CGRect = .zero
    var pendingZoomViewportTop: CGFloat?
    var pendingZoomMeasuredFrame: PhoneGalleryLayout?
    var zoomPanLastY: CGFloat?
    var zoomSettledColumns: Int?
    var zoomAnchorTops: [Int: CGFloat] = [:]
    var zoomPreparedPanRange: CGFloat = 0
    /// Leading slots change row alignment without changing document order.
    var leadingSlots = 0
    var zoomLeadingSlots: [Int: Int] = [:]
    var settlingZoom = false
    var zoomSettlementID: UUID?
    var gridFrame: CGRect = .zero
    var pinchTarget: URL?
    var pinchTargetFractionY: CGFloat = 0.5
    var pinchViewportY: CGFloat = 0
    var pendingZoomAnchor: UnitPoint?
    var pendingZoomTarget: URL?
    var pendingZoomColumns: Int?
    var hasTwoFingerContact = false
    var suppressOpeningUntil = Date.distantPast
    /// Latest materialized tile frames; reports do not invalidate the gallery.
    let measuredTiles = PhoneGalleryMeasuredTiles()
    // Debug-only state. Stored in every configuration because the Observation
    // macro must see a fixed set of properties; only DEBUG code reads it.
    var debugScrollMoving = false
    var zoomDiagnostics = PhoneGalleryZoomDiagnostics()

    @ObservationIgnored private(set) var context = PhoneGalleryZoomContext(
        images: [], columnCount: 5, imageLayout: GalleryImageLayout(),
        previewCache: PhoneGalleryPreviewCache(), displayScale: 1, colorScheme: .light,
        reduceMotion: false, topInset: 0, setColumnCount: { _ in })

    private var images: [URL] { context.images }
    private var columnCount: Int { context.columnCount }
    private var imageLayout: GalleryImageLayout { context.imageLayout }
    private var previewCache: PhoneGalleryPreviewCache { context.previewCache }
    private var galleryScrollTopInset: CGFloat { context.topInset }
    private var columnOptions: [Int] { Self.columnOptions }
    private var gallerySpacing: CGFloat { Self.spacing }

    private func use(_ newContext: PhoneGalleryZoomContext?) {
        if let newContext { context = newContext }
    }

    // MARK: Gesture entry points

    func magnifyChanged(startAnchor: UnitPoint, magnification: CGFloat, width: CGFloat,
                        viewportHeight: CGFloat, context newContext: PhoneGalleryZoomContext) {
        use(newContext)
        #if DEBUG
        if zoomDiagnostics.startedAt == nil { zoomDiagnostics.begin() }
        if zoomDiagnostics.recognizedMS == nil {
            zoomDiagnostics.recognizedMS = zoomDiagnostics.elapsedMS()
        }
        #endif
        if settlingZoom, pendingZoomColumns == nil {
            interruptGalleryZoom(width: width)
        }
        guard pendingZoomColumns == nil else { return }
        suppressOpeningUntil = .distantFuture
        if pinchTarget == nil {
            beginGalleryZoom(anchor: startAnchor, width: width, viewportHeight: viewportHeight)
        }
        updateGalleryZoom(magnification, width: width, viewportHeight: viewportHeight)
    }

    func magnifyEnded(startAnchor: UnitPoint, magnification: CGFloat, width: CGFloat,
                      viewportHeight: CGFloat, context newContext: PhoneGalleryZoomContext) {
        use(newContext)
        guard !settlingZoom else { return }
        suppressOpeningUntil = Date().addingTimeInterval(0.3)
        if pinchTarget == nil {
            beginGalleryZoom(anchor: startAnchor, width: width, viewportHeight: viewportHeight)
        }
        updateGalleryZoom(magnification, width: width, viewportHeight: viewportHeight)
        finishGalleryZoom(width: width, viewportHeight: viewportHeight)
    }

    /// Raw one-finger movement pans the overlay while Canvas owns the gallery.
    func touchesMoved(_ positions: [CGPoint], width: CGFloat, viewportHeight: CGFloat,
                      context newContext: PhoneGalleryZoomContext) {
        use(newContext)
        #if DEBUG
        if positions.count >= 2, zoomDiagnostics.movementMS == nil {
            zoomDiagnostics.movementMS = zoomDiagnostics.elapsedMS()
        }
        #endif
        guard positions.count == 1, pinchTarget != nil else { return }
        moveGalleryZoomPan(to: positions[0].y, width: width, viewportHeight: viewportHeight)
    }

    /// `isPinching` is read after a run-loop turn, so it must be live state.
    func touchContactsChanged(_ positions: [CGPoint], width: CGFloat, viewportHeight: CGFloat,
                              isPinching: @escaping @MainActor () -> Bool,
                              context newContext: PhoneGalleryZoomContext) {
        use(newContext)
        #if DEBUG
        if positions.count >= 2, !hasTwoFingerContact { zoomDiagnostics.begin() }
        #endif
        if positions.count == 1, pinchTarget != nil {
            beginGalleryZoomPan(at: positions[0].y)
        } else {
            zoomPanLastY = nil
        }
        if pendingZoomColumns != nil, positions.count >= 2 {
            // Reuse the prepared overlay while the hidden grid is
            // being restored. A second pinch must not rebuild from
            // a grid frame that may still belong to the old layout.
            pendingZoomColumns = nil
            pendingZoomTarget = nil
            pendingZoomAnchor = nil
            pendingZoomViewportTop = nil
            pendingZoomMeasuredFrame = nil
            interruptGalleryZoom(width: width)
        }
        hasTwoFingerContact = positions.count >= 2
        if positions.isEmpty, let columns = zoomSettledColumns {
            commitGalleryZoom(columns: columns, width: width, viewportHeight: viewportHeight)
        }
        if hasTwoFingerContact, settlingZoom, pendingZoomColumns == nil {
            interruptGalleryZoom(width: width)
        }
        if hasTwoFingerContact {
            guard !settlingZoom, pinchTarget == nil,
                  width > 0, viewportHeight > 0 else { return }
            let center = positions.reduce(CGPoint.zero) {
                CGPoint(x: $0.x + $1.x, y: $0.y + $1.y)
            }
            let count = CGFloat(positions.count)
            suppressOpeningUntil = .distantFuture
            beginGalleryZoom(
                anchor: UnitPoint(x: center.x / count / width,
                                  y: center.y / count / viewportHeight),
                width: width, viewportHeight: viewportHeight)
        } else {
            // Give MagnifyGesture.onEnded priority if scale was
            // recognized. Also finish two-finger taps with no zoom.
            DispatchQueue.main.async { [self] in
                guard !hasTwoFingerContact, !isPinching(), !settlingZoom,
                      pinchTarget != nil else { return }
                if zoomPresentation.scale == 1,
                   zoomPresentation.position == PhoneGalleryZoomPresentation.position(for: zoomBaseColumns),
                   zoomPresentation.offsetY == 0, zoomPanLastY == nil {
                    completeGalleryZoom()
                    return
                }
                finishGalleryZoom(width: width, viewportHeight: viewportHeight)
            }
        }
    }

    /// Called after a pinch ends; onEnded must get a chance to settle first.
    func pinchEnded(width: CGFloat, viewportHeight: CGFloat,
                    isPinching: @escaping @MainActor () -> Bool,
                    context newContext: PhoneGalleryZoomContext) {
        use(newContext)
        DispatchQueue.main.async { [self] in
            guard !isPinching(), !settlingZoom else { return }
            guard pinchTarget != nil else {
                suppressOpeningUntil = Date().addingTimeInterval(0.3)
                return
            }
            finishGalleryZoom(width: width, viewportHeight: viewportHeight)
        }
    }

    // MARK: Layout reports

    func updateMeasuredTiles(_ frames: [URL: PhoneGalleryLayout]) {
        measuredTiles.frames = frames
        measuredTiles.updatedAt = ProcessInfo.processInfo.systemUptime
    }

    func updateGridLayout(_ layout: PhoneGalleryLayout, isPinching: Bool) {
        guard layout.columns > 0 else { return }
        #if DEBUG
        // Observe movement without adding a competing drag recognizer.
        // This includes inertial scrolling, not just finger dragging.
        if gridFrame != .zero, gridFrame.minY != layout.frame.minY,
           pinchTarget == nil, !isPinching, !settlingZoom {
            debugScrollMoving = true
        }
        #endif
        gridFrame = layout.frame
        measuredGridColumns = layout.columns
    }

    // MARK: Session tasks

    func loadMissingPreviews(sessionID: UUID) async {
        #if DEBUG
        let loadingStarted = CACurrentMediaTime()
        let diagnosticSession = zoomDiagnostics.session
        #endif
        let cache = previewCache
        for url in zoomMissingPreviews {
            guard !Task.isCancelled, zoomSessionID == sessionID else { return }
            let image = await cache.load(url, maximumSize: 320)
            guard !Task.isCancelled, zoomSessionID == sessionID else { return }
            if let image { zoomPreviews[url] = image }
        }
        #if DEBUG
        if zoomDiagnostics.session == diagnosticSession {
            zoomDiagnostics.loadingMS = (CACurrentMediaTime() - loadingStarted) * 1000
        }
        #endif
    }

    /// Scrolls the hidden grid under the overlay until the focal tile matches,
    /// then reveals it.
    func restorePendingPosition(viewportHeight: CGFloat,
                                scrollTo: (URL, UnitPoint) -> Void) async {
        guard let columns = pendingZoomColumns,
              let target = pendingZoomTarget,
              let anchor = pendingZoomAnchor,
              let viewportTop = pendingZoomViewportTop else { return }
        let settlementID = zoomSettlementID
        var attempts = 0
        // Scroll only after layout has returned to the run loop.
        // Lazy rows may need a second pass after materialization.
        while !Task.isCancelled {
            do { try await Task.sleep(for: .milliseconds(32)) }
            catch { return }
            guard !Task.isCancelled, zoomSettlementID == settlementID,
                  pendingZoomColumns == columns, pendingZoomTarget == target else { return }
            guard measuredGridColumns == columns else { continue }
            if let measured = pendingZoomMeasuredFrame, measured.columns == columns,
               abs(measured.frame.minY - viewportTop) < 1 {
                completeGalleryZoom()
                return
            }
            // If exact alignment is unavailable (for example at a
            // content edge), retain the focal photo rather than
            // exposing an unconfirmed grid at its initial offset.
            if attempts >= 4, let measured = pendingZoomMeasuredFrame,
               measured.columns == columns,
               measured.frame.maxY > 0, measured.frame.minY < viewportHeight {
                completeGalleryZoom()
                return
            }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                scrollTo(target, attempts < 4 ? anchor : .center)
            }
            attempts += 1
        }
    }

    // MARK: Zoom session

    private func tileSide(columns: Int, width: CGFloat) -> CGFloat {
        GalleryZoomRules.side(columns, width: width)
    }

    private func beginGalleryZoom(anchor viewportAnchor: UnitPoint, width: CGFloat,
                                  viewportHeight: CGFloat) {
        guard !images.isEmpty, gridFrame.height > 0 else { return }
        #if DEBUG
        let preparationStarted = CACurrentMediaTime()
        defer { zoomDiagnostics.preparationMS = (CACurrentMediaTime() - preparationStarted) * 1000 }
        #endif
        zoomPresentation.stopAnimation()
        zoomGestureBaseSide = nil
        zoomBaseColumns = columnCount
        zoomBaseLeadingSlots = leadingSlots
        zoomBaseFrame = gridFrame
        zoomAnchorTops = [:]
        zoomPreparedPanRange = 0
        zoomSettledColumns = nil
        zoomPanLastY = nil
        // The recognizer lives on the viewport, not on the disappearing grid.
        let anchor = UnitPoint(
            x: viewportAnchor.x,
            y: (viewportAnchor.y * viewportHeight - gridFrame.minY) / gridFrame.height)
        zoomPresentation.position = PhoneGalleryZoomPresentation.position(for: columnCount)
        zoomPresentation.offsetY = 0
        zoomPresentation.elasticAnchor = CGPoint(
            x: viewportAnchor.x * width, y: viewportAnchor.y * viewportHeight)
        let side = tileSide(columns: columnCount, width: width)
        let stride = side + gallerySpacing
        let point = CGPoint(x: anchor.x * gridFrame.width, y: anchor.y * gridFrame.height)
        // Choose the nearest tile if the midpoint falls in the spacing or the
        // empty cells of the last row. Keep that identity for the entire gesture.
        let row = max(0, Int(((point.y - side / 2) / stride).rounded()))
        let column = min(columnCount - 1, max(0, Int(((point.x - side / 2) / stride).rounded())))
        let touch = CGPoint(x: viewportAnchor.x * width, y: viewportAnchor.y * viewportHeight)
        let viewport = CGRect(x: 0, y: 0, width: width, height: viewportHeight)
        // LazyVGrid's estimated origin can disagree with its materialized rows.
        // Pick by distance to actual tile bounds (zero inside a tile), so a
        // portrait under the fingers wins over a neighboring tile's center.
        let measuredSource = measuredTiles.frames.filter {
            $0.value.columns == columnCount && abs($0.value.frame.width - side) < 1
                && $0.value.frame.height > 0 && $0.value.frame.intersects(viewport)
                && images.contains($0.key)
        }.min { lhs, rhs in
            func distance(_ frame: CGRect) -> CGFloat {
                let dx = max(frame.minX - touch.x, max(0, touch.x - frame.maxX))
                let dy = max(frame.minY - touch.y, max(0, touch.y - frame.maxY))
                return dx * dx + dy * dy
            }
            let left = distance(lhs.value.frame), right = distance(rhs.value.frame)
            return left == right ? lhs.key.absoluteString < rhs.key.absoluteString : left < right
        }
        let index: Int
        if let measuredSource, let measuredIndex = images.firstIndex(of: measuredSource.key) {
            index = measuredIndex
        } else if columnCount == 1 {
            // Use the containing tile, not its center: a tall portrait can
            // contain the touch even when a neighboring short tile is nearer.
            index = images.indices.first {
                imageLayout.top(at: $0 + 1, width: side, spacing: gallerySpacing)
                    - gallerySpacing / 2 > point.y
            } ?? (images.count - 1)
        } else {
            index = min(images.count - 1, max(0, row * columnCount + column - leadingSlots))
        }
        zoomAnchorIndex = index
        zoomSnapshot = images
        previewCache.preparationPaused = true
        pinchTarget = images[index]
        let tileTop = galleryItemTop(index: index, columns: columnCount, width: width, leading: leadingSlots)
        let tileHeight = galleryItemHeight(index: index, columns: columnCount, width: width)
        let sourceTop = measuredSource?.value.frame.minY ?? (gridFrame.minY + tileTop)
        let sourceHeight = measuredSource?.value.frame.height ?? tileHeight
        // Translate the captured model to the visible row, then freeze it for
        // this session. Subsequent pan/zoom keeps using that same coordinate space.
        zoomBaseFrame.origin.y = sourceTop - tileTop
        pinchTargetFractionY = min(1, max(0, (touch.y - sourceTop) / sourceHeight))
        pinchViewportY = touch.y
        zoomLeadingSlots = [columnCount: leadingSlots]
        for density in columnOptions where density != columnCount {
            // Zooming out reveals neighbors around the focal tile. Zooming in
            // keeps its approximate horizontal position until it fills the width.
            let slots = GalleryZoomRules.leading(index: index, sourceColumns: columnCount,
                sourceLeading: leadingSlots, destination: density)
            zoomLeadingSlots[density] = slots
            let destinationSide = tileSide(columns: density, width: width)
            let targetTop = galleryItemTop(index: index, columns: density, width: width, leading: slots)
            if let placement = settledGalleryPlacement(columns: density, width: width,
                                                       viewportHeight: viewportHeight),
               targetTop - placement.viewportTop <= destinationSide + gallerySpacing {
                // Only regroup when the incomplete first row is offscreen.
                zoomLeadingSlots[density] = 0
            }
        }
        #if DEBUG
        recordZoomStart(index: index, viewportAnchor: viewportAnchor, point: point, touch: touch,
                        width: width, tileTop: tileTop, tileHeight: tileHeight,
                        sourceTop: sourceTop, measured: measuredSource != nil)
        #endif
        prepareZoomSlots(width: width, viewportHeight: viewportHeight)
    }

    private func prepareZoomSlots(width: CGFloat, viewportHeight: CGFloat) {
        guard let index = zoomAnchorIndex else { return }
        #if DEBUG
        let slotsStarted = CACurrentMediaTime()
        defer {
            zoomDiagnostics.slotsMS = (CACurrentMediaTime() - slotsStarted) * 1000
            zoomDiagnostics.slotCount = zoomSlots.count
            zoomDiagnostics.missingCount = zoomMissingPreviews.count
        }
        #endif
        let side = tileSide(columns: zoomBaseColumns, width: width)
        let anchorTops = zoomAnchorTops.isEmpty ? Dictionary(uniqueKeysWithValues: columnOptions.map { density in
            let top = density == zoomBaseColumns
                ? zoomBaseFrame.minY + galleryItemTop(index: index, columns: density, width: width, leading: zoomBaseLeadingSlots)
                : settledGalleryPlacement(columns: density, width: width, viewportHeight: viewportHeight)?.viewportTop ?? 0
            return (density, top)
        }) : zoomAnchorTops
        zoomAnchorTops = anchorTops
        let prepared = GalleryZoomRules.slots(images: zoomSnapshot, index: index,
            baseColumns: zoomBaseColumns, baseLeading: zoomBaseLeadingSlots,
            leading: zoomLeadingSlots, tops: anchorTops, width: width, height: viewportHeight,
            layout: imageLayout, panRange: zoomPreparedPanRange)
        let urls = Set(prepared.flatMap { $0.images.values })
        zoomPreviewSize = PhoneGalleryPreviewCache.size(for: side * context.displayScale)
        let cache = previewCache
        zoomPreviews = urls.reduce(into: [:]) { result, url in
            // Hold the best prepared copy through the entire gesture, including
            // changes between density pairs. Never evict a displayed transition.
            if let image = cache.availableImage(for: url, maximumSize: 1600) {
                result[url] = image
            }
        }
        zoomSlots = prepared
        // Load only absent snapshots, once per session, through the serial decoder.
        // The render loop itself never starts requests or changes image tiers.
        let snapshot = zoomSnapshot
        let previews = zoomPreviews
        zoomMissingPreviews = urls.filter { previews[$0] == nil }.sorted {
            let left = snapshot.firstIndex(of: $0) ?? 0
            let right = snapshot.firstIndex(of: $1) ?? 0
            return abs(left - index) < abs(right - index)
        }
        zoomSessionID = UUID()
    }

    /// Capture prepared previews on the main actor, then rasterize independently
    /// of gesture delivery and missing-preview loading.
    func prepareZoomSideBackdrop(width: CGFloat, viewportHeight: CGFloat, sessionID: UUID) async {
        guard !Task.isCancelled, zoomSessionID == sessionID else { return }
        #if DEBUG
        let backdropStarted = CACurrentMediaTime()
        let diagnosticSession = zoomDiagnostics.session
        #endif
        let side = tileSide(columns: 5, width: width)
        let stride = side + gallerySpacing
        let leading = slots(for: 5)
        guard let anchorIndex = zoomAnchorIndex,
              let anchorFrame = zoomSlots.first(where: { $0.images[5] == zoomSnapshot[anchorIndex] })?.frames[5] else {
            zoomSideBackdrops = [:]
            return
        }
        let originY = anchorFrame.minY - CGFloat((anchorIndex + leading) / 5) * stride
        // Bound destination rows, not source rows: partial rows still need
        // side copies, but nothing may extend vertically beyond real content.
        let tiles = zoomSlots.filter { slot in
            guard let column = slot.columns[5], let rect = slot.frames[5] else { return false }
            return (0..<5).contains(column) && rect.maxY >= -3 * stride
                && rect.minY <= viewportHeight + 3 * stride
        }
        guard let top = tiles.compactMap({ $0.frames[5]?.minY }).min(),
              let bottom = tiles.compactMap({ $0.frames[5]?.maxY }).max() else {
            zoomSideBackdrops = [:]
            return
        }
        // Five full column strides keep the seam identical to internal spacing.
        let bounds = CGRect(x: 0, y: top, width: width + gallerySpacing, height: bottom - top)
        var drawTiles: [Int: [PhoneGalleryBackdropRenderer.Tile]] = [:]
        for direction in [-1, 1] {
            for slot in tiles {
                guard let rect = slot.frames[5], let column = slot.columns[5] else { continue }
                let destinationRow = Int(((rect.minY - originY) / stride).rounded())
                guard let url = GalleryZoomRules.backdropURL(images: zoomSnapshot,
                    leading: leading, row: destinationRow, column: column, direction: direction) else { continue }
                guard let image = zoomPreviews[url] ?? previewCache.availableImage(for: url, maximumSize: zoomPreviewSize),
                      image.size.width > 0, image.size.height > 0 else { continue }
                let tile = rect.offsetBy(dx: 0, dy: -top)
                drawTiles[direction, default: []].append(.init(image: image, rect: tile))
            }
        }
        // Resolve dynamic colors here: a background actor has no view trait environment.
        let background = UIColor.systemBackground.resolvedColor(with:
            UITraitCollection(userInterfaceStyle: context.colorScheme == .dark ? .dark : .light))
        guard let backdrops = await PhoneGalleryBackdropRenderer.shared.render(
            tiles: drawTiles, size: bounds.size, scale: min(context.displayScale, 2), background: background),
            !Task.isCancelled, zoomSessionID == sessionID else { return }
        zoomSideBackdrops = backdrops
        zoomSideBackdropFrame = bounds
        #if DEBUG
        if zoomDiagnostics.session == diagnosticSession {
            zoomDiagnostics.backdropMS = (CACurrentMediaTime() - backdropStarted) * 1000
        }
        #endif
    }

    private func updateGalleryZoom(_ magnification: CGFloat, width: CGFloat, viewportHeight: CGFloat) {
        #if DEBUG
        defer {
            if zoomDiagnostics.appliedMS == nil {
                zoomDiagnostics.appliedMS = zoomDiagnostics.elapsedMS()
            }
        }
        #endif
        let initialSide = tileSide(columns: zoomBaseColumns, width: width)
        let minimumSide = tileSide(columns: 5, width: width)
        let maximumSide = tileSide(columns: 1, width: width)
        let requestedSide = (zoomGestureBaseSide ?? initialSide) * magnification
        let side = min(maximumSide, max(minimumSide, requestedSide))
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            // One continuous value owns the entire 5 ↔ 3 ↔ 1 transition.
            // Crossing three columns cannot pair a new grid with old progress.
            zoomPresentation.scale = side / initialSide
            // Convert rubber-band distance back to a relative scale, keeping
            // resistance and normal zoom on the same animation coordinate.
            zoomPresentation.position = GalleryZoomRules.position(requestedSide: requestedSide, width: width)
        }
    }

    func slots(for columns: Int) -> Int {
        zoomLeadingSlots[columns] ?? 0
    }

    private func galleryItemHeight(index: Int, columns: Int, width: CGFloat) -> CGFloat {
        let side = tileSide(columns: columns, width: width)
        return columns == 1 ? imageLayout.height(for: images[index], width: side) : side
    }

    func galleryItemTop(index: Int, columns: Int, width: CGFloat, leading: Int) -> CGFloat {
        let side = tileSide(columns: columns, width: width)
        return columns == 1 ? imageLayout.top(at: index, width: side, spacing: gallerySpacing)
            : CGFloat((index + leading) / columns) * (side + gallerySpacing)
    }

    private func beginGalleryZoomPan(at y: CGFloat) {
        zoomPanLastY = y
        // Cancels the restoration task without stopping the scale animation.
        pendingZoomColumns = nil
        pendingZoomTarget = nil
        pendingZoomAnchor = nil
        pendingZoomViewportTop = nil
        pendingZoomMeasuredFrame = nil
    }

    private func moveGalleryZoomPan(to y: CGFloat, width: CGFloat, viewportHeight: CGFloat) {
        guard let previousY = zoomPanLastY else {
            beginGalleryZoomPan(at: y)
            return
        }
        zoomPanLastY = y
        guard let index = zoomAnchorIndex else { return }
        let bounded = min(2, max(0, zoomPresentation.position))
        let from = bounded <= 1 ? 5 : 3
        let to = bounded <= 1 ? 3 : 1
        let progress = bounded <= 1 ? bounded : bounded - 1
        func bounds(for columns: Int) -> (top: CGFloat, bottom: CGFloat) {
            let side = tileSide(columns: columns, width: width)
            let top = (zoomAnchorTops[columns] ?? 0)
                - galleryItemTop(index: index, columns: columns, width: width, leading: slots(for: columns))
            let rows = (zoomSnapshot.count + slots(for: columns) + columns - 1) / columns
            let height = columns == 1
                ? imageLayout.top(at: zoomSnapshot.count, width: side, spacing: gallerySpacing) - gallerySpacing
                : CGFloat(rows) * side + CGFloat(max(0, rows - 1)) * gallerySpacing
            return (top, top + height)
        }
        let start = bounds(for: from)
        let end = bounds(for: to)
        let scale = 1 + zoomPresentation.position - bounded
        let anchorY = zoomPresentation.elasticAnchor.y
        let top = anchorY + (start.top + (end.top - start.top) * progress - anchorY) * scale
        let bottom = anchorY + (start.bottom + (end.bottom - start.bottom) * progress - anchorY) * scale
        let maximumOffset = galleryScrollTopInset - top
        let minimumOffset = min(maximumOffset, viewportHeight - bottom)
        zoomPresentation.offsetY = min(maximumOffset, max(minimumOffset,
            zoomPresentation.offsetY + y - previousY))
        // Keep enough prepared rows for a long drag while scale is settling.
        if abs(zoomPresentation.offsetY) > zoomPreparedPanRange {
            zoomPreparedPanRange = abs(zoomPresentation.offsetY) + viewportHeight
            prepareZoomSlots(width: width, viewportHeight: viewportHeight)
        }
    }

    private func finishGalleryZoom(width: CGFloat, viewportHeight: CGFloat) {
        let destination = GalleryZoomRules.nearest(position: zoomPresentation.position,
            baseColumns: zoomBaseColumns, width: width)
        settleGalleryZoom(columns: destination, width: width, viewportHeight: viewportHeight)
    }

    private func settleGalleryZoom(columns nearest: Int, width: CGFloat, viewportHeight: CGFloat) {
        guard !settlingZoom else { return }
        settlingZoom = true
        let settlementID = UUID()
        zoomSettlementID = settlementID
        suppressOpeningUntil = .distantFuture
        let finalScale = tileSide(columns: nearest, width: width) / tileSide(columns: zoomBaseColumns, width: width)
        let finalPosition = PhoneGalleryZoomPresentation.position(for: nearest)
        let timing = GalleryZoomRules.settlement(position: zoomPresentation.position,
            baseColumns: zoomBaseColumns, destination: nearest)
        let duration = context.reduceMotion ? 0 : timing.duration
        let gridTransition = timing.gridTransition
        zoomPresentation.animate(to: finalPosition, duration: duration,
                                 gridTransition: gridTransition) { [weak self] in
            guard let self, zoomSettlementID == settlementID else { return }
            zoomPresentation.scale = finalScale
            zoomSettledColumns = nearest
            commitGalleryZoom(columns: nearest, width: width, viewportHeight: viewportHeight)
        }
    }

    func interruptGalleryZoom(width: CGFloat) {
        // Keep the current drawing and its focal image. Rebase the new gesture
        // from the displayed size, not the previous animation's endpoint.
        zoomPresentation.stopAnimation()
        zoomSettledColumns = nil
        zoomSettlementID = nil
        settlingZoom = false
        let position = zoomPresentation.position
        let small = tileSide(columns: 5, width: width)
        let large = tileSide(columns: 1, width: width)
        let side = GalleryZoomRules.requestedSide(position: position, width: width)
        zoomGestureBaseSide = side
        zoomPresentation.scale = min(large, max(small, side)) / tileSide(columns: zoomBaseColumns, width: width)
    }

    func resetGalleryZoom(context newContext: PhoneGalleryZoomContext? = nil) {
        use(newContext)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            zoomPresentation.stopAnimation()
            zoomGestureBaseSide = nil
            zoomSettlementID = nil
            zoomPanLastY = nil
            zoomSettledColumns = nil
            zoomAnchorTops = [:]
            zoomPreparedPanRange = 0
            previewCache.preparationPaused = false
            zoomSessionID = nil
            zoomMissingPreviews = []
            zoomSlots = []
            zoomPreviews = [:]
            zoomSideBackdrops = [:]
            zoomSideBackdropFrame = .zero
            zoomSnapshot = []
            zoomAnchorIndex = nil
            hasTwoFingerContact = false
            settlingZoom = false
            pinchTarget = nil
            zoomPresentation.scale = 1
            zoomPresentation.position = PhoneGalleryZoomPresentation.position(for: columnCount)
            zoomPresentation.offsetY = 0
            pendingZoomAnchor = nil
            pendingZoomTarget = nil
            pendingZoomColumns = nil
            pendingZoomViewportTop = nil
            pendingZoomMeasuredFrame = nil
            suppressOpeningUntil = .distantPast
        }
    }

    /// Predict the same bounded scroll position used by the committed grid.
    /// Near either end, the focal image must move because there are no more rows.
    private func settledGalleryPlacement(columns: Int, width: CGFloat,
                                         viewportHeight: CGFloat) -> (anchor: UnitPoint, viewportTop: CGFloat)? {
        guard let target = pinchTarget,
              let index = images.firstIndex(of: target) else { return nil }
        let placement = GalleryZoomRules.placement(index: index, images: images,
            columns: columns, leading: slots(for: columns), width: width, height: viewportHeight,
            layout: imageLayout, fractionY: pinchTargetFractionY, viewportY: pinchViewportY,
            capturedTop: zoomAnchorTops[columns], offsetY: zoomPresentation.offsetY,
            topInset: galleryScrollTopInset)
        return (UnitPoint(x: 0.5, y: placement.anchorY), placement.top)
    }

    private func commitGalleryZoom(columns nearest: Int, width: CGFloat, viewportHeight: CGFloat) {
        // A finger always owns the visible position. Defer only the invisible
        // grid handoff, never movement of the images under that finger.
        guard zoomPanLastY == nil else { return }
        // An unchanged layout with no Canvas pan already has the right offset.
        // Once Canvas has moved, even this layout needs a position handoff.
        if zoomPresentation.offsetY == 0, nearest == zoomBaseColumns, columnCount == nearest,
           leadingSlots == slots(for: nearest) {
            completeGalleryZoom()
            return
        }
        let placement = settledGalleryPlacement(columns: nearest, width: width, viewportHeight: viewportHeight)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if let placement, let original = pinchTarget,
               let originalIndex = images.firstIndex(of: original) {
                let scroll = galleryItemTop(index: originalIndex, columns: nearest,
                    width: width, leading: slots(for: nearest)) - placement.viewportTop
                let center = scroll + viewportHeight / 2
                let side = tileSide(columns: nearest, width: width)
                let index: Int
                if nearest == 1 {
                    index = images.indices.first {
                        imageLayout.top(at: $0 + 1, width: side, spacing: gallerySpacing) > center
                    } ?? (images.count - 1)
                } else {
                    let row = max(0, Int(center / (side + gallerySpacing)))
                    index = min(images.count - 1, max(0, row * nearest - slots(for: nearest)))
                }
                let top = galleryItemTop(index: index, columns: nearest, width: width,
                                         leading: slots(for: nearest)) - scroll
                let denominator = viewportHeight - galleryScrollTopInset
                    - galleryItemHeight(index: index, columns: nearest, width: width)
                pendingZoomAnchor = UnitPoint(x: 0.5,
                    y: abs(denominator) > 1 ? (top - galleryScrollTopInset) / denominator : 0.5)
                pendingZoomTarget = images[index]
                pendingZoomColumns = nearest
                pendingZoomViewportTop = top
                pendingZoomMeasuredFrame = nil
                leadingSlots = slots(for: nearest)
                context.setColumnCount(nearest)
                // The overlay still uses the captured source geometry. Relayout
                // and scroll correction underneath cannot move it or expose a frame.
            } else {
                completeGalleryZoom()
            }
        }
    }

    private func completeGalleryZoom() {
        #if DEBUG
        if PhoneGalleryDebug.showsDiagnostics {
            zoomDiagnostics.completedGeometry = debugZoomGeometry(width: zoomBaseFrame.width)
        }
        #endif
        resetGalleryZoom()
        suppressOpeningUntil = Date().addingTimeInterval(0.3)
    }
}
