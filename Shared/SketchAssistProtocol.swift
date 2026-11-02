import Foundation

/// WatchConnectivity contract for the experimental sketch assist round trip:
/// the watch sends a PNG of the canvas, the phone replies with a generated image
/// file or with a `transferUserInfo` failure. Both carry the request identifier.
nonisolated enum SketchAssistProtocol {
    static let kindKey = "kind"
    static let requestIDKey = "sketchAssistID"
    static let labelKey = "sketchAssistLabel"
    /// Longest side of the result in pixels, sized for the watch canvas.
    static let maximumPixelsKey = "sketchAssistMaximumPixels"
    static let failureKey = "sketchAssistFailure"
    /// Free-form English diagnostics for the prototype; not localized.
    static let detailKey = "sketchAssistDetail"
    /// Bool sent with `transferUserInfo`: Image Playground can run on the phone
    /// (supported iPhone, Apple Intelligence on, image generation available).
    static let availabilityKey = "sketchAssistAvailable"
    static let requestKind = "sketchAssistRequest"
    static let resultKind = "sketchAssistResult"

    /// Stable codes; the watch owns the localized descriptions.
    enum Failure: String {
        /// Older iOS, unsupported iPhone or Apple Intelligence turned off.
        case unavailable
        /// The user dismissed Image Playground on the phone.
        case cancelled
        case unsupportedDrawing
        case failed
    }
}
