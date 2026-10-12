import SwiftUI
import WidgetKit
import ImageIO

private struct ArtworkEntry: TimelineEntry {
    let date: Date
    let image: CGImage?
    var filename: String? = nil
    var tiles: [ArtworkEntry] = []

    var destination: URL? {
        var components = URLComponents()
        components.scheme = "paintanytime"
        components.host = "gallery"
        if let filename { components.queryItems = [URLQueryItem(name: "artwork", value: filename)] }
        return components.url
    }
}

private struct ArtworkProvider: TimelineProvider {
    let favoritesOnly: Bool
    var artworkCount = 1

    func placeholder(in context: Context) -> ArtworkEntry {
        entries(count: 1, displaySize: context.displaySize)[0]
    }

    func getSnapshot(in context: Context, completion: @escaping (ArtworkEntry) -> Void) {
        completion(entries(count: 1, displaySize: context.displaySize)[0])
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ArtworkEntry>) -> Void) {
        let entries = entries(count: 7, displaySize: context.displaySize)
        completion(Timeline(entries: entries, policy: .after(entries[1].date)))
    }

    /// WidgetKit archives the bitmap's pixel dimensions, not its SwiftUI frame.
    /// Fit even previously cached previews to this particular complication slot.
    private func thumbnail(at url: URL, displaySize: CGSize) -> CGImage? {
        guard displaySize.width > 0, displaySize.height > 0,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        // Crop into a slot-sized bitmap before archiving: scaling the view alone
        // would either blur the image or exceed WidgetKit's image-area limit.
        let pixelWidth = max(1, Int(floor(displaySize.width * 2)))
        let pixelHeight = max(1, Int(floor(displaySize.height * 2)))
        let scale = min(1, max(Double(pixelWidth) / width, Double(pixelHeight) / height))
        let maxPixels = max(1, Int(ceil(max(width, height) * scale)))
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary),
              let bitmap = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
                                     bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let zoom = max(CGFloat(pixelWidth) / CGFloat(image.width),
                       CGFloat(pixelHeight) / CGFloat(image.height))
        let drawnWidth = CGFloat(image.width) * zoom
        let drawnHeight = CGFloat(image.height) * zoom
        bitmap.interpolationQuality = .high
        bitmap.draw(image, in: CGRect(x: (CGFloat(pixelWidth) - drawnWidth) / 2,
                                      y: (CGFloat(pixelHeight) - drawnHeight) / 2,
                                      width: drawnWidth, height: drawnHeight))
        return bitmap.makeImage()
    }

    private func entries(count: Int, displaySize: CGSize) -> [ArtworkEntry] {
        let now = Date()
        let calendar = Calendar.autoupdatingCurrent
        let hour = calendar.dateInterval(of: .hour, for: now)!.start
        let candidates = (try? GalleryWidgetStore.artworks(favoritesOnly: favoritesOnly)) ?? []
        let defaults = UserDefaults(suiteName: GalleryWidgetStore.groupID)
        let key = (favoritesOnly ? "widget.favorite.selection" : "widget.gallery.selection") + (artworkCount == 3 ? ".triptych" : "")
        let saved = defaults?.dictionary(forKey: key)
        var previous = candidates.first { $0.lastPathComponent == (saved?["filename"] as? String) }
        var result: [ArtworkEntry] = []
        for offset in 0..<count {
            var choices = candidates.shuffled()
            // Keep the same image during this hour, and avoid immediate repeats afterward.
            if let previous {
                choices.removeAll { $0 == previous }
                if offset == 0, (saved?["hour"] as? Date) == hour { choices.insert(previous, at: 0) }
                else { choices.append(previous) }
            }
            let date = offset == 0 ? now : calendar.date(byAdding: .hour, value: offset, to: hour)!
            var tiles: [ArtworkEntry] = []
            let tileCount = min(artworkCount, candidates.count)
            let tileSize = CGSize(width: displaySize.width / CGFloat(max(1, tileCount)), height: displaySize.height)
            for url in choices {
                if let decoded = thumbnail(at: url, displaySize: tileSize) {
                    tiles.append(ArtworkEntry(date: date, image: decoded, filename: url.lastPathComponent))
                    if tiles.count == tileCount { break }
                }
            }
            // If a corrupt file reduced the count, recrop to fill the remaining columns.
            if !tiles.isEmpty, tiles.count != tileCount {
                let corrected = CGSize(width: displaySize.width / CGFloat(tiles.count), height: displaySize.height)
                tiles = tiles.compactMap { tile in
                    guard let url = candidates.first(where: { $0.lastPathComponent == tile.filename }),
                          let image = thumbnail(at: url, displaySize: corrected) else { return nil }
                    return ArtworkEntry(date: date, image: image, filename: tile.filename)
                }
            }
            if offset == 0, let filename = tiles.first?.filename {
                defaults?.set(["filename": filename, "hour": hour], forKey: key)
            }
            previous = candidates.first { $0.lastPathComponent == tiles.first?.filename }
            var entry = tiles.first ?? ArtworkEntry(date: date, image: nil)
            if artworkCount > 1 { entry.tiles = tiles }
            result.append(entry)
        }
        return result
    }
}

