import SwiftUI
import UniformTypeIdentifiers

/// Exports a gallery PNG, a JPEG built from it, its project file or a Photoshop file built from the project
/// through `fileExporter`.
struct DrawingFile: FileDocument {
    static var readableContentTypes: [UTType] { [.png, .jpeg, .paintAnytimeProject, .photoshopImage] }
    let url: URL?
    let data: Data?
    /// Exports an imported photo's original at full resolution, with the drawing on top.
    var fullResolution = false
    /// `url` is a project, written out as a layered PSD.
    var photoshop = false
    /// `url` is a gallery image, written out as a JPEG over white.
    var jpeg = false
    init(url: URL, fullResolution: Bool = false) { self.url = url; data = nil; self.fullResolution = fullResolution }
    init(jpegFrom url: URL) { self.url = url; data = nil; jpeg = true }
    init(photoshopFrom projectURL: URL) { url = projectURL; data = nil; photoshop = true }
    init(configuration: ReadConfiguration) throws { url = nil; data = configuration.file.regularFileContents }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        if let url, photoshop {
            return try FileWrapper(url: PhotoshopExport.write(projectAt: url), options: .immediate)
        }
        if let url, jpeg {
            return try FileWrapper(url: JPEGExport.write(imageAt: url), options: .immediate)
        }
        if let url {
            let source = fullResolution ? try PhotoOriginalStore().outputImage(for: url) : url
            return try FileWrapper(url: source, options: .immediate)
        }
        return FileWrapper(regularFileWithContents: data ?? Data())
    }
}
