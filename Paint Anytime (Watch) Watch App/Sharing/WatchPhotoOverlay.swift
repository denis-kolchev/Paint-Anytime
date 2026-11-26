import CoreGraphics
import Foundation
import WatchConnectivity
import WatchKit

/// Sends the layers drawn above an imported photo, so the iPhone can put them on the
/// original photo at full resolution (see `PhotoImportProtocol`).
enum WatchPhotoOverlay {
    /// The photo's identifier while it is still exactly the imported photo, as the
    /// first stroke of the bottom layer covering the whole canvas, and everything else
    /// on that layer only paints over it. Strokes on that layer that mix with the
    /// pixels below them (eraser, blur, marker, watercolor, translucent fill, locked
    /// transparency), or any change to the photo itself (erasing, moving, cutting,
    /// hiding or fading its layer, cropping the canvas) return nil, and the phone then
    /// uses the watch's own image instead of the original. Other layers may hold anything.
    nonisolated static func photoID(in document: CanvasDocument) -> UUID? {
        guard let canvas = document.canvasSize,
              let layer = document.layers.first, layer.isVisible, layer.opacity == 1,
              !layer.locksTransparency, let stroke = layer.strokes.first,
              PhotoImportProtocol.isPhotoID(stroke.id),
              let raster = stroke.raster, stroke.transform == .identity, !stroke.locksTransparency,
              stroke.excludedAreas.isEmpty, stroke.erasures.isEmpty, stroke.fillRects == nil,
              layer.strokes.dropFirst().allSatisfy(paintsOver)
        else { return nil }
        // A proportional resize with resampling scales the photo with the canvas.
        let tolerance: CGFloat = 0.01
        guard abs(raster.bounds.minX) < tolerance, abs(raster.bounds.minY) < tolerance,
              abs(raster.bounds.width - canvas.width) < tolerance,
              abs(raster.bounds.height - canvas.height) < tolerance else { return nil }
        return stroke.id
    }

    /// True for a stroke that looks the same drawn over the photo as drawn on
    /// transparency and then put over the photo (plain source-over). Erasures attached
    /// to the stroke affect only the stroke itself.
    private nonisolated static func paintsOver(_ stroke: Stroke) -> Bool {
        guard !stroke.locksTransparency else { return false }
        if stroke.raster != nil { return true }
        switch stroke.style.instrument {
        case .monoline, .pen, .fountainPen, .reed, .pencil, .crayon:
            return true
        case .fill:
            // A translucent fill is evaluated against the pixels below it.
            return stroke.style.color.w * stroke.style.effectiveOpacity >= 1
        case .eraser:
            // Only pixel erasers draw; they would erase the photo as well.
            return stroke.style.eraserMode != .pixels
        case .marker, .watercolor, .blur:
            return false
        }
    }

    /// Call after `imageURL` (a gallery PNG) and its document are saved. Does nothing
    /// for drawings without an intact imported photo.
    @MainActor
    static func send(document: CanvasDocument, imageURL: URL, session: WCSession) {
        guard let photoID = photoID(in: document), let canvas = document.canvasSize,
              canvas.width > 0, canvas.height > 0,
              let preview = try? Data(contentsOf: imageURL) else { return }
        let stem = imageURL.deletingPathExtension().lastPathComponent
        // Everything but the photo; the phone puts it back at full resolution.
        var overlay = document
        overlay.layers[0].strokes.removeFirst()
        overlay.backgroundIsVisible = false
        var metadata: [String: Any] = [
            PhotoImportProtocol.kindKey: PhotoImportProtocol.overlayKind,
            PhotoImportProtocol.overlayForKey: stem,
            PhotoImportProtocol.photoIDKey: photoID.uuidString,
            PhotoImportProtocol.overlayDigestKey: PhotoImportProtocol.digest(preview)
        ]
        if document.backgroundIsVisible {
            let color = document.backgroundColor
            metadata[PhotoImportProtocol.overlayBackgroundKey] = [color.x, color.y, color.z, color.w].map { Double($0) }
        }
        // Sharper strokes than the canvas, within what zooming in already renders.
        let longest = max(canvas.width, canvas.height)
        let scale = max(WKInterfaceDevice.current().screenScale,
                        min(4, CGFloat(PhotoImportProtocol.maximumOverlayPixelSide) / longest))
        Task.detached(priority: .utility) {
            guard let image = WatchBitmapRenderer.render(document: overlay, size: canvas, scale: scale),
                  let png = WatchPhotoImport.png(image) else { return }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("PhotoOverlay-\(UUID().uuidString)")
                .appendingPathExtension("png")
            do {
                try png.write(to: url, options: .atomic)
                // WatchPhotoTransfer removes the file when the transfer finishes.
                session.transferFile(url, metadata: metadata)
            } catch { NSLog("Photo overlay preparation failed: %@", error.localizedDescription) }
        }
    }
}
