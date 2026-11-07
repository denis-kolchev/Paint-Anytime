import SwiftUI

struct BroomIcon: View {
    var body: some View {
        Canvas { context, size in
            var drawing = context
            drawing.scaleBy(x: size.width / 24, y: size.height / 24)
            var path = Path()
            // Diagonal handle and flared bristles.
            path.move(to: CGPoint(x: 21, y: 3))
            path.addLine(to: CGPoint(x: 12, y: 12))
            path.move(to: CGPoint(x: 10, y: 10))
            path.addLine(to: CGPoint(x: 14, y: 14))
            path.addLine(to: CGPoint(x: 10, y: 22))
            path.addLine(to: CGPoint(x: 2, y: 14))
            path.closeSubpath()
            path.move(to: CGPoint(x: 7, y: 11.5))
            path.addLine(to: CGPoint(x: 12.5, y: 17))
            path.move(to: CGPoint(x: 8, y: 15))
            path.addLine(to: CGPoint(x: 5, y: 17))
            path.move(to: CGPoint(x: 10, y: 17))
            path.addLine(to: CGPoint(x: 8, y: 20))
            drawing.stroke(path, with: .foreground,
                           style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

/// A watch outline with the two top canvas controls, as the editor places them.
struct CanvasLayoutIcon: View {
    var body: some View {
        Canvas { context, size in
            var drawing = context
            drawing.scaleBy(x: size.width / 24, y: size.height / 24)
            let body = CGRect(x: 2, y: 3, width: 18, height: 18)
            drawing.stroke(Path(roundedRect: body, cornerRadius: 5, style: .continuous),
                           with: .foreground, lineWidth: 1.7)
            // Digital Crown on the trailing edge.
            drawing.fill(Path(roundedRect: CGRect(x: 20.6, y: 8, width: 1.8, height: 4.5), cornerRadius: 0.9),
                         with: .foreground)
            // Larger dots, still clear of the case and its rounded corners.
            let diameter: CGFloat = 3.4
            let dots = [-1, 1].map { CGPoint(x: body.midX + CGFloat($0) * 4.4, y: body.midY - 4.4) }
            for dot in dots {
                drawing.fill(Path(ellipseIn: CGRect(x: dot.x - diameter / 2, y: dot.y - diameter / 2,
                                                    width: diameter, height: diameter)),
                             with: .foreground)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

/// The current palette's grid of swatches, each dot a different shade, so it
/// reads as several paints rather than one plain grid. Shades are opacities of
/// the foreground, so the icon still dims and tints like the symbols beside it.
struct CurrentPaletteIcon: View {
    /// Row by row; neighbours differ so no two adjacent swatches look alike.
    private static let shades: [Double] = [1.0, 0.5, 0.8,
                                           0.65, 0.92, 0.42,
                                           0.85, 0.55, 0.72]

    var body: some View {
        Canvas { context, size in
            var drawing = context
            drawing.scaleBy(x: size.width / 24, y: size.height / 24)
            let diameter: CGFloat = 6.2
            for (index, shade) in Self.shades.enumerated() {
                let center = CGPoint(x: 4 + CGFloat(index % 3) * 8, y: 4 + CGFloat(index / 3) * 8)
                var dot = drawing
                dot.opacity = shade
                dot.fill(Path(ellipseIn: CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2,
                                                width: diameter, height: diameter)),
                         with: .foreground)
            }
        }
        .frame(width: 19, height: 19)
        .accessibilityHidden(true)
    }
}

// Upright tool tips, rather than the diagonal editing/pencil action symbol.
struct ToolIcon: View {
    let instrument: DrawingInstrument

    var body: some View {
        Canvas { context, size in
            let started = TutorialDebug.timestamp()
            TutorialDebug.trace("toolIcon.draw.enter", "size=\(size)")
            defer { TutorialDebug.finish("toolIcon.draw", since: started) }
            var c = context
            c.scaleBy(x: size.width / 24, y: size.height / 28)
            // The foreground style, not .primary, so the icon dims and tints like SF Symbols beside it.
            let ink = GraphicsContext.Shading.foreground
            func outline(_ points: [CGPoint], closed: Bool = false) {
                var path = Path()
                guard let first = points.first else { return }
                path.move(to: first)
                for point in points.dropFirst() { path.addLine(to: point) }
                if closed { path.closeSubpath() }
                c.stroke(path, with: ink, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
            func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
                outline([CGPoint(x: x1, y: y1), CGPoint(x: x2, y: y2)])
            }
            switch instrument {
            case .monoline:
                c.stroke(Path(roundedRect: CGRect(x: 8, y: 10, width: 8, height: 16), cornerRadius: 2), with: ink, lineWidth: 1.6)
                outline([CGPoint(x: 9, y: 10), CGPoint(x: 10, y: 5), CGPoint(x: 14, y: 5), CGPoint(x: 15, y: 10)])
                line(12, 2, 12, 5)
                line(8, 15, 16, 15)
            case .pen:
                outline([CGPoint(x: 8, y: 26), CGPoint(x: 8, y: 13), CGPoint(x: 12, y: 2), CGPoint(x: 16, y: 13), CGPoint(x: 16, y: 26)])
                line(9, 13, 15, 13)
                line(12, 3, 12, 8)
            case .fountainPen:
                outline([CGPoint(x: 8, y: 26), CGPoint(x: 8, y: 18), CGPoint(x: 5, y: 12), CGPoint(x: 12, y: 2), CGPoint(x: 19, y: 12), CGPoint(x: 16, y: 18), CGPoint(x: 16, y: 26)])
                line(12, 3, 12, 11)
                c.stroke(Path(ellipseIn: CGRect(x: 10.5, y: 11, width: 3, height: 3)), with: ink, lineWidth: 1.3)
            case .marker, .reed:
                outline([CGPoint(x: 6, y: 26), CGPoint(x: 6, y: 13), CGPoint(x: 8, y: 11), CGPoint(x: 8, y: 5), CGPoint(x: 16, y: 2), CGPoint(x: 16, y: 11), CGPoint(x: 18, y: 13), CGPoint(x: 18, y: 26)])
                line(7, 15, 17, 15)
                if instrument == .reed { line(12, 5, 12, 12); line(9, 18, 9, 26); line(15, 18, 15, 26) }
            case .pencil, .crayon:
                let tip: CGFloat = instrument == .pencil ? 1 : 4
                outline([CGPoint(x: 6, y: 26), CGPoint(x: 6, y: 12), CGPoint(x: 12, y: tip), CGPoint(x: 18, y: 12), CGPoint(x: 18, y: 26)])
                outline([CGPoint(x: 6, y: 12), CGPoint(x: 9, y: 14), CGPoint(x: 12, y: 12), CGPoint(x: 15, y: 14), CGPoint(x: 18, y: 12)])
                line(10, 6, 14, 6)
                if instrument == .pencil { line(9, 15, 9, 26); line(15, 15, 15, 26) }
                else { line(6, 18, 18, 18); line(6, 23, 18, 23) }
            case .watercolor:
                var brush = Path()
                brush.move(to: CGPoint(x: 12, y: 1))
                brush.addCurve(to: CGPoint(x: 17, y: 15), control1: CGPoint(x: 9, y: 7), control2: CGPoint(x: 21, y: 8))
                brush.addQuadCurve(to: CGPoint(x: 7, y: 15), control: CGPoint(x: 12, y: 18))
                brush.addQuadCurve(to: CGPoint(x: 12, y: 1), control: CGPoint(x: 3, y: 8))
                c.stroke(brush, with: ink, lineWidth: 1.6)
                outline([CGPoint(x: 8, y: 17), CGPoint(x: 10, y: 26), CGPoint(x: 14, y: 26), CGPoint(x: 16, y: 17)])
                line(9, 20, 15, 20)
            case .blur:
                // A blending stump (tortillon): rolled paper, a graphite-worn tip and a soft halo.
                var stump = Path()
                stump.move(to: CGPoint(x: 8, y: 26))
                stump.addLine(to: CGPoint(x: 8, y: 14))
                stump.addLine(to: CGPoint(x: 11.3, y: 6.4))
                stump.addQuadCurve(to: CGPoint(x: 12.7, y: 6.4), control: CGPoint(x: 12, y: 5))
                stump.addLine(to: CGPoint(x: 16, y: 14))
                stump.addLine(to: CGPoint(x: 16, y: 26))
                c.stroke(stump, with: ink, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                var tip = Path()
                tip.move(to: CGPoint(x: 10.2, y: 9))
                tip.addLine(to: CGPoint(x: 11.3, y: 6.4))
                tip.addQuadCurve(to: CGPoint(x: 12.7, y: 6.4), control: CGPoint(x: 12, y: 5))
                tip.addLine(to: CGPoint(x: 13.8, y: 9))
                tip.closeSubpath()
                c.fill(tip, with: ink)
                // The paper seam spiralling down the cone and the body.
                line(14.2, 10.1, 8.5, 13)
                line(8, 21, 16, 17)
                for (radius, opacity) in [(CGFloat(3), 0.6), (5.5, 0.3)] {
                    var halo = c
                    halo.opacity = opacity
                    var arc = Path()
                    arc.addArc(center: CGPoint(x: 12, y: 6.5), radius: radius,
                               startAngle: .degrees(215), endAngle: .degrees(325), clockwise: false)
                    halo.stroke(arc, with: ink, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                }
            case .fill:
                outline([CGPoint(x: 3, y: 13), CGPoint(x: 12, y: 4), CGPoint(x: 21, y: 13), CGPoint(x: 12, y: 22)], closed: true)
                line(3, 13, 21, 13)
                line(8, 2, 14, 8)
                c.fill(Path(ellipseIn: CGRect(x: 19, y: 19, width: 4, height: 6)), with: ink)
            case .eraser:
                outline([CGPoint(x: 3, y: 18), CGPoint(x: 11, y: 4), CGPoint(x: 21, y: 10), CGPoint(x: 13, y: 24), CGPoint(x: 8, y: 24)], closed: true)
                line(6, 13, 16, 19)
            }
        }
        .frame(width: 22, height: 26)
        .accessibilityHidden(true)
    }
}
