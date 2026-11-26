import SwiftUI
import WidgetKit
import ImageIO
#if os(iOS)
import UIKit
#endif

// Shared by the watch complications and the iPhone widgets (Paint Anytime Widgets).

struct ArtworkEntry: TimelineEntry {
    let date: Date
    let image: CGImage?
    var filename: String? = nil
    var tiles: [ArtworkEntry] = []
    /// Tiles per row; the rows follow from the tile count.
    var columns = 1

    var destination: URL? {
        var components = URLComponents()
        components.scheme = "paintanytime"
        components.host = "gallery"
        if let filename { components.queryItems = [URLQueryItem(name: "artwork", value: filename)] }
        return components.url
    }
}

/// How many artworks a widget shows, as a grid.
struct ArtworkGrid: Equatable {
    var columns: Int
    var rows: Int
    var count: Int { columns * rows }

    /// The full grid when the gallery has enough artworks, otherwise one row of them all.
    func fitting(_ available: Int) -> ArtworkGrid {
        available >= count ? self : ArtworkGrid(columns: max(1, available), rows: 1)
    }

    static func standard(for family: WidgetFamily) -> ArtworkGrid {
        switch family {
        #if os(iOS)
        case .systemMedium, .accessoryRectangular: return ArtworkGrid(columns: 3, rows: 1)
        case .systemLarge: return ArtworkGrid(columns: 2, rows: 2)
        case .systemExtraLarge: return ArtworkGrid(columns: 4, rows: 2)
        #endif
        default:
            #if os(iOS)
            // The tall Home Screen widget of iOS 27: portrait tiles, two per row.
            if #available(iOS 27.0, *), family == .systemExtraLargePortrait {
                return ArtworkGrid(columns: 2, rows: 3)
            }
            #endif
            return ArtworkGrid(columns: 1, rows: 1)
        }
    }
}

struct ArtworkProvider: TimelineProvider {
    let favoritesOnly: Bool
    /// Fixed artwork count in one row (watch complications); nil follows the widget family.
    var artworkCount: Int? = nil

    /// Pixels per point of the bitmaps WidgetKit archives.
    private var pixelScale: CGFloat {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad ? 2 : 3
        #else
        2
        #endif
    }

    private func baseGrid(for family: WidgetFamily) -> ArtworkGrid {
        artworkCount.map { ArtworkGrid(columns: $0, rows: 1) } ?? .standard(for: family)
    }

    func placeholder(in context: Context) -> ArtworkEntry {
        entries(count: 1, displaySize: context.displaySize, family: context.family)[0]
    }

    func getSnapshot(in context: Context, completion: @escaping (ArtworkEntry) -> Void) {
        completion(entries(count: 1, displaySize: context.displaySize, family: context.family)[0])
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ArtworkEntry>) -> Void) {
        // Every entry holds its bitmaps until WidgetKit archives the timeline. Large
        // iPhone widgets keep fewer hours ahead to stay well inside the extension's memory;
        // the tall iOS 27 widget fits only the current hour.
        let pixelsPerEntry = max(1, context.displaySize.width * context.displaySize.height * pixelScale * pixelScale)
        let count = min(7, max(1, Int(3_000_000 / pixelsPerEntry)))
        let entries = entries(count: count, displaySize: context.displaySize, family: context.family)
        let calendar = Calendar.autoupdatingCurrent
        let nextHour = calendar.date(byAdding: .hour, value: 1,
                                     to: calendar.dateInterval(of: .hour, for: entries[0].date)!.start)!
        completion(Timeline(entries: entries, policy: .after(entries.count > 1 ? entries[1].date : nextHour)))
    }

    /// WidgetKit archives the bitmap's pixel dimensions, not its SwiftUI frame.
    /// Fit even previously cached previews to this particular widget slot.
    private func thumbnail(at url: URL, displaySize: CGSize) -> CGImage? {
        guard displaySize.width > 0, displaySize.height > 0,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        // Crop into a slot-sized bitmap before archiving: scaling the view alone
        // would either blur the image or exceed WidgetKit's image-area limit.
        let pixelWidth = max(1, Int(floor(displaySize.width * pixelScale)))
        let pixelHeight = max(1, Int(floor(displaySize.height * pixelScale)))
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

    private func tileSize(_ grid: ArtworkGrid, in displaySize: CGSize, family: WidgetFamily) -> CGSize {
        let spacing = ArtworkView.spacing(for: family, columns: grid.columns, rows: grid.rows)
        return CGSize(width: (displaySize.width - spacing * CGFloat(grid.columns - 1)) / CGFloat(grid.columns),
                      height: (displaySize.height - spacing * CGFloat(grid.rows - 1)) / CGFloat(grid.rows))
    }

    private func entries(count: Int, displaySize: CGSize, family: WidgetFamily) -> [ArtworkEntry] {
        let grid = baseGrid(for: family)
        let now = Date()
        let calendar = Calendar.autoupdatingCurrent
        let hour = calendar.dateInterval(of: .hour, for: now)!.start
        let candidates = (try? GalleryWidgetStore.artworks(favoritesOnly: favoritesOnly)) ?? []
        let defaults = UserDefaults(suiteName: GalleryWidgetStore.groupID)
        let suffix = grid.count == 1 ? "" : grid.count == 3 ? ".triptych" : ".\(grid.count)"
        let key = (favoritesOnly ? "widget.favorite.selection" : "widget.gallery.selection") + suffix
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
            var layout = grid.fitting(candidates.count)
            let size = tileSize(layout, in: displaySize, family: family)
            for url in choices {
                if let decoded = thumbnail(at: url, displaySize: size) {
                    tiles.append(ArtworkEntry(date: date, image: decoded, filename: url.lastPathComponent))
                    if tiles.count == layout.count { break }
                }
            }
            // If a corrupt file reduced the count, recrop to fill the remaining tiles.
            if !tiles.isEmpty, tiles.count != layout.count {
                layout = grid.fitting(tiles.count)
                let corrected = tileSize(layout, in: displaySize, family: family)
                tiles = tiles.prefix(layout.count).compactMap { tile in
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
            if grid.count > 1 {
                entry.tiles = tiles
                entry.columns = layout.columns
            }
            result.append(entry)
        }
        return result
    }
}

/// Preserve image detail when the watch face or Home Screen recolors the widget.
private struct ArtworkImage: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    let image: CGImage

    var body: some View {
        let artwork = Image(decorative: image, scale: 1)
            .renderingMode(.original)
            .resizable()
        if #available(watchOS 11.0, iOS 18.0, *) {
            artwork.widgetAccentedRenderingMode(.accentedDesaturated)
        } else if renderingMode == .accented {
            // watchOS 10 recolors alpha, so an opaque image otherwise becomes
            // a solid rectangle. Carry its luminance into the alpha channel.
            artwork.luminanceToAlpha().widgetAccentable()
        } else {
            artwork
        }
    }
}

