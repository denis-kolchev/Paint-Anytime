import SwiftUI

@main
struct RenderCheck {
    @MainActor static func main() async {
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
        // Flat nib: a tap is horizontal; first movement rotates the whole footprint.
        var flatMarker = PencilStyle.initial(for: .marker)
        flatMarker.width = 20
        flatMarker.color = SIMD4(0, 0, 0, 1)
        let tap = render([Stroke(points: [sample(40, 40)], style: flatMarker)])
        precondition(pixel(tap, 94, 80)[0] < 250 && pixel(tap, 80, 90)[0] == 255,
                     "Marker tap must be a thin horizontal rectangle")
        let horizontal = render([Stroke(points: [sample(40, 40), sample(70, 40)], style: flatMarker)])
        precondition(pixel(horizontal, 80, 94)[0] < 250 && pixel(horizontal, 66, 80)[0] == 255,
                     "First movement must rotate the initial nib without leaving the old footprint")
        for endpoint in [sample(75, 60), sample(75, 35), sample(75, 85)] {
            let bent = Stroke(points: [sample(30, 20), sample(30, 60), endpoint], style: flatMarker)
            let geometry = try! WatchStrokeCoverage.geometry(for: bent)
            precondition(geometry.primitives.count == 2 && geometry.endCap == nil)
            let direction = BrushGeometry.markerDirection(for: bent)!
            precondition(direction == SIMD2<Float>(0, 1), "Bends must preserve the initial nib angle")
            let cache = WatchBitmapRenderer.Cache()
            let key = WatchBitmapRenderer.CacheKey(documentID: ObjectIdentifier(cache),
                documentRevision: 1, size: CGSize(width: 100, height: 100), scale: 2)
            for count in 1...bent.points.count {
                let prefix = Stroke(points: Array(bent.points.prefix(count)), style: flatMarker)
                let live = cache.render(strokes: [], activeStroke: prefix, key: key, activeStrokeID: 1)!
                let exported = render([prefix])
                precondition(CFEqual(live.dataProvider!.data, exported.dataProvider!.data),
                             "Rotating the nib and bending must match export at every event")
            }
        }
        // A misleading first event must not lock a diagonal stroke to an axis.
        let settlingPoints = [sample(30, 30), sample(30.6, 30), sample(31, 31),
                              sample(32, 32), sample(34, 34), sample(40, 40),
                              sample(50, 50), sample(70, 30)]
        let settlingCache = WatchBitmapRenderer.Cache()
        let settlingKey = WatchBitmapRenderer.CacheKey(documentID: ObjectIdentifier(settlingCache),
            documentRevision: 1, size: CGSize(width: 100, height: 100), scale: 2)
        for count in 1...settlingPoints.count {
            let prefix = Stroke(points: Array(settlingPoints.prefix(count)), style: flatMarker)
            let live = settlingCache.render(strokes: [], activeStroke: prefix,
                key: settlingKey, activeStrokeID: 1)!
            let exported = render([prefix])
            precondition(CFEqual(live.dataProvider!.data, exported.dataProvider!.data),
                         "Refining the angle must replace old ink and match full replay")
        }
        let tinyMove = Stroke(points: Array(settlingPoints.prefix(2)), style: flatMarker)
        let earlyDirection = BrushGeometry.markerDirection(for: tinyMove)!
        precondition(earlyDirection.y > 0.9, "Initial footprint must rotate gradually")
        let diagonalPrefix = Stroke(points: Array(settlingPoints.prefix(7)), style: flatMarker)
        let settled = BrushGeometry.markerOrientation(for: diagonalPrefix)
        precondition(settled.settled && abs(settled.direction!.x - settled.direction!.y) < 0.03,
                     "Opening direction must follow the developing diagonal, not the first event")
        let finalDirection = BrushGeometry.markerDirection(
            for: Stroke(points: settlingPoints, style: flatMarker))!
        precondition(finalDirection == settled.direction!, "Later bends must preserve the settled nib")
        precondition(settlingCache.activeCoverageBuildCount == 1,
                     "Refining the nib must reuse the active coverage")
        let rightAngle = render([Stroke(points: [sample(30, 20), sample(30, 60), sample(75, 60)], style: flatMarker)])
        precondition(pixel(rightAngle, 120, 120)[0] < 250 && pixel(rightAngle, 120, 130)[0] == 255,
                     "A right-angle turn must travel on the thin edge of the nib")
        style.instrument = .monoline
        style.width = 8
        let crossing = render([Stroke(points: [sample(-20, 50), sample(120, 50)], style: style)])
        precondition(pixel(crossing, 0, 100)[0] == 0, "Off-canvas stroke must enter at the left edge")
        precondition(pixel(crossing, 199, 100)[0] == 0, "Off-canvas stroke must reach the right edge")
        let outside = render([Stroke(points: [sample(-20, 20), sample(-20, 80)], style: style)])
        precondition(pixel(outside, 0, 100)[0] == 255, "Outside ink must not be clamped onto the canvas")
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
                        let alpha = (tool == .watercolor ? 1.0 : 0.7) * Double(color.w)
                        let k = tool == .watercolor ? 0.85 : 0.8
                        for _ in 0..<count {
                            expected = (1-alpha)*expected + alpha*(k*expected*source + (1-k)*source)
                        }
                        precondition(abs(Double(actual[channel]) - expected*255) <= 4,
                                     "Hybrid formula mismatch: \(tool), \(color), \(count), \(actual), expected \(expected*255)")
                    }
                }
            }
        }
        // Reference document: all 121 combinations of yellow then blue layers.
        var yellow = PencilStyle.initial(for: .watercolor)
        yellow.width = 20
        yellow.color = SIMD4<Float>(1, 204.0/255, 26.0/255, 1)
        var blue = yellow
        blue.color = SIMD4<Float>(38.0/255, 179.0/255, 230.0/255, 1)
        for n in 0...10 {
            for m in 0...10 {
                let strokes = Array(repeating: Stroke(points: [point], style: yellow), count: n)
                    + Array(repeating: Stroke(points: [point], style: blue), count: m)
                let actual = pixel(render(strokes), 80, 80)
                for channel in 0..<3 {
                    var expected = 1.0
                    for _ in 0..<n { expected = Double(yellow.color[channel]) * (0.15 + 0.85 * expected) }
                    for _ in 0..<m { expected = Double(blue.color[channel]) * (0.15 + 0.85 * expected) }
                    precondition(abs(Double(actual[channel]) - expected * 255) <= 2,
                                 "Watercolor reference grid mismatch at \(n):\(m): \(actual)")
                }
            }
        }
        // Independent reference values for base=0.2, source=0.7 (straight RGB).
        let blendFixtures: [(ColorBlendingMode, Float)] = [
            (.normal, 0.7), (.multiply, 0.14), (.hybrid, 0.224),
            (.screen, 0.76), (.overlay, 0.28), (.softLight, 0.2992),
            (.hardLight, 0.52), (.darken, 0.2), (.lighten, 0.7),
            (.colorDodge, 2.0 / 3), (.colorBurn, 0), (.add, 0.9),
            (.difference, 0.5), (.exclusion, 0.62)
        ]
        precondition(blendFixtures.count == ColorBlendingMode.allCases.count)
        for (mode, expected) in blendFixtures {
            precondition(abs(mode.blend(base: 0.2, source: 0.7, instrument: .watercolor) - expected) < 0.00001,
                         "Reference formula mismatch: \(mode)")
            let clearResult = mode.composite(base: .zero, source: SIMD4(0.7, 0.4, 0.2, 0.5), instrument: .watercolor)
            precondition(clearResult == SIMD4(0.35, 0.2, 0.1, 0.5), "Clear backdrop must not tint source")
            let partial = mode.composite(base: SIMD4(0.05, 0.05, 0.05, 0.25),
                                         source: SIMD4(0.7, 0.7, 0.7, 0.5), instrument: .watercolor)
            precondition(abs(partial.x - (0.2875 + 0.125 * expected)) < 0.00001 && partial.w == 0.625,
                         "Premultiplied alpha mismatch: \(mode)")
            for d: Float in [0, 0.25, 0.5, 1] {
                for source: Float in [0, 0.5, 1] {
                    let value = mode.blend(base: d, source: source, instrument: .watercolor)
                    precondition(value.isFinite && (0...1).contains(value), "Invalid blend endpoint")
                }
            }
            var savedStyle = PencilStyle.initial(for: .watercolor)
            savedStyle.blendingMode = mode
            let restored = try! JSONDecoder().decode(PencilStyle.self, from: JSONEncoder().encode(savedStyle))
            precondition(restored == savedStyle, "Blend mode must survive saving")
        }
        // Pixel integration: coverage and opacity must agree with the blend model.
        for mode in ColorBlendingMode.allCases {
            for tool in [DrawingInstrument.marker, .watercolor] {
                var style = PencilStyle.initial(for: tool)
                style.width = 20
                style.color = SIMD4(0.3, 0.6, 0.8, 0.5)
                style.blendingMode = mode
                let dot = Stroke(points: [point], style: style)
                let actual = pixel(render([background, dot, dot]), 80, 80)
                for channel in 0..<3 {
                    var expected = Double(beforeWhite[channel]) / 255
                    let a: Double = tool == .watercolor ? 0.5 : 0.35
                    let source = Double(style.color[channel])
                    for _ in 0..<2 {
                        let mixed = mode.blend(base: Float(expected), source: Float(source), instrument: tool)
                        expected = (1-a)*expected + a*Double(mixed)
                    }
                    precondition(abs(Double(actual[channel]) - expected*255) <= 3, "Blend mode pixel mismatch: \(mode)")
                }
            }
        }
        // Help grids must match actual strokes on EMPTY canvas, not opaque paper.
        for mode in ColorBlendingMode.allCases where !mode.usesMultiplyFastPath {
            var yellowStyle = PencilStyle.initial(for: .watercolor)
            yellowStyle.width = 20
            yellowStyle.blendingMode = mode
            yellowStyle.color = SIMD4(1, 0.78, 0.04, 0.8)
            var blueStyle = yellowStyle
            blueStyle.color = SIMD4(0.04, 0.48, 0.9, 0.8)
            for yellowCount in [0, 1, 2, 5, 10] {
                for blueCount in [0, 1, 2, 5, 10] {
                    let strokes = Array(repeating: Stroke(points: [point], style: yellowStyle), count: yellowCount)
                        + Array(repeating: Stroke(points: [point], style: blueStyle), count: blueCount)
                    let actual = pixel(render(strokes), 80, 80)
                    let chart = mode.referenceSwatch(yellowPasses: yellowCount, bluePasses: blueCount)
                    for channel in 0..<3 {
                        precondition(abs(Float(actual[channel]) - chart[channel] * 255) <= 2,
                                     "Help/canvas mismatch: \(mode), \(yellowCount), \(blueCount)")
                    }
                }
            }
        }
        // Preserve the first three reference charts, including repeated overlaps.
        for mode in [ColorBlendingMode.hybrid, .multiply, .normal] {
            for yellowCount in 0...10 {
                for blueCount in 0...10 {
                    var expected = SIMD4<Float>(1, 1, 1, 1)
                    for _ in 0..<yellowCount {
                        expected = mode.composite(base: expected, source: SIMD4(1, 0.78, 0.04, 0.8), instrument: .watercolor)
                    }
                    for _ in 0..<blueCount {
                        expected = mode.composite(base: expected, source: SIMD4(0.04, 0.48, 0.9, 0.8), instrument: .watercolor)
                    }
                    precondition(mode.referenceSwatch(yellowPasses: yellowCount, bluePasses: blueCount)
                                 == SIMD3(expected.x, expected.y, expected.z))
                }
            }
        }
        print("PASS: help charts match empty-canvas rendering for all 11 additional modes; first three unchanged")
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
                       render(strokes), "Commit/undo/redo/object deletion/clear must preserve replay parity")
        }
        precondition(cache.rebuildCount == 4 && cache.appendCount == 2)
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
        for step in -10...0 {
            let p = b + direction * Float(step) * 0.5
            let value = pixel(diagonalImage, Int(p.x * 2), Int(p.y * 2))[0]
            precondition(abs(Int(value) - 77) <= 1, "Flat marker endpoint must not have an internal seam")
        }
        // Commit transparent strokes in rapid batches; only the unseen suffix is rasterized.
        let appendCache = WatchBitmapRenderer.Cache()
        var appended: [Stroke] = []
        _ = appendCache.render(strokes: appended, activeStroke: nil, key: key(300))
        for index in 0..<24 {
            var style = PencilStyle()
            style.instrument = index % 5 == 4 ? .eraser : (index % 2 == 0 ? .marker : .watercolor)
            style.width = 14
            style.color = SIMD4(0.2, 0.4, 0.8, 0.6)
            appended.append(Stroke(points: [sample(20, 20 + Float(index)), sample(70, 60),
                                            sample(20, 20 + Float(index))], style: style))
            // Simulate cancelled/skipped requests between several commits.
            if index % 3 == 2 {
                let snapshotKey = key(UInt64(301 + index))
                assertSame(appendCache.render(strokes: appended, activeStroke: nil, key: snapshotKey),
                           render(appended), "Batched append must preserve transparency and pixel erasing")
                precondition(appendCache.rebuildCount == 1)
                precondition(appendCache.committedRasterizedStrokeCount == appended.count,
                             "Old strokes must not be rasterized again on append")
            }
        }
        precondition(appendCache.appendCount == 8)
        var editedPrefix = appended
        editedPrefix[0].points.append(sample(90, 90))
        editedPrefix.append(marker)
        assertSame(appendCache.render(strokes: editedPrefix, activeStroke: nil, key: key(330)),
                   render(editedPrefix), "Edited prefix plus append requires a full rebuild")
        precondition(appendCache.rebuildCount == 2)
        let reordered = Array(editedPrefix.reversed())
        assertSame(appendCache.render(strokes: reordered, activeStroke: nil, key: key(331)),
                   render(reordered), "Reordering must rebuild in the new compositing order")
        precondition(appendCache.rebuildCount == 3)
        let cancelledAppend = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return appendCache.render(strokes: reordered + [marker], activeStroke: nil, key: key(332))
        }
        let cancelledFrame = await cancelledAppend.value
        precondition(cancelledFrame == nil)
        assertSame(appendCache.render(strokes: reordered + [marker], activeStroke: nil, key: key(333)),
                   render(reordered + [marker]), "Cancelled append must not corrupt the saved prefix")
        precondition(appendCache.rebuildCount == 3 && appendCache.appendCount == 9)
        let transitionCache = WatchBitmapRenderer.Cache()
        _ = transitionCache.render(strokes: [background], activeStroke: marker,
                                   key: key(340), activeStrokeID: 1)
        assertSame(transitionCache.render(strokes: [background, marker], activeStroke: appended[1],
                                          key: key(341), activeStrokeID: 2),
                   render([background, marker, appended[1]]),
                   "Committing while a new gesture starts must not duplicate active ink")
        assertSame(transitionCache.render(strokes: [background, marker], activeStroke: nil,
                                          key: key(341), activeStrokeID: 2),
                   render([background, marker]), "Cancelling the next gesture must retain committed ink")
        precondition(transitionCache.rebuildCount == 1 && transitionCache.appendCount == 1)
        print("PASS: incremental commits, skipped batches, transparent overlap, erasing, edited/reordered prefix, cancellation")

        // Geometry and bounds are resolution-independent for every brush, including
        // marker caps and watercolor bands (whose blending differs from normal paths).
        let geometryCache = WatchBitmapRenderer.Cache()
        let brushStrokes = DrawingInstrument.allCases.map { instrument in
            var style = PencilStyle()
            style.instrument = instrument
            style.width = 9
            return Stroke(points: [sample(20, 20), sample(60, 60), sample(20, 60),
                                   sample(60, 20), sample(20, 20)], style: style)
        }
        for scale: CGFloat in [1, 2, 4, 2] {
            let frameKey = key(200, scale: scale)
            assertSame(geometryCache.render(strokes: brushStrokes, activeStroke: nil, key: frameKey),
                       WatchBitmapRenderer.render(strokes: brushStrokes, size: frameKey.size, scale: scale),
                       "Cached brush geometry must preserve full replay at every scale")
            precondition(geometryCache.geometryBuildCount == brushStrokes.count,
                         "Zoom must reuse all brush geometry")
            for stroke in brushStrokes {
                let bounds = geometryCache.geometry[stroke.id]!.bounds
                precondition(!bounds.isNull && bounds.contains(CGPoint(x: 20, y: 20)))
                // The cached bounds must enclose every painted pixel, with an AA fringe.
                let single = WatchBitmapRenderer.render(strokes: [stroke], size: frameKey.size, scale: scale)!
                let pixels = single.dataProvider!.data! as Data
                let padded = bounds.insetBy(dx: -2 / scale, dy: -2 / scale)
                for y in 0..<single.height {
                    for x in 0..<single.width {
                        let offset = y * single.bytesPerRow + x * 4
                        if pixels[offset] < 250 || pixels[offset + 1] < 250 || pixels[offset + 2] < 250 {
                            precondition(padded.contains(CGPoint(x: CGFloat(x) / scale, y: CGFloat(y) / scale)),
                                         "Bounds must include all visible brush geometry")
                        }
                    }
                }
            }
        }
        var edited = brushStrokes[0]
        let originalID = edited.id
        edited.points.append(sample(90, 90))
        precondition(edited.id == originalID)
        let changed = [edited] + Array(brushStrokes.dropFirst())
        assertSame(geometryCache.render(strokes: changed, activeStroke: nil, key: key(201)),
                   WatchBitmapRenderer.render(strokes: changed, size: key(201).size, scale: 2),
                   "Editing points must invalidate just that stroke's geometry")
        precondition(geometryCache.geometryBuildCount == brushStrokes.count + 1)
        _ = geometryCache.render(strokes: [], activeStroke: nil, key: key(202))
        precondition(geometryCache.geometry.isEmpty, "Clear must release geometry and bounds")
        assertSame(geometryCache.render(strokes: brushStrokes, activeStroke: nil, key: key(203)),
                   WatchBitmapRenderer.render(strokes: brushStrokes, size: key(203).size, scale: 2),
                   "Undo after clear must restore identical artwork")
        let priorBuildCount = geometryCache.geometryBuildCount
        _ = geometryCache.render(strokes: brushStrokes, activeStroke: nil, key: otherKey)
        precondition(geometryCache.geometryBuildCount == priorBuildCount + brushStrokes.count,
                     "Switching documents must clear geometry ownership")
        let copies = [brushStrokes[0], edited]
        assertSame(geometryCache.render(strokes: copies, activeStroke: nil, key: key(204)),
                   WatchBitmapRenderer.render(strokes: copies, size: key(204).size, scale: 2),
                   "Separately edited copies sharing an ID must not substitute geometry")
        for instrument in [DrawingInstrument.marker, .watercolor] {
            var style = PencilStyle()
            style.instrument = instrument
            let dot = Stroke(points: [sample(40, 40), sample(40, 40)], style: style)
            let dotCache = WatchBitmapRenderer.Cache()
            assertSame(dotCache.render(strokes: [dot], activeStroke: nil, key: key(205, scale: 4)),
                       WatchBitmapRenderer.render(strokes: [dot], size: key(205).size, scale: 4),
                       "Cached coverage must preserve stationary dots")
        }
        precondition(WatchBitmapRenderer.rasterScale(displayScale: 2, zoom: 0.5) == 2)
        precondition(WatchBitmapRenderer.rasterScale(displayScale: 2, zoom: 1.5) == 3)
        precondition(WatchBitmapRenderer.rasterScale(displayScale: 2, zoom: 4) == 4)
        print("PASS: geometry reuse, cached bounds, edits, clear/undo, document isolation, raster scale cap")

        // Exercise the actor boundary, resolution changes, and cancellation recovery.
        let renderer = WatchArtworkRenderer()
        let actorStrokes = [diagonal]
        for scale: CGFloat in [2, 8, 2] {
            let frameKey = key(100, scale: scale)
            let frame = await renderer.render(strokes: actorStrokes, activeStroke: nil,
                                              key: frameKey, activeStrokeID: 0)
            assertSame(frame, WatchBitmapRenderer.render(strokes: actorStrokes,
                       size: frameKey.size, scale: scale), "Actor render must match full replay")
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await renderer.render(strokes: [], activeStroke: nil,
                                         key: key(101), activeStrokeID: 0)
        }
        let cancelledImage = await cancelled.value
        precondition(cancelledImage == nil, "Cancelled requests must not return a frame")
        let recovered = await renderer.render(strokes: actorStrokes, activeStroke: nil,
                                              key: key(100), activeStrokeID: 0)
        assertSame(recovered, render(actorStrokes), "Cancellation must preserve usable cache")
        print("PASS: background actor parity, resolution changes, cancellation and recovery")
        print("PASS: incremental coverage, self-crossings, moving caps, batched samples, clipping, gesture identity")
        print("PASS: cached/full replay parity, active cache reuse, cancel, history changes, zoom, resize, document identity")
        print("PASS: all brush dots and lines, orientation, opacity overlap, white pigment coverage, long marker opacity, eraser modes, empty canvas, invalid sizes, 2x resolution")
    }
}
