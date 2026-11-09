import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WatchKit

/// Turns a photo sent from the iPhone (see `PhotoImportProtocol`) into a new gallery
/// drawing whose only layer starts with the photo.
enum WatchPhotoImport {
    enum ImportError: LocalizedError {
        case unreadable
        var errorDescription: String? { L10n.text("The photo could not be opened on Apple Watch.") }
    }

    /// `name` is the gallery stem the phone already lists the photo under. `photoID`
    /// links the photo stroke to the original the phone keeps; without one (an older
    /// iPhone app) the drawing is never paired with an original. Nil when the phone's
    /// entry was deleted before the photo arrived.
    @MainActor
    static func save(imageData: Data?, fitsWatch: Bool, name: String?, photoID: UUID?) throws -> CanvasExport? {
        let folder = try CanvasExportStore.directory()
        let existing = name.map { CanvasExport(url: folder.appendingPathComponent($0).appendingPathExtension("png")) }
        if let existing,
           try GalleryDeletionStore.names(in: folder).contains(existing.url.lastPathComponent) { return nil }
        guard let imageData,
              let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0, image.height > 0 else { throw ImportError.unreadable }
        let device = WKInterfaceDevice.current()
        let scale = max(1, device.screenScale)
        let imageSize = CGSize(width: image.width, height: image.height)
        let canvas = canvasSize(for: imageSize, fitsWatch: fitsWatch,
                                screen: device.screenBounds.size, scale: scale)
        // Fitting stores the screen's pixels; otherwise keep extra detail for zooming in.
        // Never enlarge the photo.
        let detail = fitsWatch ? 1 : CGFloat(PhotoImportProtocol.photoDetailFactor)
        let fit = min(1, canvas.width * scale * detail / imageSize.width,
                      canvas.height * scale * detail / imageSize.height)
        let pixels = CGSize(width: max(1, (imageSize.width * fit).rounded()),
                            height: max(1, (imageSize.height * fit).rounded()))
        guard let raster = pixels == imageSize ? image : resized(image, to: pixels),
              let png = png(raster) else { throw ImportError.unreadable }

        var document = CanvasDocument()
        document.canvasSize = canvas
        // The canvas has the photo's aspect; covering it exactly avoids a hairline of
        // paper where pixel rounding makes the two differ by a fraction of a pixel.
        let photo = WatchSketchAssist.rasterStroke(png: png, imageSize: canvas,
                                                   in: CGRect(origin: .zero, size: canvas),
                                                   id: photoID ?? UUID())
        // An ordinary one-layer drawing: the photo is the first stroke of Layer 1.
        document.layers = [CanvasLayer(strokes: [photo])]
        // Saving "over" the phone's entry only reuses its name; nothing exists here yet.
        return try CanvasExporter.save(document: document, size: canvas, scale: scale, replacing: existing)
    }

    /// Canvas size in points, always with the photo's aspect so the paper has no
    /// margins. Fitting makes the largest such canvas inside the screen; otherwise the
    /// canvas takes the photo's pixel size within the editor's per-side limit.
    static func canvasSize(for imageSize: CGSize, fitsWatch: Bool, screen: CGSize, scale: CGFloat) -> CGSize {
        let shrink = fitsWatch
            ? min(screen.width * scale / imageSize.width, screen.height * scale / imageSize.height)
            : min(1, CGFloat(PhotoImportProtocol.maximumCanvasPixelSide) / max(imageSize.width, imageSize.height))
        // Whole pixels, so the photo covers the paper edge to edge.
        return CGSize(width: max(1, (imageSize.width * shrink).rounded()) / scale,
                      height: max(1, (imageSize.height * shrink).rounded()) / scale)
    }

    private static func resized(_ image: CGImage, to size: CGSize) -> CGImage? {
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        return context.makeImage()
    }

    nonisolated static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
