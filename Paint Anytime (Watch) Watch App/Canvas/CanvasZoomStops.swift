import Foundation

/// The zoom values the Crown clicks through: round percents whose step grows with the
/// zoom, so every click changes it by roughly the same share (2.5–6% from 100% up).
/// Up to 200% they are the 5% steps the linear Crown had; above, the step doubles
/// with every doubling of zoom. Free log2 steps gave equal shares but odd percents.
enum CanvasZoomStops {
    /// (first percent of the band, step) — each band runs to the next one's start.
    private static let bands: [(start: Int, step: Int)] = [
        (25, 5), (200, 10), (400, 20), (800, 50), (1600, 100), (3200, 200), (6400, 400)
    ]
    static let maximumPercent = 12_800

    /// All stops as zoom factors, ascending: 0.25 … 128.
    static let all: [Double] = {
        var percents: [Int] = []
        for (index, band) in bands.enumerated() {
            let end = index + 1 < bands.count ? bands[index + 1].start : maximumPercent + band.step
            percents.append(contentsOf: stride(from: band.start, to: end, by: band.step))
        }
        return percents.filter { $0 <= maximumPercent }.map { Double($0) / 100 }
    }()

    /// Index of the stop nearest to `zoom` (by ratio).
    static func index(nearest zoom: Double) -> Int {
        guard zoom > 0 else { return 0 }
        var best = 0, bestDistance = Double.infinity
        for (index, stop) in all.enumerated() {
            let distance = abs(log(stop / zoom))
            if distance < bestDistance { best = index; bestDistance = distance }
        }
        return best
    }

    /// Index of the highest stop at or below `limit`.
    static func lastIndex(atMost limit: Double) -> Int {
        all.lastIndex { $0 <= limit + 0.000_1 } ?? 0
    }
}
