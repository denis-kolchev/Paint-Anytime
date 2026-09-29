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
        print("PASS: all brush dots and lines, orientation, opacity overlap, white pigment coverage, long marker opacity, eraser modes, empty canvas, invalid sizes, 2x resolution")
    }
}
