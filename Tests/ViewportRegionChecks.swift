import SwiftUI

/// A viewport region (`origin`, stroke culling, 1×1 inks of layers without ink there,
/// region-offset live buffers) must reproduce the full-canvas raster inside it.
@main
struct ViewportRegionCheck {
    @MainActor static func main() {
        let canvas = CGSize(width: 120, height: 140)

        func stroke(_ instrument: DrawingInstrument, width: Float, _ points: [SIMD2<Float>],
                    color: SIMD4<Float>? = nil, opacity: Float? = nil) -> Stroke {
            var style = PencilStyle.initial(for: instrument)
            style.width = width
            if let color { style.color = color }
            if let opacity { style.opacity = opacity }
            return Stroke(points: points.enumerated().map {
                PointerSample(position: $1, pressure: 1, timestamp: Double($0) * 0.016)
            }, style: style)
        }
        /// A dense zigzag between two points, so every brush lays down many samples.
        func zigzag(from a: SIMD2<Float>, to b: SIMD2<Float>, amplitude: Float = 6, count: Int = 40) -> [SIMD2<Float>] {
            let direction = simd_normalize(b - a), normal = SIMD2(-direction.y, direction.x)
            return (0...count).map { i in
                let t = Float(i) / Float(count)
                return a + (b - a) * t + normal * (i.isMultiple(of: 2) ? amplitude : -amplitude)
            }
        }

        // Every instrument and stroke feature that maps canvas points to pixels by hand.
        func document(withBlur: Bool) -> CanvasDocument {
            var bottom: [Stroke] = [
                stroke(.monoline, width: 3, [SIMD2(-10, -10), SIMD2(130, 150)]),
                stroke(.pen, width: 7, zigzag(from: SIMD2(5, 20), to: SIMD2(115, 30)), color: SIMD4(0.8, 0.1, 0.1, 1)),
                stroke(.fountainPen, width: 9, zigzag(from: SIMD2(10, 45), to: SIMD2(110, 60))),
                stroke(.reed, width: 10, zigzag(from: SIMD2(110, 70), to: SIMD2(10, 75))),
                stroke(.marker, width: 12, zigzag(from: SIMD2(15, 90), to: SIMD2(105, 95)),
                       color: SIMD4(0.1, 0.5, 0.9, 1)),
                stroke(.watercolor, width: 16, zigzag(from: SIMD2(20, 110), to: SIMD2(100, 120)),
                       color: SIMD4(0.2, 0.7, 0.3, 1)),
                stroke(.pencil, width: 6, zigzag(from: SIMD2(5, 130), to: SIMD2(115, 5), amplitude: 3)),
                stroke(.crayon, width: 8, zigzag(from: SIMD2(115, 135), to: SIMD2(5, 100), amplitude: 4),
                       color: SIMD4(0.9, 0.6, 0.1, 1)),
            ]
            var fill = stroke(.fill, width: 4, [SIMD2(30, 40)], color: SIMD4(0.6, 0.2, 0.7, 1), opacity: 0.5)
            fill.fillRects = [SIMD4(22, 32, 41, 27), SIMD4(63, 50, 19, 33)]
            bottom.append(fill)
            // A turned object with its own erasers, one crossing the region edges.
            var object = stroke(.monoline, width: 14, zigzag(from: SIMD2(25, 60), to: SIMD2(95, 85)))
            var eraser = stroke(.eraser, width: 9, zigzag(from: SIMD2(20, 65), to: SIMD2(100, 80), amplitude: 9))
            eraser.style.eraserMode = .pixels
            object.erasures = [eraser]
            object.transform = StrokeTransform(CGAffineTransform(rotationAngle: 0.12).translatedBy(x: 3.5, y: -6.25))
            bottom.append(object)
            var pixelEraser = stroke(.eraser, width: 11, zigzag(from: SIMD2(60, 10), to: SIMD2(65, 130), amplitude: 8))
            pixelEraser.style.eraserMode = .pixels
            bottom.append(pixelEraser)

            var locked = CanvasLayer(name: "Locked", strokes: [
                stroke(.watercolor, width: 30, [SIMD2(30, 30), SIMD2(90, 110)], color: SIMD4(0.9, 0.9, 0.2, 1))
            ])
            locked.opacity = 0.6
            var over = stroke(.pen, width: 20, zigzag(from: SIMD2(10, 50), to: SIMD2(110, 100)), color: SIMD4(0.1, 0.1, 0.8, 1))
            over.locksTransparency = true
            locked.strokes.append(over)
            locked.locksTransparency = true
            // Ink only in one corner: most regions see it as an empty 1×1 layer.
            let sparse = CanvasLayer(name: "Sparse", strokes: [
                stroke(.marker, width: 8, [SIMD2(100, 120), SIMD2(115, 135)], color: SIMD4(0.3, 0.3, 0.3, 1))
            ])
            var document = CanvasDocument(strokes: bottom)
            document.layers.append(locked)
            document.layers.append(sparse)
            if withBlur {
                document.layers.append(CanvasLayer(name: "Blur", strokes: [
                    stroke(.blur, width: 18, zigzag(from: SIMD2(40, 50), to: SIMD2(80, 90), amplitude: 5))
                ]))
            }
            document.canvasSize = canvas
            return document
        }

        func rgba(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            bytes.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                        bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.setBlendMode(.copy)
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return bytes
        }

        struct Region {
            let origin: CGPoint
            let size: CGSize
            /// Pixel rectangle of the region in the full raster (rows from the top).
            let pixels: CGRect
        }
        /// As `WatchCanvasView.desiredRegion` snaps it: whole pixels of the full raster.
        func region(_ rect: CGRect, scale: CGFloat) -> Region {
            let rect = rect.intersection(CGRect(origin: .zero, size: canvas))
            let minX = floor(rect.minX * scale), minY = floor(rect.minY * scale)
            let maxX = ceil(rect.maxX * scale), maxY = ceil(rect.maxY * scale)
            return Region(origin: CGPoint(x: minX / scale, y: minY / scale),
                          size: CGSize(width: (maxX - minX - 0.001) / scale, height: (maxY - minY - 0.001) / scale),
                          pixels: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
        }

        /// At most 1 of 255 per channel, except within `margin` pixels of a region edge
        /// that lies inside the canvas (blur samples beyond it on the full canvas).
        func assertMatches(_ regionImage: CGImage?, _ full: CGImage?, _ region: Region,
                           margin: Int = 0, _ message: String) {
            guard let regionImage, let full,
                  let crop = full.cropping(to: region.pixels) else { fatalError("Missing image: \(message)") }
            precondition(regionImage.width == crop.width && regionImage.height == crop.height,
                         "Size \(regionImage.width)×\(regionImage.height) ≠ \(crop.width)×\(crop.height): \(message)")
            let lhs = rgba(regionImage), rhs = rgba(crop)
            let width = crop.width, height = crop.height
            let left = region.pixels.minX > 0 ? margin : 0
            let top = region.pixels.minY > 0 ? margin : 0
            let right = Int(region.pixels.maxX) < full.width ? margin : 0
            let bottom = Int(region.pixels.maxY) < full.height ? margin : 0
            var worst = 0, differing = 0
            for y in top..<max(top, height - bottom) {
                for x in left..<max(left, width - right) {
                    let i = (y * width + x) * 4
                    let difference = (0..<4).map { abs(Int(lhs[i + $0]) - Int(rhs[i + $0])) }.max()!
                    worst = max(worst, difference)
                    if difference > 0 { differing += 1 }
                }
            }
            precondition(worst <= 1, "\(message): differs by up to \(worst) at \(differing) pixels")
        }

        let rects = [
            CGRect(x: 0, y: 0, width: 50, height: 60),          // origin zero, as at the top-left corner
            CGRect(x: 23.3, y: 31.7, width: 47, height: 52),    // fractional, inside the canvas
            CGRect(x: 72.6, y: 88.1, width: 60, height: 60),    // clamped at the right and bottom
            CGRect(x: 97, y: 4, width: 20, height: 22),         // ink of few strokes only
        ]
        let scales: [CGFloat] = [1, 2, 3.25, 5.5]

        // Committed frames: regions with culling and without it, against the full canvas.
        for withBlur in [false, true] {
            let document = document(withBlur: withBlur)
            for scale in scales {
                let full = WatchBitmapRenderer.render(document: document, size: canvas, scale: scale)
                // Three box passes reach about 1.75 blur radii, the feather 0.15 widths.
                let margin = withBlur ? Int(ceil((4 * 1.75 + 18 * 0.2 + 2) * scale)) + 2 : 0
                for rect in rects {
                    let region = region(rect, scale: scale)
                    let label = "scale \(scale), region \(rect), blur \(withBlur)"
                    let culled = WatchBitmapRenderer.render(document: document, size: region.size, scale: scale,
                        origin: region.origin, isRegion: true, cache: WatchBitmapRenderer.LayerCache())
                    assertMatches(culled, full, region, margin: margin, "Region must match the full canvas, \(label)")
                    // The same region without culling: the whole image, edges included.
                    let unculled = WatchBitmapRenderer.render(document: document, size: region.size, scale: scale,
                        origin: region.origin)
                    let whole = Region(origin: region.origin, size: region.size,
                                       pixels: CGRect(origin: .zero, size: region.pixels.size))
                    assertMatches(culled, unculled, whole, "Culling must not change the region, \(label)")
                }
            }
            print("Committed regions match (blur \(withBlur))")
        }

        // Live strokes: region-offset incremental buffers against the full canvas's ones,
        // during the gesture and after the commit (promoted live ink).
        let document = document(withBlur: false)
        for instrument: DrawingInstrument in [.monoline, .pen, .marker, .watercolor, .pencil, .crayon] {
            for layerIndex in [0, 2] { // An inked layer, and one empty inside most regions.
                for scale: CGFloat in [2, 5.5] {
                    for rect in rects {
                        let region = region(rect, scale: scale)
                        let label = "\(instrument), layer \(layerIndex), scale \(scale), region \(rect)"
                        var current = document
                        let selected = current.layers[layerIndex].id
                        let fullCache = WatchBitmapRenderer.LayerCache()
                        let regionCache = WatchBitmapRenderer.LayerCache()
                        let points = zigzag(from: SIMD2(8, 15), to: SIMD2(112, 125), amplitude: 5, count: 30)
                        let gesture = stroke(instrument, width: 9, points, color: SIMD4(0.7, 0.2, 0.5, 1))
                        for count in [1, 2, 6, 15, 31] {
                            var live = gesture
                            live.points = Array(gesture.points.prefix(count))
                            let full = WatchBitmapRenderer.render(document: current, size: canvas, scale: scale,
                                activeStroke: live, selectedLayerID: selected, cache: fullCache)
                            let regional = WatchBitmapRenderer.render(document: current, size: region.size,
                                scale: scale, origin: region.origin, isRegion: true,
                                activeStroke: live, selectedLayerID: selected, cache: regionCache)
                            assertMatches(regional, full, region, "Live region must match, \(count) samples, \(label)")
                        }
                        current.layers[layerIndex].strokes.append(gesture)
                        let full = WatchBitmapRenderer.render(document: current, size: canvas, scale: scale,
                            selectedLayerID: selected, cache: fullCache)
                        let regional = WatchBitmapRenderer.render(document: current, size: region.size,
                            scale: scale, origin: region.origin, isRegion: true,
                            selectedLayerID: selected, cache: regionCache)
                        assertMatches(regional, full, region, "Committed live stroke must match, \(label)")
                    }
                }
            }
            print("Live \(instrument) regions match")
        }
        print("Viewport region checks passed")
    }
}
