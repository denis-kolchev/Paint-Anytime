import SwiftUI

struct WatchCanvasSizeView: View {
    @ObservedObject var controller: CanvasController
    let viewportSize: CGSize
    let displayScale: CGFloat
    @ObservedObject var tutorial = TutorialSession.inactive
    /// The tutorial shows Adjust size as its own page; without it the row pushes the editor.
    var onOpenAdjustSize: (() -> Void)? = nil

    var body: some View {
        List {
            // The tutorial teaches Adjust size; Rotate stays visible but closed.
            if let onOpenAdjustSize {
                Button(action: onOpenAdjustSize) {
                    Label(L10n.text("Adjust size"), systemImage: "arrow.up.left.and.arrow.down.right")
                        .tutorialHint(tutorial, steps: [.openAdjustSize])
                }
            } else {
                NavigationLink {
                    adjustment(mode: 0)
                } label: {
                    Label(L10n.text("Adjust size"), systemImage: "arrow.up.left.and.arrow.down.right")
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
                            messageKey: "Change the canvas width and height, up to 1024 pixels. The drawing can scale with the canvas or keep its size; without scaling, Horizontal and Vertical place it, and hidden strokes remain editable."),
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
