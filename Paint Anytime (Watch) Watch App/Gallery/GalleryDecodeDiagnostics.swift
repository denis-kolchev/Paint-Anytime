#if DEBUG
import Foundation

nonisolated struct GalleryDecodeDiagnostics: Sendable {
    var requests = 0
    var cacheHits = 0
    var decodes = 0
    var failures = 0
    var decodeMS = 0.0
    var maximumDecodeMS = 0.0
}
#endif
