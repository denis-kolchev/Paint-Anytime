import CoreGraphics
import CoreTransferable
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Builds a layered Photoshop file from a drawing's `.paintanytime` project on this
/// iPhone. The watch's renderer is compiled into this target too, so every layer looks
/// exactly as it does on the watch, without asking the watch for anything.
enum PhotoshopExport {
    static let fileExtension = "psd"

    /// Writes the PSD to a temporary file named after the drawing and returns it.
    static func write(projectAt projectURL: URL) throws -> URL {
        let data = try encode(projectAt: projectURL, paperName: L10n.text("Paper"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Photoshop", isDirectory: true)
        removeStaleExports(in: root)
        // A folder per export, so a share sheet and a save running together never
        // overwrite each other's file.
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(projectURL.deletingPathExtension().lastPathComponent)
            .appendingPathExtension(fileExtension)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// The project's layers bottom to top over its paper, at the resolution of its preview
    /// (the gallery image): each layer rendered alone, opaque and over no paper, then
    /// given its own opacity, visibility and transparency lock in the file.
    static func encode(projectAt url: URL, paperName: String) throws -> Data {
        do {
            let project = try PaintProject.read(url)
            let document = try autoreleasepool { try JSONDecoder().decode(CanvasDocument.self, from: project.document) }
            guard let source = CGImageSourceCreateWithData(project.preview as CFData, nil),
                  let preview = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  preview.width > 0, preview.height > 0 else { throw ExportError.failed }
            let width = preview.width, height = preview.height
            let size = document.canvasSize ?? CGSize(width: width, height: height)
            guard size.width > 0, size.height > 0 else { throw ExportError.failed }
            let scale = CGFloat(width) / size.width
            var writer = try PSDWriter(width: width, height: height, resolution: document.resolution)
            writer.appendSolidLayer(name: paperName, color: document.backgroundColor,
                                    isVisible: document.backgroundIsVisible)
            for layer in document.layers {
                try autoreleasepool {
                    var image: CGImage?
                    if !layer.strokes.isEmpty {
                        var shown = layer
                        shown.isVisible = true
                        shown.opacity = 1
                        var alone = document
                        alone.layers = [shown]
                        alone.backgroundIsVisible = false
                        image = WatchBitmapRenderer.render(document: alone, size: size, scale: scale)
                        guard image != nil else { throw ExportError.failed }
                    }
                    try writer.appendLayer(name: layer.name, image: image, opacity: layer.opacity,
                                           isVisible: layer.isVisible, locksTransparency: layer.locksTransparency)
                }
            }
            let isOpaque = document.backgroundIsVisible && document.backgroundColor.w >= 1
            return try writer.data(composite: preview, isOpaque: isOpaque)
        } catch let error as PaintProject.ProjectError {
            throw error
        } catch {
            NSLog("Photoshop export failed: %@", String(describing: error))
            throw ExportError.failed
        }
    }

    /// Exports older than an hour have been shared or saved long ago.
    private static func removeStaleExports(in root: URL) {
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let limit = Date().addingTimeInterval(-3600)
        for folder in folders {
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if created < limit { try? FileManager.default.removeItem(at: folder) }
        }
    }

    enum ExportError: LocalizedError {
        case failed
        var errorDescription: String? { L10n.text("Could not create the Photoshop file.") }
    }
}

/// Shares a drawing as a layered PSD, built when the share sheet asks for the file
/// rather than when the menu appears.
struct DrawingPhotoshopExport: Transferable {
    let projectURL: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .photoshopImage) { item in
            SentTransferredFile(try PhotoshopExport.write(projectAt: item.projectURL))
        }
    }
}
