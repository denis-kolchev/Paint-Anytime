import CoreGraphics
import CoreTransferable
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Keeps the original of each photo sent to the watch, and the overlays the watch sends
/// back, so saving and sharing use the photo at full resolution (see
/// `PhotoImportProtocol`). Every gallery image without a valid pairing is used as is.
nonisolated struct PhotoOriginalStore {
    /// One gallery drawing's pairing with an original.
    private struct Pairing: Codable {
        var photoID: UUID
        /// Digest of the gallery PNG this pairing describes.
        var digest: String
        /// False for the phone's own preview, before the watch has sent an overlay.
        var hasOverlay: Bool
        var background: [Double]?
    }

    private static let lock = NSLock()
    /// A drawing saved under a new name can deliver its overlay before its image.
    private static let unmatchedPairingLifetime: TimeInterval = 24 * 60 * 60
    private let folderOverride: URL?

    init(folder: URL? = nil) { folderOverride = folder }

    private func root() throws -> URL {
        let folder = try folderOverride ?? FileManager.default
            .url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("PhotoOriginals", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Overlays", isDirectory: true),
                                                withIntermediateDirectories: true)
        return folder
    }

    private func originalURL(_ photoID: UUID) throws -> URL {
        try root().appendingPathComponent(photoID.uuidString).appendingPathExtension("original")
    }
    private func pairingURL(_ stem: String) throws -> URL {
        try root().appendingPathComponent("Overlays").appendingPathComponent(stem).appendingPathExtension("json")
    }
    private func overlayURL(_ stem: String) throws -> URL {
        try root().appendingPathComponent("Overlays").appendingPathComponent(stem).appendingPathExtension("png")
    }
    private func compositeFolder(_ stem: String) throws -> URL {
        try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("PhotoComposites", isDirectory: true)
            .appendingPathComponent(stem, isDirectory: true)
    }

    // MARK: Sending

    /// Stores the original photo and pairs the phone's preview with it.
    func storeOriginal(_ original: Data, photoID: UUID, stem: String, preview: Data) throws {
        guard PhotoImportProtocol.isSafeStem(stem) else { throw CocoaError(.fileWriteInvalidFileName) }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        try original.write(to: originalURL(photoID), options: .atomic)
        try write(Pairing(photoID: photoID, digest: PhotoImportProtocol.digest(preview), hasOverlay: false),
                  for: stem)
    }

    // MARK: Receiving

    /// Moves an overlay file from the watch into place. Ignored without its original.
    func receiveOverlay(_ file: URL, metadata: [String: Any]) throws {
        guard let stem = metadata[PhotoImportProtocol.overlayForKey] as? String,
              PhotoImportProtocol.isSafeStem(stem),
              let photoID = (metadata[PhotoImportProtocol.photoIDKey] as? String).flatMap(UUID.init(uuidString:)),
              let digest = metadata[PhotoImportProtocol.overlayDigestKey] as? String else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let background = (metadata[PhotoImportProtocol.overlayBackgroundKey] as? [Double])
            .flatMap { $0.count == 4 && $0.allSatisfy(\.isFinite) ? $0 : nil }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard FileManager.default.fileExists(atPath: try originalURL(photoID).path) else { return }
        let destination = try overlayURL(stem)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: file, to: destination)
        try write(Pairing(photoID: photoID, digest: digest, hasOverlay: true, background: background), for: stem)
    }

    /// Removes pairings of drawings no longer in the gallery, then originals that no
    /// pairing uses. `deleted` drawings go at once; a pairing whose image has not
    /// arrived yet is kept for a day.
    func prune(galleryImages: [URL], deleted: [String]) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        do {
            let overlays = try root().appendingPathComponent("Overlays")
            let present = Set(galleryImages.map { $0.deletingPathExtension().lastPathComponent })
            let removed = Set(deleted.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent })
            var used = Set<UUID>()
            let pairings = try FileManager.default.contentsOfDirectory(
                at: overlays, includingPropertiesForKeys: [.contentModificationDateKey])
                .filter { $0.pathExtension == "json" }
            for url in pairings {
                let stem = url.deletingPathExtension().lastPathComponent
                let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                let expired = !present.contains(stem)
                    && Date().timeIntervalSince(modified ?? .distantPast) > Self.unmatchedPairingLifetime
                if removed.contains(stem) || expired {
                    try? FileManager.default.removeItem(at: url)
                    try? FileManager.default.removeItem(at: overlayURL(stem))
                    try? FileManager.default.removeItem(at: compositeFolder(stem))
                } else if let pairing = try? JSONDecoder().decode(Pairing.self, from: Data(contentsOf: url)) {
                    used.insert(pairing.photoID)
                }
            }
            for url in try FileManager.default.contentsOfDirectory(at: root(), includingPropertiesForKeys: nil)
            where url.pathExtension == "original" {
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                      !used.contains(id) else { continue }
                try? FileManager.default.removeItem(at: url)
            }
        } catch { NSLog("Photo original cleanup failed: %@", error.localizedDescription) }
    }

    // MARK: Output

    /// The image to save or share for a gallery PNG: the original photo at full
    /// resolution with the watch's drawing on top while they still match, otherwise
    /// the gallery PNG itself.
    func outputImage(for image: URL) throws -> URL {
        let stem = image.deletingPathExtension().lastPathComponent
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard image.pathExtension.lowercased() == "png",
              let pairing = try? JSONDecoder().decode(Pairing.self, from: Data(contentsOf: pairingURL(stem))),
              FileManager.default.fileExists(atPath: try originalURL(pairing.photoID).path),
              PhotoImportProtocol.digest(try Data(contentsOf: image)) == pairing.digest else { return image }
        let folder = try compositeFolder(stem)
        let output = folder.appendingPathComponent(pairing.digest, isDirectory: true)
            .appendingPathComponent(stem).appendingPathExtension("png")
        if FileManager.default.fileExists(atPath: output.path) { return output }
        // Keep only the latest revision's composite.
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try compose(pairing, stem: stem, to: output)
        return output
    }

    func hasOriginal(for image: URL) -> Bool {
        let stem = image.deletingPathExtension().lastPathComponent
        return (try? FileManager.default.fileExists(atPath: pairingURL(stem).path)) ?? false
    }

    private func compose(_ pairing: Pairing, stem: String, to output: URL) throws {
        guard let source = CGImageSourceCreateWithURL(try originalURL(pairing.photoID) as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw CocoaError(.fileReadCorruptFile) }
        // The same upright pixels the watch received, at the original's full size.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let photo = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let space = photo.colorSpace.flatMap({ $0.model == .rgb ? $0 : nil }) ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: photo.width, height: photo.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CocoaError(.fileReadCorruptFile) }
        let bounds = CGRect(x: 0, y: 0, width: photo.width, height: photo.height)
        if let paper = pairing.background {
            context.setFillColor(CGColor(srgbRed: paper[0], green: paper[1], blue: paper[2], alpha: paper[3]))
            context.fill(bounds)
        }
        context.draw(photo, in: bounds)
        if pairing.hasOverlay {
            guard let overlaySource = CGImageSourceCreateWithURL(try overlayURL(stem) as CFURL, nil),
                  let overlay = CGImageSourceCreateImageAtIndex(overlaySource, 0, nil)
            else { throw CocoaError(.fileReadCorruptFile) }
            context.interpolationQuality = .high
            context.draw(overlay, in: bounds)
        }
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    private func write(_ pairing: Pairing, for stem: String) throws {
        try JSONEncoder().encode(pairing).write(to: pairingURL(stem), options: .atomic)
    }
}

/// Shares a gallery drawing as `PhotoOriginalStore.outputImage(for:)`, composed when
/// the share sheet asks for the file rather than when the menu appears.
struct DrawingImageExport: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .png) { item in
            SentTransferredFile(try PhotoOriginalStore().outputImage(for: item.url))
        }
    }
}
