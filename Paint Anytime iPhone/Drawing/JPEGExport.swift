import CoreGraphics
import CoreTransferable
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes a gallery drawing as a JPEG: the same image as the PNG export
/// (`PhotoOriginalStore.outputImage(for:)`, so a photo keeps its full resolution),
/// flattened onto white because JPEG has no transparency.
nonisolated enum JPEGExport {
    static let fileExtension = "jpg"
    /// High enough that brush texture survives; far smaller than the PNG for photos.
    static let compressionQuality = 0.92

    /// Writes the JPEG to a temporary file named after the drawing and returns it.
    static func write(imageAt url: URL) throws -> URL {
        let source = try PhotoOriginalStore().outputImage(for: url)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("JPEG", isDirectory: true)
        removeStaleExports(in: root)
        // A folder per export, so a share sheet and a save running together never
        // overwrite each other's file.
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let output = folder.appendingPathComponent(url.deletingPathExtension().lastPathComponent)
            .appendingPathExtension(fileExtension)
        try encode(imageAt: source, to: output)
        return output
    }

    private static func encode(imageAt source: URL, to output: URL) throws {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
              image.width > 0, image.height > 0,
              let space = image.colorSpace.flatMap({ $0.model == .rgb ? $0 : nil }) ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw ExportError.failed }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        // Transparent pixels would otherwise turn black.
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        guard let flattened = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw ExportError.failed }
        CGImageDestinationAddImage(destination, flattened,
                                   [kCGImageDestinationLossyCompressionQuality: compressionQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.failed }
    }

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
        var errorDescription: String? { L10n.text("Could not create the JPEG file.") }
    }
}

/// Shares a drawing as a JPEG, built when the share sheet asks for the file
/// rather than when the menu appears.
struct DrawingJPEGExport: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .jpeg) { item in
            SentTransferredFile(try JPEGExport.write(imageAt: item.url))
        }
    }
}
