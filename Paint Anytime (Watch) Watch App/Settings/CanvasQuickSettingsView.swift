import SwiftUI

struct CanvasQuickSettingsView: View {
    let action: CanvasQuickAction
    @ObservedObject var controller: CanvasController
    let viewportSize: CGSize
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            destination
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.text("Close"), systemImage: "xmark") { dismiss() }
                    }
                }
        }
    }

    @ViewBuilder private var destination: some View {
        switch action {
        case .language: AppLanguageSelectionView()
        case .canvasSize:
            WatchCanvasSizeView(controller: controller, viewportSize: viewportSize, displayScale: displayScale)
        case .toolSynchronization: ToolSynchronizationView(controller: controller)
        case .visiblePalettes: PaletteVisibilitySettingsView(controller: controller)
        case .blending: ColorBlendingSelectionView(controller: controller)
        case .perspectiveGuides:
            PerspectiveGuidesSettingsView(controller: controller, viewportSize: viewportSize)
        case .canvasEditor: CanvasEditorSettingsView(instrument: controller.pencilStyle.instrument)
        case .autosave: AutosaveSettingsView()
        case .share: CanvasShareView(controller: controller, viewportSize: viewportSize)
        default: EmptyView()
        }
    }
}

/// ShareLink cannot open the share sheet by itself, so the action shows the
/// drawing with a Share button that offers Messages and Mail.
private struct CanvasShareView: View {
    @ObservedObject var controller: CanvasController
    let viewportSize: CGSize
    @Environment(\.displayScale) private var displayScale
    @State private var shared: (url: URL, image: CGImage)?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 8) {
            if let shared {
                Image(decorative: shared.image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .overlay { Rectangle().strokeBorder(.white.opacity(0.25), lineWidth: 1) }
                    .frame(maxHeight: .infinity)
                    .accessibilityHidden(true)
                ShareLink(item: DrawingShareItem(url: shared.url),
                          preview: SharePreview("Paint Anytime", image: DrawingShareItem(url: shared.url))) {
                    Label(L10n.text("Share"), systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
            } else if let error {
                Text(error)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .frame(maxHeight: .infinity)
            } else {
                ProgressView().frame(maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 8)
        .navigationTitle(L10n.text("Share"))
        .task {
            guard shared == nil, error == nil else { return }
            do {
                shared = try CanvasExporter.sharePNG(document: controller.document, size: viewportSize,
                                                  scale: displayScale)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
