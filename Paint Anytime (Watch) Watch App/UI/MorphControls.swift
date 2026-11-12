import SwiftUI
import Observation

/// Only the control views read these properties during body evaluation.
/// The canvas owner keeps a reference for dismissal and lifecycle events.
@Observable
final class CanvasMorphState {
    var customExpandedSlot: Int?
    var showsMorphToolbar = false
    var showsContentActions = false
    var showsSelectionActions = false
}

/// Panel bounds are read at gesture start. Only native anchors notify the control views.
@Observable
final class CanvasControlRegions {
    @ObservationIgnored var frames: [CanvasToolbarControl: CGRect] = [:]
    private(set) var toolbarAnchors: [CanvasToolbarControl: CGRect] = [:]
    /// The canvas in global coordinates; `.null` until the canvas is laid out.
    @ObservationIgnored var screenBounds: CGRect = .null

    func updateToolbarFrames(_ frames: [CanvasToolbarControl: CGRect]) {
        self.frames = frames
        // A hidden bar reports its slots off screen. Keep the last on-screen slot instead,
        // so hiding the bars for a custom layout never discards a measured position.
        var anchors = toolbarAnchors
        for (control, frame) in frames where Self.anchorControls.contains(control) && isOnScreen(frame) {
            anchors[control] = frame
        }
        if toolbarAnchors != anchors { toolbarAnchors = anchors }
    }

    /// Every custom-layout slot has a native position measured on screen.
    var hasCustomLayoutAnchors: Bool {
        CustomCanvasControls.anchors.allSatisfy { toolbarAnchors[$0] != nil }
    }

    private static let anchorControls: Set<CanvasToolbarControl> = [.more, .tools, .clear, .undo, .redo, .save]

    private func isOnScreen(_ frame: CGRect) -> Bool {
        guard !frame.isEmpty else { return false }
        guard !screenBounds.isNull else { return true }
        return screenBounds.insetBy(dx: 4, dy: 4).contains(CGPoint(x: frame.midX, y: frame.midY))
    }
}

/// Evaluate the builder in a separate body so Observation tracks menu changes
/// here, rather than in the parent that creates the canvas and raster artwork.
struct MorphControlsScope<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View { content() }
}

/// Fallback anchors before native toolbar layout is available.
struct MorphPanelGeometry {
    var size: CGSize
    var layoutDirection: LayoutDirection
    var top: CGFloat = 16
    static let buttonDiameter: CGFloat = 36
    var diameter: CGFloat = Self.buttonDiameter

    var leadingX: CGFloat { layoutDirection == .rightToLeft ? size.width - 30 : 30 }
    var trailingX: CGFloat { layoutDirection == .rightToLeft ? 30 : size.width - 30 }
    var bottom: CGFloat { size.height - 8 }

    func rowHeight(count: CGFloat, minimum: CGFloat = 20, panelTop: CGFloat? = nil) -> CGFloat {
        min(diameter, max(minimum, (size.height - (panelTop ?? top) - 16) / count))
    }
}

/// Shared by the gallery's expanding action panel.
@Observable
final class GalleryMorphState {
    var isExpanded = false
    var toolbarFrame: CGRect?
    var backButtonFrame: CGRect?
    // Visible glass size is independent of the native toolbar's layout slot.
    static let buttonDiameter: CGFloat = 36
    static let toolbarDiameter: CGFloat = 32
}

/// Use the same native bottom-toolbar slot as the canvas actions button.
struct GalleryMorphToolbarButton: View {
    let state: GalleryMorphState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
                state.isExpanded.toggle()
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 18, height: 18)
                .opacity(0)
        }
        .watchToolbarButtonStyle(diameter: GalleryMorphState.toolbarDiameter, hidesNativeChrome: true)
        // The native toolbar sits above the visible morph panel and must handle taps.
        .accessibilityLabel(L10n.text(state.isExpanded ? "Close" : "More"))
        .onGeometryChange(for: CGRect.self) { geometry in
            geometry.frame(in: .global)
        } action: { frame in
            if state.toolbarFrame != frame { state.toolbarFrame = frame }
        }
    }
}

