import SwiftUI
import Observation

/// Only the control views read these properties during body evaluation.
/// The canvas owner keeps a reference for dismissal and lifecycle events.
@Observable
final class CanvasMorphState {
    var showsMorphToolbar = false
    var showsContentActions = false
    var showsSelectionActions = false
}

/// Panel bounds are read at gesture start. Only native anchors notify the control views.
@Observable
final class CanvasControlRegions {
    @ObservationIgnored var frames: [CanvasToolbarControl: CGRect] = [:]
    private(set) var toolbarAnchors: [CanvasToolbarControl: CGRect] = [:]

    func updateToolbarFrames(_ frames: [CanvasToolbarControl: CGRect]) {
        self.frames = frames
        let anchors = frames.filter { [.more, .tools, .clear].contains($0.key) }
        if toolbarAnchors != anchors { toolbarAnchors = anchors }
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
    var diameter: CGFloat = 36

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
                // Six equal gaps: four between the intrinsic symbol widths and two at the edges.
                Spacer(minLength: 0)
                Button(action: toggleGalleryActions) {
                    galleryActionIcon("xmark", itemWidth: nil)
                }
                .accessibilityHidden(true)
                Spacer(minLength: 0)

                Button { showsGalleryActions = false; onEdit() } label: {
                    galleryActionIcon("pencil", itemWidth: nil)
                }
                .accessibilityLabel(L10n.text("Edit drawing"))
                Spacer(minLength: 0)

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
                Spacer(minLength: 0)

                ShareLink(item: DrawingShareItem(url: drawing.url),
                          preview: SharePreview(Text(verbatim: drawing.url.lastPathComponent),
                                                image: DrawingShareItem(url: drawing.url))) {
                    galleryActionIcon("square.and.arrow.up", itemWidth: nil)
                }
                .accessibilityLabel(L10n.text("Share"))
                Spacer(minLength: 0)

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    galleryActionIcon("trash", itemWidth: nil)
                }
                .accessibilityLabel(L10n.text("Delete drawing"))
                Spacer(minLength: 0)
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

