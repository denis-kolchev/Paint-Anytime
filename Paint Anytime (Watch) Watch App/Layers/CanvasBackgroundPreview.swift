import SwiftUI

struct CanvasBackgroundPreview: View {
    let color: SIMD4<Float>

    var body: some View {
        ZStack {
            TransparencyCheckerboard()
            Color(.sRGB, red: Double(color.x), green: Double(color.y),
                  blue: Double(color.z), opacity: Double(color.w))
        }
        .clipped()
    }
}
