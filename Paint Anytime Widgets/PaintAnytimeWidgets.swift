import SwiftUI
import WidgetKit

// The provider and layout are shared with the watch complications:
// Paint Anytime Complications/GalleryArtworkComplications.swift.

private var artworkFamilies: [WidgetFamily] {
    var families: [WidgetFamily] = [
        .systemSmall, .systemMedium, .systemLarge, .systemExtraLarge, .accessoryRectangular
    ]
    // The tall Home Screen widget, nearly the whole screen; iOS 27 and later.
    if #available(iOS 27.0, *) { families.append(.systemExtraLargePortrait) }
    return families
}

struct RandomArtworkWidget: Widget {
    let kind = GalleryWidgetStore.randomKind
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ArtworkProvider(favoritesOnly: false)) { entry in
            ArtworkView(entry: entry, favoritesOnly: false)
        }
        .configurationDisplayName("Gallery artwork")
        .description("A random artwork every hour.")
        .supportedFamilies(artworkFamilies)
        .contentMarginsDisabled()
    }
}

struct FavoriteArtworkWidget: Widget {
    let kind = GalleryWidgetStore.favoriteKind
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ArtworkProvider(favoritesOnly: true)) { entry in
            ArtworkView(entry: entry, favoritesOnly: true)
        }
        .configurationDisplayName("Favorite artwork")
        .description("A random favorite every hour.")
        .supportedFamilies(artworkFamilies)
        .contentMarginsDisabled()
    }
}

@main
struct PaintAnytimeWidgets: WidgetBundle {
    var body: some Widget {
        RandomArtworkWidget()
        FavoriteArtworkWidget()
    }
}
