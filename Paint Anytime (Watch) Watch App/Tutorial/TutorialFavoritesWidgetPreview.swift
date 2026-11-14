import SwiftUI
import UIKit

/// After the favorites lesson: a watch face with the time and the rectangular favorites
/// widget, filled with the pictures the user just liked, as the widget lays out three of them
/// side by side. Display only; after a moment a ✕ appears where the canvas keeps its •••
/// button, and it closes the preview back to the gallery.
struct TutorialFavoritesWidgetPreview: View {
    let drawings: [URL]
    /// The lesson card's height; the face is centred in the space above it.
    let hintReservedHeight: CGFloat
    /// The canvas's ••• button as measured in earlier lessons, in global coordinates.
    let closeButtonFrame: CGRect?
    let onClose: () -> Void
    @State private var images: [UIImage] = []
    @State private var showsClose = false
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width * 0.8
            VStack(spacing: 6) {
                TimelineView(.everyMinute) { context in
                    Text(context.date, format: .dateTime.hour().minute())
                        .font(.system(size: 48, weight: .regular, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .foregroundStyle(.white)
                }
                widget
                    .frame(width: width, height: width * 0.42)
            }
            .frame(width: geometry.size.width,
                   height: max(0, geometry.size.height - hintReservedHeight))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("Favorites can appear in a widget on your watch face."))

            if showsClose {
                let anchor = closeAnchor(in: geometry)
                closeButton
                    .position(x: anchor.x, y: anchor.y)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .background(Color.black)
        .ignoresSafeArea()
        .task(id: drawings) { await load() }
        .task {
            // A moment to look at the face before it can be dismissed.
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.25)) { showsClose = true }
        }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
        }
        .buttonStyle(TutorialOverlayButtonStyle(diameter: MorphPanelGeometry.buttonDiameter, hitDiameter: 44))
        .accessibilityLabel(L10n.text("Close"))
    }

    /// Same corner as the canvas's ••• button; the editor's fallback when it was not measured.
    private func closeAnchor(in proxy: GeometryProxy) -> CGPoint {
        let origin = proxy.frame(in: .global).origin
        if let frame = closeButtonFrame, !frame.isEmpty {
            let point = CGPoint(x: frame.midX - origin.x, y: frame.midY - origin.y)
            if CGRect(origin: .zero, size: proxy.size).insetBy(dx: 4, dy: 4).contains(point) { return point }
        }
        let geometry = MorphPanelGeometry(size: proxy.size, layoutDirection: layoutDirection)
        return CGPoint(x: geometry.leadingX, y: geometry.top + 18)
    }

    /// Like the widget: each picture fills its own column of one rounded card.
    @ViewBuilder private var widget: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(images.indices, id: \.self) { index in
                    Image(uiImage: images[index])
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width / CGFloat(max(1, images.count)),
                               height: geometry.size.height)
                        .clipped()
                }
            }
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
    }

    /// The widget shows up to three favorites.
    @MainActor private func load() async {
        let urls = Array(drawings.prefix(3))
        let loaded = await Task.detached(priority: .userInitiated) {
            urls.compactMap { UIImage(contentsOfFile: $0.path) }
        }.value
        images = loaded
    }
}
