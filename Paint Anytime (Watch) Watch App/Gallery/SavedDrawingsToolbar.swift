import SwiftUI

/// Gallery toolbar: the photo's morph button, Select / Cancel and Back.
/// Every displayed value is passed in, so the items refresh with the gallery.
struct SavedDrawingsToolbar: ToolbarContent {
    let tutorial: TutorialSession
    let morphState: GalleryMorphState
    /// The 1:1 photo is settled and outside the tutorial.
    let showsMorphButton: Bool
    let hostsSelectButton: Bool
    let showsSelectButton: Bool
    let allowsBack: Bool
    let isSelecting: Bool
    let isLoading: Bool
    let isTransitioning: Bool
    let isCleanViewing: Bool
    let reduceMotion: Bool
    let onToggleSelecting: () -> Void
    let onBack: () -> Void

    var body: some ToolbarContent {
        if showsMorphButton {
            ToolbarItemGroup(placement: .bottomBar) {
                GalleryMorphToolbarButton(state: morphState)
                    .disabled(isCleanViewing || isLoading || isTransitioning)
                    .accessibilityHidden(isCleanViewing || isTransitioning)
                Spacer(minLength: 0)
            }
        }
        if hostsSelectButton {
            ToolbarItem(placement: .topBarTrailing) {
                selectButton
            }
        }
        if allowsBack {
            ToolbarItem(placement: .topBarLeading) {
                backButton
                    // The tutorial fades Back in with the gallery and out before it closes.
                    .tutorialChromeFade(tutorial.isActive)
            }
        }
    }

    private var selectButton: some View {
        // Same hidden-chrome slot and glass circle as the back button.
        Button(action: onToggleSelecting) {
            Image(systemName: "checkmark.circle")
                .opacity(0)
        }
        .disabled(isLoading || isTransitioning || !showsSelectButton)
        .watchToolbarButtonStyle(diameter: GalleryMorphState.toolbarDiameter, hidesNativeChrome: true)
        .overlay {
            Image(systemName: isSelecting ? "xmark" : "checkmark.circle")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .contentTransition(.opacity)
                .frame(width: GalleryMorphState.buttonDiameter,
                       height: GalleryMorphState.buttonDiameter)
                .modifier(CanvasMorphGlass(adaptsToCanvas: true))
                // The visible circle carries the hint; the button's own label stays transparent.
                .tutorialHint(tutorial, steps: [.startSelection], isSuggested: !isSelecting)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        // The 1:1 photo has its own morph actions; fade rather than remove.
        .opacity(showsSelectButton ? 1 : 0)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: showsSelectButton)
        .allowsHitTesting(showsSelectButton)
        .accessibilityHidden(!showsSelectButton)
        .accessibilityLabel(L10n.text(isSelecting ? "Cancel" : "Select"))
    }

    private var backButton: some View {
        Button(action: onBack) {
            Image(systemName: "chevron.left")
                .opacity(0)
                .tutorialHint(tutorial, steps: [.returnToCanvas])
        }
        .disabled(isTransitioning || isCleanViewing || isLoading)
        .watchToolbarButtonStyle(diameter: GalleryMorphState.toolbarDiameter, hidesNativeChrome: true)
        .overlay {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: GalleryMorphState.buttonDiameter,
                       height: GalleryMorphState.buttonDiameter)
                .modifier(CanvasMorphGlass(adaptsToCanvas: true))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .opacity(isCleanViewing ? 0 : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: isCleanViewing)
        .allowsHitTesting(!isCleanViewing)
        .accessibilityHidden(isCleanViewing)
        .accessibilityLabel(L10n.text("Back"))
        .onGeometryChange(for: CGRect.self) { geometry in
            geometry.frame(in: .global)
        } action: { frame in
            if morphState.backButtonFrame != frame { morphState.backButtonFrame = frame }
        }
    }
}
