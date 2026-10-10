import SwiftUI
import WidgetKit

private struct LauncherEntry: TimelineEntry {
    let date: Date
}

private struct LauncherProvider: TimelineProvider {
    func placeholder(in context: Context) -> LauncherEntry { LauncherEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (LauncherEntry) -> Void) {
        completion(LauncherEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LauncherEntry>) -> Void) {
        completion(Timeline(entries: [LauncherEntry(date: .now)], policy: .never))
    }
}

private struct LauncherView<Icon: View>: View {
    let icon: Icon
    let title: LocalizedStringKey
    let destination: String

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            icon
                .foregroundStyle(.white)
                .padding(7)
                .widgetAccentable()
        }
        .containerBackground(for: .widget) { Color.clear }
        .accessibilityLabel(Text(title))
        .widgetURL(URL(string: "paintanytime://\(destination)"))
    }
}

private struct OpenAppView: View {
    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            LauncherSailboat()
                .fill(.white)
                .padding(7)
                .widgetAccentable()
        }
        .containerBackground(for: .widget) { Color.clear }
        .accessibilityLabel(Text("Open Paint Anytime"))
        .widgetURL(URL(string: "paintanytime://app"))
    }
}

/// A transparent, single-color version of the app artwork, drawn directly
/// so every watch face rendering mode retains the sail, sun, and hull.
private struct LauncherSailboat: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        // Optical centering compensates for the sun and bow extending right.
        let origin = CGPoint(x: rect.midX - side / 2 - side * 0.04, y: rect.midY - side / 2)
        let transform = CGAffineTransform(scaleX: side / 100, y: side / 100)
            .concatenating(CGAffineTransform(translationX: origin.x, y: origin.y))
        var path = Path()

        // The leaning triangular sail follows the app icon's silhouette.
        path.move(to: CGPoint(x: 12, y: 65))
        path.addLine(to: CGPoint(x: 45, y: 10))
        path.addQuadCurve(to: CGPoint(x: 49, y: 11), control: CGPoint(x: 48, y: 6))
        path.addLine(to: CGPoint(x: 59, y: 62))
        path.addQuadCurve(to: CGPoint(x: 57, y: 65), control: CGPoint(x: 60, y: 65))
        path.addLine(to: CGPoint(x: 15, y: 69))
        path.addQuadCurve(to: CGPoint(x: 12, y: 65), control: CGPoint(x: 10, y: 70))
        path.closeSubpath()

        // Leave a clear gap from the sail so the sun survives monochrome tinting.
        path.move(to: CGPoint(x: 56, y: 23))
        path.addCurve(to: CGPoint(x: 90, y: 52),
                      control1: CGPoint(x: 73, y: 21), control2: CGPoint(x: 89, y: 34))
        path.addLine(to: CGPoint(x: 62, y: 52))
        path.closeSubpath()

        // Curved bow and shallow hull, separated from the sail by open space.
        path.move(to: CGPoint(x: 27, y: 74))
        path.addQuadCurve(to: CGPoint(x: 91, y: 70), control: CGPoint(x: 63, y: 74))
        path.addQuadCurve(to: CGPoint(x: 93, y: 73), control: CGPoint(x: 95, y: 69))
        path.addQuadCurve(to: CGPoint(x: 77, y: 89), control: CGPoint(x: 85, y: 88))
        path.addQuadCurve(to: CGPoint(x: 38, y: 90), control: CGPoint(x: 61, y: 92))
        path.addQuadCurve(to: CGPoint(x: 29, y: 83), control: CGPoint(x: 32, y: 89))
        path.addLine(to: CGPoint(x: 25, y: 78))
        path.addQuadCurve(to: CGPoint(x: 27, y: 74), control: CGPoint(x: 23, y: 74))
        path.closeSubpath()

        return path.applying(transform)
    }
}

private struct NewCanvasIcon: View {
    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let plus = Path { path in
                path.move(to: CGPoint(x: side * 0.65, y: side * 0.36))
                path.addLine(to: CGPoint(x: side * 0.93, y: side * 0.36))
                path.move(to: CGPoint(x: side * 0.79, y: side * 0.22))
                path.addLine(to: CGPoint(x: side * 0.79, y: side * 0.50))
            }
            ZStack {
                LauncherSailboat()
                    .fill(.white)
                    .mask {
                        // Cut a transparent outline around the overlapping badge.
                        ZStack {
                            Rectangle().fill(.white)
                            plus.stroke(.black, style: StrokeStyle(
                                lineWidth: side * 0.14, lineCap: .round))
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                    }
                plus.stroke(.white, style: StrokeStyle(
                    lineWidth: side * 0.065, lineCap: .round))
            }
            .frame(width: side, height: side)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }
}

private struct GalleryIcon: View {
    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                // Only the exposed edges of the rear photo are drawn.
                Path { path in
                    path.move(to: CGPoint(x: side * 0.13, y: side * 0.70))
                    path.addLine(to: CGPoint(x: side * 0.08, y: side * 0.70))
                    path.addQuadCurve(to: CGPoint(x: side * 0.03, y: side * 0.65),
                                      control: CGPoint(x: side * 0.03, y: side * 0.70))
                    path.addLine(to: CGPoint(x: side * 0.03, y: side * 0.20))
                    path.addQuadCurve(to: CGPoint(x: side * 0.08, y: side * 0.15),
                                      control: CGPoint(x: side * 0.03, y: side * 0.15))
                    path.addLine(to: CGPoint(x: side * 0.72, y: side * 0.15))
                    path.addQuadCurve(to: CGPoint(x: side * 0.77, y: side * 0.20),
                                      control: CGPoint(x: side * 0.77, y: side * 0.15))
                }
                .stroke(.white, style: StrokeStyle(lineWidth: side * 0.055, lineCap: .round))

                RoundedRectangle(cornerRadius: side * 0.06)
                    .strokeBorder(.white, lineWidth: side * 0.055)
                    .frame(width: side * 0.79, height: side * 0.63)
                    .position(x: side * 0.595, y: side * 0.575)

                LauncherSailboat()
                    .fill(.white)
                    .frame(width: side * 0.47, height: side * 0.47)
                    .position(x: side * 0.59, y: side * 0.53)

            }
            .frame(width: side, height: side)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }
}

struct OpenAppComplication: Widget {
    let kind = "PaintAnytime.OpenApp"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LauncherProvider()) { _ in
            OpenAppView()
        }
        .configurationDisplayName("Open App")
        .description("Open Paint Anytime without changing your canvas.")
        .supportedFamilies([.accessoryCircular])
    }
}

struct NewCanvasComplication: Widget {
    let kind = "PaintAnytime.NewCanvas"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LauncherProvider()) { _ in
            LauncherView(icon: NewCanvasIcon(), title: "New canvas", destination: "new-canvas")
        }
        .configurationDisplayName("New canvas")
        .description("Open a fresh canvas in Paint Anytime.")
        .supportedFamilies([.accessoryCircular])
    }
}

struct GalleryComplication: Widget {
    let kind = "PaintAnytime.Gallery"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LauncherProvider()) { _ in
            LauncherView(icon: GalleryIcon(), title: "Gallery", destination: "gallery")
        }
        .configurationDisplayName("Gallery")
        .description("Open your saved drawings in Paint Anytime.")
        .supportedFamilies([.accessoryCircular])
    }
}

@main
struct PaintAnytimeComplications: WidgetBundle {
    var body: some Widget {
        OpenAppComplication()
        NewCanvasComplication()
        GalleryComplication()
    }
}
