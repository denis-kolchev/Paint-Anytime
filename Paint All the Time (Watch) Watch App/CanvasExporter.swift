import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import WatchKit

enum CanvasExporter {
    @MainActor
    static func save(strokes: [Stroke], size: CGSize, scale: CGFloat, in folder: URL? = nil) throws -> CanvasExport {
        guard size.width > 0, size.height > 0 else { throw ExportError.render }
        // Export exactly the same compositing as the live canvas, including long marker paths.
        guard let image = WatchBitmapRenderer.render(strokes: strokes, size: size, scale: scale)
        else { throw ExportError.render }
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss_SSS"
        let name = "Paint-Anytime_\(formatter.string(from: now))_\(UUID().uuidString.prefix(8))"
        let device = WKInterfaceDevice.current()
        let details: [String: Any] = [
            "application": "Paint All the Time",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "createdAt": ISO8601DateFormatter().string(from: now),
            "timeZone": TimeZone.current.identifier,
            "utcOffsetSeconds": TimeZone.current.secondsFromGMT(for: now),
            "deviceModel": device.model,
            "systemVersion": device.systemVersion,
            "pixelWidth": image.width, "pixelHeight": image.height,
            "canvasWidthPoints": size.width, "canvasHeightPoints": size.height,
            "scale": scale, "strokeCount": strokes.count,
            "instruments": Array(Set(strokes.map { $0.style.instrument.title })).sorted()
        ]
        let metadata = try JSONSerialization.data(withJSONObject: details, options: [.sortedKeys])
        let properties: [CFString: Any] = [
            kCGImagePropertyPNGDictionary: [
                kCGImagePropertyPNGTitle: name,
                kCGImagePropertyPNGSoftware: "Paint All the Time",
                kCGImagePropertyPNGCreationTime: ISO8601DateFormatter().string(from: now),
                kCGImagePropertyPNGDescription: String(decoding: metadata, as: UTF8.self)
            ]
        ]
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw ExportError.encoding }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.encoding }
        return try CanvasExportStore.save(document: CanvasDocument(strokes: strokes),
                                          imageData: data as Data, name: name, in: folder)
    }

    enum ExportError: LocalizedError {
        case render, encoding
        var errorDescription: String? { L10n.text("Could not save the canvas image. Please try again.") }
    }
}