    private func galleryActionIcon(_ symbol: String, itemWidth: CGFloat?) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .medium))
            .frame(width: itemWidth, height: GalleryMorphState.buttonDiameter)
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
                // Older SwiftUI toolbar hosts animate the hidden, full-size
                // layout from stale coordinates. Collapse its visual contents
                // to the current button center instead of merely fading them.
                .scaleEffect(usesLegacyMorphAnimation && !isExpanded ? 0 : 1, anchor: .center)
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
    @Binding var showsCanvasSize: Bool
    @Binding var showsLayers: Bool
    var onStartLasso: () -> Void
    var onFinishLasso: () -> Void
    var onMoveSelectionLayer: (Int) -> Void
    var onClearLayerMoveName: () -> Void
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
            if usesMorphToolbar && isVisible && !isMovingCanvas && !lasso.isActive && controller.activeStroke == nil {
                let diameter = panelGeometry.diameter
                let top = trailing.y - 18
                let centerX = trailing.x
                let rowHeight = panelGeometry.rowHeight(count: 3, panelTop: top)
                let panelHeight = showsMorphToolbar ? rowHeight * 3 : diameter
                morphToolbar(diameter: diameter, rowHeight: rowHeight)
                    .position(x: centerX, y: top + panelHeight / 2)
                    .zIndex(3)

                // Both controls use the same glass and explicit outer diameter.
                // Native toolbar buttons handle taps in their slots; other rows stay interactive.

                let contentTop = leading.y - 18
                let contentRowCount: CGFloat = AppReleaseFeatures.current.showsCanvasSizeControls ? 6 : 5
                let contentRowHeight = panelGeometry.rowHeight(count: contentRowCount, panelTop: contentTop)
                let contentHeight = showsContentActions ? contentRowHeight * contentRowCount : diameter
                morphContentActions(diameter: diameter, rowHeight: contentRowHeight)
                    .position(x: leading.x,
                              y: contentTop + contentHeight / 2)
                    .zIndex(3)
            }

            if !usesMorphToolbar && isVisible && !isMovingCanvas && !lasso.isActive && controller.activeStroke == nil {
                let diameter = panelGeometry.diameter
                let height = showsContentActions ? diameter * 3 : diameter
                contentActions(diameter: diameter)
                    .position(x: bottom.x,
                              y: bottom.y + 18 - height / 2)
                    .zIndex(3)
            }

            if isVisible && lasso.isActive && !lasso.hidesControls {
                let diameter = panelGeometry.diameter
                let left = bottom.x - diameter / 2
                let availableWidth = max(0, size.width - left * 2)
                let panelWidth = min(diameter * (showsSelectionActions ? 4 : 2), availableWidth)
                lassoMorph(diameter: diameter, panelWidth: panelWidth)
                    .position(x: size.width / 2, y: bottom.y)
                    .zIndex(3)

                if showsSelectionActions {
                    let trailingTop = trailing.y - 18
                    let historyRowHeight = panelGeometry.rowHeight(count: 3, panelTop: trailingTop)
                    lassoHistoryMorph(diameter: diameter, rowHeight: historyRowHeight)
                        .position(x: trailing.x,
                                  y: trailingTop + historyRowHeight * 3 / 2)
                        .zIndex(3)
                }
            }

        }
        .frame(width: size.width, height: size.height)
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
        return CGPoint(x: frame.midX - canvasOrigin.x, y: frame.midY - canvasOrigin.y)
    }

    private func openContentActions() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
            showsMorphToolbar = false
            showsContentActions = true
        }
    }

    private func contentActions(diameter: CGFloat) -> some View {
        CanvasMorphContent(isExpanded: showsContentActions) {
            VStack(spacing: 0) {
                morphButton("Clear canvas", height: diameter) {
                    showsContentActions = false
                    session.requestCanvasAction(.clear)
                } label: { BroomIcon() }
                .disabled(!controller.canClear)
                morphButton("Save drawing", height: diameter) {
                    showsContentActions = false
                    session.saveDrawing(size: size, scale: displayScale)
                } label: { Image(systemName: "square.and.arrow.down") }
                morphButton("Lasso", height: diameter, action: onStartLasso) { Image(systemName: "lasso") }
                .accessibilityHidden(true)
            }
        } collapsed: {
            VStack(spacing: 0) {
                morphButton("Canvas actions", height: diameter, action: openContentActions) {
                    Image(systemName: "doc.badge.gearshape")
                }
                .accessibilityHidden(true)

            }
        }
        .frame(width: diameter)
        .modifier(CanvasMorphGlass())
        .trackCanvasControl(.contentMorph, frames: framesBinding)
    }

    private func morphContentActions(diameter: CGFloat, rowHeight: CGFloat) -> some View {
        CanvasMorphContent(isExpanded: showsContentActions) {
            VStack(spacing: 0) {
                morphButton("More", height: rowHeight) {
                    controller.cancelStroke()
                    showsContentActions = false
                    showsAppSettings = true
                } label: { Image(systemName: "ellipsis") }
                .accessibilityHidden(true)
                morphButton("Clear canvas", height: rowHeight) {
                    showsContentActions = false
                    session.requestCanvasAction(.clear)
                } label: { BroomIcon() }
                .disabled(!controller.canClear)
                morphButton("Save drawing", height: rowHeight) {
                    showsContentActions = false
                    session.saveDrawing(size: size, scale: displayScale)
                } label: { Image(systemName: "square.and.arrow.down") }
                if AppReleaseFeatures.current.showsCanvasSizeControls {
                    morphButton("Canvas size", height: rowHeight) {
                        controller.cancelStroke()
                        showsContentActions = false
                        showsCanvasSize = true
                    } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                }
                morphButton("Lasso", height: rowHeight, action: onStartLasso) {
                    Image(systemName: "lasso")
                }
                morphButton("Layers", height: rowHeight) {
                    controller.cancelStroke()
                    showsContentActions = false
                    showsLayers = true
                } label: { Image(systemName: "square.3.layers.3d") }
            }
        } collapsed: {
            VStack(spacing: 0) {

                morphButton("Canvas actions", height: diameter, action: openContentActions) {
                    Image(systemName: "doc.badge.gearshape")
                }
                .accessibilityHidden(true)

            }
        }
        .frame(width: diameter)
        .modifier(CanvasMorphGlass())
        .trackCanvasControl(.contentMorph, frames: framesBinding)
    }

    private func morphToolbar(diameter: CGFloat, rowHeight: CGFloat) -> some View {
        CanvasMorphContent(isExpanded: showsMorphToolbar) {
            VStack(spacing: 0) {
                morphButton("Tool settings", height: rowHeight) {
                    showsMorphToolbar = false
                    controller.cancelStroke()
                    showsToolSettings = true
                } label: {
                    ToolIcon(instrument: controller.pencilStyle.instrument)
                        .frame(width: 18, height: 18)
                }
                .accessibilityHidden(true)
                morphButton("Undo", height: rowHeight, action: { controller.undo() }) {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(!controller.canUndo)
                morphButton("Redo", height: rowHeight, action: { controller.redo() }) {
                    Image(systemName: "arrow.uturn.forward")
                }
                .disabled(!controller.canRedo)
            }
        } collapsed: {
            VStack(spacing: 0) {
                morphButton("Open drawing controls", height: diameter) {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
                        showsContentActions = false
                        showsMorphToolbar = true
                    }
                } label: {
                    Image(systemName: "paintbrush.pointed")
                }
                .accessibilityHidden(true)

            }
        }
        .frame(width: diameter)
        .modifier(CanvasMorphGlass())
        .trackCanvasControl(.morph, frames: framesBinding)
    }

    private func lassoHistoryMorph(diameter: CGFloat, rowHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            morphButton("Done", height: rowHeight) { onFinishLasso() } label: {
                Image(systemName: "checkmark").foregroundStyle(.green)
            }
            .accessibilityHidden(true)

            morphButton("Undo", height: rowHeight) {
                onClearLayerMoveName()
                lasso.undo(controller)
            } label: { Image(systemName: "arrow.uturn.backward") }
            .disabled(!lasso.canUndo)
            .opacity(lasso.canUndo ? 1 : 0.35)
            morphButton("Redo", height: rowHeight) {
                onClearLayerMoveName()
                lasso.redo(controller)
            } label: { Image(systemName: "arrow.uturn.forward") }
            .disabled(!lasso.canRedo)
            .opacity(lasso.canRedo ? 1 : 0.35)
        }
        .frame(width: diameter)
        .modifier(CanvasMorphGlass())
        .trackCanvasControl(.morph, frames: framesBinding)
    }

    private var selectionForeground: AnyShapeStyle {
        if #available(watchOS 26, *) { return AnyShapeStyle(.primary) }
        return AnyShapeStyle(.white)
    }

    private func lassoMorph(diameter: CGFloat, panelWidth: CGFloat) -> some View {
        CanvasMorphContent(isExpanded: showsSelectionActions) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                morphButton("Move to layer above", height: diameter, intrinsicWidth: true) {
                    onMoveSelectionLayer(1)
                } label: { Image(systemName: "square.3.layers.3d.top.filled") }
                .disabled(!lasso.canMoveLayer(1, controller: controller))
                .opacity(lasso.canMoveLayer(1, controller: controller) ? 1 : 0.35)
                Spacer(minLength: 0)

                morphButton("Move to layer below", height: diameter, intrinsicWidth: true) {
                    onMoveSelectionLayer(-1)
                } label: { Image(systemName: "square.3.layers.3d.bottom.filled") }
                .disabled(!lasso.canMoveLayer(-1, controller: controller))
                .opacity(lasso.canMoveLayer(-1, controller: controller) ? 1 : 0.35)
                Spacer(minLength: 0)
                morphButton("Duplicate", height: diameter, intrinsicWidth: true) { lasso.duplicate(controller) } label: {
                    Image(systemName: "plus.square.on.square")
                }
                .disabled(lasso.bounds == nil)
                Spacer(minLength: 0)
                morphButton("Delete", height: diameter, intrinsicWidth: true) { lasso.delete(controller) } label: {
                    Image(systemName: "trash").foregroundStyle(.red)
                }
                .disabled(lasso.bounds == nil)
                Spacer(minLength: 0)
            }
        } collapsed: {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                ForEach(WatchLassoMode.allCases, id: \.self) { mode in
                    morphButton(mode.title, height: diameter, intrinsicWidth: true) { lasso.setMode(mode) } label: {
                        Image(systemName: mode.symbol)
                            .foregroundStyle(lasso.mode == mode ? AnyShapeStyle(.green) : selectionForeground)
                    }
                    .accessibilityAddTraits(lasso.mode == mode ? [.isSelected] : [])
                    Spacer(minLength: 0)

                }
            }
        }
        .frame(width: panelWidth, height: diameter)
        .modifier(CanvasMorphGlass(adaptsToCanvas: true))
        .trackCanvasControl(.canvasToolsMorph, frames: framesBinding)
    }

    private func morphButton<Label: View>(_ title: String, height: CGFloat, intrinsicWidth: Bool = false, action: @escaping () -> Void,
                                          @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            label()
                .font(.system(size: 17, weight: .semibold))
                .frame(maxWidth: intrinsicWidth ? nil : .infinity)
                .frame(height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text(title))
    }

}

/// One glass surface persists as the circle expands into a capsule.
struct CanvasMorphGlass: ViewModifier {
    var adaptsToCanvas = false
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(watchOS 26, *) {
            content
                .foregroundStyle(.primary)
                .glassEffect(.regular.interactive(), in: Capsule())
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
