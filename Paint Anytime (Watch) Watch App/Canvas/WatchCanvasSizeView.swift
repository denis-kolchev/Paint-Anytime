import SwiftUI

struct WatchCanvasSizeView: View {
    @ObservedObject var controller: CanvasController
    let viewportSize: CGSize
    let displayScale: CGFloat
    @ObservedObject var tutorial = TutorialSession.inactive
    /// The tutorial shows Crop as its own page; without it the row pushes the editor.
    var onOpenCrop: (() -> Void)? = nil

    var body: some View {
        List {
            // The tutorial teaches Crop; the other adjustments stay visible but closed.
            NavigationLink {
                adjustment(mode: 0)
            } label: {
                Label(L10n.text("Adjust size"), systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .disabled(tutorial.isActive)
            if let onOpenCrop {
                Button(action: onOpenCrop) {
                    Label(L10n.text("Crop"), systemImage: "crop")
                        .tutorialHint(tutorial, steps: [.openCrop])
                }
            } else {
                NavigationLink {
                    adjustment(mode: 1)
                } label: {
                    Label(L10n.text("Crop"), systemImage: "crop")
                }
            }
            NavigationLink {
                adjustment(mode: 2)
            } label: {
                Label(L10n.text("Rotate"), systemImage: "rotate.right")
            }
            .disabled(tutorial.isActive)
        }
        .navigationTitle(L10n.text("Canvas size"))
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            // Its information page would push over the tutorial's lesson.
            if !tutorial.isActive {
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
    }

    private func adjustment(mode: Int) -> some View {
        WatchCanvasAdjustmentView(controller: controller, viewportSize: viewportSize,
                                  displayScale: displayScale, mode: mode, tutorial: tutorial)
    }
}
