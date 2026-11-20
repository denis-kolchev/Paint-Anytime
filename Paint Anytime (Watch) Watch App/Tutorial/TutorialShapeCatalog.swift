import SwiftUI

/// Every shape the recognizer snaps to, drawn in the circle lesson's red ink with names,
/// six to a page in two rows of three. The pages turn sideways; an arrow like the tool
/// editor's suggests the swipe until the first page turn. Display-only: the outlines are
/// the snapped results, not recognizer input.
struct TutorialShapeCatalog: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    /// Clears the ••• button in the top-left corner above the title.
    let topInset: CGFloat
    /// The first page turn: ••• appears and the hint below asks for it.
    var onTurnPage: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var page: Int? = 0
    /// Each page draws its outlines the first time it is shown.
    @State private var drawnPages: Set<Int> = []
    @State private var hasTurnedPage = false

    // Same red swatch as the circle guide and the lesson's brush.
    private var ink: Color {
        InkPreset.all.first { $0.nameKey == "Red" }?.color ?? .red
    }

    private static let columns = 3
    private static let rows = 2
    private static let pages: [[TutorialCatalogShape]] = {
        let all = TutorialCatalogShape.allCases
        let size = columns * rows
        return stride(from: 0, to: all.count, by: size).map { Array(all[$0..<min($0 + size, all.count)]) }
    }()

    var body: some View {
        VStack(spacing: 6) {
            Text(L10n.text("Shapes you can draw"))
                .font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
            // Paged sideways: the Crown keeps no role on this step.
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(Self.pages.indices, id: \.self) { index in
                        pageView(Self.pages[index], page: index)
                            .padding(.horizontal, 10)
                            .containerRelativeFrame(.horizontal)
                            .id(index)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $page)
            .scrollIndicators(.hidden)
            .frame(maxHeight: .infinity)
            .overlay {
                // Forward is a swipe towards the leading edge, as in the tool editor.
                if !hasTurnedPage {
                    // Half a second later than in the tool editor: the list fades in and draws first.
                    TutorialToolSwipeGuide(direction: layoutDirection == .leftToRight ? -1 : 1,
                                           delay: .milliseconds(1500))
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: reduceMotion ? 0.15 : 0.25), value: hasTurnedPage)
            pageIndicator
        }
        .padding(.top, topInset)
        .padding(.bottom, 4)
        .onAppear { draw(page ?? 0) }
        .onChange(of: page) { _, page in
            guard let page else { return }
            if page != 0, !hasTurnedPage {
                hasTurnedPage = true
                onTurnPage()
            }
            draw(page)
        }
    }

    private func draw(_ page: Int) {
        guard !drawnPages.contains(page) else { return }
        if reduceMotion { drawnPages.insert(page) }
        else { withAnimation { _ = drawnPages.insert(page) } }
    }

    private func pageView(_ shapes: [TutorialCatalogShape], page: Int) -> some View {
        VStack(spacing: 6) {
            ForEach(0..<Self.rows, id: \.self) { row in
                HStack(alignment: .top, spacing: 4) {
                    ForEach(0..<Self.columns, id: \.self) { column in
                        let index = row * Self.columns + column
                        if index < shapes.count {
                            cell(shapes[index], index: index, isDrawn: drawnPages.contains(page))
                        } else {
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private var pageIndicator: some View {
        HStack(spacing: 4) {
            ForEach(Self.pages.indices, id: \.self) { index in
                Circle()
                    .fill(.white.opacity(index == (page ?? 0) ? 0.9 : 0.3))
                    .frame(width: 4, height: 4)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: page)
        .accessibilityHidden(true)
    }

    private func cell(_ shape: TutorialCatalogShape, index: Int, isDrawn: Bool) -> some View {
        VStack(spacing: 3) {
            TutorialCatalogOutline(shape: shape)
                .trim(from: 0, to: isDrawn ? 1 : 0)
                .stroke(ink, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                // Drawn one after another, as if by hand with the lesson's marker.
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.5).delay(0.25 + Double(index) * 0.09),
                           value: isDrawn)
                .frame(minHeight: 16, maxHeight: 28)
                .padding(.horizontal, 4)
            Text(L10n.text(shape.nameKey))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text(shape.nameKey))
    }
}

/// The catalog's order: lines and curves, round shapes, polygons, symbols, arrows.
enum TutorialCatalogShape: CaseIterable {
    case line, arc, circle, ellipse, square, rectangle
    case triangle, quadrilateral, pentagon, hexagon, polygon, star
    case heart, cloud, speechBubble, arrow, curvedArrow, blockArrow

    var nameKey: String {
        switch self {
        case .line: "Line"
        case .arc: "Arc"
        case .circle: "Circle"
        case .ellipse: "Ellipse"
        case .square: "Square"
        case .rectangle: "Rectangle"
        case .triangle: "Triangle"
        case .quadrilateral: "Quadrilateral"
        case .pentagon: "Pentagon"
        case .hexagon: "Hexagon"
        // The recognizer snaps seven to twelve corners to a regular polygon.
        case .polygon: "Polygon"
        case .star: "Star"
        case .heart: "Heart"
        case .cloud: "Cloud"
        case .speechBubble: "Speech bubble"
        case .arrow: "Arrow"
        case .curvedArrow: "Curved arrow"
        case .blockArrow: "Block arrow"
        }
    }

    /// Polylines in their own units; the outline fits them to the cell keeping proportions.
    var strokes: [(points: [CGPoint], closed: Bool)] {
        switch self {
        case .line: return [([CGPoint(x: 0, y: 1), CGPoint(x: 1.6, y: 0)], false)]
        case .arc:
            return [((0...40).map { i in
                let angle = Double.pi * (1.1 + 0.8 * Double(i) / 40)
                return CGPoint(x: cos(angle), y: sin(angle))
            }, false)]
        case .circle: return [(Self.ellipse(rx: 1, ry: 1), true)]
        case .ellipse: return [(Self.ellipse(rx: 1.5, ry: 0.85), true)]
        case .square: return [(Self.points([(0, 0), (1, 0), (1, 1), (0, 1)]), true)]
        case .rectangle: return [(Self.points([(0, 0), (1.7, 0), (1.7, 1), (0, 1)]), true)]
        case .triangle: return [(Self.regular(3), true)]
        case .quadrilateral: return [(Self.points([(0.3, 0), (1.6, 0.15), (1.3, 1), (0, 0.8)]), true)]
        case .pentagon: return [(Self.regular(5), true)]
        case .hexagon: return [(Self.regular(6), true)]
        case .polygon: return [(Self.regular(8), true)]
        case .star:
            return [((0..<10).map { i in
                let angle = Double(i) * .pi / 5 - .pi / 2
                let radius = i.isMultiple(of: 2) ? 1 : 0.45
                return CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
            }, true)]
        case .heart:
            return [((0..<96).map { i in
                let t = Double(i) * 2 * .pi / 96
                let x = 16 * pow(sin(t), 3)
                let y = -(13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t))
                return CGPoint(x: x, y: y)
            }, true)]
        case .cloud:
            // Round lobes meeting at inward cusps, as the recognizer's cloud snaps.
            return [((0..<120).map { i in
                let t = Double(i) * 2 * .pi / 120
                let radius = 0.8 + 0.2 * abs(sin(3 * t))
                return CGPoint(x: cos(t) * radius * 1.35, y: sin(t) * radius)
            }, true)]
        case .speechBubble:
            return [(Self.points([(-1, -0.7), (1, -0.7), (1, 0.5), (0.2, 0.5),
                                  (-0.5, 1), (-0.4, 0.5), (-1, 0.5)]), true)]
        case .arrow:
            return [(Self.points([(0, 0.5), (1.6, 0.5), (1.15, 0.15)]), false),
                    (Self.points([(1.6, 0.5), (1.15, 0.85)]), false)]
        case .curvedArrow:
            let arc = (0...32).map { i -> CGPoint in
                let angle = Double.pi * (1.05 + 0.85 * Double(i) / 32)
                return CGPoint(x: cos(angle), y: sin(angle) * 0.8)
            }
            // The head follows the curve's direction at its end.
            let tip = arc[arc.count - 1], before = arc[arc.count - 4]
            let length = hypot(tip.x - before.x, tip.y - before.y)
            let direction = CGPoint(x: (tip.x - before.x) / length, y: (tip.y - before.y) / length)
            let normal = CGPoint(x: -direction.y, y: direction.x)
            func wing(_ side: Double) -> CGPoint {
                CGPoint(x: tip.x - direction.x * 0.4 + normal.x * 0.28 * side,
                        y: tip.y - direction.y * 0.4 + normal.y * 0.28 * side)
            }
            return [(arc + [wing(1)], false), ([tip, wing(-1)], false)]
        case .blockArrow:
            return [(Self.points([(-1, -0.3), (0.2, -0.3), (0.2, -0.7), (1, 0),
                                  (0.2, 0.7), (0.2, 0.3), (-1, 0.3)]), true)]
        }
    }

    private static func points(_ values: [(Double, Double)]) -> [CGPoint] {
        values.map { CGPoint(x: $0.0, y: $0.1) }
    }

    private static func ellipse(rx: Double, ry: Double) -> [CGPoint] {
        (0..<64).map { i in
            let t = Double(i) * 2 * .pi / 64 - .pi / 2
            return CGPoint(x: cos(t) * rx, y: sin(t) * ry)
        }
    }

    private static func regular(_ sides: Int) -> [CGPoint] {
        (0..<sides).map { i in
            let angle = Double(i) * 2 * .pi / Double(sides) - .pi / 2
            return CGPoint(x: cos(angle), y: sin(angle))
        }
    }
}

private struct TutorialCatalogOutline: Shape {
    let shape: TutorialCatalogShape

    func path(in rect: CGRect) -> Path {
        let strokes = shape.strokes
        let all = strokes.flatMap(\.points)
        guard let first = all.first else { return Path() }
        var low = first, high = first
        for point in all {
            low = CGPoint(x: min(low.x, point.x), y: min(low.y, point.y))
            high = CGPoint(x: max(high.x, point.x), y: max(high.y, point.y))
        }
        // Leave room for the round line caps at the cell's edges.
        let area = rect.insetBy(dx: 2, dy: 2)
        let width = max(0.001, high.x - low.x), height = max(0.001, high.y - low.y)
        let scale = min(area.width / width, area.height / height)
        let origin = CGPoint(x: area.midX - (low.x + width / 2) * scale,
                             y: area.midY - (low.y + height / 2) * scale)
        var path = Path()
        for stroke in strokes {
            let placed = stroke.points.map { CGPoint(x: origin.x + $0.x * scale, y: origin.y + $0.y * scale) }
            path.addLines(placed)
            if stroke.closed { path.closeSubpath() }
        }
        return path
    }
}