struct GalleryMorphActions: View {
    let state: GalleryMorphState
    let canvasOrigin: CGPoint
    let drawing: CanvasExport
    let size: CGSize
    let isFavorite: Bool
    let favoriteProgress: Double
    var onEdit: () -> Void
    var onFavorite: (Bool) -> Void
    var onDelete: () -> Void
    private var showsGalleryActions: Bool {
        get { state.isExpanded }
        nonmutating set { state.isExpanded = newValue }
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let anchor = state.toolbarFrame.flatMap { frame -> CGPoint? in
            guard !frame.isEmpty else { return nil }
            return CGPoint(x: frame.midX - canvasOrigin.x, y: frame.midY - canvasOrigin.y)
        } ?? CGPoint(x: 30, y: size.height - 26)
        let diameter = GalleryMorphState.buttonDiameter
        let centerX = state.backButtonFrame.map { $0.midX - canvasOrigin.x } ?? anchor.x
        let left = centerX - diameter / 2
        // Keep matching screen-edge insets when the full-width panel does not fit.
        let expandedWidth = min(36 * 5, max(0, size.width - left * 2))
        let panelWidth = showsGalleryActions ? expandedWidth : diameter
        galleryActions(for: drawing, expandedWidth: expandedWidth)
            .position(x: left + panelWidth / 2, y: anchor.y)
    }

    private func toggleGalleryActions() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
            showsGalleryActions.toggle()
        }
    }

    private func galleryActions(for drawing: CanvasExport, expandedWidth: CGFloat) -> some View {
        CanvasMorphContent(isExpanded: showsGalleryActions) {
            HStack(spacing: 0) {
                // Equal cells without spacers: the interactive glass reacts anywhere in the
                // capsule, so every point must belong to the nearest action.
                Button(action: toggleGalleryActions) {
                    galleryActionIcon("xmark", itemWidth: nil)
                }
                .accessibilityHidden(true)
                Button { showsGalleryActions = false; onEdit() } label: {
                    galleryActionIcon("pencil", itemWidth: nil)
                }
                .accessibilityLabel(L10n.text("Edit drawing"))

                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                        onFavorite(!isFavorite)
                    }
                } label: {
                    ZStack {
                        galleryActionIcon("heart", itemWidth: nil)
                            .opacity(1 - favoriteProgress)
                        galleryActionIcon("heart.fill", itemWidth: nil)
                            .opacity(favoriteProgress)
                    }
                }
                .accessibilityLabel(L10n.text(isFavorite ? "Remove from favorites" : "Add to favorites"))

                ShareLink(item: DrawingShareItem(url: drawing.url),
                          preview: SharePreview(Text(verbatim: drawing.url.lastPathComponent),
                                                image: DrawingShareItem(url: drawing.url))) {
                    galleryActionIcon("square.and.arrow.up", itemWidth: nil)
                }
                .accessibilityLabel(L10n.text("Share"))

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    galleryActionIcon("trash", itemWidth: nil)
                }
                .accessibilityLabel(L10n.text("Delete drawing"))
            }
            .frame(width: expandedWidth, height: GalleryMorphState.buttonDiameter)
        } collapsed: {
            Button(action: toggleGalleryActions) {
                galleryActionIcon("ellipsis", itemWidth: GalleryMorphState.buttonDiameter)
            }
            .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .fixedSize()
        .modifier(GalleryMorphGlass())
    }

    /// `itemWidth: nil` fills an equal share of the expanded panel.
    private func galleryActionIcon(_ symbol: String, itemWidth: CGFloat?) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .medium))
            .frame(width: itemWidth, height: GalleryMorphState.buttonDiameter)
            .frame(maxWidth: itemWidth == nil ? .infinity : nil)
            .contentShape(Rectangle())
    }

}

