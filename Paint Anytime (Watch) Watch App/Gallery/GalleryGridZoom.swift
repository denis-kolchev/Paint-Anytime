import SwiftUI
import Observation

/// Watch input adapter for the same captured slots and settlement rules as iPhone.
@MainActor
@Observable
final class GalleryGridZoom {
    private(set) var sessionID: UUID?
    private(set) var slots: [GalleryZoomSlot] = []
    private(set) var images: [URL: CGImage] = [:]
    private(set) var bitmaps: [URL: GalleryBitmap] = [:]
    private(set) var snapshot: [URL] = []
    private(set) var leading: [Int: Int] = [:]
    private(set) var tops: [Int: CGFloat] = [:]
    private(set) var baseColumns = 5
    private(set) var index = 0
    private(set) var position: CGFloat = 0
    private(set) var offsetY: CGFloat = 0
    private(set) var pendingCommit: GalleryZoomCommit?
    private(set) var loadingID = UUID()
    private(set) var loadingComplete = false
    private(set) var errorMessage: String?
    private(set) var viewport: CGSize = .zero
    private(set) var topInset: CGFloat = 0
    private(set) var elasticAnchor: CGPoint = .zero
    private(set) var singleFrame: CGRect = .zero
    private(set) var isPanning = false
    private var favorites: Set<URL> = []
    private var nativeGridIsOriginal = true
    private var baseLeading = 0
    private var layout = GalleryImageLayout()
    private var panRange: CGFloat = 0
    private var lastPan: CGFloat = 0
    private var settledColumns: Int?
    private var crownInput: Double = 0
    @ObservationIgnored private var animation: Task<Void, Never>?
    @ObservationIgnored private var animationID: UUID?

    var target: URL? { snapshot.indices.contains(index) ? snapshot[index] : nil }
    var active: Bool { sessionID != nil }
    var presentationOffsetY: CGFloat { offsetY * min(1, max(0, 2 - position)) }

    func begin(images urls: [URL], target: URL, baseColumns: Int, baseLeading: Int,
               sourceFrame: CGRect, viewport: CGSize, topInset: CGFloat, bottomInset: CGFloat,
               layout: GalleryImageLayout, cached: [URL: GalleryBitmap], favorites: Set<URL>, crown: Double) {
        guard let index = urls.firstIndex(of: target), viewport.width > 0, viewport.height > topInset + bottomInset else { return }
        reset()
        self.snapshot = urls
        self.favorites = favorites
        self.index = index
        self.baseColumns = baseColumns
        self.baseLeading = baseLeading
        self.viewport = CGSize(width: viewport.width, height: viewport.height - topInset - bottomInset)
        self.topInset = topInset
        self.layout = layout
        self.crownInput = crown
        self.position = GalleryZoomRules.position(baseColumns)
        self.bitmaps = cached
        self.images = cached.mapValues(\.image)
        let size = cached[target]?.originalSize ?? CGSize(width: viewport.width,
            height: layout.height(for: target, width: viewport.width))
        singleFrame = GalleryArtworkLayout.frame(imageSize: size, viewport: viewport, fitsViewport: true)
            .offsetBy(dx: 0, dy: -topInset)
        let focalY = baseColumns == 1 ? singleFrame.midY : sourceFrame.midY - topInset
        elasticAnchor = CGPoint(x: baseColumns == 1 ? singleFrame.midX : sourceFrame.midX, y: focalY)
        leading = [baseColumns: baseLeading]
        for density in GalleryZoomRules.densities where density != baseColumns {
            let proposed = GalleryZoomRules.leading(index: index, sourceColumns: baseColumns,
                sourceLeading: baseLeading, destination: density)
            leading[density] = proposed
            let placement = GalleryZoomRules.placement(index: index, images: urls, columns: density,
                leading: proposed, width: viewport.width, height: self.viewport.height,
                layout: layout, fractionY: 0.5, viewportY: focalY)
            let top = GalleryZoomRules.itemTop(index: index, columns: density, leading: proposed, width: viewport.width, layout: layout)
            if top - placement.top <= GalleryZoomRules.side(density, width: viewport.width) + GalleryZoomRules.spacing {
                leading[density] = 0
            }
        }
        for density in GalleryZoomRules.densities {
            if density == 1 { tops[density] = singleFrame.minY }
            else if density == baseColumns { tops[density] = sourceFrame.minY - topInset }
            else {
                tops[density] = GalleryZoomRules.placement(index: index, images: urls, columns: density,
                    leading: leading[density] ?? 0, width: viewport.width, height: self.viewport.height,
                    layout: layout, fractionY: 0.5, viewportY: focalY).top
            }
        }
        sessionID = UUID()
        rebuildSlots()
    }

