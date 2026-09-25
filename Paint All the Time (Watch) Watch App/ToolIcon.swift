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
            drawing.stroke(path, with: .color(.primary),
                           style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 22, height: 22)
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
            let ink = GraphicsContext.Shading.color(.primary)
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
            case .eraser:
                outline([CGPoint(x: 3, y: 18), CGPoint(x: 11, y: 4), CGPoint(x: 21, y: 10), CGPoint(x: 13, y: 24), CGPoint(x: 8, y: 24)], closed: true)
                line(6, 13, 16, 19)
            }
        }
        .frame(width: 22, height: 26)
        .accessibilityHidden(true)
    }
}