/// Grid selection actions: the 1:1 morph panel without its close and edit cells.
/// Select/Cancel in the top bar owns dismissal, so the panel stays expanded.
struct GallerySelectionActions: View {
    let drawings: [CanvasExport]
    var onFavorite: (Bool) -> Void
    var onDelete: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var allFavorite: Bool { !drawings.isEmpty && drawings.allSatisfy(\.isFavorite) }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                    onFavorite(!allFavorite)
                }
            } label: {
                icon(allFavorite ? "heart.fill" : "heart")
            }
            .accessibilityLabel(L10n.text(allFavorite ? "Remove from favorites" : "Add to favorites"))

            ShareLink(items: drawings.map { DrawingShareItem(url: $0.url) }) { item in
                SharePreview(Text(verbatim: item.url.lastPathComponent), image: item)
            } label: {
                icon("square.and.arrow.up")
            }
            .accessibilityLabel(L10n.text("Share"))

            Button(role: .destructive, action: onDelete) {
                icon("trash")
            }
            .accessibilityLabel(L10n.text("Delete drawing"))
        }
        .disabled(drawings.isEmpty)
        .opacity(drawings.isEmpty ? 0.45 : 1)
        .frame(width: GalleryMorphState.buttonDiameter * 3, height: GalleryMorphState.buttonDiameter)
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .fixedSize()
        .modifier(GalleryMorphGlass())
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .medium))
            .frame(height: GalleryMorphState.buttonDiameter)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
    }
}

/// Let glass resolve the foreground contrast over the current gallery artwork.
/// A fixed white foreground prevents the light glass appearance from using dark symbols.
private struct GalleryMorphGlass: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(watchOS 26, *) {
            content
                .glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
        }
    }
}

/// Keep both states mounted so opening a panel does not insert its buttons.
struct CanvasMorphContent<Expanded: View, Collapsed: View>: View {
    let isExpanded: Bool
    @ViewBuilder var expanded: Expanded
    @ViewBuilder var collapsed: Collapsed

    private var usesLegacyMorphAnimation: Bool {
        if #available(watchOS 27, *) { return false }
        return true
    }

    var body: some View {
        CanvasMorphLayout(isExpanded: isExpanded,
                          progress: isExpanded ? 1 : 0,
                          interpolatesLayout: usesLegacyMorphAnimation) {
            expanded
                // Grow the rows out of the button center and collapse them back into it,
                // instead of fading a full-size column in place. Older SwiftUI toolbar hosts
                // animate the hidden layout from stale coordinates; on watchOS 27 the column
                // keeps its full height from the first frame, so its top rows started above
                // the button (seen once the canvas controls lost their native toolbar slots).
                .scaleEffect(isExpanded ? 1 : 0, anchor: .center)
                .opacity(isExpanded ? 1 : 0)
                .allowsHitTesting(isExpanded)
                .accessibilityHidden(!isExpanded)
            collapsed
                // Hide the source symbols before the expanding layout moves them.
                // Scope this transaction to opacity so the panel still morphs.
                .transaction { transaction in
                    if isExpanded { transaction.animation = nil }
                } body: { content in
                    content.opacity(isExpanded ? 0 : 1)
                }
                .allowsHitTesting(!isExpanded)
                .accessibilityHidden(isExpanded)
        }
    }
}

/// Measure both states in advance, but let only the active state size the glass.
private struct CanvasMorphLayout: Layout {
    let isExpanded: Bool
    var progress: CGFloat
    let interpolatesLayout: Bool

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map {
            $0.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        }
        if interpolatesLayout {
            // Resolve the bounds on every animation frame so both layers share
            // the moving panel center, including when the animation reverses.
            return CGSize(width: sizes[1].width + (sizes[0].width - sizes[1].width) * progress,
                          height: sizes[1].height + (sizes[0].height - sizes[1].height) * progress)
        }
        return sizes[isExpanded ? 0 : 1]
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(
                at: CGPoint(x: bounds.midX, y: bounds.midY),
                anchor: .center,
                proposal: ProposedViewSize(width: bounds.width, height: nil)
            )
        }
    }
}

