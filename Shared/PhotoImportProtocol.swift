import Foundation

/// WatchConnectivity contract for starting a watch drawing from an iPhone photo.
/// The phone sends an oriented PNG no larger than `maximumPhotoPixelSide`; the watch
/// builds the document, because only the watch target has the drawing model.
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

    /// Matches the watch's own gallery names, which also set the gallery order.
    static func newDrawingName(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss_SSS"
        return namePrefix + formatter.string(from: date) + "_" + UUID().uuidString.prefix(8)
    }

    /// A bare file stem in the gallery's naming scheme; anything else is ignored.
    static func isValidDrawingName(_ name: String) -> Bool {
        name.hasPrefix(namePrefix) && name.count <= 80
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}
