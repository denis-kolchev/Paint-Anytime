import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// A single representation for both the shared drawing and its preview.
/// The watchOS 10 crash report shows concurrent registration crashing in
/// CoreTransferable's tuple-description cache. Avoid the built-in URL/Image
/// representations here, which can expand into tuples during ShareLink setup.
struct DrawingShareItem: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .png) { item in
            SentTransferredFile(item.url)
        }
    }
}