struct CanvasMorphPanels: View {
    let state: CanvasMorphState
    let regions: CanvasControlRegions
    @ObservedObject var session: DrawingSessionController
    @ObservedObject var lasso: WatchLassoController
    let size: CGSize
    let canvasOrigin: CGPoint
    let isVisible: Bool
    let usesMorphToolbar: Bool
    let isMovingCanvas: Bool
    let isEyedropperActive: Bool
    @Binding var showsToolSettings: Bool
    @Binding var showsAppSettings: Bool
    @Binding var showsLayers: Bool
    var onStartLasso: () -> Void
    var onFinishLasso: () -> Void
    var onMoveSelectionLayer: (Int) -> Void
    var onClearLayerMoveName: () -> Void
    @AppStorage(WatchSketchAssist.phoneAvailabilityKey) private var sketchAssistOnPhone = false
    @State private var showsSketchAssistRequirements = false
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection

    private var controller: CanvasController { session.canvas }
    private var framesBinding: Binding<[CanvasToolbarControl: CGRect]> {
        Binding(get: { regions.frames }, set: { regions.frames = $0 })
    }
    private var showsMorphToolbar: Bool {
        get { state.showsMorphToolbar }
        nonmutating set { state.showsMorphToolbar = newValue }
    }
    private var showsContentActions: Bool {
        get { state.showsContentActions }
        nonmutating set { state.showsContentActions = newValue }
    }
    private var showsSelectionActions: Bool {
        get { state.showsSelectionActions }
        nonmutating set { state.showsSelectionActions = newValue }
    }

