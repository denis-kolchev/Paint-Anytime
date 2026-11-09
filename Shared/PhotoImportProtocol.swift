import CryptoKit
import Foundation

/// WatchConnectivity contract for starting a watch drawing from an iPhone photo.
/// The phone sends an oriented PNG no larger than `maximumPhotoPixelSide`; the watch
/// builds the document, because only the watch target has the drawing model.
///
/// The phone keeps the original photo. While the drawing's bottom layer still holds
/// exactly that photo, the watch also sends the layers above it as a transparent
/// overlay, and the phone saves and shares the original at full resolution with the
/// overlay on top. Watch layers composite independently with normal blending, so
/// the overlay over the photo matches the watch's own image.
nonisolated enum PhotoImportProtocol {
    /// Shares the metadata key with `SketchAssistProtocol` so one lookup routes files.
    static let kindKey = SketchAssistProtocol.kindKey
    static let kind = "photoImport"
    /// Bool: true sizes the canvas to fit the watch screen; false sizes it to the
    /// photo's pixels, limited to `maximumCanvasPixelSide`. Both keep the photo's aspect.
    static let fitsWatchKey = "photoImportFitsWatch"
    /// The watch canvas editor accepts at most 1024 px per side. The watch renders the
    /// whole canvas into float buffers at up to 4x zoom, so a larger canvas would cost
    /// memory and brush speed in every drawing, not only in photos.
    static let maximumCanvasPixelSide = 1024
    /// A full-size canvas keeps up to twice its pixels of photo detail, which zooming
    /// in shows. The photo layer is cached apart from the layers drawn above it.
    static let photoDetailFactor = 2
    static let maximumPhotoPixelSide = maximumCanvasPixelSide * photoDetailFactor
    /// Gallery file stem chosen by the phone. The phone lists the photo under it at
    /// once; the watch saves the drawing under the same stem, so the drawing it sends
    /// back replaces that entry instead of adding a second one.
    static let nameKey = "photoImportName"
    private static let namePrefix = "Paint-Anytime_"

    /// UUID string: the photo stroke's identifier, which also names the phone's
    /// original. It survives edits, saves under new names and project round trips.
    static let photoIDKey = "photoImportID"

    // Overlay file the watch sends with each save of a drawing whose photo is intact.
    static let overlayKind = "photoOverlay"
    /// Gallery stem of the drawing the overlay belongs to.
    static let overlayForKey = "photoOverlayFor"
    /// `digest(_:)` of the gallery PNG sent with the same save. The phone uses the
    /// overlay only while its gallery PNG has this digest, so an overlay never pairs
    /// with a later revision that changed the photo.
    static let overlayDigestKey = "photoOverlayDigest"
    /// [r, g, b, a] of the visible paper, which shows through transparent photos.
    /// Absent when the paper is hidden.
    static let overlayBackgroundKey = "photoOverlayBackground"
    /// The overlay's longer side. Strokes are drawn at this size and then enlarged to
    /// the original photo; zooming in on the watch already renders this many pixels.
    static let maximumOverlayPixelSide = 2048

    /// Matches the watch's own gallery names, which also set the gallery order.
    static func newDrawingName(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss_SSS"
        return namePrefix + formatter.string(from: date) + "_" + UUID().uuidString.prefix(8)
    }

    /// A bare file stem in the gallery's naming scheme; anything else is ignored.
    static func isValidDrawingName(_ name: String) -> Bool {
        name.hasPrefix(namePrefix) && isSafeStem(name)
    }

    /// Any gallery stem the watch writes (saved, autosaved or imported drawings),
    /// and nothing that could leave its folder.
    static func isSafeStem(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 80
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// Photo stroke identifiers start with these bytes ("PAPH"), so the watch can tell
    /// the imported photo from any other raster without keeping a list.
    private static let photoIDMarker: [UInt8] = [0x50, 0x41, 0x50, 0x48]

    static func newPhotoID() -> UUID {
        var bytes = withUnsafeBytes(of: UUID().uuid) { Array($0) }
        bytes.replaceSubrange(0..<photoIDMarker.count, with: photoIDMarker)
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func isPhotoID(_ id: UUID) -> Bool {
        withUnsafeBytes(of: id.uuid) { Array($0.prefix(photoIDMarker.count)) } == photoIDMarker
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
