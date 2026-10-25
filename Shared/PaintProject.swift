import Foundation
import ImageIO

/// Portable, versioned JSON envelope. Document JSON is embedded verbatim so the
/// phone can preserve drawing features without needing the watch renderer.
nonisolated struct PaintProject: Codable {
    static let fileExtension = "paintanytime"
    static let typeIdentifier = "com.deniskolchev.paintanytime.project"
    static let maximumBytes = 64 * 1024 * 1024
    let format: String
    let version: Int
    let document: Data
    let preview: Data

    init(document: Data, preview: Data) {
        format = "Paint Anytime Project"
        version = 1
        self.document = Self.restoringCanvasSize(in: document, preview: preview)
        self.preview = preview
    }

    static func read(_ url: URL) throws -> Self {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumBytes else { throw ProjectError.tooLarge }
        return try decode(Data(contentsOf: url))
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw ProjectError.tooLarge }
        let project = try JSONDecoder().decode(Self.self, from: data)
        guard project.format == "Paint Anytime Project", project.version == 1 else { throw ProjectError.unsupported }
        guard let object = try JSONSerialization.jsonObject(with: project.document) as? [String: Any],
              object["layers"] is [[String: Any]],
              project.preview.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { throw ProjectError.invalid }
        return Self(document: project.document, preview: project.preview)
    }

    func write(to url: URL) throws {
        let data = try JSONEncoder().encode(Self(document: document, preview: preview))
        _ = try Self.decode(data)
        try data.write(to: url, options: .atomic)
    }

    /// Legacy exports omitted the logical canvas size. Recover it from the
    /// original PNG metadata, never from the receiving device's screen or DPI.
    static func restoringCanvasSize(in document: Data, preview: Data) -> Data {
        guard var object = try? JSONSerialization.jsonObject(with: document) as? [String: Any],
              object["canvasSize"] == nil || object["canvasSize"] is NSNull,
              let source = CGImageSourceCreateWithData(preview as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any],
              let description = png[kCGImagePropertyPNGDescription] as? String,
              let metadataData = description.data(using: .utf8),
              let metadata = try? JSONSerialization.jsonObject(with: metadataData) as? [String: Any],
              let width = metadata["canvasWidthPoints"] as? Double,
              let height = metadata["canvasHeightPoints"] as? Double,
              width.isFinite, height.isFinite,
              width > 0, height > 0, width <= 2048, height <= 2048 else { return document }
        object["canvasSize"] = [width, height]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? document
    }

    enum ProjectError: LocalizedError {
        case unsupported, invalid, tooLarge
        var errorDescription: String? {
            switch self {
            case .unsupported: "This project requires a different version of Paint Anytime."
            case .invalid: "This is not a valid Paint Anytime project."
            case .tooLarge: "This project exceeds the 64 MB import limit."
            }
        }
    }
}

extension Notification.Name {
    static let paintProjectImported = Notification.Name("PaintAnytimeProjectImported")
}