    var body: some View {
        let panelGeometry = MorphPanelGeometry(size: size, layoutDirection: layoutDirection)
        let leading = anchor(.more, fallback: CGPoint(x: panelGeometry.leadingX, y: panelGeometry.top + 18))
        let trailing = anchor(.tools, fallback: CGPoint(x: panelGeometry.trailingX, y: panelGeometry.top + 18))
        let bottom = anchor(.clear, fallback: CGPoint(x: panelGeometry.leadingX, y: panelGeometry.bottom - 18))
        ZStack {
            if isVisible && isMovingCanvas && !lasso.isActive && controller.activeStroke == nil {
                // Native toolbar slots still handle taps. Draw both camera controls
                // with the same anchors, diameter and glass as the canvas controls.
                cameraIcon("eyedropper", diameter: panelGeometry.diameter,
                           isHighlighted: isEyedropperActive)
                    .position(leading)
                cameraIcon("checkmark", diameter: panelGeometry.diameter, isHighlighted: true)
                    .position(trailing)
            }
            let showsDrawingMorph = usesMorphToolbar && isVisible && !isMovingCanvas && !lasso.isActive
                && controller.activeStroke == nil
            let showsLassoDone = isVisible && lasso.isActive && !lasso.hidesControls
            // One branch for both modes: the drawing morph and the lasso's Done share the
            // same glass, so starting or finishing the lasso cross-fades the symbol in place
            // (like the gallery's Select / Cancel) instead of swapping buttons on one frame.
            // Its own container, so the lasso's changes animate only this panel.
            ZStack {
                if showsDrawingMorph || showsLassoDone {
                    let diameter = panelGeometry.diameter
                    let top = trailing.y - 18
                    let rowCount: CGFloat = lasso.isActive ? 3 : 4
                    let rowHeight = panelGeometry.rowHeight(count: rowCount, panelTop: top)
                    let isExpanded = lasso.isActive ? showsSelectionActions : showsMorphToolbar
                    let panelHeight = isExpanded ? rowHeight * rowCount : diameter
                    let center = CGPoint(x: trailing.x, y: top + panelHeight / 2)
                    // With the built-in controls this view persists and only the symbol inside
                    // cross-fades (see `trailingMorph`). A custom layout has no drawing morph
                    // here, so Done is inserted and removed: scale it around its own center.
                    trailingMorph(diameter: diameter, rowHeight: rowHeight)
                        .position(center)
                        .transition(morphTransition(anchor: unitPoint(center)))
                }
            }
            .animation(lassoPanelAnimation, value: lasso.isActive)
            // The lasso hides its controls while an outline is drawn or prepared.
            .animation(lassoPanelAnimation, value: lasso.hidesControls)
            .zIndex(3)

            if showsDrawingMorph {
                let diameter = panelGeometry.diameter
                // Both controls use the same glass and explicit outer diameter.
                // Native toolbar buttons handle taps in their slots; other rows stay interactive.

                let contentTop = leading.y - 18
                let contentRowCount: CGFloat = 5
                let contentRowHeight = panelGeometry.rowHeight(count: contentRowCount, panelTop: contentTop)
                let contentHeight = showsContentActions ? contentRowHeight * contentRowCount : diameter
                morphContentActions(diameter: diameter, rowHeight: contentRowHeight)
                    .position(x: leading.x,
                              y: contentTop + contentHeight / 2)
                    .zIndex(3)
            }

            // Its own container, so the lasso's start and finish animate only this panel.
            ZStack {
                if isVisible && lasso.isActive && !lasso.hidesControls {
                    let diameter = panelGeometry.diameter
                    let left = bottom.x - diameter / 2
                    let availableWidth = max(0, size.width - left * 2)
                    let panelWidth = min(diameter * (showsSelectionActions ? 4 : CGFloat(lassoModes.count)), availableWidth)
                    // A lasso opened into one mode skips the mode picker; Complete strokes
                    // leaves only the send checkmark until its image arrives.
                    if showsSelectionActions || (!lasso.isModeLocked && !(lasso.hidesSelectionActions && lasso.bounds != nil)) {
                        lassoMorph(diameter: diameter, panelWidth: panelWidth)
                            .position(x: size.width / 2, y: bottom.y)
                            // Same entrance as the gallery's selection actions.
                            .transition(morphTransition(anchor: unitPoint(
                                CGPoint(x: size.width / 2, y: bottom.y))))
                    }
                }
            }
            // Starting and finishing the lasso are not animated by their callers.
            .animation(lassoPanelAnimation, value: lasso.isActive)
            .animation(lassoPanelAnimation, value: lasso.hidesControls)
            .zIndex(3)

        }
        .frame(width: size.width, height: size.height)
    }