struct ArtworkView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ArtworkEntry
    let favoritesOnly: Bool

    /// Home Screen widgets separate their tiles; accessory widgets join them, as on the watch.
    static func spacing(for family: WidgetFamily, columns: Int, rows: Int) -> CGFloat {
        isAccessory(family) || columns * rows == 1 ? 0 : 2
    }

    /// The system masks Home Screen widgets itself; accessory slots need the rounding.
    static func isAccessory(_ family: WidgetFamily) -> Bool {
        switch family {
        case .accessoryCircular, .accessoryRectangular, .accessoryInline: return true
        #if os(watchOS)
        case .accessoryCorner: return true
        #endif
        default: return false
        }
    }

    private var isAccessory: Bool { Self.isAccessory(family) }

    /// The circular slot clips to its circle; other accessories get rounded corners.
    private var artworkShape: AnyShape {
        family == .accessoryCircular
            ? AnyShape(Circle())
            : AnyShape(RoundedRectangle(cornerRadius: isAccessory ? 15 : 0, style: .continuous))
    }

    private var label: Text {
        Text(favoritesOnly ? LocalizedStringKey("Favorite artwork") : LocalizedStringKey("Gallery artwork"))
    }

    var body: some View {
        Group {
            if !entry.tiles.isEmpty {
                let columns = max(1, entry.columns)
                let rows = (entry.tiles.count + columns - 1) / columns
                let spacing = Self.spacing(for: family, columns: columns, rows: rows)
                GeometryReader { geometry in
                    let width = (geometry.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
                    let height = (geometry.size.height - spacing * CGFloat(rows - 1)) / CGFloat(rows)
                    VStack(spacing: spacing) {
                        ForEach(0..<rows, id: \.self) { row in
                            HStack(spacing: spacing) {
                                ForEach(row * columns..<min(entry.tiles.count, (row + 1) * columns), id: \.self) { index in
                                    let tile = entry.tiles[index]
                                    if let image = tile.image, let destination = tile.destination {
                                        Link(destination: destination) {
                                            ArtworkImage(image: image)
                                                .scaledToFill()
                                                .frame(width: width, height: height)
                                                .clipped()
                                        }
                                        .accessibilityLabel(label)
                                    }
                                }
                            }
                        }
                    }
                    .clipShape(artworkShape)
                }
            } else if let image = entry.image {
                GeometryReader { geometry in
                    ArtworkImage(image: image)
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipShape(artworkShape)
                }
                .accessibilityLabel(label)
            } else if family == .accessoryCircular {
                // A 1×1 slot has no room for the explanation; the icon stands in for it.
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: favoritesOnly ? "heart" : "photo.on.rectangle")
                        .font(.title3)
                        .widgetAccentable()
                }
                .accessibilityLabel(Text(favoritesOnly ? LocalizedStringKey("No favorites yet") : LocalizedStringKey("No artwork in the gallery to display")))
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
        .containerBackground(for: .widget) {
            if isAccessory { Color.clear } else { Color.black }
        }
        .widgetURL(entry.destination)
        .unredacted()
    }
}

#if os(watchOS)
struct RandomArtworkComplication: Widget {
    let kind = GalleryWidgetStore.randomKind
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ArtworkProvider(favoritesOnly: false, artworkCount: 1)) { entry in
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
        StaticConfiguration(kind: kind, provider: ArtworkProvider(favoritesOnly: true, artworkCount: 1)) { entry in
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
#endif
