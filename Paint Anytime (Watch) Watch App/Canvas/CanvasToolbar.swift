import SwiftUI

/// Canvas toolbar items: custom-layout anchors, lasso controls, the leading
/// More / eyedropper button and the trailing tool control.
///
/// Every value the items display is passed in by `ContentView`, so they refresh
/// with it exactly as when they were part of its body. The references are used
/// for actions and child views only.
struct CanvasToolbar: ToolbarContent {
    let controller: CanvasController
    let lasso: WatchLassoController
    let lassoToolbarInput: WatchLassoToolbarInput
    let morphState: CanvasMorphState
    let customLayout: CanvasControlLayout?
    /// The canvas is on screen: active, with no tutorial and no gallery.
    let isShown: Bool
    let isMovingCanvas: Bool
    let hasActiveStroke: Bool
    let instrument: DrawingInstrument
    let lassoIsActive: Bool
    let awaitsSketchAssistConfirmation: Bool
    let lassoHidesControls: Bool
    let canMoveSelectionUp: Bool
    let showsMorphToolbar: Bool
    let showsContentActions: Bool
    let showsSelectionActions: Bool
    /// The menu or autosave covers the canvas controls.
    let hidesMenuControls: Bool
    /// The menu, a quick setting or autosave covers the custom anchors.
    let hidesCustomAnchors: Bool
    let reduceMotion: Bool
    @Binding var showsToolSettings: Bool
    @Binding var showsAppSettings: Bool
    @Binding var isEyedropperActive: Bool
    @Binding var hasEyedropperSession: Bool
    @Binding var cameraSampledColor: SIMD4<Float>?
    let controlFrames: Binding<[CanvasToolbarControl: CGRect]>
    let onMoveSelectionLayer: (Int) -> Void
    let onFinishLasso: () -> Void
    let onFinishCameraTool: () -> Void
    let onAction: (CanvasQuickAction) -> Void

