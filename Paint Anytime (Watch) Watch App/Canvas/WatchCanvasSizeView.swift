import SwiftUI

struct WatchCanvasSizeView: View {
    @ObservedObject var controller: CanvasController
    let viewportSize: CGSize
    let displayScale: CGFloat

    var body: some View {
        List {
            NavigationLink {
                adjustment(mode: 0)
            } label: {
                Label(L10n.text("Adjust size"), systemImage: "arrow.up.left.and.arrow.down.right")
            }
            NavigationLink {
                adjustment(mode: 1)
            } label: {
                Label(L10n.text("Crop"), systemImage: "crop")
            }
            NavigationLink {
                adjustment(mode: 2)
            } label: {
                Label(L10n.text("Rotate"), systemImage: "rotate.right")
            }
        }
        .navigationTitle(L10n.text("Canvas size"))
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            SettingsInformationButton(
                accessibilityKey: "About canvas size",
                titleKey: "Canvas size",
                items: [
                    SettingsInformationItem(titleKey: "Adjust size",
                        messageKey: "Change the canvas width and height, up to 1024 pixels. The drawing can scale with the canvas or keep its size."),
                    SettingsInformationItem(titleKey: "Crop",
                        messageKey: "Trim canvas edges. Hidden strokes remain editable."),
                    SettingsInformationItem(titleKey: "Rotate",
                        messageKey: "Turn the whole canvas by 90° or 180°.")
                ]
            )
        }
    }

    private func adjustment(mode: Int) -> some View {
        WatchCanvasAdjustmentView(controller: controller, viewportSize: viewportSize,
                                  displayScale: displayScale, mode: mode)
    }
}
