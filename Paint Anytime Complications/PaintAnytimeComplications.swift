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

private struct LauncherView: View {
    let symbol: String
    let title: LocalizedStringKey
    let destination: String

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .medium))
                .widgetAccentable()
        }
        .containerBackground(for: .widget) { Color.clear }
        .accessibilityLabel(Text(title))
        .widgetURL(URL(string: "paintanytime://\(destination)"))
    }
}

private struct OpenAppView: View {
    @Environment(\.widgetRenderingMode) private var renderingMode

    private var appIcon: some View {
        Image("PaintAnytimeIcon")
            .resizable()
            .scaledToFit()
            .clipShape(Circle())
    }

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            if renderingMode == .fullColor {
                appIcon
            } else {
                // Use the original transparent artwork layers. An opaque app
                // icon becomes a solid disc when watchOS applies its tint.
                ZStack {
                    Image("PaintAnytimeSail")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                    Image("PaintAnytimeBoat")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                }
                // The source layers include the full app icon's outer margins.
                .scaleEffect(1.4)
                .foregroundStyle(.white)
                .widgetAccentable()
            }
        }
        .containerBackground(for: .widget) { Color.clear }
        .accessibilityLabel(Text("Open Paint Anytime"))
        .widgetURL(URL(string: "paintanytime://app"))
    }
}

struct OpenAppComplication: Widget {
    let kind = "PaintAnytime.OpenApp"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LauncherProvider()) { _ in
            OpenAppView()
        }
        .configurationDisplayName("Paint Anytime")
        .description("Open Paint Anytime without changing your canvas.")
        .supportedFamilies([.accessoryCircular])
    }
}

struct NewCanvasComplication: Widget {
    let kind = "PaintAnytime.NewCanvas"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LauncherProvider()) { _ in
            LauncherView(symbol: "doc.badge.plus", title: "New canvas", destination: "new-canvas")
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
            LauncherView(symbol: "photo.on.rectangle", title: "Gallery", destination: "gallery")
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
