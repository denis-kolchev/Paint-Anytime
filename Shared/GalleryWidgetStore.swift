import Foundation
import ImageIO
#if os(watchOS)
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

    static func publish(_ drawings: [(url: URL, isFavorite: Bool)]) throws {
        let folder = try directory()
        var items: [GalleryWidgetArtwork] = []
        for drawing in drawings {
            let name = drawing.url.lastPathComponent
            let preview = folder.appendingPathComponent(name)
            let existingSource = CGImageSourceCreateWithURL(preview as CFURL, nil)
            let hasReadablePreview = existingSource.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } != nil
            if !hasReadablePreview {
                guard let source = CGImageSourceCreateWithURL(drawing.url as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 360
                      ] as CFDictionary) else { continue }
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
                else { continue }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { continue }
                try (data as Data).write(to: preview, options: .atomic)
            }
            items.append(GalleryWidgetArtwork(filename: name, isFavorite: drawing.isFavorite))
        }
        try JSONEncoder().encode(items).write(to: folder.appendingPathComponent("index.json"), options: .atomic)
        let retained = Set(items.map(\.filename))
        for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            where url.pathExtension == "png" && !retained.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
        #if os(watchOS)
        WidgetCenter.shared.reloadTimelines(ofKind: randomKind)
        WidgetCenter.shared.reloadTimelines(ofKind: favoriteKind)
        WidgetCenter.shared.reloadTimelines(ofKind: randomTrioKind)
        WidgetCenter.shared.reloadTimelines(ofKind: favoriteTrioKind)
        #endif
    }
}
