#if DEBUG
import SwiftUI

/// Non-observable counters: recording an event must not invalidate the gallery.
@MainActor
final class WatchGalleryDiagnostics {
    static let shared = WatchGalleryDiagnostics()
    private(set) var geometryUpdates = 0
    private(set) var geometryMS = 0.0
    private(set) var loads = 0
    private(set) var cancellations = 0
    private(set) var pending = 0
    private(set) var visible = 0
    private(set) var missing = 0
    private(set) var measured = 0
    private(set) var heldMB = 0.0
    private(set) var mode = "grid"
    var scrollPhase = "unknown"
    var crownEvents = 0
    var crownIdleEvents = 0
    var crownValue = 0.0
    var crownVelocity = 0.0
    var crownAt: Double?
    var crownResult = "none"
    var restoreAttempts = 0
    var restoreError: CGFloat = 0
    var restoreReady = false
    var restoreAt: Double?

    func crown(_ value: Double, result: String) {
        guard GalleryDebug.isEnabled else { return }
        crownEvents += 1
        crownValue = value
        crownAt = ProcessInfo.processInfo.systemUptime
        crownResult = result
    }

    func inputText(zoom: GalleryGridZoom, focus: String, dragging: Bool) -> String {
        let now = ProcessInfo.processInfo.systemUptime
        let age = crownAt.map { String(format: "%.0f", (now - $0) * 1000) } ?? "—"
        let restoreAge = zoom.pendingCommit == nil ? 0 : restoreAt.map { (now - $0) * 1000 } ?? 0
        return String(format: "scroll %@ drag %d focus %@\nCrown #%d idle %d age %@ms\nv %.2f speed %.2f %@\nzoom %@ pos %.2f pan %d\nrestore %d %.0fms dy %.1f ready %d",
            scrollPhase, dragging ? 1 : 0, focus,
            crownEvents, crownIdleEvents, age, crownValue, crownVelocity, crownResult,
            zoom.debugPhase, zoom.position, zoom.isPanning ? 1 : 0,
            zoom.pendingCommit == nil ? 0 : restoreAttempts, restoreAge,
            zoom.pendingCommit == nil ? 0 : restoreError, restoreReady ? 1 : 0)
    }

    // Keep the last captured grids visible after the compositor resets.
    private var lastGridText = "captured grids —"

    func gridText(zoom: GalleryGridZoom, urls: [URL], selected: URL?, focused: URL?,
                  displayed: URL?, frames: [URL: CGRect], columns: Int, leading: Int,
                  topInset: CGFloat) -> String {
        func label(_ url: URL?) -> String {
            guard let url else { return "—" }
            return urls.firstIndex(of: url).map { "#\($0)" } ?? "missing"
        }
        func number(_ value: CGFloat) -> String { String(format: "%.1f", Double(value)) }
        let reference = frames.first { urls.contains($0.key) }
        let originY: String
        if let (url, frame) = reference, let index = urls.firstIndex(of: url) {
            let row = (index + leading) / columns
            originY = number(frame.minY - CGFloat(row) * (frame.width + GalleryZoomRules.spacing))
        } else {
            originY = "—"
        }
        if zoom.active {
            let rows = GalleryZoomRules.densities.map { density -> String in
                let padding = zoom.leading[density] ?? 0
                let slot = zoom.index + padding
                let top = zoom.tops[density] ?? 0
                let stride = GalleryZoomRules.side(density, width: zoom.viewport.width) + GalleryZoomRules.spacing
                let scroll = density == 1 ? "—" : number(CGFloat(slot / density) * stride - top)
                return "\(density)c L\(padding) r\(slot / density)c\(slot % density) y\(number(top)) s\(scroll)"
            }
            lastGridText = "target \(label(zoom.target)) base \(zoom.baseColumns)c\n" + rows.joined(separator: "\n")
        }
        let commit = zoom.pendingCommit.map {
            "commit \(label($0.target)) \($0.columns)c L\($0.leading)\ny\(number($0.viewportTop)) anchor \(number($0.anchorY))"
        } ?? "commit —"
        return "sel \(label(selected)) focus \(label(focused)) img \(label(displayed))\n" +
            "native \(columns)c L\(leading) y\(originY) inset \(number(topInset))\n" +
            (zoom.active ? "LIVE " : "LAST ") + lastGridText + "\n" +
            "pan \(number(zoom.offsetY)) shown \(number(zoom.presentationOffsetY))\n" + commit
    }

    private var lastDetails = -Double.infinity

    func geometry(elapsedMS: Double, frames: [URL: CGRect], viewport: CGSize,
                  bitmaps: [URL: GalleryBitmap], columns: Int, zooming: Bool) {
        guard GalleryDebug.isEnabled else { return }
        geometryUpdates += 1
        geometryMS += elapsedMS
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastDetails >= 0.5 else { return }
        lastDetails = now
        let bounds = CGRect(origin: .zero, size: viewport)
        var visibleCount = 0, missingCount = 0
        for (url, frame) in frames where frame.intersects(bounds) {
            visibleCount += 1
            if bitmaps[url] == nil { missingCount += 1 }
        }
        visible = visibleCount
        missing = missingCount
        measured = frames.count
        heldMB = Double(bitmaps.values.reduce(0) { $0 + $1.memoryCost }) / 1_048_576
        mode = zooming ? "zoom" : "\(columns)col"
    }

    func beganLoad() {
        guard GalleryDebug.isEnabled else { return }
        loads += 1
        pending += 1
    }

    func endedLoad(cancelled: Bool) {
        guard GalleryDebug.isEnabled else { return }
        pending = max(0, pending - 1)
        if cancelled { cancellations += 1 }
    }
}
#endif