private struct ArtworkView: View {
    let entry: ArtworkEntry
    let favoritesOnly: Bool

    var body: some View {
        Group {
            if !entry.tiles.isEmpty {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        ForEach(entry.tiles.indices, id: \.self) { index in
                            let tile = entry.tiles[index]
                            if let image = tile.image, let destination = tile.destination {
                                Link(destination: destination) {
                                    Image(decorative: image, scale: 1)
                                        .renderingMode(.original)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: geometry.size.width / CGFloat(entry.tiles.count), height: geometry.size.height)
                                        .clipped()
                                }
                                .accessibilityLabel(Text(favoritesOnly ? LocalizedStringKey("Favorite artwork") : LocalizedStringKey("Gallery artwork")))
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
            } else if let image = entry.image {
                GeometryReader { geometry in
                    Image(decorative: image, scale: 1)
                        .renderingMode(.original)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
                .accessibilityLabel(Text(favoritesOnly ? LocalizedStringKey("Favorite artwork") : LocalizedStringKey("Gallery artwork")))
            } else {
                VStack(spacing: 3) {
                    Image(systemName: favoritesOnly ? "heart" : "photo.on.rectangle")
                        .font(.headline)
                    Text(favoritesOnly ? LocalizedStringKey("No favorites yet") : LocalizedStringKey("No artwork in the gallery to display"))
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.65)
                }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .containerBackground(for: .widget) { Color.clear }
        .widgetURL(entry.destination)
        .unredacted()
    }
}

struct RandomArtworkComplication: Widget {
    let kind = GalleryWidgetStore.randomKind
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ArtworkProvider(favoritesOnly: false)) { entry in
            ArtworkView(entry: entry, favoritesOnly: false)
        }
        .configurationDisplayName("Gallery artwork")
        .description("A random artwork every hour.")
        .supportedFamilies([.accessoryRectangular])
        .contentMarginsDisabled()
    }
}

struct FavoriteArtworkComplication: Widget {
    let kind = GalleryWidgetStore.favoriteKind
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ArtworkProvider(favoritesOnly: true)) { entry in
            ArtworkView(entry: entry, favoritesOnly: true)
        }
        .configurationDisplayName("Favorite artwork")
        .description("A random favorite every hour.")
        .supportedFamilies([.accessoryRectangular])
        .contentMarginsDisabled()
    }
}

struct RandomArtworkTrioComplication: Widget {
    let kind = GalleryWidgetStore.randomTrioKind
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ArtworkProvider(favoritesOnly: false, artworkCount: 3)) { entry in
            ArtworkView(entry: entry, favoritesOnly: false)
        }
        .configurationDisplayName("Gallery · 3")
        .description("Gallery · 3")
        .supportedFamilies([.accessoryRectangular])
        .contentMarginsDisabled()
    }
}

struct FavoriteArtworkTrioComplication: Widget {
    let kind = GalleryWidgetStore.favoriteTrioKind
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ArtworkProvider(favoritesOnly: true, artworkCount: 3)) { entry in
            ArtworkView(entry: entry, favoritesOnly: true)
        }
        .configurationDisplayName("Favorites · 3")
        .description("Favorites · 3")
        .supportedFamilies([.accessoryRectangular])
        .contentMarginsDisabled()
    }
}