    private func rebuildSlots() {
        slots = GalleryZoomRules.slots(images: snapshot, index: index, baseColumns: baseColumns,
            baseLeading: baseLeading, leading: leading, tops: tops,
            width: viewport.width, height: viewport.height, layout: layout,
            panRange: panRange, singlePhotoFrame: singleFrame)
        loadingComplete = false
        loadingID = UUID()
    }

    func loadImages(scale: CGFloat) async {
        guard let session = sessionID, let target else { return }
        let requestID = loadingID
        let urls = Set(slots.flatMap { $0.images.values }).sorted {
            abs((snapshot.firstIndex(of: $0) ?? 0) - index) < abs((snapshot.firstIndex(of: $1) ?? 0) - index)
        }
        for url in urls {
            guard !Task.isCancelled, sessionID == session, loadingID == requestID else { return }
            // Freeze prepared images through the interaction; only missing previews
            // and the focal photo's full-sized transition copy are decoded here.
            if images[url] != nil, url != target { continue }
            let pixels = Int(ceil(GalleryZoomRules.side(url == target ? 1 : 3, width: viewport.width) * scale / 32)) * 32
            let bitmap = await GalleryImageCache.shared.load(GalleryImageRequest(url: url, shortSidePixels: pixels, displayScale: scale))
            guard !Task.isCancelled, sessionID == session, loadingID == requestID else { return }
            if let bitmap {
                images[url] = url != target && favorites.contains(url)
                    ? (GalleryFavoriteThumbnailRenderer.render(bitmap) ?? bitmap).image : bitmap.image
                bitmaps[url] = bitmap
            } else if url == target, images[url] == nil {
                errorMessage = L10n.text("Could not open the image.")
                reset(keepingError: true)
                return
            }
        }
        if !Task.isCancelled, sessionID == session, loadingID == requestID { loadingComplete = true }
    }

    func updateCrown(_ value: Double) {
        guard active else { return }
        interrupt()
        // Integrate deltas against the currently displayed size. A new turn during
        // settlement resumes from that frame, not the previous animation target.
        let delta = CGFloat(value - crownInput)
        crownInput = value
        let requested = GalleryZoomRules.requestedSide(position: position, width: viewport.width)
        let small = GalleryZoomRules.side(5, width: viewport.width)
        let large = GalleryZoomRules.side(1, width: viewport.width)
        // Logarithmic Crown travel follows the phone's proportional magnification.
        let next = requested * pow(large / small, delta / 2)
        position = GalleryZoomRules.position(requestedSide: next, width: viewport.width)
    }

