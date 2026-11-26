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
    /// Complete strokes' ✕: before ✓ and while its request is out.
    let showsSketchAssistCancel: Bool
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
    /// Tool settings' palette / Information corner, installed here with Done.
    let toolSettingsCorner: ToolSettingsCorner
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
    /// Tool settings' corner and Done: the drawn canvas circles' size, so the circles
    /// keep their size as the settings open (32 pt read smaller than the morph's 36 pt).
    private var toolSettingsDiameter: CGFloat { MorphPanelGeometry.buttonDiameter }
    /// The canvas draws this corner's glass; the native button keeps only the slot and taps.
    /// The lasso's Done is drawn there too, sharing one glass with the drawing morph.
    private var morphOwnsTrailingControl: Bool {
        !showsToolSettings && (isMovingCanvas || lassoIsActive || usesMorphToolbar)
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
                        .allowsHitTesting(!showsSketchAssistCancel)
                    sketchAssistCancelControl
                }
            }
        }
        // A custom layout assigns the top-left slot itself, except while the
        // free camera borrows it for the eyedropper. Tool settings put their corner on the
        // same button, as Done replaces the trailing control: added inside the settings'
        // fade, the toolbar moved it into place from the screen's corner, and a different
        // view in this item flew in the same way.
        if isShown && (showsToolSettings || (!lassoIsActive && (customLayout == nil || isMovingCanvas))) {
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

    /// The tool settings' corner opens the palette on the Color page and Information elsewhere.
    /// `ContentView` observes the corner, so this toolbar is rebuilt as the page changes.
    private var cornerOpensPalette: Bool {
        // Until the settings restore their page, open on the page they will restore.
        toolSettingsCorner.opensPalette
            ?? WatchToolSettingsView.opensOnColorPage(style: controller.pencilStyle)
    }

    /// More, canvas actions, the free camera's eyedropper, the lasso's check or,
    /// in tool settings, the palette / Information corner.
    private var leadingControl: some View {
        let hidesForStroke = !showsToolSettings && hasActiveStroke
        return MorphControlsScope {
            Button(action: leadingAction) {
                Group {
                    if showsToolSettings {
                        ToolSettingsCornerIcon(opensPalette: cornerOpensPalette)
                    } else {
                        Image(systemName: lassoIsActive ? "checkmark" : isMovingCanvas ? "eyedropper" : usesMorphToolbar ? "doc.badge.gearshape" : "ellipsis")
                            .foregroundStyle(lassoIsActive || isEyedropperActive ? .green : .primary)
                            .frame(width: 18, height: 18, alignment: .center)
                            .opacity(lassoIsActive || isMovingCanvas || usesMorphToolbar ? 0 : 1)
                    }
                }
                .contentShape(Rectangle())
            }
            // Canvas material in tool settings too: the native style lays the button out
            // about 2.5 pt from this slot, and the toolbar slid it there as the settings opened.
            .watchToolbarButtonStyle(diameter: showsToolSettings ? toolSettingsDiameter : canvasToolbarDiameter, usesCanvasMaterial: true,
                                     hidesNativeChrome: !showsToolSettings && (lassoIsActive || usesMorphToolbar || isMovingCanvas || hasActiveStroke))
            .accessibilityLabel(L10n.text(showsToolSettings ? (cornerOpensPalette ? "Current palette" : "Information") : lassoIsActive ? (showsSelectionActions ? "Move to layer above" : WatchLassoMode.strokes.title) : isMovingCanvas ? "Eyedropper" : usesMorphToolbar && !showsContentActions ? "Canvas actions" : "More"))
            .disabled(!showsToolSettings && lassoIsActive && showsSelectionActions && !canMoveSelectionUp)
            .accessibilityAddTraits(!showsToolSettings && isEyedropperActive ? [.isSelected] : [])
            .trackCanvasControl(.more, frames: controlFrames)
            .modifier(CanvasMenuControlVisibility(isHidden: hidesMenuControls))
            .opacity(hidesForStroke ? 0 : 1)
            .allowsHitTesting(!hidesForStroke)
            .accessibilityHidden(hidesForStroke)
        }
    }

    private func leadingAction() {
        if showsToolSettings {
            toolSettingsCorner.onTap()
        } else if lassoIsActive {
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

    /// Complete strokes: before ✓ discards the outlined strokes; after ✓ cancels the
    /// request on the watch and the iPhone, keeping the strokes ready to send again.
    private var sketchAssistCancelControl: some View {
        let isShown = showsSketchAssistCancel
        return MorphControlsScope {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { lasso.cancelSketchAssist() }
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
            // Canvas material for Done too: the native style lays the button out about 2.5 pt
            // from this slot, and the toolbar slid ✓ there as the settings opened.
            .watchToolbarButtonStyle(diameter: showsToolSettings ? toolSettingsDiameter : canvasToolbarDiameter, usesCanvasMaterial: true, hidesNativeChrome: morphOwnsTrailingControl || lassoHidesControls || (!showsToolSettings && hasActiveStroke))
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
