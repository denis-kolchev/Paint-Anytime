import Foundation
import ImageIO
#if os(watchOS) || os(iOS)
import WidgetKit
#endif

nonisolated struct GalleryWidgetArtwork: Codable {
    let filename: String
    let isFavorite: Bool
}

/// Small previews shared with the widget; original drawings remain in the app gallery.
nonisolated enum GalleryWidgetStore {
    static let groupID = "group.com.deniskolchev.paintanytime"
    static let randomKind = "PaintAnytime.RandomArtwork"
    static let randomTrioKind = "PaintAnytime.RandomArtworkTrio"
    static let favoriteTrioKind = "PaintAnytime.FavoriteArtworkTrio"
    static let favoriteKind = "PaintAnytime.FavoriteArtwork"
    /// The iPhone's 1×1 Lock Screen artwork widgets.
    static let randomCircularKind = "PaintAnytime.RandomArtworkCircular"
    static let favoriteCircularKind = "PaintAnytime.FavoriteArtworkCircular"
    /// Application-context key: the watch's favorite drawing filenames, for the iPhone widgets.
    static let favoritesContextKey = "favoriteDrawings"
    /// Longest preview side. The watch's 360 px fills its complications; iPhone widgets
    /// show up to four tiles at 3× and need more.
    #if os(iOS)
    static let previewPixelSize = 600
    #else
    static let previewPixelSize = 360
    #endif

    static func directory() throws -> URL {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
        else { throw CocoaError(.fileNoSuchFile) }
        let folder = root.appendingPathComponent("GalleryWidgets", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func artworks(favoritesOnly: Bool) throws -> [URL] {
        let folder = try directory()
        let index = folder.appendingPathComponent("index.json")
        guard FileManager.default.fileExists(atPath: index.path) else { return [] }
        let items = try JSONDecoder().decode([GalleryWidgetArtwork].self, from: Data(contentsOf: index))
        return items.filter { !favoritesOnly || $0.isFavorite }.compactMap { item in
            guard item.filename == URL(fileURLWithPath: item.filename).lastPathComponent else { return nil }
            let url = folder.appendingPathComponent(item.filename)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    static func publish(_ drawings: [(url: URL, isFavorite: Bool)]) throws {
        let folder = try directory()
        var items: [GalleryWidgetArtwork] = []
        // Widgets reload only when their images or favorites change: the iPhone app
        // publishes on every gallery refresh, and background reloads are budgeted.
        var changed = false
        for drawing in drawings {
            let name = drawing.url.lastPathComponent
            let preview = folder.appendingPathComponent(name)
            // Header check only: fully decoding every preview here cost ~200 ms on each
            // gallery open with 90 drawings. A complete source with one image is readable.
            let existingSource = CGImageSourceCreateWithURL(preview as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
            let hasReadablePreview = existingSource.map {
                CGImageSourceGetStatus($0) == .statusComplete && CGImageSourceGetCount($0) > 0
                    && CGImageSourceCopyPropertiesAtIndex($0, 0, nil) != nil
            } ?? false
            // A re-saved drawing keeps its filename, so a readable preview can still
            // show an earlier stage. Compare modification dates (a stat, no decode).
            let isPreviewCurrent = hasReadablePreview && {
                guard let previewDate = modificationDate(of: preview),
                      let drawingDate = modificationDate(of: drawing.url) else { return false }
                return previewDate >= drawingDate
            }()
            if !isPreviewCurrent {
                guard let source = CGImageSourceCreateWithURL(drawing.url as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: previewPixelSize
                      ] as CFDictionary) else { continue }
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
                else { continue }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { continue }
                try (data as Data).write(to: preview, options: .atomic)
                changed = true
            }
            items.append(GalleryWidgetArtwork(filename: name, isFavorite: drawing.isFavorite))
        }
        let indexURL = folder.appendingPathComponent("index.json")
        let index = try JSONEncoder().encode(items)
        if (try? Data(contentsOf: indexURL)) != index {
            try index.write(to: indexURL, options: .atomic)
            changed = true
        }
        let retained = Set(items.map(\.filename))
        for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            where url.pathExtension == "png" && !retained.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
        guard changed else { return }
        #if os(watchOS) || os(iOS)
        WidgetCenter.shared.reloadTimelines(ofKind: randomKind)
        WidgetCenter.shared.reloadTimelines(ofKind: favoriteKind)
        WidgetCenter.shared.reloadTimelines(ofKind: randomTrioKind)
        WidgetCenter.shared.reloadTimelines(ofKind: favoriteTrioKind)
        WidgetCenter.shared.reloadTimelines(ofKind: randomCircularKind)
        WidgetCenter.shared.reloadTimelines(ofKind: favoriteCircularKind)
        #endif
    }
}
