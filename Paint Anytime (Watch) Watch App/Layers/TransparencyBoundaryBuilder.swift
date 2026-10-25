import SwiftUI

enum TransparencyBoundaryBuilder {
    nonisolated static func inkBoundary(strokes: [Stroke], size: CGSize) -> Path? {
        let scale = min(1, 400 / max(size.width, size.height))
        guard !Task.isCancelled,
              let image = WatchBitmapRenderer.layerThumbnail(strokes: strokes, size: size, scale: scale)
        else { return nil }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            // Copy the CGImage without flipping: its first pixel row already
            // corresponds to the top of the image displayed by SwiftUI.
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered, !Task.isCancelled else { return nil }
        func occupied(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && x < width && y >= 0 && y < height && pixels[(y * width + x) * 4 + 3] > 8
        }
        // Directed pixel edges form closed loops, including holes left by the eraser.
        let stride = width + 1
        var edges: [Int: [Int]] = [:]
        func edge(_ x: Int, _ y: Int, _ endX: Int, _ endY: Int) {
            edges[y * stride + x, default: []].append(endY * stride + endX)
        }
        for y in 0..<height {
            guard !Task.isCancelled else { return nil }
            for x in 0..<width where occupied(x, y) {
                if !occupied(x, y - 1) { edge(x, y, x + 1, y) }
                if !occupied(x + 1, y) { edge(x + 1, y, x + 1, y + 1) }
                if !occupied(x, y + 1) { edge(x + 1, y + 1, x, y + 1) }
                if !occupied(x - 1, y) { edge(x, y + 1, x, y) }
            }
        }
        func point(_ vertex: Int) -> CGPoint {
            CGPoint(x: CGFloat(vertex % stride) / CGFloat(width),
                    y: CGFloat(vertex / stride) / CGFloat(height))
        }
        var path = Path()
        while let start = edges.keys.min() {
            var current = start
            path.move(to: point(start))
            while var outgoing = edges[current], let next = outgoing.popLast() {
                edges[current] = outgoing.isEmpty ? nil : outgoing
                path.addLine(to: point(next))
                current = next
                if current == start { path.closeSubpath(); break }
            }
        }
        return path
    }
}
