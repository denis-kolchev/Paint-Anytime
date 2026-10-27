import SwiftUI

/// A slot stays in the same place relative to the focal image at every density.
struct PhoneGalleryZoomTile: View {
    let source: URL?
    let destination: URL?
    let blend: Double
    let side: CGFloat

    var body: some View {
        ZStack {
            if let source {
                DrawingPreview(url: source, maximumSize: 1600, fillsFrame: true)
                    .id(source)
            }
            if let destination, destination != source {
                DrawingPreview(url: destination, maximumSize: 1600, fillsFrame: true)
                    .id(destination)
                    // Newly revealed columns have no previous image to dissolve.
                    .opacity(source == nil ? 1 : blend)
            }
        }
        .frame(width: side, height: side)
        .background {
            if source != nil || destination != nil {
                Rectangle().fill(.quaternary)
            }
        }
        .clipped()
    }
}
