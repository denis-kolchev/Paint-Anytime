import SwiftUI
import WidgetKit

@main
struct PaintAnytimeComplications: WidgetBundle {
    var body: some Widget {
        OpenAppComplication()
        NewCanvasComplication()
        GalleryComplication()
        RandomArtworkTrioComplication()
        FavoriteArtworkTrioComplication()
    }
}