    /// The built-in controls are the morph menus; any other arrangement is a custom layout.
    private var usesMorphToolbar: Bool { customLayout == nil }
    private var canvasToolbarDiameter: CGFloat {
        usesMorphToolbar ? 32 : MorphPanelGeometry.buttonDiameter
    }
    private var morphOwnsTrailingControl: Bool {
        !showsToolSettings && (isMovingCanvas || (lassoIsActive && showsSelectionActions) ||
            (!lassoIsActive && usesMorphToolbar))
    }
    private var morphSpring: Animation? {
        reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)
    }

    var body: some ToolbarContent {
        if let customLayout, isShown, !showsToolSettings, !isMovingCanvas, !lassoIsActive {
            ToolbarItem(placement: .topBarTrailing) {
                customToolbarAnchor(0, layout: customLayout)
            }
            ToolbarItem(placement: .topBarLeading) {
                customToolbarAnchor(CanvasControlLayout.topLeadingSlot, layout: customLayout)
            }
            ToolbarItemGroup(placement: .bottomBar) {
                customToolbarAnchor(1, layout: customLayout)
                Spacer(minLength: 0)
                customToolbarAnchor(2, layout: customLayout)
                Spacer(minLength: 0)
                customToolbarAnchor(3, layout: customLayout)
                Spacer(minLength: 0)
                customToolbarAnchor(4, layout: customLayout)
            }
        }
        if isShown && !showsToolSettings && lassoIsActive {
            ToolbarItem(placement: .topBarLeading) {
                // Both stay installed, like the trailing Done: swapping them with if/else
                // left the ✕ unrendered when Complete strokes opened from a custom layout,
                // whose hidden bars reappear with the lasso.
                ZStack {
                    // Balance Done to center the system clock, and forward this
                    // native toolbar region's drags to the same lasso controller.
                    WatchLassoToolbarTouchRegion(input: lassoToolbarInput, lasso: lasso,
                        controller: controller, diameter: canvasToolbarDiameter)
                        .allowsHitTesting(!awaitsSketchAssistConfirmation)
                    sketchAssistCancelControl
                }
            }
        }
        // A custom layout assigns the top-left slot itself, except while the
        // free camera borrows it for the eyedropper.
        if isShown && !showsToolSettings && !lassoIsActive && (customLayout == nil || isMovingCanvas) {
            ToolbarItem(placement: .topBarLeading) {
                leadingControl
            }
        }
        if isShown && (customLayout == nil || showsToolSettings || isMovingCanvas || lassoIsActive) {
            ToolbarItem(placement: .topBarTrailing) {
                trailingToolControl
            }
        }
    }

    /// More, canvas actions, the free camera's eyedropper or the lasso's check.
    private var leadingControl: some View {
        MorphControlsScope {
            Button(action: leadingAction) {
                Image(systemName: lassoIsActive ? "checkmark" : isMovingCanvas ? "eyedropper" : usesMorphToolbar ? "doc.badge.gearshape" : "ellipsis")
                    .foregroundStyle(lassoIsActive || isEyedropperActive ? .green : .primary)
                    .frame(width: 18, height: 18, alignment: .center)
                    .opacity(lassoIsActive || isMovingCanvas || usesMorphToolbar ? 0 : 1)
                    .contentShape(Rectangle())
            }
            .watchToolbarButtonStyle(diameter: canvasToolbarDiameter, usesCanvasMaterial: true, hidesNativeChrome: lassoIsActive ? true : (usesMorphToolbar || isMovingCanvas) || hasActiveStroke)
            .accessibilityLabel(L10n.text(lassoIsActive ? (showsSelectionActions ? "Move to layer above" : WatchLassoMode.strokes.title) : isMovingCanvas ? "Eyedropper" : usesMorphToolbar && !showsContentActions ? "Canvas actions" : "More"))
            .disabled(lassoIsActive && showsSelectionActions && !canMoveSelectionUp)
            .accessibilityAddTraits(isEyedropperActive ? [.isSelected] : [])
            .trackCanvasControl(.more, frames: controlFrames)
            .modifier(CanvasMenuControlVisibility(isHidden: hidesMenuControls))
            .opacity(hasActiveStroke ? 0 : 1)
            .allowsHitTesting(!hasActiveStroke)
            .accessibilityHidden(hasActiveStroke)
        }
    }

    private func leadingAction() {
        if lassoIsActive {
            if showsSelectionActions { onMoveSelectionLayer(1) }
            else { lasso.setMode(.strokes) }
        } else if isMovingCanvas {
            controller.cancelStroke()
            isEyedropperActive.toggle()
            // Deselecting cancels the pick, so ✓ won't open the color editor.
            hasEyedropperSession = isEyedropperActive
            if !isEyedropperActive { cameraSampledColor = nil }
        } else if usesMorphToolbar {
            if showsContentActions {
                // The morph stays open: collapsing it fights the transition into the menu.
                showsAppSettings = true
            } else {
                withAnimation(morphSpring) {
                    morphState.showsMorphToolbar = false
                    morphState.showsContentActions = true
                }
            }
        } else { showsAppSettings = true }
    }

    /// Complete strokes: discards the outlined strokes instead of sending them.
    /// Shown only while the outlined strokes wait for confirmation.
    private var sketchAssistCancelControl: some View {
        let isShown = awaitsSketchAssistConfirmation && !lassoHidesControls
        return MorphControlsScope {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { lasso.resetSelection() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 18, height: 18, alignment: .center)
                    .contentShape(Rectangle())
            }
            .watchToolbarButtonStyle(diameter: canvasToolbarDiameter, usesCanvasMaterial: true,
                                     hidesNativeChrome: !isShown)
            .accessibilityLabel(L10n.text("Cancel"))
            .trackCanvasControl(.more, frames: controlFrames)
            .opacity(isShown ? 1 : 0)
            .allowsHitTesting(isShown)
            .accessibilityHidden(!isShown)
        }
    }

    /// The trailing toolbar control: tool settings, Done or the drawing morph.
    private var trailingToolControl: some View {
        MorphControlsScope {
            Button(action: trailingAction) {
                Group {
                    if showsToolSettings || isMovingCanvas || lassoIsActive {
                        Image(systemName: "checkmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.green)
                    } else if usesMorphToolbar {
                        Image(systemName: "paintbrush.pointed")
                    } else {
                        ToolIcon(instrument: instrument)
                    }
                }
                // Keep the label bounds identical when switching to Done,
                // so the toolbar centers the checkmark like the tool icon.
                .frame(width: 18, height: 18, alignment: .center)
                .opacity(morphOwnsTrailingControl ? 0 : 1)
                .contentShape(Rectangle())
            }
            .watchToolbarButtonStyle(diameter: showsToolSettings ? 32 : canvasToolbarDiameter, usesCanvasMaterial: !showsToolSettings, hidesNativeChrome: morphOwnsTrailingControl || lassoHidesControls || (!showsToolSettings && hasActiveStroke))
            .accessibilityLabel(lassoIsActive && awaitsSketchAssistConfirmation ? L10n.text("Send to iPhone") : showsToolSettings || isMovingCanvas || lassoIsActive ? L10n.text("Done") : L10n.text(usesMorphToolbar && !showsMorphToolbar ? "Open drawing controls" : "Tool settings"))
            .trackCanvasControl(.tools, frames: controlFrames)
            .modifier(CanvasMenuControlVisibility(isHidden: hidesMenuControls))
            // Keep the toolbar slot installed so the system clock does not
            // move when drawing temporarily hides the button.
            .opacity((!showsToolSettings && hasActiveStroke) || lassoHidesControls ? 0 : 1)
            .allowsHitTesting((showsToolSettings || !hasActiveStroke) && !lassoHidesControls)
            .accessibilityHidden((!showsToolSettings && hasActiveStroke) || lassoHidesControls)
        }
    }

    private func trailingAction() {
        if lassoIsActive {
            if awaitsSketchAssistConfirmation { lasso.confirmSketchAssist(controller) }
            else { onFinishLasso() }
        } else if isMovingCanvas {
            onFinishCameraTool()
        }
        else if usesMorphToolbar && !showsToolSettings {
            if showsMorphToolbar {
                // The morph stays open: collapsing it fights the transition into the brush editor.
                showsToolSettings = true
            } else {
                withAnimation(morphSpring) {
                    morphState.showsContentActions = false
                    morphState.showsMorphToolbar = true
                }
            }
        } else { showsToolSettings.toggle() }
    }

    private func customToolbarAnchor(_ index: Int, layout: CanvasControlLayout) -> some View {
        CustomCanvasToolbarAnchor(index: index, assignment: layout.slots[index],
                                  state: morphState, onAction: onAction)
            .trackCanvasControl(CustomCanvasControls.anchors[index], frames: controlFrames)
            .modifier(CanvasMenuControlVisibility(isHidden: hidesCustomAnchors))
            .opacity(hasActiveStroke ? 0 : 1)
            // The bars are hidden while these anchors exist; they only report frames for the
            // drawn controls. Taking touches, the hidden slots swallowed taps on the drawn
            // buttons under them (probe: window saw them, the canvas screen did not).
            .allowsHitTesting(false)
    }
}
