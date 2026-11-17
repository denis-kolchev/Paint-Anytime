import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import WatchKit

enum CanvasExporter {
    @MainActor
    static func save(strokes: [Stroke], size: CGSize, scale: CGFloat, in folder: URL? = nil) throws -> CanvasExport {
        return try save(document: CanvasDocument(strokes: strokes), size: size, scale: scale, in: folder)
    }

    @MainActor
    static func save(document: CanvasDocument, size: CGSize, scale: CGFloat, in folder: URL? = nil,
                     replacing previous: CanvasExport? = nil) throws -> CanvasExport {
        let now = Date()
        let name = previous.map(fileStem(of:)) ?? newFileStem(at: now)
        let encoded = try encode(document: document, size: size, scale: scale, name: name,
                                 info: .current(for: document), at: now)
        let export = try CanvasExportStore.save(document: encoded.document,
                                                imageData: encoded.png, name: name, in: folder)
        GalleryPreviewStore.shared.store(image: encoded.image, originalSize: encoded.document.canvasSize ?? size,
                                         for: export.url)
        return export
    }

    nonisolated static func fileStem(of export: CanvasExport) -> String {
        export.url.deletingPathExtension().lastPathComponent
    }

    nonisolated static func newFileStem(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss_SSS"
        return "Paint-Anytime_\(formatter.string(from: date))_\(UUID().uuidString.prefix(8))"
    }

    /// App and device details for the PNG description, read on the main actor.
    nonisolated struct ExportInfo: Sendable {
        let version: String
        let build: String
        let deviceModel: String
        let systemVersion: String
        /// Localized instrument titles, which need the main actor.
        let instruments: [String]

        @MainActor static func current(for document: CanvasDocument) -> Self {
            let device = WKInterfaceDevice.current()
            return Self(
                version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                deviceModel: device.model, systemVersion: device.systemVersion,
                instruments: Array(Set(document.strokes.map { $0.style.instrument.title })).sorted())
        }
    }

    nonisolated struct EncodedDrawing: @unchecked Sendable {
        /// The document as stored, with its canvas size.
        let document: CanvasDocument
        let png: Data
        let image: CGImage
    }

    /// Renders and encodes the drawing; safe off the main thread.
    nonisolated static func encode(document: CanvasDocument, size: CGSize, scale: CGFloat, name: String,
                                   info: ExportInfo, at now: Date) throws -> EncodedDrawing {
        let size = document.size(fallback: size)
        let strokes = document.strokes
        guard size.width > 0, size.height > 0 else { throw ExportError.render }
        // Export exactly the same compositing as the live canvas, including long marker paths.
        guard let image = WatchBitmapRenderer.render(document: document, size: size, scale: scale)
        else { throw ExportError.render }
        let details: [String: Any] = [
            "application": "Paint Anytime",
            "version": info.version,
            "build": info.build,
            "createdAt": ISO8601DateFormatter().string(from: now),
            "timeZone": TimeZone.current.identifier,
            "utcOffsetSeconds": TimeZone.current.secondsFromGMT(for: now),
            "deviceModel": info.deviceModel,
            "systemVersion": info.systemVersion,
            "pixelWidth": image.width, "pixelHeight": image.height,
            "canvasWidthPoints": size.width, "canvasHeightPoints": size.height,
            "scale": scale, "strokeCount": strokes.count,
            "instruments": info.instruments
        ]
        let metadata = try JSONSerialization.data(withJSONObject: details, options: [.sortedKeys])
        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: document.resolution,
            kCGImagePropertyDPIHeight: document.resolution,
            kCGImagePropertyPNGDictionary: [
                kCGImagePropertyPNGTitle: name,
                kCGImagePropertyPNGSoftware: "Paint Anytime",
                kCGImagePropertyPNGCreationTime: ISO8601DateFormatter().string(from: now),
                kCGImagePropertyPNGDescription: String(decoding: metadata, as: UTF8.self)
            ]
        ]
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw ExportError.encoding }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.encoding }
        var savedDocument = document
        savedDocument.canvasSize = size
        return EncodedDrawing(document: savedDocument, png: data as Data, image: image)
    }

    /// A PNG of the current canvas for sharing, kept out of the gallery.
    @MainActor
    static func sharePNG(document: CanvasDocument, size: CGSize, scale: CGFloat) throws -> (url: URL, image: CGImage) {
        let size = document.size(fallback: size)
        guard size.width > 0, size.height > 0,
              let image = WatchBitmapRenderer.render(document: document, size: size, scale: scale)
        else { throw ExportError.render }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Share", isDirectory: true)
        // Only the latest shared image is needed.
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Paint Anytime.png")
        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: document.resolution,
            kCGImagePropertyDPIHeight: document.resolution
        ]
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw ExportError.encoding }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.encoding }
        return (url, image)
    }

    enum ExportError: LocalizedError {
        case render, encoding
        var errorDescription: String? { L10n.text("Could not save the canvas image. Please try again.") }
    }
}
