import SwiftUI
import WatchKit

/// Hue around the wheel, saturation from the centre to the rim, brightness on
/// the Digital Crown or by dragging the arc beside the wheel. The wheel sits where Apple's app icon grid draws its
/// largest circle: centred on the screen and four fifths of its width across.
struct ColorWheelEditor: View {
    @FocusState private var crownFocused: Bool
    /// Hue in degrees, then saturation and brightness in percent, as in the HSB page.
    @Binding var values: [Double]
    let isActive: Bool
    /// The full-screen area the wheel is centred in.
    let size: CGSize

    private static let diameterRatio: CGFloat = 0.8
    /// Leaves room above and below for the thumb and the brightness arc's ends.
    private static let heightRatio: CGFloat = 0.9
    private static let thumbDiameter: CGFloat = 22
    /// Degrees of the brightness arc beside the Crown.
    private static let arcSpan: Double = 70
    private static let arcGap: CGFloat = 9
    /// Touch band of the arc: wide enough for a finger, reaching the wheel's rim
    /// without covering it, since the wheel is drawn and hit-tested above.
    private static let arcTouchWidth: CGFloat = 20
    private static let space = "colorWheel"

    private var color: Color {
        Color(hue: values[0] / 360, saturation: values[1] / 100, brightness: values[2] / 100)
    }

    private var brightness: Binding<Double> {
        Binding { values[2] } set: { value in
            guard isActive else { return }
            values[2] = min(100, max(0, value.rounded()))
        }
    }

    var body: some View {
        let device = WKInterfaceDevice.current()
        // Height only limits it in a short area, as in the tutorial above its lesson card.
        let radius = min(size.width * Self.diameterRatio, size.height * Self.heightRatio) / 2
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let crownOnLeft = device.crownOrientation == .left
        return ZStack {
            brightnessArc(radius: radius + Self.arcGap, crownOnLeft: crownOnLeft)
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)).onChanged { value in
                    setBrightness(at: value.location, center: center, crownOnLeft: crownOnLeft)
                })
                .position(center)
            wheel(radius: radius)
                .position(center)
            thumb
                .position(thumbPosition(center: center, radius: radius))
                .allowsHitTesting(false)
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: Self.space)
        .focusable(isActive)
        .focused($crownFocused)
        .modifier(SteppedCrownModifier(value: brightness, range: 0...100, context: isActive ? 1 : 0))
        .onAppear { crownFocused = isActive }
        .onChange(of: isActive) { _, active in crownFocused = active }
    }

    private func wheel(radius: CGFloat) -> some View {
        Circle()
            // Red at the top, hues running clockwise.
            .fill(AngularGradient(colors: (0...12).map { Color(hue: Double($0) / 12, saturation: 1, brightness: 1) },
                                  center: .center, startAngle: .degrees(-90), endAngle: .degrees(270)))
            .overlay {
                Circle().fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center,
                                             startRadius: 0, endRadius: radius))
            }
            .overlay { Circle().fill(.black.opacity(1 - values[2] / 100)) }
            .overlay { Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1) }
            .frame(width: radius * 2, height: radius * 2)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                select(value.location, radius: radius)
            })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("Hue"))
            .accessibilityValue("\(Int(values[0].rounded()))°, "
                                + L10n.text("Saturation") + " " + L10n.percent(values[1] / 100) + ", "
                                + L10n.text("Brightness") + " " + L10n.percent(values[2] / 100))
            .accessibilityAdjustableAction { direction in
                guard isActive else { return }
                let step: Double = direction == .increment ? 5 : -5
                values[0] = (values[0] + step + 360).truncatingRemainder(dividingBy: 360)
            }
    }

    /// The chosen color with the same white rim as the slider thumbs.
    private var thumb: some View {
        Circle()
            .fill(color)
            .overlay { Circle().strokeBorder(.white, lineWidth: 2) }
            .frame(width: Self.thumbDiameter, height: Self.thumbDiameter)
            .shadow(color: .black.opacity(0.35), radius: 2)
            .accessibilityHidden(true)
    }

    private func thumbPosition(center: CGPoint, radius: CGFloat) -> CGPoint {
        let angle = (values[0] - 90) * .pi / 180
        let distance = radius * values[1] / 100
        return CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
    }

    /// Fills from the bottom as brightness rises, on the side the Crown is on.
    private func brightnessArc(radius: CGFloat, crownOnLeft: Bool) -> some View {
        let span = Self.arcSpan / 360
        let level = span * values[2] / 100
        let style = StrokeStyle(lineWidth: 3, lineCap: .round)
        return ZStack {
            Circle().trim(from: 0, to: span).stroke(.white.opacity(0.25), style: style)
            // The right arc is drawn top to bottom, the left one bottom to top.
            Circle().trim(from: crownOnLeft ? 0 : span - level, to: crownOnLeft ? level : span)
                .stroke(.white, style: style)
        }
        .frame(width: radius * 2, height: radius * 2)
        .contentShape(ArcBand(span: span, width: Self.arcTouchWidth))
        .rotationEffect(.degrees(crownOnLeft ? 180 - Self.arcSpan / 2 : -Self.arcSpan / 2))
        .accessibilityHidden(true)
    }

    /// Top of the arc is full brightness, bottom is black; past either end clamps.
    private func setBrightness(at location: CGPoint, center: CGPoint, crownOnLeft: Bool) {
        guard isActive else { return }
        let angle = atan2(location.y - center.y, location.x - center.x) * 180 / .pi
        let half = Self.arcSpan / 2
        let fraction: Double
        if crownOnLeft {
            // Measured from the bottom end at 180° − half, rising to the top end.
            let around = angle < 0 ? angle + 360 : angle
            fraction = (around - (180 - half)) / Self.arcSpan
        } else {
            // Measured from the bottom end at +half, rising to the top end at −half.
            fraction = (half - angle) / Self.arcSpan
        }
        values[2] = (min(1, max(0, fraction)) * 100).rounded()
        crownFocused = true
    }

    private func select(_ location: CGPoint, radius: CGFloat) {
        guard isActive else { return }
        let dx = location.x - radius, dy = location.y - radius
        var hue = atan2(dy, dx) * 180 / .pi + 90
        if hue < 0 { hue += 360 }
        let saturation = min(1, hypot(dx, dy) / radius)
        values = [hue.rounded().truncatingRemainder(dividingBy: 360), (saturation * 100).rounded(), values[2]]
        crownFocused = true
    }
}

/// The brightness arc's outline thickened into a band, for hit testing.
private struct ArcBand: Shape {
    let span: Double
    let width: CGFloat

    func path(in rect: CGRect) -> Path {
        Circle().trim(from: 0, to: span).path(in: rect)
            .strokedPath(StrokeStyle(lineWidth: width, lineCap: .round))
    }
}
