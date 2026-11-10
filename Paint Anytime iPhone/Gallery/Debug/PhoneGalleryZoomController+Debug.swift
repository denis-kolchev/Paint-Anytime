#if DEBUG
import SwiftUI

/// Text for the gallery's geometry overlay. Reads zoom state only.
extension PhoneGalleryZoomController {
    private func debugNumber(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }

    private func debugRect(_ frame: CGRect) -> String {
        "\(debugNumber(frame.minX)),\(debugNumber(frame.minY)) \(debugNumber(frame.width))x\(debugNumber(frame.height))"
    }

    func debugInteraction(isPinching: Bool) -> String {
        if pendingZoomColumns != nil { return "Zoom: restoring position" }
        if settlingZoom { return "Zoom: settling" }
        if isPinching { return "Gesture: pinch" }
        if hasTwoFingerContact { return "Zoom: two fingers" }
        if pinchTarget != nil { return "Zoom: finishing" }
        if debugScrollMoving { return "Scroll: moving" }
        return "Gesture: idle"
    }

    func debugOverlayText(width: CGFloat, isPinching: Bool) -> String {
        debugInteraction(isPinching: isPinching) + "\n" + zoomDiagnostics.text + "\n"
            + zoomDiagnostics.sourceText + "\n"
            + (pinchTarget == nil ? "LAST\n" + zoomDiagnostics.completedGeometry
               : "LIVE\n" + debugZoomGeometry(width: width))
    }

    /// Clears the scroll indicator once the grid stops moving.
    func settleDebugScroll() async {
        guard debugScrollMoving else { return }
        do {
            try await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            debugScrollMoving = false
        } catch { /* A newer scroll position restarts the idle delay. */ }
    }

    func debugZoomGeometry(width: CGFloat) -> String {
        let images = context.images
        let columnCount = context.columnCount
        func identity(_ url: URL?) -> String {
            guard let url else { return "—" }
            return images.firstIndex(of: url).map { "#\($0)" } ?? "missing"
        }
        var lines = ["target \(identity(pinchTarget)) captured #\(zoomAnchorIndex.map(String.init) ?? "—")",
                     "native \(columnCount)c measured \(measuredGridColumns)c L\(leadingSlots)",
                     "grid \(debugRect(gridFrame))",
                     "pos \(debugNumber(zoomPresentation.position)) pan \(debugNumber(zoomPresentation.offsetY))"]
        if let index = zoomAnchorIndex, images.indices.contains(index) {
            for density in Self.columnOptions {
                let leading = slots(for: density)
                let top = zoomAnchorTops[density] ?? 0
                let itemTop = galleryItemTop(index: index, columns: density, width: width, leading: leading)
                lines.append("\(density)c L\(leading) r\((index + leading) / density)c\((index + leading) % density) y\(debugNumber(top)) scroll\(debugNumber(itemTop - top))")
            }
        }
        if let target = pinchTarget, let index = images.firstIndex(of: target),
           let measured = measuredTiles.frames[target], measured.columns == columnCount {
            let predicted = gridFrame.minY + galleryItemTop(index: index, columns: columnCount,
                width: width, leading: leadingSlots)
            lines.append("native tile \(debugRect(measured.frame))")
            lines.append("native dy \(debugNumber(measured.frame.minY - predicted)) (actual-calc)")
        } else {
            lines.append("native tile — (not measured)")
        }
        lines.append("return \(identity(pendingZoomTarget)) \(pendingZoomColumns.map(String.init) ?? "—")c y\(pendingZoomViewportTop.map(debugNumber) ?? "—")")
        if let measured = pendingZoomMeasuredFrame {
            lines.append("measured \(measured.columns)c \(debugRect(measured.frame))")
            if let top = pendingZoomViewportTop {
                lines.append("return dy \(debugNumber(measured.frame.minY - top))")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Records how the pinch picked its focal tile.
    func recordZoomStart(index: Int, viewportAnchor: UnitPoint, point: CGPoint, touch: CGPoint,
                         width: CGFloat, tileTop: CGFloat, tileHeight: CGFloat,
                         sourceTop: CGFloat, measured: Bool) {
        guard PhoneGalleryDebug.showsDiagnostics else { return }
        let images = context.images
        let columnCount = context.columnCount
        zoomDiagnostics.sourceText = "start \(columnCount)c L\(leadingSlots) grid \(debugRect(gridFrame))\n"
            + "touch screen \(debugNumber(viewportAnchor.x * width)),\(debugNumber(pinchViewportY))\n"
            + "touch grid \(debugNumber(point.x)),\(debugNumber(point.y)) frac \(debugNumber(pinchTargetFractionY))\n"
            + "pick #\(index) \(images[index].lastPathComponent)\n"
            + "tile screen y \(debugNumber(gridFrame.minY + tileTop)) h \(debugNumber(tileHeight))"
            + "\nsource \(measured ? "measured" : "fallback") y \(debugNumber(sourceTop))"
            + " shift \(debugNumber(zoomBaseFrame.minY - gridFrame.minY))"
        let touched = measuredTiles.frames.filter {
            $0.value.columns == columnCount && $0.value.frame.contains(touch)
        }.min { $0.key.absoluteString < $1.key.absoluteString }
        let touchedIndex = touched.flatMap { images.firstIndex(of: $0.key) }
        zoomDiagnostics.sourceText += "\nactual hit \(touchedIndex.map { "#\($0)" } ?? "— (gap/unmeasured)")"
        if let measuredFrame = measuredTiles.frames[images[index]],
           measuredFrame.columns == columnCount {
            let expectedY = gridFrame.minY + tileTop
            zoomDiagnostics.sourceText += "\nactual pick \(debugRect(measuredFrame.frame))"
                + "\nstart dy \(debugNumber(measuredFrame.frame.minY - expectedY)) dh \(debugNumber(measuredFrame.frame.height - tileHeight))"
        } else {
            zoomDiagnostics.sourceText += "\nactual pick — (not measured)"
        }
        let age = (ProcessInfo.processInfo.systemUptime - measuredTiles.updatedAt) * 1000
        zoomDiagnostics.sourceText += "\ngeometry age \(String(format: "%.0f", age))ms"
    }
}
#endif
