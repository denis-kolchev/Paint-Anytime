import SwiftUI

@main
struct FillOptimizationChecks {
    static func mask(_ stroke: Stroke, width: Int, height: Int, scale: Float = 2) -> [Bool] {
        var result = [Bool](repeating: false, count: width * height)
        for r in stroke.fillRects ?? [] {
            for y in Int((r.y * scale).rounded())..<Int(((r.y + r.w) * scale).rounded()) {
                for x in Int((r.x * scale).rounded())..<Int(((r.x + r.z) * scale).rounded()) {
                    precondition(!result[y * width + x], "Merged rectangles must not overlap")
                    result[y * width + x] = true
                }
            }
        }
        return result
    }

    static func image(_ bytes: [UInt8], width: Int, height: Int) -> CGImage {
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func reference(_ bytes: [UInt8], width: Int, height: Int, seed: Int, tolerance: Int) -> [Bool] {
        var region = [Bool](repeating: false, count: width * height)
        var pending = [seed]
        while let i = pending.popLast() {
            guard !region[i], (0..<4).allSatisfy({ abs(Int(bytes[i * 4 + $0]) - Int(bytes[seed * 4 + $0])) <= tolerance }) else { continue }
            region[i] = true
            let x = i % width, y = i / width
            if x > 0 { pending.append(i - 1) }; if x + 1 < width { pending.append(i + 1) }
            if y > 0 { pending.append(i - width) }; if y + 1 < height { pending.append(i + width) }
        }
        var result = region
        if bytes[seed * 4 + 3] == 0 {
            for i in region.indices where region[i] {
                for y in max(0, i / width - 1)...min(height - 1, i / width + 1) {
                    for x in max(0, i % width - 1)...min(width - 1, i % width + 1) {
                        if bytes[(y * width + x) * 4 + 3] > 0 { result[y * width + x] = true }
                    }
                }
            }
        }
        return result
    }

    @MainActor static func main() async {
        let workspace = WatchBitmapRenderer.FillWorkspace()
        var style = PencilStyle.initial(for: .fill)
        // Deterministic mixed transparent, translucent and opaque pixels, with
        // narrow contours and disconnected regions. Reuse buffers across sizes.
        var random: UInt64 = 9123
        for iteration in 0..<80 {
            let width = 13 + iteration % 7, height = 11 + iteration % 5
            var bytes: [UInt8] = []
            for _ in 0..<(width * height) {
                random = random &* 6364136223846793005 &+ 1
                let alpha: UInt8 = [0, 64, 255][Int((random >> 32) % 3)]
                bytes += [alpha / 2, alpha / 4, 0, alpha]
            }
            let seed = iteration % (width * height)
            style.fillSensitivity = Float(iteration % 4) / 3
            let source = image(bytes, width: width, height: height)
            let stroke = WatchBitmapRenderer.floodFill(image: source, scale: 2,
                point: CGPoint(x: CGFloat(seed % width) / 2, y: CGFloat(seed / width) / 2), style: style, workspace: workspace)!
            let expected = reference(bytes, width: width, height: height, seed: seed,
                tolerance: Int((style.effectiveFillSensitivity * 255).rounded()))
            precondition(mask(stroke, width: width, height: height) == expected, "Coverage changed at case \(iteration)")
        }
        let empty = image([UInt8](repeating: 0, count: 100 * 80 * 4), width: 100, height: 80)
        style.smoothFill = true
        let compact = WatchBitmapRenderer.floodFill(image: empty, scale: 2, point: .zero, style: style, workspace: workspace)!
        precondition(compact.fillRects!.count == 2, "A rectangular region should compact to two rectangles")
        var rows = compact
        rows.fillRects = (0..<80).map { SIMD4<Float>(0, Float($0) / 2, 50, 0.5) }
        let a = WatchBitmapRenderer.layerThumbnail(strokes: [compact], size: CGSize(width: 50, height: 40), scale: 2)!
        let b = WatchBitmapRenderer.layerThumbnail(strokes: [rows], size: CGSize(width: 50, height: 40), scale: 2)!
        precondition(CFEqual(a.dataProvider!.data, b.dataProvider!.data), "Compaction must preserve smoothed contours")

        // A hole and unequal neighbouring runs exercise cancellation of the
        // internal edges of tall rectangles, not only a solid rectangle.
        var holeBytes = [UInt8](repeating: 0, count: 100 * 80 * 4)
        for y in 20..<60 {
            for x in 30..<70 { holeBytes[(y * 100 + x) * 4 + 3] = 255 }
        }
        style.fillSensitivity = 0
        let hole = WatchBitmapRenderer.floodFill(image: image(holeBytes, width: 100, height: 80),
            scale: 2, point: .zero, style: style, workspace: workspace)!
        var expanded = hole
        expanded.fillRects = hole.fillRects!.flatMap { r in
            (0..<Int((r.w * 2).rounded())).map { row in
                SIMD4<Float>(r.x, r.y + Float(row) / 2, r.z, 0.5)
            }
        }
        let compactHole = WatchBitmapRenderer.layerThumbnail(strokes: [hole], size: CGSize(width: 50, height: 40), scale: 2)!
        let expandedHole = WatchBitmapRenderer.layerThumbnail(strokes: [expanded], size: CGSize(width: 50, height: 40), scale: 2)!
        precondition(CFEqual(compactHole.dataProvider!.data, expandedHole.dataProvider!.data),
                     "Compaction must preserve holes and irregular smoothed contours")

        let worker = WatchFillWorker()
        var document = CanvasDocument(strokes: [])
        let size = CGSize(width: 50, height: 40)
        for step in 0..<4 {
            let layer = document.layers[0]
            let cached = await worker.fill(layer: layer, size: size, point: CGPoint(x: 10, y: 10), style: style)!
            let fresh = WatchBitmapRenderer.floodFill(layer: layer, size: size, point: CGPoint(x: 10, y: 10), style: style)!
            precondition(mask(cached, width: 100, height: 80) == mask(fresh, width: 100, height: 80), "Incremental cache changed coverage")
            if step == 2 { document.layers[0].strokes.removeAll() }
            else { document.layers[0].strokes.append(cached) }
            style.color = SIMD4(Float(step) / 3, 0.5, 0.2, 1)
        }
        let task = Task { await worker.fill(layer: document.layers[0], size: size, point: .zero, style: style) }
        task.cancel()
        let cancelled = await task.value
        precondition(cancelled == nil, "Cancelled requests must not produce fills")
        print("PASS: fill coverage, compact geometry, smoothing, incremental cache and cancellation")
    }
}