    func settle(to requested: Int? = nil, reduceMotion: Bool) {
        guard active else { return }
        interrupt()
        let columns = requested ?? GalleryZoomRules.nearest(position: position, baseColumns: baseColumns, width: viewport.width)
        let timing = GalleryZoomRules.settlement(position: position, baseColumns: baseColumns, destination: columns)
        let session = sessionID
        let token = UUID()
        animationID = token
        let start = GalleryZoomRules.sizeProgress(position)
        let endPosition = GalleryZoomRules.position(columns)
        let end = GalleryZoomRules.sizeProgress(endPosition)
        animation = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            let began = clock.now
            while !Task.isCancelled {
                guard let self, self.sessionID == session, self.animationID == token else { return }
                let elapsed = began.duration(to: clock.now).components
                let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                let time = reduceMotion ? 1 : min(1, seconds / timing.duration)
                let progress = GalleryZoomRules.easing(time, gridTransition: timing.gridTransition)
                self.position = time >= 1 ? endPosition : GalleryZoomRules.positionFromSize(start + (end - start) * CGFloat(progress))
                if time >= 1 {
                    self.settledColumns = columns
                    self.commitIfReady()
                    return
                }
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            }
        }
    }

    private func interrupt() {
        animation?.cancel()
        animation = nil
        animationID = nil
        settledColumns = nil
        pendingCommit = nil
    }

    func pan(to translation: CGFloat) {
        guard active else { return }
        if !isPanning {
            isPanning = true
            lastPan = 0
            pendingCommit = nil
        }
        let delta = translation - lastPan
        lastPan = translation
        let bounded = min(2, max(0, position))
        let from = bounded <= 1 ? 5 : 3, to = bounded <= 1 ? 3 : 1
        let progress = bounded <= 1 ? bounded : bounded - 1
        func bounds(_ columns: Int) -> (top: CGFloat, bottom: CGFloat) {
            if columns == 1 { return (singleFrame.minY, singleFrame.maxY) }
            let side = GalleryZoomRules.side(columns, width: viewport.width)
            let start = (tops[columns] ?? 0) - GalleryZoomRules.itemTop(index: index, columns: columns,
                leading: leading[columns] ?? 0, width: viewport.width, layout: layout)
            let rows = (snapshot.count + (leading[columns] ?? 0) + columns - 1) / columns
            return (start, start + CGFloat(rows) * side + CGFloat(max(0, rows - 1)) * GalleryZoomRules.spacing)
        }
        let a = bounds(from), b = bounds(to)
        let scale = 1 + position - bounded
        let anchorY = elasticAnchor.y
        let top = anchorY + (a.top + (b.top - a.top) * progress - anchorY) * scale
        let bottom = anchorY + (a.bottom + (b.bottom - a.bottom) * progress - anchorY) * scale
        guard bottom - top > viewport.height else { return }
        offsetY = min(-top, max(viewport.height - bottom, offsetY + delta))
        if abs(offsetY) > panRange {
            panRange = abs(offsetY) + viewport.height
            rebuildSlots()
        }
    }

    func endPan() {
        isPanning = false
        lastPan = 0
        commitIfReady()
    }

    func nativeLayoutWillChange() {
        nativeGridIsOriginal = false
    }

    private func commitIfReady() {
        guard let columns = settledColumns, !isPanning, let target else { return }
        if columns == 1 {
            pendingCommit = GalleryZoomCommit(columns: 1, leading: 0, target: target, anchorY: 0.5, viewportTop: singleFrame.minY + topInset)
            return
        }
        if columns == baseColumns, offsetY == 0, nativeGridIsOriginal {
            // The original grid is still mounted at its exact original offset.
            pendingCommit = GalleryZoomCommit(columns: columns, leading: baseLeading, target: target,
                anchorY: -1, viewportTop: (tops[columns] ?? 0) + topInset)
            return
        }
        let placement = GalleryZoomRules.placement(index: index, images: snapshot, columns: columns,
            leading: leading[columns] ?? 0, width: viewport.width, height: viewport.height,
            layout: layout, fractionY: 0.5, viewportY: singleFrame.midY,
            capturedTop: tops[columns], offsetY: offsetY)
        let top = GalleryZoomRules.itemTop(index: index, columns: columns, leading: leading[columns] ?? 0, width: viewport.width, layout: layout)
        let scroll = top - placement.top
        let side = GalleryZoomRules.side(columns, width: viewport.width)
        let row = max(0, Int((scroll + viewport.height / 2) / (side + GalleryZoomRules.spacing)))
        let visibleIndex = min(snapshot.count - 1, max(0, row * columns - (leading[columns] ?? 0)))
        let visibleTop = GalleryZoomRules.itemTop(index: visibleIndex, columns: columns,
            leading: leading[columns] ?? 0, width: viewport.width, layout: layout) - scroll
        let denominator = viewport.height - side
        pendingCommit = GalleryZoomCommit(columns: columns, leading: leading[columns] ?? 0,
            target: snapshot[visibleIndex], anchorY: abs(denominator) > 1 ? visibleTop / denominator : 0.5,
            viewportTop: visibleTop + topInset)
    }

    func reset(keepingError: Bool = false) {
        interrupt()
        sessionID = nil
        nativeGridIsOriginal = true
        loadingComplete = false
        slots = []
        images = [:]
        bitmaps = [:]
        snapshot = []
        offsetY = 0
        panRange = 0
        isPanning = false
        lastPan = 0
        if !keepingError { errorMessage = nil }
    }
}
