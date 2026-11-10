import SwiftUI
import UniformTypeIdentifiers

/// Exports a gallery PNG or its project file through `fileExporter`.
struct DrawingFile: FileDocument {
    static var readableContentTypes: [UTType] { [.png, .paintAnytimeProject] }
    let url: URL?
    let data: Data?
    /// Exports an imported photo's original at full resolution, with the drawing on top.
    var fullResolution = false
    init(url: URL, fullResolution: Bool = false) { self.url = url; data = nil; self.fullResolution = fullResolution }
    init(configuration: ReadConfiguration) throws { url = nil; data = configuration.file.regularFileContents }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        if let url {
            let source = fullResolution ? try PhotoOriginalStore().outputImage(for: url) : url
            return try FileWrapper(url: source, options: .immediate)
        }
        return FileWrapper(regularFileWithContents: data ?? Data())
    }
}
