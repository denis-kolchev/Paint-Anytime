import Foundation
import CoreGraphics

@main
struct GalleryArtworkLayoutChecks {
    static func main() {
        for viewport in [CGSize(width: 162, height: 197), CGSize(width: 205, height: 251)] {
            for image in [CGSize(width: 205, height: 251), CGSize(width: 400, height: 200),
                          CGSize(width: 200, height: 400), CGSize(width: 80, height: 80)] {
                let frame = GalleryArtworkLayout.frame(imageSize: image, viewport: viewport, fitsViewport: true)
                precondition(frame.minX >= -0.001 && frame.minY >= -0.001)
                precondition(frame.maxX <= viewport.width + 0.001 && frame.maxY <= viewport.height + 0.001)
                precondition(abs(frame.midX - viewport.width / 2) < 0.001)
                precondition(abs(frame.midY - viewport.height / 2) < 0.001)
                precondition(abs(frame.width / frame.height - image.width / image.height) < 0.001)
                precondition(abs(frame.width - viewport.width) < 0.001 || abs(frame.height - viewport.height) < 0.001)
                let original = GalleryArtworkLayout.frame(imageSize: image, viewport: viewport, fitsViewport: false)
                precondition(original.size == image)
            }
        }
        precondition(GalleryArtworkLayout.frame(imageSize: .zero, viewport: CGSize(width: 162, height: 197), fitsViewport: true) == .zero)
        print("Gallery artwork layout checks passed: fit, centering, aspect ratio, and original-size mode.")
    }
}
