import SwiftUI
import simd
import ImageIO

// Resolve connectivity once at tap time and persist compact horizontal spans.
// Replaying a saved fill never re-evaluates boundaries after later layer edits.
extension WatchBitmapRenderer {
    nonisolated static func floodFill(layer: CanvasLayer, size: CGSize, point: CGPoint,
                                     style: PencilStyle) -> Stroke? {
        let scale: CGFloat = 2
        guard layer.isVisible, point.x.isFinite, point.y.isFinite,
              point.x >= 0, point.y >= 0, point.x < size.width, point.y < size.height,
              style.effectiveOpacity > 0,
              let image = layerThumbnail(strokes: layer.strokes, size: size, scale: scale) else { return nil }
        // Layer opacity and paper color affect presentation, not ink connectivity.
        return floodFill(image: image, scale: scale, point: point, style: style)
    }

    nonisolated static func floodFill(document: CanvasDocument, size: CGSize, point: CGPoint,
                          style: PencilStyle) -> Stroke? {
        let scale: CGFloat = 2
        guard point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0,
              point.x < size.width, point.y < size.height, style.effectiveOpacity > 0,
              let image = render(document: document, size: size, scale: scale) else { return nil }
        return floodFill(image: image, scale: scale, point: point, style: style)
    }

    // Shared by the canvas and the sensitivity preview so their boundaries agree.
    nonisolated static func floodFill(image: CGImage, scale: CGFloat, point: CGPoint,
                          style: PencilStyle) -> Stroke? {
        return floodFill(image: image, scale: scale, point: point, style: style, workspace: FillWorkspace())
    }

    // Owned by one worker; reuse allocations without sharing mutable buffers.
    nonisolated final class FillWorkspace {
        var context: CGContext?
        var source: CGImage?
        var visited: [UInt64] = []
        var covered: [UInt64] = []
        var pending: [Int] = []
    }

    nonisolated static func floodFill(image: CGImage, scale: CGFloat, point: CGPoint,
                                      style: PencilStyle, workspace: FillWorkspace) -> Stroke? {
        let width = image.width, height = image.height
        guard scale.isFinite, scale > 0, point.x.isFinite, point.y.isFinite,
              point.x >= 0, point.y >= 0, point.x * scale < CGFloat(width),
              point.y * scale < CGFloat(height), !Task.isCancelled else { return nil }
        if workspace.context?.width != width || workspace.context?.height != height {
            workspace.source = nil
            workspace.context = CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        }
        guard let context = workspace.context, let data = context.data else { return nil }
        if workspace.source !== image {
            // Copy, rather than blend, so old pixels cannot survive transparent ink.
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            workspace.source = image
        }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        let seed = Int(point.y * scale) * width + Int(point.x * scale)
        let target = (0..<4).map { Int(pixels[seed * 4 + $0]) }
        let tolerance = Int((style.effectiveFillSensitivity * 255).rounded())
        let words = (width * height + 63) / 64
        if workspace.visited.count != words {
            workspace.visited = [UInt64](repeating: 0, count: words)
            workspace.covered = [UInt64](repeating: 0, count: words)
        } else {
            for i in 0..<words { workspace.visited[i] = 0; workspace.covered[i] = 0 }
        }
        func contains(_ bits: [UInt64], _ i: Int) -> Bool {
            bits[i >> 6] & (UInt64(1) << (i & 63)) != 0
        }
        func mark(_ bits: inout [UInt64], _ i: Int) {
            bits[i >> 6] |= UInt64(1) << (i & 63)
        }
        func matches(_ index: Int) -> Bool {
            !contains(workspace.visited, index) && (0..<4).allSatisfy {
                abs(Int(pixels[index * 4 + $0]) - target[$0]) <= tolerance
            }
        }
        struct Span { let y: Int; let left: Int; let right: Int }
        var spans: [Span] = []
        workspace.pending.removeAll(keepingCapacity: true)
        workspace.pending.append(seed)
        var minX = width, maxX = 0, minY = height, maxY = 0
        while let index = workspace.pending.popLast() {
            guard !Task.isCancelled else { return nil }
            guard matches(index) else { continue }
            let y = index / width
            var left = index % width, right = left
            while left > 0 && matches(y * width + left - 1) { left -= 1 }
            while right + 1 < width && matches(y * width + right + 1) { right += 1 }
            for x in left...right { mark(&workspace.visited, y * width + x) }
            spans.append(Span(y: y, left: left, right: right))
            minX = min(minX, left); maxX = max(maxX, right)
            minY = min(minY, y); maxY = max(maxY, y)
            for nextY in [y - 1, y + 1] where nextY >= 0 && nextY < height {
                var insideRun = false
                for x in left...right {
                    let next = nextY * width + x
                    let match = matches(next)
                    if match && !insideRun { workspace.pending.append(next) }
                    insideRun = match
                }
            }
        }
        guard !spans.isEmpty else { return nil }
        if target[3] == 0 {
            // Visit each span's neighbouring rows once, not eight neighbours of
            // every pixel. Only pixels outside the original region can be added;
            // added coverage never propagates through a thin contour.
            for span in spans {
                guard !Task.isCancelled else { return nil }
                for y in max(0, span.y - 1)...min(height - 1, span.y + 1) {
                    for x in max(0, span.left - 1)...min(width - 1, span.right + 1) {
                        let i = y * width + x
                        if !contains(workspace.visited, i), pixels[i * 4 + 3] > 0 {
                            mark(&workspace.covered, i)
                        }
                    }
                }
            }
            minX = max(0, minX - 1); maxX = min(width - 1, maxX + 1)
            minY = max(0, minY - 1); maxY = min(height - 1, maxY + 1)
        }
        struct Run: Hashable { let left: Int; let right: Int }
        var previous: [Run: Int] = [:]
        var rectangles: [SIMD4<Float>] = []
        let unit = 1 / Float(scale)
        // Only scan the affected bounds, and merge identical runs vertically.
        for y in minY...maxY {
            guard !Task.isCancelled else { return nil }
            var current: [Run: Int] = [:]
            var x = minX
            func filled(_ x: Int) -> Bool {
                let i = y * width + x
                return contains(workspace.visited, i) || contains(workspace.covered, i)
            }
            while x <= maxX {
                guard filled(x) else { x += 1; continue }
                let left = x
                while x <= maxX && filled(x) { x += 1 }
                let run = Run(left: left, right: x)
                // Preserve one source-height span as the smoothing grid marker
                // used by the contour smoothing renderer.
                if let index = previous[run], index != 0 {
                    rectangles[index].w += unit
                    current[run] = index
                } else {
                    current[run] = rectangles.count
                    rectangles.append(SIMD4(Float(left) * unit, Float(y) * unit,
                                            Float(x - left) * unit, unit))
                }
            }
            previous = current
        }
        var fillStyle = style
        fillStyle.instrument = .fill
        fillStyle.blendingMode = .normal
        var stroke = Stroke(points: [PointerSample(position: SIMD2(Float(point.x), Float(point.y)),
                                                   pressure: 1, timestamp: 0)], style: fillStyle)
        stroke.fillRects = rectangles
        return stroke
    }
}
