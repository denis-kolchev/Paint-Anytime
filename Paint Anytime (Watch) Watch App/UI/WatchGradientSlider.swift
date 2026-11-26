import SwiftUI

/// Shared track for color channels and layer opacity.
struct WatchGradientSlider: View {
    @Binding var value: Double
    let maximum: Double
    let colors: [Color]
    let thumbColor: Color

    var body: some View {
        GeometryReader { geometry in
            let diameter: CGFloat = max(1, min(18, min(geometry.size.height, geometry.size.width)))
            let travel = max(1, geometry.size.width - diameter)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(height: diameter)
                    .overlay { Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 1) }
                Circle()
                    .fill(thumbColor)
                    .overlay { Circle().strokeBorder(.white, lineWidth: 2) }
                    .frame(width: diameter, height: diameter)
                    .offset(x: travel * min(1, max(0, value / maximum)))
                    .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                value = min(maximum, max(0, ((gesture.location.x - diameter / 2) / travel) * maximum))
            })
        }
    }
}
