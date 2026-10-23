import Foundation
import CoreGraphics

@main
struct TransparencyClippingChecks {
    static func main() throws {
        let size = CGSize(width: 100, height: 100)
        func stroke(_ points: [SIMD2<Float>], width: Float, locked: Bool = false) -> Stroke {
            var style = PencilStyle.initial(for: .monoline)
            style.width = width
            var ink = Stroke(points: points.map { PointerSample(position: $0, pressure: 1, timestamp: 0) }, style: style)
            ink.locksTransparency = locked
            return ink
        }
        func pixels(_ strokes: [Stroke]) -> [UInt8] {
            let image = WatchBitmapRenderer.layerThumbnail(strokes: strokes, size: size, scale: 2)!
            let context = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8,
                bytesPerRow: 800, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 200, height: 200))
            return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: 160_000))
        }
        let base = stroke([SIMD2(30, 30)], width: 20)
        let invisible = stroke([SIMD2(70, 70), SIMD2(90, 70)], width: 6, locked: true)
        let hidden = try WatchTransparencyClipping.prepare(strokes: [base, invisible], size: size, scale: 2)
        var independent = hidden[1]
        independent.locksTransparency = false
        precondition(pixels([independent]).enumerated().allSatisfy { $0.offset % 4 != 3 || $0.element == 0 },
                     "A fully hidden locked stroke must have no selectable ink")
        let paint = stroke([SIMD2(5, 30), SIMD2(90, 30)], width: 6, locked: true)
        let clipped = try WatchTransparencyClipping.prepare(strokes: [base, paint], size: size, scale: 2)
        precondition(clipped[0] == base && clipped[1].id == paint.id)
        var visible = clipped[1]
        visible.locksTransparency = false
        let mask = pixels([base]), ink = pixels([visible])
        var count = 0
        for index in stride(from: 3, to: ink.count, by: 4) where ink[index] > 0 {
            precondition(mask[index] > 0, "Invisible tails must be clipped before selection")
            count += 1
        }
        precondition(count > 0)
        // The exclusions are local: translating the stroke cannot reveal its tails.
        visible.transform = StrokeTransform(CGAffineTransform(translationX: 10, y: 15))
        var movedBase = base
        movedBase.transform = visible.transform
        let movedMask = pixels([movedBase]), movedInk = pixels([visible])
        for index in stride(from: 3, to: movedInk.count, by: 4) where movedInk[index] > 0 {
            precondition(movedMask[index] > 0, "Clipping must move with the selected stroke")
        }
        let original = pixels([base, paint]), prepared = pixels(clipped)
        precondition(zip(original, prepared).allSatisfy { abs(Int($0) - Int($1)) <= 1 },
                     "Preparing selection must preserve the original artwork")
        var eraserStyle = PencilStyle.initial(for: .eraser)
        eraserStyle.width = 6
        let eraser = Stroke(points: [PointerSample(position: SIMD2(30, 30), pressure: 1, timestamp: 0)], style: eraserStyle)
        let erased = try WatchTransparencyClipping.prepare(strokes: [base, eraser, paint], size: size, scale: 2)
        var overErased = erased[2]
        overErased.locksTransparency = false
        let erasedMask = pixels([base, eraser]), erasedInk = pixels([overErased])
        for index in stride(from: 3, to: erasedInk.count, by: 4) where erasedInk[index] > 0 {
            precondition(erasedMask[index] > 0, "Earlier erasures must also clip locked ink")
        }
        let empty = try WatchTransparencyClipping.prepare(strokes: [invisible], size: size, scale: 2)
        var onEmpty = empty[0]
        onEmpty.locksTransparency = false
        precondition(pixels([onEmpty]).enumerated().allSatisfy { $0.offset % 4 != 3 || $0.element == 0 })
        print("Transparency clipping checks passed: hidden ink, partial overlap, movement, appearance, and empty layers.")
    }
}
