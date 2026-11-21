import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns a Photoshop file into a `.paintanytime` project on this iPhone: each pixel
/// layer becomes a layer holding one raster stroke, with its name, opacity, visibility
/// and transparency lock. The counterpart of `PhotoshopExport`.
///
/// What the drawing model cannot hold is baked or dropped: pixel masks and clipping
/// masks are applied to the pixels, groups pass their visibility and opacity to their
/// layers, and blend modes, layer effects, adjustment and fill layers and vector masks
/// are lost (`Imported.notice` says so). Files the reader cannot take apart (PSB, CMYK,
/// Lab, 32-bit…) open as one layer from their flattened image.
enum PhotoshopImport {
    struct Imported {
        let project: PaintProject
        /// What the user should know about features that were not kept; nil if none.
        let notice: String?
    }

    /// Watch canvases are measured in points at the watch's 2× screen scale.
    private static let watchScale: CGFloat = 2

    private enum Loss { case none, simplified, flattened }

    /// Reports the finished fraction, 0…1, from the calling thread.
    typealias Progress = @Sendable (Double) -> Void

    /// Slow for large files: call off the main actor. Throws `CancellationError` when
    /// the calling task is cancelled between layers.
    nonisolated static func project(from url: URL, progress: Progress = { _ in }) throws -> Imported {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .alwaysMapped)
        } catch {
            throw ImportError.unreadable
        }
        let reader: PSDReader
        do {
            reader = try PSDReader(data: data)
        } catch {
            return try flattened(data, loss: .flattened, progress: progress)
        }
        progress(0.02)
        guard reader.layers.contains(where: { $0.section == .none }) else {
            // A flat PSD: its only image is the flattened one.
            return try flattened(data, loss: .none, progress: progress)
        }
        do {
            return try layered(reader, progress: progress)
        } catch ImportError.tooLarge {
            throw ImportError.tooLarge
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            NSLog("Photoshop layers could not be read: %@", String(describing: error))
            return try flattened(data, loss: .flattened, progress: progress)
        }
    }

    /// Shares of the whole import: decoding layers takes most of it, then the preview.
    private static let layersEnd = 0.85
    private static let previewEnd = 0.95

    // MARK: - Layers

    private nonisolated static func layered(_ reader: PSDReader, progress: Progress) throws -> Imported {
        let fit = min(1, CGFloat(PhotoImportProtocol.maximumCanvasPixelSide) / CGFloat(max(reader.width, reader.height)))
        let pixelWidth = max(1, (CGFloat(reader.width) * fit).rounded())
        let pixelHeight = max(1, (CGFloat(reader.height) * fit).rounded())
        // PSD pixels to canvas pixels, per axis, so the layers cover the canvas exactly.
        let scaleX = pixelWidth / CGFloat(reader.width)
        let scaleY = pixelHeight / CGFloat(reader.height)
        let canvas = CGSize(width: pixelWidth / watchScale, height: pixelHeight / watchScale)
        let space = colorSpace(for: reader)
        let layers = reader.layers
        var loss = Loss.none

        // Groups, walked top to bottom: a group's header comes above its layers and its
        // end marker below them.
        var groups: [(isVisible: Bool, opacity: Double)] = []
        var inheritedVisibility = [Bool](repeating: true, count: layers.count)
        var inheritedOpacity = [Double](repeating: 1, count: layers.count)
        for index in layers.indices.reversed() {
            let layer = layers[index]
            if layer.section == .groupEnd {
                if !groups.isEmpty { groups.removeLast() }
                continue
            }
            let parent = groups.last ?? (isVisible: true, opacity: 1.0)
            inheritedVisibility[index] = parent.isVisible
            inheritedOpacity[index] = parent.opacity
            guard layer.isFolder else { continue }
            let blend = layer.sectionBlendMode ?? layer.blendMode
            // Opacity spread over several layers differs where they overlap.
            if !["pass", "norm"].contains(blend) || layer.opacity < 255 || layer.hasEffects || layer.mask != nil {
                loss = .simplified
            }
            groups.append((parent.isVisible && !layer.isHidden, parent.opacity * Double(layer.opacity) / 255))
        }

        // Decoding time follows pixel count, so each layer advances by its area.
        let totalArea = max(1, layers.reduce(0) { total, layer in
            layer.section == .none && !layer.isAdjustment ? total + layer.rect.width * layer.rect.height : total
        })
        var doneArea = 0
        func advance(by layer: PSDReader.Layer) {
            doneArea += layer.rect.width * layer.rect.height
            progress(0.02 + (layersEnd - 0.02) * Double(doneArea) / Double(totalArea))
        }

        var document = CanvasDocument()
        document.layers = []
        document.resolution = reader.resolution * Double(fit)
        // The last unclipped layer, which the clipped layers above it are clipped to.
        var base: (rect: PSDReader.Rect, alpha: [UInt8]?, isVisible: Bool, opacity: Double)?
        var isBottom = true
        for index in layers.indices {
            let layer = layers[index]
            guard layer.section == .none else { continue }
            try Task.checkCancellation()
            if layer.isAdjustment {
                loss = .simplified
                continue
            }
            if layer.hasEffects || layer.hasVectorMask || !["norm", "pass", "diss"].contains(layer.blendMode) {
                loss = .simplified
            }
            var isVisible = !layer.isHidden && inheritedVisibility[index]
            var opacity = Double(layer.opacity) / 255 * Double(layer.fillOpacity) / 255 * inheritedOpacity[index]
            var pixels = try autoreleasepool { try reader.pixels(of: layer) }
            if layer.isClipped, let clip = base {
                isVisible = isVisible && clip.isVisible
                opacity *= clip.opacity
                if pixels != nil { applyClip(&pixels!, rect: layer.rect, to: clip.rect, alpha: clip.alpha) }
            } else {
                base = (layer.rect, pixels.map(alphaPlane), isVisible, opacity)
            }

            defer {
                isBottom = false
                advance(by: layer)
            }
            if isBottom, !layer.isClipped, opacity >= 1, layer.blendMode == "norm", !layer.hasEffects,
               layer.rect == PSDReader.Rect(top: 0, left: 0, bottom: reader.height, right: reader.width),
               let pixels, let color = uniformColor(pixels, space: space) {
                // A plain opaque bottom layer, like Photoshop's Background or the paper of
                // a PSD this app exported, becomes the paper.
                document.backgroundColor = color
                document.backgroundIsVisible = isVisible
                continue
            }

            var canvasLayer = CanvasLayer(name: layer.name.isEmpty ? "Layer \(document.layers.count + 1)" : layer.name)
            canvasLayer.isVisible = isVisible
            canvasLayer.opacity = Float(min(1, max(0, opacity)))
            canvasLayer.locksTransparency = layer.locksTransparency
            if let pixels {
                let stroke = try autoreleasepool {
                    try rasterStroke(pixels, rect: layer.rect, space: space, scaleX: scaleX, scaleY: scaleY)
                }
                if let stroke { canvasLayer.strokes = [stroke] }
            }
            document.layers.append(canvasLayer)
        }
        if document.layers.isEmpty { document.layers = [CanvasLayer()] }
        progress(layersEnd)
        return try finish(document, canvas: canvas, loss: loss, progress: progress)
    }

    /// The layer's own straight-alpha pixels as a raster stroke over its canvas area, at
    /// most at canvas resolution, cropped to its visible pixels. Nil when none are visible.
    private nonisolated static func rasterStroke(_ pixels: [UInt8], rect: PSDReader.Rect, space: CGColorSpace,
                                                 scaleX: CGFloat, scaleY: CGFloat) throws -> Stroke? {
        let width = rect.width, height = rect.height
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width * 4
            for x in 0..<width where pixels[row + x * 4 + 3] != 0 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let cropWidth = maxX - minX + 1, cropHeight = maxY - minY + 1
        var cropped = [UInt8](repeating: 0, count: cropWidth * cropHeight * 4)
        for y in 0..<cropHeight {
            let source = ((minY + y) * width + minX) * 4
            cropped.replaceSubrange((y * cropWidth * 4)..<((y + 1) * cropWidth * 4),
                                    with: pixels[source..<(source + cropWidth * 4)])
        }
        guard let provider = CGDataProvider(data: Data(cropped) as CFData),
              let straight = CGImage(width: cropWidth, height: cropHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                                     bytesPerRow: cropWidth * 4, space: space,
                                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: true,
                                     intent: .defaultIntent)
        else { throw ImportError.unreadable }

        let left = CGFloat(rect.left + minX), top = CGFloat(rect.top + minY)
        let size = CGSize(width: max(1, (CGFloat(cropWidth) * scaleX).rounded()),
                          height: max(1, (CGFloat(cropHeight) * scaleY).rounded()))
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        var image = straight
        if size.width != CGFloat(cropWidth) || size.height != CGFloat(cropHeight)
            || (space.name as String?) != (CGColorSpace.sRGB as String) {
            // Scaling and colour conversion need a premultiplied context.
            guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                          bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw ImportError.unreadable }
            context.interpolationQuality = .high
            context.draw(straight, in: CGRect(origin: .zero, size: size))
            guard let converted = context.makeImage() else { throw ImportError.unreadable }
            image = converted
        }
        guard let png = png(image) else { throw ImportError.unreadable }
        let bounds = CGRect(x: left * scaleX / watchScale, y: top * scaleY / watchScale,
                            width: CGFloat(cropWidth) * scaleX / watchScale,
                            height: CGFloat(cropHeight) * scaleY / watchScale)
        return rasterStroke(png: png, bounds: bounds)
    }

    private nonisolated static func rasterStroke(png: Data, bounds: CGRect) -> Stroke {
        var style = PencilStyle()
        style.blendingMode = .normal
        var stroke = Stroke(points: [], style: style)
        stroke.raster = StrokeRaster(png: png, bounds: bounds)
        return stroke
    }

    private nonisolated static func alphaPlane(_ pixels: [UInt8]) -> [UInt8] {
        stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
    }

    /// Keeps the clipped layer only where its base layer has paint.
    private nonisolated static func applyClip(_ pixels: inout [UInt8], rect: PSDReader.Rect,
                                              to baseRect: PSDReader.Rect, alpha: [UInt8]?) {
        for y in 0..<rect.height {
            let canvasY = rect.top + y
            for x in 0..<rect.width {
                let canvasX = rect.left + x
                var coverage = 0
                if let alpha, canvasY >= baseRect.top, canvasY < baseRect.bottom,
                   canvasX >= baseRect.left, canvasX < baseRect.right {
                    coverage = Int(alpha[(canvasY - baseRect.top) * baseRect.width + canvasX - baseRect.left])
                }
                let index = (y * rect.width + x) * 4 + 3
                pixels[index] = UInt8((Int(pixels[index]) * coverage + 127) / 255)
            }
        }
    }

    /// The colour of a layer whose every pixel is the same opaque colour, in sRGB.
    private nonisolated static func uniformColor(_ pixels: [UInt8], space: CGColorSpace) -> SIMD4<Float>? {
        guard pixels.count >= 4, pixels[3] == 255 else { return nil }
        let red = pixels[0], green = pixels[1], blue = pixels[2]
        var index = 0
        while index < pixels.count {
            guard pixels[index] == red, pixels[index + 1] == green, pixels[index + 2] == blue,
                  pixels[index + 3] == 255 else { return nil }
            index += 4
        }
        let components = [CGFloat(red) / 255, CGFloat(green) / 255, CGFloat(blue) / 255, 1]
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let color = CGColor(colorSpace: space, components: components)?
                .converted(to: sRGB, intent: .defaultIntent, options: nil),
              let converted = color.components, converted.count >= 3 else {
            return SIMD4(Float(red) / 255, Float(green) / 255, Float(blue) / 255, 1)
        }
        return SIMD4(Float(converted[0]), Float(converted[1]), Float(converted[2]), 1)
    }

    /// The file's own RGB profile, or sRGB. Grayscale is expanded to RGB as sRGB.
    private nonisolated static func colorSpace(for reader: PSDReader) -> CGColorSpace {
        if reader.mode == .rgb, let profile = reader.iccProfile,
           let space = CGColorSpace(iccData: profile as CFData), space.model == .rgb {
            return space
        }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }

    // MARK: - Flattened image

    /// One layer from the image ImageIO composites, as other apps show the file.
    private nonisolated static func flattened(_ data: Data, loss: Loss, progress: Progress) throws -> Imported {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: PhotoImportProtocol.maximumCanvasPixelSide,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              image.width > 0, image.height > 0,
              let png = png(image) else { throw ImportError.unreadable }
        try Task.checkCancellation()
        progress(layersEnd)
        let canvas = CGSize(width: CGFloat(image.width) / watchScale, height: CGFloat(image.height) / watchScale)
        var document = CanvasDocument()
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        if let dpi = (properties?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue,
           let originalWidth = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
           dpi.isFinite, dpi > 0, originalWidth > 0 {
            document.resolution = dpi * Double(image.width) / originalWidth
        }
        document.layers = [CanvasLayer(strokes: [rasterStroke(png: png, bounds: CGRect(origin: .zero, size: canvas))])]
        return try finish(document, canvas: canvas, loss: loss, progress: progress)
    }

    // MARK: - Project

    private nonisolated static func finish(_ document: CanvasDocument, canvas: CGSize, loss: Loss,
                                           progress: Progress) throws -> Imported {
        var document = document
        document.canvasSize = canvas
        guard let image = WatchBitmapRenderer.render(document: document, size: canvas, scale: watchScale),
              let preview = png(image, details: [
                  "application": "Paint Anytime",
                  "pixelWidth": image.width, "pixelHeight": image.height,
                  "canvasWidthPoints": canvas.width, "canvasHeightPoints": canvas.height,
                  "scale": watchScale
              ]) else { throw ImportError.unreadable }
        try Task.checkCancellation()
        progress(previewEnd)
        let json = try JSONEncoder().encode(document)
        // The project stores both as base64.
        guard (json.count + preview.count) / 3 * 4 + 4096 <= PaintProject.maximumBytes else {
            throw ImportError.tooLarge
        }
        let project = PaintProject(document: json, preview: preview, restoresCanvasSize: false)
        let notice: String? = switch loss {
        case .none: nil
        case .simplified: L10n.text("Some Photoshop features could not be kept, such as blend modes, layer effects or adjustment layers. The drawing may look different.")
        case .flattened: L10n.text("This Photoshop file was imported as a single layer.")
        }
        return Imported(project: project, notice: notice)
    }

    private nonisolated static func png(_ image: CGImage, details: [String: Any]? = nil) -> Data? {
        var properties: [CFString: Any] = [:]
        if let details, let metadata = try? JSONSerialization.data(withJSONObject: details, options: [.sortedKeys]) {
            properties[kCGImagePropertyPNGDictionary] = [
                kCGImagePropertyPNGSoftware: "Paint Anytime",
                kCGImagePropertyPNGDescription: String(decoding: metadata, as: UTF8.self)
            ]
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    enum ImportError: LocalizedError {
        case unreadable, tooLarge
        var errorDescription: String? {
            switch self {
            case .unreadable: L10n.text("This Photoshop file could not be opened.")
            case .tooLarge: L10n.text("This Photoshop file is too large to import. Merge some layers or reduce the image size, then try again.")
            }
        }
    }
}
