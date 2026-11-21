import SwiftUI
import UniformTypeIdentifiers

/// Exports a gallery PNG, its project file or a Photoshop file built from the project
/// through `fileExporter`.
struct DrawingFile: FileDocument {
    static var readableContentTypes: [UTType] { [.png, .paintAnytimeProject, .photoshopImage] }
    let url: URL?
    let data: Data?
    /// Exports an imported photo's original at full resolution, with the drawing on top.
    var fullResolution = false
    /// `url` is a project, written out as a layered PSD.
    var photoshop = false
    init(url: URL, fullResolution: Bool = false) { self.url = url; data = nil; self.fullResolution = fullResolution }
    init(photoshopFrom projectURL: URL) { url = projectURL; data = nil; photoshop = true }
    init(configuration: ReadConfiguration) throws { url = nil; data = configuration.file.regularFileContents }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        if let url, photoshop {
            return try FileWrapper(url: PhotoshopExport.write(projectAt: url), options: .immediate)
        }
        if let url {
            let source = fullResolution ? try PhotoOriginalStore().outputImage(for: url) : url
            return try FileWrapper(url: source, options: .immediate)
        }
        return FileWrapper(regularFileWithContents: data ?? Data())
    }
}
