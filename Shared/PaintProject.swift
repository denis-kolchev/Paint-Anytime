import Foundation

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
        self.document = document
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
        return project
    }

    func write(to url: URL) throws {
        let data = try JSONEncoder().encode(self)
        _ = try Self.decode(data)
        try data.write(to: url, options: .atomic)
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
