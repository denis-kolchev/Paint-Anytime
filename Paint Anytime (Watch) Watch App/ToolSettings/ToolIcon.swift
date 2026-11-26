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

/// What the Current color, width and opacity actions show. A value is nil when the
/// tool has no such setting, as the eraser has no color and the fill no width.
struct BrushSummary: Equatable {
    var color: SIMD4<Float>?
    /// The width as a share of the tool's maximum, 0...1, for the size of its dot.
    var width: Double?
    /// The width in points, as the Width page shows it.
    var widthPoints: Int?
    var opacity: Double?

    init(color: SIMD4<Float>? = nil, width: Double? = nil, widthPoints: Int? = nil, opacity: Double? = nil) {
        self.color = color
        self.width = width
        self.widthPoints = widthPoints
        self.opacity = opacity
    }

    /// Follows the pages the tool settings offer for this style.
    init(style: PencilStyle) {
        let pages = WatchToolSettingsView.availableSettings(for: style)
        let maximum = style.instrument.maximumWidth
        let hasWidth = pages.contains(.width) && maximum > 0
        self.init(color: pages.contains(.color) ? style.color : nil,
                  width: hasWidth ? Double(min(1, max(0, style.width / maximum))) : nil,
                  widthPoints: hasWidth ? Int(style.width) : nil,
                  opacity: pages.contains(.opacity) ? Double(style.effectiveOpacity) : nil)
    }
}

private struct BrushSummaryKey: EnvironmentKey {
    static let defaultValue = BrushSummary()
}

extension EnvironmentValues {
    /// The brush the summary icons show. The canvas sets it once at its root, so
    /// presented menus and the editor read it too; the tutorial sets its own.
    var brushSummary: BrushSummary {
        get { self[BrushSummaryKey.self] }
        set { self[BrushSummaryKey.self] = newValue }
    }
}

/// Current color, width or opacity. Color is the brush in a white ring: a dot of its
/// color, sized by the width and as see-through as the opacity over a checkerboard.
/// A hairline outside the ring keeps white visible on a light surface, such as the
/// editor's canvas; a tool without a color leaves the ring empty. Width and opacity
/// print their value as the tool settings show it ("40 pt", "100%"), or a dash for
/// a tool without that setting.
struct BrushSummaryIcon: View {
    enum Kind { case color, width, opacity }

    let kind: Kind
    @Environment(\.brushSummary) private var summary

    /// Large enough for the values. The ring shrinks to fit a tighter space, such as
    /// a short morph row or a list's icon column.
    private static let maximumDiameter: CGFloat = 26

    var body: some View {
        switch kind {
        case .color: colorRing
        case .width: value(summary.widthPoints.map { L10n.format("%d pt", $0) })
        case .opacity: value(summary.opacity.map { L10n.percent($0) })
        }
    }

    private var colorRing: some View {
        GeometryReader { proxy in
            let diameter = min(proxy.size.width, proxy.size.height)
            let ring = max(1.5, diameter * 0.08)
            let inner = diameter - ring * 2
            ZStack {
                if let rgba = summary.color {
                    dot(rgba, inner: inner)
                }
                Circle().strokeBorder(.white, lineWidth: ring)
                Circle().strokeBorder(Color.black.opacity(0.2), lineWidth: 0.5)
            }
            .frame(width: diameter, height: diameter)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        // The ideal size answers a layout that proposes none, which a bare GeometryReader
        // would meet with its 10 pt default.
        .frame(idealWidth: Self.maximumDiameter, maxWidth: Self.maximumDiameter,
               idealHeight: Self.maximumDiameter, maxHeight: Self.maximumDiameter)
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    /// The thinnest width still leaves a dot 40% of the opening; the square root
    /// spreads the thin widths people use most. The widest, or a tool without
    /// a width such as the fill, fills the ring.
    private func dot(_ rgba: SIMD4<Float>, inner: CGFloat) -> some View {
        let size = summary.width.map { inner * (0.4 + 0.6 * CGFloat($0.squareRoot())) } ?? inner
        let color = Color(.sRGB, red: Double(rgba.x), green: Double(rgba.y), blue: Double(rgba.z), opacity: 1)
        return ZStack {
            // Only a see-through brush shows the checkerboard behind its color.
            if (summary.opacity ?? 1) < 1 {
                Color.white
                CheckerboardShape(cell: max(2, inner / 6)).fill(Color(white: 0.75))
            }
            color.opacity(summary.opacity ?? 1)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private func value(_ text: String?) -> some View {
        // The foreground style, so the value dims and tints like the symbols beside it.
        Text(text ?? "–")
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: Self.maximumDiameter + 2)
            .accessibilityHidden(true)
    }
}

/// Squares of every other cell, for showing transparency behind a color.
private struct CheckerboardShape: Shape {
    let cell: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let columns = Int((rect.width / cell).rounded(.up)), rows = Int((rect.height / cell).rounded(.up))
        for row in 0..<rows {
            for column in 0..<columns where (row + column).isMultiple(of: 2) {
                path.addRect(CGRect(x: rect.minX + CGFloat(column) * cell,
                                    y: rect.minY + CGFloat(row) * cell, width: cell, height: cell))
            }
        }
        return path
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
                // A flat-top blending brush: a wide, dense head flaring from a short ferrule.
                var head = Path()
                head.move(to: CGPoint(x: 8.5, y: 13))
                head.addCurve(to: CGPoint(x: 4, y: 3.5), control1: CGPoint(x: 6, y: 10.5), control2: CGPoint(x: 4, y: 7))
                head.addQuadCurve(to: CGPoint(x: 5.5, y: 2), control: CGPoint(x: 4, y: 2))
                head.addLine(to: CGPoint(x: 18.5, y: 2))
                head.addQuadCurve(to: CGPoint(x: 20, y: 3.5), control: CGPoint(x: 20, y: 2))
                head.addCurve(to: CGPoint(x: 15.5, y: 13), control1: CGPoint(x: 20, y: 7), control2: CGPoint(x: 18, y: 10.5))
                c.stroke(head, with: ink, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                // Darker bristle tips across the flat top, and the glossy ferrule band.
                let ferrule = Path(roundedRect: CGRect(x: 8.5, y: 13, width: 7, height: 5), cornerRadius: 1)
                var tint = c
                tint.opacity = 0.45
                tint.fill(Path(roundedRect: CGRect(x: 4.7, y: 2.6, width: 14.6, height: 2.4), cornerRadius: 0.8), with: ink)
                tint.fill(ferrule, with: ink)
                c.stroke(ferrule, with: ink, lineWidth: 1.6)
                line(10, 18, 10.5, 26)
                line(14, 18, 13.5, 26)
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
