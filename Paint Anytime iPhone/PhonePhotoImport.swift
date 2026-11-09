import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import WatchConnectivity

/// The iPhone only prepares and sends the photo; the drawing is created and edited
/// on Apple Watch (see `PhotoImportProtocol`).
nonisolated enum PhonePhotoImport {
    enum ImportError: LocalizedError {
        case unreadable, watchUnavailable
        var errorDescription: String? {
            switch self {
            case .unreadable: String(localized: "This photo could not be opened.")
            case .watchUnavailable: String(localized: "Connect your Apple Watch and install Paint Anytime before sending a project.")
            }
        }
    }

    /// An upright PNG whose longer side is at most the watch's photo detail limit.
    static func preparedPNG(from data: Data) throws -> Data {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Applies the EXIF orientation, so the watch receives upright pixels.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: PhotoImportProtocol.maximumPhotoPixelSide,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw ImportError.unreadable }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { throw ImportError.unreadable }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ImportError.unreadable }
        return output as Data
    }

    /// `original` is the photo as picked. The phone keeps it, so saving and sharing
    /// can use it at full resolution with the drawing from the watch on top.
    static func send(png: Data, original: Data, fitsWatch: Bool) throws {
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled
        else { throw ImportError.watchUnavailable }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoImport-\(UUID().uuidString)")
            .appendingPathExtension("png")
        try png.write(to: url, options: .atomic)
        let name = PhotoImportProtocol.newDrawingName()
        let photoID = PhotoImportProtocol.newPhotoID()
        // WatchDrawingReceiver removes the temporary file when the transfer finishes.
        session.transferFile(url, metadata: [PhotoImportProtocol.kindKey: PhotoImportProtocol.kind,
                                             PhotoImportProtocol.fitsWatchKey: fitsWatch,
                                             PhotoImportProtocol.nameKey: name,
                                             PhotoImportProtocol.photoIDKey: photoID.uuidString])
        do {
            try PhotoOriginalStore().storeOriginal(original, photoID: photoID, stem: name, preview: png)
        } catch {
            // The drawing still works; saving and sharing then use the watch's resolution.
            NSLog("Photo original could not be kept: %@", error.localizedDescription)
        }
        addToGallery(png, name: name)
    }

    /// Lists the photo in the phone gallery now, rather than only once the watch app
    /// has opened and sent the drawing back. That drawing, with its project, replaces
    /// this preview under the same name. Without it the photo still arrives that way.
    private static func addToGallery(_ png: Data, name: String) {
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoImportPreview-\(UUID().uuidString)")
            .appendingPathExtension("png")
        do {
            try png.write(to: copy, options: .atomic)
            try IncomingDrawingStore().receive(copy, name: name + ".png")
        } catch {
            try? FileManager.default.removeItem(at: copy)
            NSLog("Photo import gallery preview failed: %@", error.localizedDescription)
        }
    }

    /// Loads the picked photo, prepares it for the watch and sends it. Returns the
    /// confirmation to show; throws with the error text otherwise.
    @MainActor
    static func importPhoto(_ item: PhotosPickerItem) async throws -> String {
        guard let original = try await item.loadTransferable(type: Data.self) else {
            throw ImportError.unreadable
        }
        // Full camera photos are large; decode and encode away from the main actor.
        let png = try await Task.detached(priority: .userInitiated) {
            try preparedPNG(from: original)
        }.value
        // Always keeps the photo's resolution: tools that edit the photo's own layer
        // reduce it to the watch resolution anyway, so fitting it first gains nothing.
        try send(png: png, original: original, fitsWatch: false)
        return String(localized: "Photo queued. It will appear in your watch gallery as a new drawing when the transfer finishes. Open it there to edit.")
    }
}
