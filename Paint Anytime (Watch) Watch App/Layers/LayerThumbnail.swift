import SwiftUI

struct LayerThumbnail: View {
    let layer: CanvasLayer
    let canvasSize: CGSize
    var previewOpacity: Double = 1
    var maximumPixelDimension: CGFloat = 124
    var showsCheckerboard = true
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if showsCheckerboard {
                TransparencyCheckerboard()
            }
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
                    .opacity(previewOpacity)
            }
        }
        .aspectRatio(canvasSize.width > 0 && canvasSize.height > 0
            ? canvasSize.width / canvasSize.height : 200.0 / 240.0, contentMode: .fit)
        .clipped()
        .task(id: layer.strokes.map(\.geometryRevision)) {
            let strokes = layer.strokes
            let size = canvasSize.width > 0 && canvasSize.height > 0 ? canvasSize : CGSize(width: 200, height: 240)
            let scale = min(1, maximumPixelDimension / max(size.width, size.height))
            let task = Task.detached(priority: .utility) {
                WatchBitmapRenderer.layerThumbnail(strokes: strokes, size: size, scale: scale)
            }
            let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            guard !Task.isCancelled else { return }
            image = result
        }
    }
}
