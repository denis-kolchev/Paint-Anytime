import CoreGraphics
import Foundation

/// A square piece of the zoomed canvas on a fixed pixel grid of its scale. Each tile is a
/// viewport region (`WatchRasterArtwork.Region`) with its own render queue and layer cache,
/// so tiles of one scale render in parallel, survive pans and short zoom-outs, and match
/// the full-canvas raster pixel for pixel like any region.
struct RegionTile: Identifiable, Equatable {
    struct ID: Hashable {
        let scale: CGFloat
        let column: Int
        let row: Int
    }
    let id: ID
    let region: WatchRasterArtwork.Region
    var rect: CGRect { CGRect(origin: region.origin, size: region.size) }
}

enum RegionTiling {
    /// Pixels per tile side. Smaller tiles waste fewer pixels around the view; each one
    /// also costs a render queue, a composite and its share of every stroke's geometry.
    static let tilePixels: CGFloat = 256

    /// Scales on a ladder of √2 steps, so the same scale always yields the same tile IDs.
    static func ladderScale(_ scale: CGFloat) -> CGFloat {
        pow(2, (log2(scale) * 2).rounded() / 2)
    }

    /// The tile of `id`, clipped to the paper's pixels at its scale; nil past the paper.
    static func tile(_ id: RegionTile.ID, paper: CGSize) -> RegionTile? {
        let scale = id.scale
        let width = ceil(paper.width * scale), height = ceil(paper.height * scale)
        let minX = CGFloat(id.column) * tilePixels, minY = CGFloat(id.row) * tilePixels
        let maxX = min(width, minX + tilePixels), maxY = min(height, minY + tilePixels)
        guard id.column >= 0, id.row >= 0, maxX > minX, maxY > minY else { return nil }
        // Slightly under the pixel count, so `ceil(size * scale)` cannot add a column.
        return RegionTile(id: id, region: WatchRasterArtwork.Region(
            origin: CGPoint(x: minX / scale, y: minY / scale),
            size: CGSize(width: (maxX - minX - 0.001) / scale, height: (maxY - minY - 0.001) / scale),
            scale: scale))
    }

    /// Cells covering `rect` (canvas points) at `scale`, nearest to `center` first:
    /// the order tiles are created in, so the middle of the view is queued first.
    static func cells(covering rect: CGRect, scale: CGFloat, paper: CGSize,
                      nearest center: CGPoint) -> [RegionTile.ID] {
        let bounds = rect.intersection(CGRect(origin: .zero, size: paper))
        guard !bounds.isNull, !bounds.isEmpty, scale > 0 else { return [] }
        let columns = Int(floor(bounds.minX * scale / tilePixels))...max(
            Int(floor(bounds.minX * scale / tilePixels)), Int(ceil(bounds.maxX * scale / tilePixels)) - 1)
        let rows = Int(floor(bounds.minY * scale / tilePixels))...max(
            Int(floor(bounds.minY * scale / tilePixels)), Int(ceil(bounds.maxY * scale / tilePixels)) - 1)
        let cx = center.x * scale / tilePixels, cy = center.y * scale / tilePixels
        var ids: [RegionTile.ID] = []
        for row in rows {
            for column in columns where tile(.init(scale: scale, column: column, row: row), paper: paper) != nil {
                ids.append(.init(scale: scale, column: column, row: row))
            }
        }
        return ids.sorted {
            hypot(CGFloat($0.column) + 0.5 - cx, CGFloat($0.row) + 0.5 - cy)
                < hypot(CGFloat($1.column) + 0.5 - cx, CGFloat($1.row) + 0.5 - cy)
        }
    }

    /// Pixels held by the tiles covering `rect` at `scale`.
    static func pixels(covering rect: CGRect, scale: CGFloat, paper: CGSize) -> CGFloat {
        cells(covering: rect, scale: scale, paper: paper, nearest: .zero).reduce(0) { sum, id in
            guard let tile = tile(id, paper: paper) else { return sum }
            return sum + ceil(tile.region.size.width * scale) * ceil(tile.region.size.height * scale)
        }
    }
}
