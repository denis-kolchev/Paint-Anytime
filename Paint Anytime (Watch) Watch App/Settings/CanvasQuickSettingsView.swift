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
        case .privacy: WatchLegalDocumentView(title: "Privacy Policy", paragraphs: WatchLegalText.privacy)
        default: EmptyView()
        }
    }
}
