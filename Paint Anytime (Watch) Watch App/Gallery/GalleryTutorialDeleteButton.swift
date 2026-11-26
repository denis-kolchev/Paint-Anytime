import SwiftUI

/// The tutorial's delete button on the 1:1 photo, aligned under the back button.
struct GalleryTutorialDeleteButton: View {
    @Environment(\.tutorialHintReservedHeight) private var tutorialHintReservedHeight
    @ObservedObject var tutorial: TutorialSession
    let morphState: GalleryMorphState
    let showsActions: Bool
    let isTransitioning: Bool
    let isLoading: Bool
    let onDelete: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let centerX = morphState.backButtonFrame.map {
                $0.midX - geometry.frame(in: .global).minX
            } ?? 30
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: GalleryMorphState.buttonDiameter,
                           height: GalleryMorphState.buttonDiameter)
                    .modifier(CanvasMorphGlass(adaptsToCanvas: true))
                    .tutorialHint(tutorial, steps: [.deleteDrawing])
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .position(x: centerX,
                      y: max(22, geometry.size.height - tutorialHintReservedHeight - 22))
            .opacity(showsActions ? 1 : 0)
            .disabled(!showsActions || isTransitioning || isLoading)
            .allowsHitTesting(showsActions && !isTransitioning)
            .accessibilityHidden(!showsActions || isTransitioning)
            .accessibilityLabel(L10n.text("Delete drawing"))
        }
    }
}
