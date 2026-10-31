import Foundation
import CoreGraphics

/// Geometry and interaction policy shared by phone pinch and watch Crown/taps.
/// No decoding, timers, platform views, or document mutations happen here.
enum GalleryZoomRules {
    static let densities = [5, 3, 1]
    static let spacing: CGFloat = 2

    static func side(_ columns: Int, width: CGFloat) -> CGFloat {
        max(1, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
    }

    static func position(_ columns: Int) -> CGFloat { columns == 5 ? 0 : columns == 3 ? 1 : 2 }
    static func sizeProgress(_ position: CGFloat) -> CGFloat {
        position <= 1 ? position / 6 : 1 / 6 + (position - 1) * 5 / 6
    }
    static func positionFromSize(_ size: CGFloat) -> CGFloat {
        size <= 1 / 6 ? size * 6 : 1 + (size - 1 / 6) * 6 / 5
    }
    static func rubberBand(_ distance: CGFloat, dimension: CGFloat) -> CGFloat {
        let d = max(1, dimension)
        return (1 - 1 / (0.55 * max(0, distance) / d + 1)) * d
    }
    static func position(requestedSide: CGFloat, width: CGFloat) -> CGFloat {
        let small = side(5, width: width), middle = side(3, width: width), large = side(1, width: width)
        if requestedSide < small { return -rubberBand(small - requestedSide, dimension: width) / small / 5 }
        if requestedSide > large { return 2 + rubberBand(requestedSide - large, dimension: width) / large }
        return requestedSide <= middle ? (requestedSide - small) / (middle - small)
            : 1 + (requestedSide - middle) / (large - middle)
    }
    static func requestedSide(position: CGFloat, width: CGFloat) -> CGFloat {
        let small = side(5, width: width), middle = side(3, width: width), large = side(1, width: width)
        if position < 0 {
            let offset = min(width * 0.999, -position * small * 5)
            return max(0.001, small - offset / (0.55 * (1 - offset / width)))
        }
        if position > 2 {
            let offset = min(width * 0.999, (position - 2) * large)
            return large + offset / (0.55 * (1 - offset / width))
        }
        return position <= 1 ? small + (middle - small) * position : middle + (large - middle) * (position - 1)
    }
    static func leading(index: Int, sourceColumns: Int, sourceLeading: Int, destination: Int) -> Int {
        let fraction = (CGFloat((index + sourceLeading) % sourceColumns) + 0.5) / CGFloat(sourceColumns)
        let column = destination > sourceColumns ? destination / 2 : min(destination - 1, Int(fraction * CGFloat(destination)))
        return (column - index % destination + destination) % destination
    }
    static func nearest(position current: CGFloat, baseColumns: Int, width: CGFloat) -> Int {
        let bounded = min(2, max(0, current))
        let size = requestedSide(position: bounded, width: width)
        let nearest = densities.min { abs(log(side($0, width: width) / size)) < abs(log(side($1, width: width) / size)) } ?? baseColumns
        if nearest != baseColumns {
            if bounded > position(baseColumns), position(nearest) < bounded { return densities[Int(bounded.rounded(.up))] }
            if bounded < position(baseColumns), position(nearest) > bounded { return densities[Int(bounded.rounded(.down))] }
        }
        return nearest
    }
    static func settlement(position current: CGFloat, baseColumns: Int, destination: Int) -> (duration: Double, gridTransition: Bool) {
        let rubber = current < 0 || current > 2
        let grid = destination != baseColumns && !rubber
        let multiplier = destination == baseColumns && current >= 0 ? Double(destination) : 1
        return (grid ? 0.28 + 0.16 * Double(min(2, abs(position(destination) - current)))
            : (rubber ? 0.24 : 0.18) * multiplier, grid)
    }
    static func easing(_ time: Double, gridTransition: Bool) -> Double {
        if gridTransition { return time * time * (3 - 2 * time) }
        var low = 0.0, high = 1.0
        for _ in 0..<14 {
            let t = (low + high) / 2
            let x = 3 * (1 - t) * (1 - t) * t * 0.33 + 3 * (1 - t) * t * t * 0.67 + t * t * t
            if x < time { low = t } else { high = t }
        }
        return 1 - pow(1 - (low + high) / 2, 3)
    }
    static func itemTop(index: Int, columns: Int, leading: Int, width: CGFloat, layout: GalleryImageLayout) -> CGFloat {
        columns == 1 ? layout.top(at: index, width: width, spacing: spacing)
            : CGFloat((index + leading) / columns) * (side(columns, width: width) + spacing)
    }
    static func placement(index: Int, images: [URL], columns: Int, leading: Int, width: CGFloat,
                          height: CGFloat, layout: GalleryImageLayout, fractionY: CGFloat,
                          viewportY: CGFloat, capturedTop: CGFloat? = nil, offsetY: CGFloat = 0,
                          topInset: CGFloat = 0) -> (top: CGFloat, anchorY: CGFloat) {
        let tileSide = side(columns, width: width)
        let tileHeight = columns == 1 ? layout.height(for: images[index], width: tileSide) : tileSide
        let top = itemTop(index: index, columns: columns, leading: leading, width: width, layout: layout)
        let rows = (images.count + leading + columns - 1) / columns
        let contentHeight = columns == 1 ? layout.top(at: images.count, width: tileSide, spacing: spacing) - spacing
            : CGFloat(rows) * tileSide + CGFloat(max(0, rows - 1)) * spacing
        let denominator = height - tileHeight
        let anchor = abs(denominator) > 1 ? min(1, max(0, (viewportY - fractionY * tileHeight) / denominator)) : 0.5
        let minimum = -max(0, topInset)
        let maximum = max(minimum, contentHeight - height)
        let settled = min(maximum, max(minimum, top - (capturedTop ?? anchor * denominator)))
        let scroll = min(maximum, max(minimum, settled - offsetY))
        let viewportTop = top - scroll
        return (viewportTop, abs(denominator) > 1 ? viewportTop / denominator : anchor)
    }

    static func slots(images: [URL], index: Int, baseColumns: Int, baseLeading: Int,
                      leading: [Int: Int], tops: [Int: CGFloat], width: CGFloat, height: CGFloat,
                      layout: GalleryImageLayout, panRange: CGFloat = 0,
                      singlePhotoFrame: CGRect? = nil) -> [GalleryZoomSlot] {
        let anchorRow = (index + baseLeading) / baseColumns
        let anchorColumn = (index + baseLeading) % baseColumns
        var radius = Int(ceil((height + panRange) / (side(5, width: width) + spacing))) + 2
        if singlePhotoFrame == nil {
            let singleTop = layout.top(at: index, width: width, spacing: spacing)
            for candidate in images.indices {
                let top = (tops[1] ?? 0) + layout.top(at: candidate, width: width, spacing: spacing) - singleTop
                if top <= height + panRange, top + layout.height(for: images[candidate], width: width) >= -panRange {
                    radius = max(radius, abs(candidate - index) + 2)
                }
            }
        }
        var result: [GalleryZoomSlot] = []
        for row in (anchorRow - radius)...(anchorRow + radius) {
            for column in -4..<(baseColumns + 4) {
                var urls: [Int: URL] = [:], mappedColumns: [Int: Int] = [:], frames: [Int: CGRect] = [:]
                for density in densities {
                    let mappedColumn = (index + (leading[density] ?? 0)) % density + column - anchorColumn
                    mappedColumns[density] = mappedColumn
                    let tileWidth = side(density, width: width)
                    let rowIndex = index + row - anchorRow
                    let relativeTop = density == 1
                        ? layout.top(at: rowIndex, width: tileWidth, spacing: spacing) - layout.top(at: index, width: tileWidth, spacing: spacing)
                        : CGFloat(row - anchorRow) * (tileWidth + spacing)
                    let tileHeight = density == 1 && images.indices.contains(rowIndex) ? layout.height(for: images[rowIndex], width: tileWidth) : tileWidth
                    frames[density] = CGRect(x: CGFloat(mappedColumn) * (tileWidth + spacing),
                        y: (tops[density] ?? 0) + relativeTop, width: tileWidth, height: tileHeight)
                    if density == 1, let singlePhotoFrame {
                        // Keep adjacent slot edges one spacing apart throughout
                        // interpolation. Adding a viewport-sized offset here opens
                        // black bands before the focal photo fills the screen.
                        // The pager takes over at the fitted-photo endpoint.
                        frames[density] = singlePhotoFrame.offsetBy(
                            dx: CGFloat(mappedColumn) * (singlePhotoFrame.width + spacing),
                            dy: CGFloat(row - anchorRow) * (singlePhotoFrame.height + spacing))
                    }
                    let mappedIndex = index + (row - anchorRow) * density + column - anchorColumn
                    if (0..<density).contains(mappedColumn), images.indices.contains(mappedIndex) { urls[density] = images[mappedIndex] }
                }
                result.append(GalleryZoomSlot(id: result.count, frames: frames, images: urls, columns: mappedColumns))
            }
        }
        return result
    }

    /// Decorative rows repeat horizontally, without filling real empty cells or
    /// extending the last partial row into the right-hand strip.
    static func backdropURL(images: [URL], leading: Int, row: Int, column: Int, direction: Int) -> URL? {
        let rowCount = (images.count + leading + 4) / 5
        guard (0..<rowCount).contains(row) else { return nil }
        if direction > 0, row == rowCount - 1, (images.count + leading) % 5 != 0 { return nil }
        let first = max(0, row * 5 - leading), end = min(images.count, (row + 1) * 5 - leading)
        guard first < end else { return nil }
        let count = end - first
        let repeated = direction < 0 ? column - 5 : column
        return images[first + (repeated % count + count) % count]
    }
}
