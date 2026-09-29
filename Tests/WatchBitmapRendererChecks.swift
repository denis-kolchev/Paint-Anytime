import SwiftUI

@main
struct RenderCheck {
    @MainActor static func main() {
        let point = PointerSample(position: SIMD2<Float>(40, 40), pressure: 1, timestamp: 0)
        func render(_ strokes: [Stroke]) -> CGImage {
            guard let image = WatchBitmapRenderer.render(strokes: strokes, size: CGSize(width: 100, height: 100), scale: 2) else { fatalError("No bitmap") }
            precondition(image.width == 200 && image.height == 200)
            return image
        }
        func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            bytes.withUnsafeMutableBytes { buffer in
                let c = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            let i = (y * image.width + x) * 4
            return Array(bytes[i..<i+4])
        }
        for instrument in DrawingInstrument.allCases where instrument != .eraser {
            var style = PencilStyle()
            style.instrument = instrument
            style.width = 12
            let stroke = Stroke(points: [point], style: style)
            let started = ProcessInfo.processInfo.systemUptime
            let image = render([stroke])
            // Pixel coordinates correspond to the canvas at 2x resolution.
            let center = pixel(image, 80, 80)
            precondition(center[0] < 250, "Missing ink: \(instrument), \(center)")
            print("\(instrument) first dot: \((ProcessInfo.processInfo.systemUptime-started)*1000) ms")
        }
        var style = PencilStyle()
        style.width = 20
        let ink = Stroke(points: [point], style: style)
        style.instrument = .eraser
        style.width = 30
        let erased = render([ink, Stroke(points: [point], style: style)])
        precondition(pixel(erased, 80, 80)[0] == 255, "Eraser must reveal white paper")
        let empty = render([])
        precondition(pixel(empty, 80, 80)[0] == 255, "Empty canvas must be white")
        func sample(_ x: Float, _ y: Float) -> PointerSample {
            PointerSample(position: SIMD2<Float>(x, y), pressure: 1, timestamp: 0)
        }
        style.instrument = .monoline
        style.width = 8
        let line = Stroke(points: [sample(20, 30), sample(80, 30)], style: style)
        let lineImage = render([line])
        precondition(pixel(lineImage, 100, 60)[0] == 0, "Line position or orientation")
        precondition(pixel(lineImage, 100, 140)[0] == 255, "Unexpected mirrored line")
        style.instrument = .marker
        let marker = Stroke(points: line.points, style: style)
        let once = render([marker])
        let twice = render([marker, marker])
        precondition(pixel(twice, 100, 60)[0] < pixel(once, 100, 60)[0], "Marker overlap must darken")
        style.instrument = .eraser
        style.eraserMode = .objects
        let objectErase = render([line, Stroke(points: line.points, style: style)])
        precondition(pixel(objectErase, 100, 60)[0] == 0, "Object eraser is handled by controller")
        precondition(WatchBitmapRenderer.render(strokes: [], size: .zero, scale: 2) == nil)
        precondition(WatchBitmapRenderer.render(strokes: [], size: CGSize(width: 100, height: 100), scale: 0) == nil)
        for tool in DrawingInstrument.allCases where tool != .eraser {
            style.instrument = tool
            let stroke = Stroke(points: [sample(20, 30), sample(50, 30), sample(80, 30)], style: style)
            let result = render([stroke])
            precondition(pixel(result, 100, 60)[0] < 250, "Missing line for \(tool)")
        }
        // White must paint pigment over existing ink, including translucent brushes.
        var backgroundStyle = PencilStyle()
        backgroundStyle.width = 40
        backgroundStyle.color = SIMD4(0.1, 0.2, 0.3, 1)
        let background = Stroke(points: [sample(20, 40), sample(80, 40)], style: backgroundStyle)
        let beforeWhite = pixel(render([background]), 80, 80)
        for tool in DrawingInstrument.allCases where tool != .eraser {
            var whiteStyle = PencilStyle.initial(for: tool)
            whiteStyle.width = 12
            whiteStyle.color = SIMD4(1, 1, 1, 1)
            for points in [[sample(40, 40)], [sample(20, 40), sample(80, 40)]] {
                let whiteStroke = Stroke(points: points, style: whiteStyle)
                let result = pixel(render([background, whiteStroke]), 80, 80)
                precondition((0..<3).allSatisfy { result[$0] > beforeWhite[$0] + 5 },
                             "White must lighten existing ink: \(tool), \(points.count) points, \(result)")
                precondition(result[3] == 255, "White paint must not erase alpha")
                if [.monoline, .pen, .fountainPen, .reed].contains(tool) {
                    precondition(result.prefix(3).allSatisfy { $0 == 255 }, "Opaque white must cover ink")
                }
                if [.marker, .watercolor].contains(tool) {
                    precondition(result[0] < 255, "White translucent brushes must retain their opacity")
                    let twice = pixel(render([background, whiteStroke, whiteStroke]), 80, 80)
                    precondition(twice[0] > result[0], "Repeated white strokes must build coverage")
                }
            }
        }
        // Verify the archive formula against rendered pixels, including repeated colors,
        // white pigment, and source alpha. Allow for 8-bit intermediate rounding.
        for tool in [DrawingInstrument.marker, .watercolor] {
            for color in [SIMD4<Float>(254.0/255, 208.0/255, 48.0/255, 1),
                          SIMD4<Float>(1.0/255, 199.0/255, 251.0/255, 1),
                          SIMD4<Float>(1, 1, 1, 1), SIMD4<Float>(0.2, 0.7, 0.35, 0.5)] {
                var brush = PencilStyle.initial(for: tool)
                brush.width = 20
                brush.color = color
                let stroke = Stroke(points: [point], style: brush)
                for count in [1, 2, 10] {
                    let actual = pixel(render([background] + Array(repeating: stroke, count: count)), 80, 80)
                    for channel in 0..<3 {
                        var expected = Double(beforeWhite[channel]) / 255
                        let source = Double(color[channel])
                        let alpha = 0.7 * Double(color.w)
                        for _ in 0..<count {
                            expected = (1-alpha)*expected + alpha*(0.8*expected*source + 0.2*source)
                        }
                        precondition(abs(Double(actual[channel]) - expected*255) <= 4,
                                     "Hybrid formula mismatch: \(tool), \(color), \(count), \(actual), expected \(expected*255)")
                    }
                }
            }
        }
        // Long marker paths are internally batched by Core Graphics. A single gesture
        // must keep the same opacity across those batches; separate gestures build ink.
        for color in [SIMD4<Float>(0.2, 0.7, 0.35, 1), SIMD4<Float>(1, 1, 1, 1),
                      SIMD4<Float>(0.2, 0.7, 0.35, 0.5)] {
            var markerStyle = PencilStyle.initial(for: .marker)
            markerStyle.width = 20
            markerStyle.color = color
            let short = Stroke(points: [sample(20, 40), sample(80, 40)], style: markerStyle)
            let reference = pixel(render([background, short]), 100, 80)
            for count in [100, 500, 1000, 2000] {
                let points = (0..<count).map { sample($0 % 2 == 0 ? 20 : 80, 40) }
                let long = Stroke(points: points, style: markerStyle)
                let actual = pixel(render([background, long]), 100, 80)
                precondition(zip(reference, actual).allSatisfy { abs(Int($0) - Int($1)) <= 1 },
                             "One marker gesture must not accumulate opacity: \(count), \(reference) -> \(actual)")
            }
            let separate = pixel(render([background, short, short]), 100, 80)
            precondition(separate != reference, "Separate marker gestures must still build coverage")
        }
        // A cached ink snapshot must render exactly like a full replay, including erasing.
        let cache = WatchBitmapRenderer.Cache()
        let cacheID = ObjectIdentifier(cache)
        func key(_ revision: UInt64, scale: CGFloat = 2, size: CGSize = CGSize(width: 100, height: 100)) -> WatchBitmapRenderer.CacheKey {
            .init(documentID: cacheID, documentRevision: revision, size: size, scale: scale)
        }
        func assertSame(_ cached: CGImage?, _ full: CGImage?, _ message: String) {
            guard let cached, let full else { fatalError("Missing image: \(message)") }
            precondition(cached.width == full.width && cached.height == full.height)
            let lhs = cached.dataProvider!.data! as Data
            let rhs = full.dataProvider!.data! as Data
            precondition(lhs.count == rhs.count)
            precondition(zip(lhs, rhs).allSatisfy { abs(Int($0) - Int($1)) <= 1 }, message)
        }
        var history = [background, marker]
        for tool in DrawingInstrument.allCases {
            var brush = PencilStyle.initial(for: tool)
            brush.width = 18
            brush.color = SIMD4(0.2, 0.65, 0.9, 0.8)
            brush.eraserMode = .pixels
            let active = Stroke(points: [sample(25, 40), sample(60, 40)], style: brush)
            assertSame(cache.render(strokes: history, activeStroke: active, key: key(1)),
                       render(history + [active]), "Cached active stroke differs: \(tool)")
            precondition(cache.rebuildCount == 1, "Active updates must reuse committed ink")
        }
        assertSame(cache.render(strokes: history, activeStroke: nil, key: key(1)),
                   render(history), "Cancelling a stroke must restore the cached drawing")
        precondition(cache.rebuildCount == 1)
        history.append(marker)
        for (revision, strokes) in [(UInt64(2), history), (3, Array(history.dropLast())),
                                    (4, history), (5, [background]), (6, [])] {
            assertSame(cache.render(strokes: strokes, activeStroke: nil, key: key(revision)),
                       render(strokes), "Commit/undo/redo/object deletion/clear must rebuild")
        }
        precondition(cache.rebuildCount == 6)
        for scale: CGFloat in [1, 3] {
            assertSame(cache.render(strokes: history, activeStroke: marker, key: key(7, scale: scale)),
                       WatchBitmapRenderer.render(strokes: history + [marker], size: CGSize(width: 100, height: 100), scale: scale),
                       "Zoom must rebuild at the new resolution")
        }
        let resized = CGSize(width: 120, height: 90)
        assertSame(cache.render(strokes: history, activeStroke: nil, key: key(7, size: resized)),
                   WatchBitmapRenderer.render(strokes: history, size: resized, scale: 2), "Resize must rebuild")
        let otherCache = WatchBitmapRenderer.Cache()
        let otherKey = WatchBitmapRenderer.CacheKey(documentID: ObjectIdentifier(otherCache),
                                                    documentRevision: 7, size: resized, scale: 2)
        assertSame(cache.render(strokes: [background], activeStroke: nil, key: otherKey),
                   WatchBitmapRenderer.render(strokes: [background], size: resized, scale: 2),
                   "Switching documents with equal revisions must invalidate")
        // Feed a single gesture in uneven batches, including a tap becoming a line,
        // sharp turns, crossings, retracing, and travel outside the canvas.
        for tool in [DrawingInstrument.marker, .watercolor] {
            for resolution: CGFloat in [1, 2, 3] {
                var brush = PencilStyle.initial(for: tool)
                brush.width = 13
                brush.color = SIMD4(0.25, 0.7, 0.9, 0.65)
                let gestureCache = WatchBitmapRenderer.Cache()
                let gestureKey = WatchBitmapRenderer.CacheKey(documentID: ObjectIdentifier(gestureCache),
                    documentRevision: 1, size: CGSize(width: 100, height: 100), scale: resolution)
                let points = [sample(20, 20), sample(50, 20), sample(50, 60), sample(20, 20),
                              sample(70, 70), sample(20, 20), sample(-15, 35), sample(120, 75),
                              sample(40, 40), sample(40, 40), sample(80, 20)]
                for length in [1, 2, 3, 5, 8, 10, 11] {
                    let gesture = Stroke(points: Array(points.prefix(length)), style: brush)
                    let actual = gestureCache.render(strokes: history, activeStroke: gesture,
                                                     key: gestureKey, activeStrokeID: 1)
                    let expected = WatchBitmapRenderer.render(strokes: history + [gesture],
                                                              size: gestureKey.size, scale: resolution)
                    assertSame(actual, expected, "Incremental/full parity: \(tool), \(length), \(resolution)x")
                    precondition(gestureCache.activeCoverageBuildCount == 1, "Appending must reuse coverage")
                }
                let gesture = Stroke(points: points, style: brush)
                let countBefore = gestureCache.activeRasterizedPrimitiveCount
                _ = gestureCache.render(strokes: history, activeStroke: gesture, key: gestureKey, activeStrokeID: 1)
                precondition(gestureCache.activeRasterizedPrimitiveCount == countBefore,
                             "An unchanged gesture must not rasterize again")
                // A new gesture can arrive without SwiftUI displaying the intervening nil.
                let replacement = Stroke(points: [points[0], points[1], sample(30, 65)], style: brush)
                assertSame(gestureCache.render(strokes: history, activeStroke: replacement,
                                               key: gestureKey, activeStrokeID: 2),
                           WatchBitmapRenderer.render(strokes: history + [replacement], size: gestureKey.size, scale: resolution),
                           "New gesture identity must reset coverage")
                precondition(gestureCache.activeCoverageBuildCount == 2)
                assertSame(gestureCache.render(strokes: history, activeStroke: nil, key: gestureKey),
                           WatchBitmapRenderer.render(strokes: history, size: gestureKey.size, scale: resolution),
                           "Cancel must discard active coverage")
            }
        }
        // A long gesture must process only new samples, not its existing prefix.
        for tool in [DrawingInstrument.marker, .watercolor] {
            var brush = PencilStyle.initial(for: tool)
            brush.width = 16
            func curve(_ index: Int) -> PointerSample {
                let t = Float(index) * 0.025
                return sample(50 + 30 * cos(t), 50 + 30 * sin(t))
            }
            var gesture = Stroke(points: (0..<1000).map(curve), style: brush)
            let longCache = WatchBitmapRenderer.Cache()
            let longKey = WatchBitmapRenderer.CacheKey(documentID: ObjectIdentifier(longCache),
                documentRevision: 1, size: CGSize(width: 100, height: 100), scale: 2)
            precondition(longCache.render(strokes: [], activeStroke: gesture, key: longKey, activeStrokeID: 1) != nil)
            let before = longCache.activeRasterizedPrimitiveCount
            for index in 1000..<1020 {
                gesture.points.append(curve(index))
                precondition(longCache.render(strokes: [], activeStroke: gesture, key: longKey, activeStrokeID: 1) != nil)
            }
            precondition(longCache.activeCoverageBuildCount == 1)
            precondition(longCache.activeRasterizedPrimitiveCount - before <= 120,
                         "A long gesture must not rasterize its old geometry again")
            assertSame(longCache.render(strokes: [], activeStroke: gesture, key: longKey, activeStrokeID: 1),
                       render([gesture]), "Long incremental gesture must match export")
        }
        // The endpoint overlaps the segment's antialiasing instead of leaving a seam.
        var diagonalStyle = PencilStyle.initial(for: .marker)
        diagonalStyle.width = 14
        diagonalStyle.color = SIMD4(0, 0, 0, 1)
        let a = SIMD2<Float>(20.25, 40.5)
        let b = SIMD2<Float>(72.3, 65.7)
        let diagonal = Stroke(points: [sample(a.x, a.y), sample(b.x, b.y)], style: diagonalStyle)
        let diagonalImage = render([diagonal])
        let direction = (b - a) / sqrt((b.x-a.x)*(b.x-a.x) + (b.y-a.y)*(b.y-a.y))
        for step in -10...10 {
            let p = b + direction * Float(step) * 0.5
            let value = pixel(diagonalImage, Int(p.x * 2), Int(p.y * 2))[0]
            precondition(abs(Int(value) - 77) <= 1, "Moving square cap must not have an internal seam")
        }
        print("PASS: incremental coverage, self-crossings, moving caps, batched samples, clipping, gesture identity")
        print("PASS: cached/full replay parity, active cache reuse, cancel, history changes, zoom, resize, document identity")
        print("PASS: all brush dots and lines, orientation, opacity overlap, white pigment coverage, long marker opacity, eraser modes, empty canvas, invalid sizes, 2x resolution")
    }
}