    private var lassoPanelAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)
    }

    /// The gallery's selection-actions transition, scaled around the panel's own center.
    /// `.position` makes a panel canvas-sized, so the default center anchor would pull it
    /// toward the middle of the screen.
    private func morphTransition(anchor: UnitPoint) -> AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.6, anchor: anchor).combined(with: .opacity)
    }

    /// A canvas point as a unit point of the canvas, for transition anchors.
    private func unitPoint(_ point: CGPoint) -> UnitPoint {
        UnitPoint(x: size.width > 0 ? point.x / size.width : 0.5,
                  y: size.height > 0 ? point.y / size.height : 0.5)
    }

    private func cameraIcon(_ symbol: String, diameter: CGFloat, isHighlighted: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(isHighlighted ? AnyShapeStyle(.green) : AnyShapeStyle(.primary))
            .frame(width: diameter, height: diameter, alignment: .center)
            .modifier(CanvasMorphGlass(adaptsToCanvas: true))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func anchor(_ control: CanvasToolbarControl, fallback: CGPoint) -> CGPoint {
        guard let frame = regions.toolbarAnchors[control], !frame.isEmpty else { return fallback }
        let point = CGPoint(x: frame.midX - canvasOrigin.x, y: frame.midY - canvasOrigin.y)
        // Frames persist after their toolbar item leaves (a custom layout hides the bars,
        // then lasso removes its anchors), so a stale slot can sit off screen or at the
        // wrong edge. Keep only anchors on screen and on the same half as the fallback.
        guard CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4).contains(point),
              (point.y < size.height / 2) == (fallback.y < size.height / 2) else { return fallback }
        return point
    }

    /// Collapse after choosing an option, with the same spring as opening.
    private func collapse(_ change: () -> Void) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8), change)
    }

    private func openContentActions() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
            showsMorphToolbar = false
            showsContentActions = true
        }
    }

    private func morphContentActions(diameter: CGFloat, rowHeight: CGFloat) -> some View {
        CanvasMorphContent(isExpanded: showsContentActions) {
            VStack(spacing: 0) {
                // Options collapse the morph with its spring. More keeps it open:
                // a collapse would fight the push transition into the menu.
                morphButton("More", height: rowHeight) {
                    controller.cancelStroke()
                    showsAppSettings = true
                } label: { Image(systemName: "ellipsis") }
                .accessibilityHidden(true)
                morphButton("Save drawing", height: rowHeight) {
                    guard session.beginSavingDrawing() else { return }
                    let scale = displayScale
                    // Export only after the collapse settles: it blocks the main thread.
                    withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8),
                                  completionCriteria: .removed) {
                        showsContentActions = false
                    } completion: {
                        session.completeSavingDrawing(size: size, scale: scale)
                    }
                } label: { Image(systemName: "square.and.arrow.down") }
                morphButton("Lasso", height: rowHeight, action: onStartLasso) {
                    Image(systemName: "lasso")
                }
                morphButton("Layers", height: rowHeight) {
                    controller.cancelStroke()
                    collapse { showsContentActions = false }
                    showsLayers = true
                } label: { Image(systemName: "square.3.layers.3d") }
                morphButton("Clear canvas", height: rowHeight, isUnavailable: !controller.canClear) {
                    collapse { showsContentActions = false }
                    session.requestCanvasAction(.clear)
                } label: { BroomIcon() }
            }
        } collapsed: {
            VStack(spacing: 0) {

                morphButton("Canvas actions", height: diameter, isCircular: true, action: openContentActions) {
                    Image(systemName: "doc.badge.gearshape")
                }
                .accessibilityHidden(true)

            }
        }
        .frame(width: diameter)
        .modifier(CanvasMorphGlass())
        .trackCanvasControl(.contentMorph, frames: framesBinding)
    }

    /// The trailing morph: the drawing controls, or the lasso's Done with its history.
    /// Collapsed, both are one glass circle whose symbol cross-fades between modes.
    private func trailingMorph(diameter: CGFloat, rowHeight: CGFloat) -> some View {
        let isLasso = lasso.isActive
        return CanvasMorphContent(isExpanded: isLasso ? showsSelectionActions : showsMorphToolbar) {
            if isLasso {
                lassoHistoryRows(rowHeight: rowHeight)
            } else {
                drawingToolRows(rowHeight: rowHeight)
            }
        } collapsed: {
            VStack(spacing: 0) {
                morphButton(isLasso ? "Done" : "Open drawing controls", height: diameter, isCircular: true) {
                    if isLasso {
                        if lasso.awaitsSketchAssistConfirmation { lasso.confirmSketchAssist(controller) }
                        else { onFinishLasso() }
                    } else {
                        withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
                            showsContentActions = false
                            showsMorphToolbar = true
                        }
                    }
                } label: {
                    // Like the gallery's Select / Cancel: the glass stays put and only the
                    // symbol cross-fades. The animation is scoped to the symbol, so neither
                    // the glass position nor its size animates when the mode changes.
                    // Both symbols stay mounted and cross-fade by opacity: swapping one Image's
                    // symbol with `.contentTransition(.opacity)` switched on a single frame here.
                    ZStack {
                        Image(systemName: "paintbrush.pointed")
                            .opacity(isLasso ? 0 : 1)
                        Image(systemName: "checkmark")
                            .foregroundStyle(.green)
                            .opacity(isLasso ? 1 : 0)
                    }
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: isLasso)
                }
                .accessibilityHidden(true)
            }
        }
        .frame(width: diameter)
        .modifier(CanvasMorphGlass())
        .trackCanvasControl(.morph, frames: framesBinding)
    }

    private func drawingToolRows(rowHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            // Tool settings keeps the morph open: a collapse would fight the
            // transition into the brush editor.
            morphButton("Tool settings", height: rowHeight) {
                controller.cancelStroke()
                showsToolSettings = true
            } label: {
                ToolIcon(instrument: controller.pencilStyle.instrument)
                    .frame(width: 18, height: 18)
            }
            .accessibilityHidden(true)
            morphButton("Undo", height: rowHeight, isUnavailable: !controller.canUndo,
                        action: { controller.undo() }) {
                Image(systemName: "arrow.uturn.backward")
            }
            morphButton("Redo", height: rowHeight, isUnavailable: !controller.canRedo,
                        action: { controller.redo() }) {
                Image(systemName: "arrow.uturn.forward")
            }
            morphButton("Close", height: rowHeight) {
                collapse { showsMorphToolbar = false }
            } label: { Image(systemName: "xmark") }
        }
    }

    private func lassoHistoryRows(rowHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            morphButton("Done", height: rowHeight) { onFinishLasso() } label: {
                Image(systemName: "checkmark").foregroundStyle(.green)
            }
            .accessibilityHidden(true)

            morphButton("Undo", height: rowHeight, isUnavailable: !lasso.canUndo) {
                onClearLayerMoveName()
                lasso.undo(controller)
            } label: { Image(systemName: "arrow.uturn.backward") }
            morphButton("Redo", height: rowHeight, isUnavailable: !lasso.canRedo) {
                onClearLayerMoveName()
                lasso.redo(controller)
            } label: { Image(systemName: "arrow.uturn.forward") }
        }
    }

    /// Sketch assist ships with 1.3; it stays visible but locked until the iPhone reports support.
    private var lassoModes: [WatchLassoMode] {
        WatchLassoMode.allCases.filter { $0 != .sketchAssist || AppReleaseFeatures.current.showsSketchAssist }
    }

    private var selectionForeground: AnyShapeStyle {
        if #available(watchOS 26, *) { return AnyShapeStyle(.primary) }
        return AnyShapeStyle(.white)
    }

    private func lassoMorph(diameter: CGFloat, panelWidth: CGFloat) -> some View {
        CanvasMorphContent(isExpanded: showsSelectionActions) {
            HStack(spacing: 0) {
                morphButton("Move to layer above", height: diameter) {
                    onMoveSelectionLayer(1)
                } label: { Image(systemName: "square.3.layers.3d.top.filled") }
                .disabled(!lasso.canMoveLayer(1, controller: controller))
                .opacity(lasso.canMoveLayer(1, controller: controller) ? 1 : 0.35)

                morphButton("Move to layer below", height: diameter) {
                    onMoveSelectionLayer(-1)
                } label: { Image(systemName: "square.3.layers.3d.bottom.filled") }
                .disabled(!lasso.canMoveLayer(-1, controller: controller))
                .opacity(lasso.canMoveLayer(-1, controller: controller) ? 1 : 0.35)
                morphButton("Duplicate", height: diameter) { lasso.duplicate(controller) } label: {
                    Image(systemName: "plus.square.on.square")
                }
                .disabled(lasso.bounds == nil)
                morphButton("Delete", height: diameter) { lasso.delete(controller) } label: {
                    Image(systemName: "trash").foregroundStyle(.red)
                }
                .disabled(lasso.bounds == nil)
            }
        } collapsed: {
            // Equal cells without spacers: every point of the glass selects the nearest mode.
            HStack(spacing: 0) {
                ForEach(lassoModes, id: \.self) { mode in
                    let isLocked = mode == .sketchAssist && !sketchAssistOnPhone
                    morphButton(mode.title, height: diameter) {
                        if isLocked { showsSketchAssistRequirements = true } else { lasso.setMode(mode) }
                    } label: {
                        Image(systemName: mode.symbol)
                            .foregroundStyle(lasso.mode == mode ? AnyShapeStyle(.green) : selectionForeground)
                            .modifier(SketchAssistLock(isLocked: isLocked))
                    }
                    .accessibilityAddTraits(lasso.mode == mode ? [.isSelected] : [])
                    .accessibilityValue(isLocked ? L10n.text("Unavailable") : "")
                }
            }
        }
        .frame(width: panelWidth, height: diameter)
        .modifier(CanvasMorphGlass(adaptsToCanvas: true))
        .trackCanvasControl(.canvasToolsMorph, frames: framesBinding)
        .onChange(of: sketchAssistOnPhone) { _, available in
            if !available && lasso.mode == .sketchAssist { lasso.setMode(.area) }
        }
        .modifier(SketchAssistRequirementsAlert(isPresented: $showsSketchAssistRequirements))
    }

    /// `isCircular`: a collapsed one-button panel, hit-tested like its round glass so the
    /// corners beside it stay drawable. Rows of an expanded panel tile it as rectangles.
    /// `isUnavailable` dims the button like `.disabled` but keeps the tap, which then plays
    /// `UnavailableActionFeedback` instead of the action.
    private func morphButton<Label: View>(_ title: String, height: CGFloat, isCircular: Bool = false,
                                          isUnavailable: Bool = false,
                                          action: @escaping () -> Void,
                                          @ViewBuilder label: () -> Label) -> some View {
        Button {
            if isUnavailable { UnavailableActionFeedback.play() } else { action() }
        } label: {
            label()
                .font(.system(size: 17, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .contentShape(isCircular ? AnyShape(Circle()) : AnyShape(Rectangle()))
                .opacity(isUnavailable ? 0.35 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text(title))
    }

}

/// One glass surface persists as the circle expands into a capsule.
struct CanvasMorphGlass: ViewModifier {
    var adaptsToCanvas = false
    /// Interactive glass reacts to touches on its own. Over Buttons with no native toolbar
    /// slot above them it showed the press but the Button often never fired; those
    /// controls pass false and give press feedback in `CanvasMorphButtonStyle`.
    var isInteractive = true
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(watchOS 26, *) {
            content
                .foregroundStyle(.primary)
                .glassEffect(isInteractive ? .regular.interactive() : .regular, in: Capsule())
                // Selection controls need the glass's adaptive foreground;
                // forcing dark appearance makes white icons vanish on light glass.
                .environment(\.colorScheme, adaptsToCanvas ? colorScheme : .dark)
        } else {
            content
                .foregroundStyle(.white)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }
}

/// Buttons drawn on the canvas with no native toolbar slot above them (the custom layout
/// hides the native bars). The surrounding glass is not interactive, so the press feedback
/// lives on the Button itself and every press it shows also reaches the action.
struct CanvasMorphButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CanvasMorphButtonLabel(configuration: configuration)
    }
}

private struct CanvasMorphButtonLabel: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isCanvasActionUnavailable) private var isUnavailable
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isPressed = configuration.isPressed && !isUnavailable
        configuration.label
            .opacity(!isEnabled || isUnavailable ? 0.45 : isPressed ? 0.55 : 1)
            .scaleEffect(isPressed && !reduceMotion ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
