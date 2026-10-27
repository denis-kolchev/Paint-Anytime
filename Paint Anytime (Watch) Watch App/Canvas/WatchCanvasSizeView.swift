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
    }

    private func adjustment(mode: Int) -> some View {
        WatchCanvasAdjustmentView(controller: controller, viewportSize: viewportSize,
                                  displayScale: displayScale, mode: mode)
    }
}
