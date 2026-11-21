import SwiftUI
import WatchKit

/// Presents the reference full screen. Kept out of `ContentView.body`, which is
/// already at the type checker's limit.
struct ReferencePresentation: ViewModifier {
    @Binding var isPresented: Bool
    // Not observed: the full-screen view reads the drawing only when asked to show it.
    let controller: CanvasController
    let viewportSize: CGSize

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: $isPresented) {
                ReferenceFullscreenView(controller: controller, viewportSize: viewportSize)
            }
    }
}

/// The reference as a photo opened full screen: Back returns to the thumbnail, the
/// bottom-leading circle opens its actions — the eyedropper, the canvas instead of the
/// reference and back, another gallery image, or removing the reference.
struct ReferenceFullscreenView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @ObservedObject var store = ReferenceImageStore.shared
    let controller: CanvasController
    let viewportSize: CGSize
    @AppStorage("watch.inkPalette.v1") private var paletteData = Data()
    @AppStorage("watch.inkPalettes.v2") private var palettesData = Data()
    /// The color the eyedropper took to the palette opened over the reference.
    @State private var paletteColor: SIMD4<Float>?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsCanvas = false
    /// Rendered once, on the first switch to the canvas: the drawing cannot change here.
    @State private var canvasImage: CGImage?
    @State private var choosesReplacement = false
    /// The gallery's 1:1 photo morph: the same native bottom slot, Back anchor and panel.
    @State private var morphState = GalleryMorphState()
    /// The eyedropper is sampling the picture on screen; nil when it is off.
    @State private var sample: ReferenceColorSample?
    @State private var isSampling = false
    /// A tap on the picture hides Back, the actions and the system clock, as in the gallery.
    @State private var isCleanViewing = false
    /// The canvas's Crown zoom, in only: the same detents, maximum and 100% snap. The
    /// reference and the canvas shown in its place each keep their own zoom and position,
    /// restored from the store when the cover opens again.
    @State private var referenceViewport = ReferenceImageStore.shared.viewerState.reference
    @State private var canvasViewport = ReferenceImageStore.shared.viewerState.canvas
    @State private var panOrigin: CGSize?
    /// Where the eyedropper's finger is on screen, to resample it when the zoom changes.
    @State private var sampleLocation: CGPoint?
    @FocusState private var crownFocused: Bool
    /// The viewport of the picture on screen.
    private var viewport: ReferenceViewport {
        get { showsCanvas ? canvasViewport : referenceViewport }
        nonmutating set {
            if showsCanvas { canvasViewport = newValue } else { referenceViewport = newValue }
        }
    }
    private var crownZoom: Double { viewport.crownZoom }
    private var zoom: Double { viewport.zoom }
    private var offset: CGSize { viewport.offset }

    /// The picture on screen, which the eyedropper samples.
    private var shownImage: CGImage? { showsCanvas ? canvasImage ?? store.image : store.image }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ZStack {
                    Color.black
                    picture
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: toggleCleanViewing)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            updateSample(at: value.location, size: geometry.size)
                        }, including: isSampling ? .all : .subviews)
                        // The picture moves under the finger at any zoom, as the canvas in its move mode.
                        .gesture(panGesture, including: !isSampling ? .all : .subviews)
                    if isSampling, let sample {
                        ReferenceLoupe(sample: sample, point: screenPoint(sample.point, size: geometry.size))
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .focusable(!choosesReplacement && paletteColor == nil)
                .focused($crownFocused)
                .digitalCrownRotation(detent: Binding(
                    get: { crownZoom },
                    set: { value in setCrownZoom(value, size: geometry.size) }
                // Zoom in only: the picture already fits the screen at 100%.
                ), from: 1, through: 8, by: 0.05, sensitivity: .low,
                   isContinuous: false, isHapticFeedbackEnabled: false)
                .accessibilityValue(L10n.format("Zoom %d percent", Int(zoom * 100)))
                .overlay(alignment: .bottomLeading) {
                    ReferenceMorphActions(state: morphState,
                                          canvasOrigin: geometry.frame(in: .global).origin,
                                          size: geometry.size, showsCanvas: showsCanvas,
                                          onEyedropper: { startSampling(size: geometry.size) },
                                          onToggleCanvas: toggleCanvas,
                                          onReplace: { choosesReplacement = true },
                                          // Nothing left to remove once the image is gone.
                                          onRemove: store.image == nil ? nil : { store.remove() })
                        .opacity(isSampling || isCleanViewing ? 0 : 1)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: isCleanViewing)
                        .allowsHitTesting(!isSampling && !isCleanViewing)
                        .accessibilityHidden(isSampling || isCleanViewing)
                }
            }
            .ignoresSafeArea()
            .toolbar {
                // The cover's own dismiss slot: a leading item of its own would sit beside
                // the system close button instead of replacing it.
                ToolbarItem(placement: .cancellationAction) { backButton }
                // Always installed: balancing Back centers the system clock, as in the gallery
                // and on the canvas. Outside the eyedropper the slot is empty and inert.
                ToolbarItem(placement: .topBarTrailing) { confirmButton }
                if !isSampling {
                    ToolbarItemGroup(placement: .bottomBar) {
                        GalleryMorphToolbarButton(state: morphState)
                            .disabled(isCleanViewing)
                            .accessibilityHidden(isCleanViewing)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        // Over the reference, not pushed onto its stack: a pop back relays out this page's
        // toolbar mid-transition, so Back and the "⋯" slot drew with other insets and then
        // jumped into place. Under a cover the page and its toolbar stay where they are.
        .fullScreenCover(isPresented: $choosesReplacement) {
            NavigationStack {
                ReferencePickerView {
                    canvasImage = nil
                    showsCanvas = false
                    referenceViewport = ReferenceViewport()
                }
            }
        }
        // The canvas under the cover gives up the Crown; take it here, and again on
        // coming back from the replacement picker or the palette. watchOS 10 can drop focus
        // requested in the same update that installs the target, so wait for it as the canvas does.
        .task(id: choosesReplacement || paletteColor != nil) {
            crownFocused = false
            guard !choosesReplacement, paletteColor == nil else { return }
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            crownFocused = true
        }
        .onChange(of: store.image == nil) { _, removed in
            if removed { dismiss() }
        }
        .onAppear(perform: restoreCanvasViewport)
        // Kept for the next opening; the store resets the reference's on a new image.
        .onChange(of: referenceViewport) { _, viewport in store.viewerState.reference = viewport }
        .onChange(of: canvasViewport) { _, viewport in store.viewerState.canvas = viewport }
        // A full-screen cover is outside the app root's clock host, so it brings its own,
        // like the canvas editor.
        .requestsHiddenClock(isCleanViewing)
        .modifier(ClockVisibilityHost())
        // The sampled color goes to the palette as on the canvas, and saving it comes back
        // to this reference, whether it was opened from the canvas or from settings.
        .fullScreenCover(isPresented: Binding(get: { paletteColor != nil },
                                              set: { if !$0 { paletteColor = nil } })) {
            InkPaletteBrowser(library: InkPaletteLibrary.decode(palettesData, legacy: paletteData),
                              controller: controller, initialColor: paletteColor) { library in
                if let data = try? JSONEncoder().encode(library) { palettesData = data }
                // The color just picked is in the active palette, so it stays current.
                if !library.activePalette.selectedColors.contains(where: { $0.rgba == controller.drawingColor }),
                   let first = library.activePalette.selectedColors.first {
                    controller.setDrawingColor(first.rgba)
                }
            }
            .environment(\.colorScheme, .dark)
        }
    }

    /// The gallery's clean viewing: a tap folds the actions and hides or shows the chrome.
    private func toggleCleanViewing() {
        guard !isSampling else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
            morphState.isExpanded = false
        }
        isCleanViewing.toggle()
    }

    @ViewBuilder private var picture: some View {
        ZStack {
            if let image = store.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(referenceViewport.zoom)
                    .offset(referenceViewport.offset)
                    .opacity(showsCanvas && canvasImage != nil ? 0 : 1)
                    .accessibilityLabel(L10n.text("Reference image"))
            }
            if let canvasImage {
                Image(decorative: canvasImage, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(canvasViewport.zoom)
                    .offset(canvasViewport.offset)
                    .opacity(showsCanvas ? 1 : 0)
                    .accessibilityHidden(!showsCanvas)
            }
        }
        .animation(.easeInOut(duration: reduceMotion ? 0.1 : 0.25), value: showsCanvas)
    }

    /// Back, or the eyedropper's ✕ while it samples: the same slot, as on the canvas.
    private var backButton: some View {
        // Same hidden-chrome slot and glass circle as the gallery's photo Back.
        Button {
            if isSampling { stopSampling() } else { dismiss() }
        } label: {
            Image(systemName: "chevron.left").opacity(0)
        }
        .watchToolbarButtonStyle(diameter: GalleryMorphState.toolbarDiameter, hidesNativeChrome: true)
        .overlay {
            Image(systemName: isSampling ? "xmark" : "chevron.left")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .contentTransition(.opacity)
                .frame(width: GalleryMorphState.buttonDiameter, height: GalleryMorphState.buttonDiameter)
                .modifier(CanvasMorphGlass(adaptsToCanvas: true))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .disabled(isCleanViewing)
        .opacity(isCleanViewing ? 0 : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: isCleanViewing)
        .allowsHitTesting(!isCleanViewing)
        .accessibilityHidden(isCleanViewing)
        .accessibilityLabel(L10n.text(isSampling ? "Cancel" : "Back"))
        // The actions panel lines up under Back, as in the gallery.
        .onGeometryChange(for: CGRect.self) { geometry in
            geometry.frame(in: .global)
        } action: { frame in
            if morphState.backButtonFrame != frame { morphState.backButtonFrame = frame }
        }
    }

    /// The canvas eyedropper's green ✓: takes the sampled color to the palette over the reference.
    private var confirmButton: some View {
        Button {
            guard let color = sample?.color else { return }
            stopSampling()
            paletteColor = color
        } label: {
            Image(systemName: "checkmark").opacity(0)
        }
        .disabled(!isSampling || sample == nil)
        .watchToolbarButtonStyle(diameter: GalleryMorphState.toolbarDiameter, hidesNativeChrome: true)
        .overlay {
            Image(systemName: "checkmark")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.green)
                .frame(width: GalleryMorphState.buttonDiameter, height: GalleryMorphState.buttonDiameter)
                .modifier(CanvasMorphGlass(adaptsToCanvas: true))
                .opacity(sample == nil ? 0.45 : 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .opacity(isSampling ? 1 : 0)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isSampling)
        .allowsHitTesting(isSampling)
        .accessibilityHidden(!isSampling)
        .accessibilityLabel(L10n.text("Done"))
    }

    /// The canvas's Crown zoom about the screen center: the 100% snap clicks, and the
    /// picture keeps its offset there.
    private func setCrownZoom(_ value: Double, size: CGSize) {
        guard panOrigin == nil, value != crownZoom else { return }
        var next = viewport
        let previousZoom = next.zoom
        let wasSnapped = previousZoom == 1
        next.crownZoom = value
        if next.zoom == 1 && !wasSnapped { WKInterfaceDevice.current().play(.click) }
        // Keep the picture point at the screen center fixed, at 100% too: the Crown limits
        // only the zoom, so the picture stays where it was moved.
        let ratio = next.zoom / previousZoom
        next.offset = CGSize(width: next.offset.width * ratio, height: next.offset.height * ratio)
        viewport = next
        if isSampling, let sampleLocation { updateSample(at: sampleLocation, size: size) }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if panOrigin == nil { panOrigin = offset }
                let origin = panOrigin ?? offset
                let proposed = CGSize(width: origin.width + value.translation.width,
                                      height: origin.height + value.translation.height)
                // The canvas's centering magnet, in screen points.
                let wasCentered = offset == .zero
                let isCentered = hypot(proposed.width, proposed.height) <= (wasCentered ? 12 : 8)
                viewport.offset = isCentered ? .zero : proposed
                if isCentered && !wasCentered { WKInterfaceDevice.current().play(.click) }
            }
            .onEnded { _ in panOrigin = nil }
    }

    /// A screen point in the unzoomed, scaled-to-fit frame the eyedropper samples.
    private func fittedPoint(_ point: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: (point.x - size.width / 2 - offset.width) / zoom + size.width / 2,
                y: (point.y - size.height / 2 - offset.height) / zoom + size.height / 2)
    }

    private func screenPoint(_ point: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: (point.x - size.width / 2) * zoom + size.width / 2 + offset.width,
                y: (point.y - size.height / 2) * zoom + size.height / 2 + offset.height)
    }

    private func startSampling(size: CGSize) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
            morphState.isExpanded = false
        }
        isCleanViewing = false
        isSampling = true
        // Starts at the center, like the canvas eyedropper.
        updateSample(at: CGPoint(x: size.width / 2, y: size.height / 2), size: size)
    }

    private func stopSampling() {
        isSampling = false
        sample = nil
        sampleLocation = nil
    }

    private func updateSample(at location: CGPoint, size: CGSize) {
        guard isSampling, let image = shownImage else { return }
        sampleLocation = location
        sample = ReferenceColorSample(image: image, location: fittedPoint(location, size: size), frame: size) ?? sample
    }

    /// Another drawing size makes the saved canvas zoom meaningless: start it over.
    private func restoreCanvasViewport() {
        let size = controller.document.size(fallback: viewportSize)
        guard store.viewerState.canvasSize != size else { return }
        store.viewerState.canvasSize = size
        canvasViewport = ReferenceViewport()
    }

    private func toggleCanvas() {
        if !showsCanvas && canvasImage == nil {
            let document = controller.document
            let size = document.size(fallback: viewportSize)
            // Screen resolution is enough to look at: a large canvas is not rendered at full size.
            let screenSide = max(viewportSize.width, viewportSize.height) * displayScale
            let scale = min(displayScale, screenSide / max(1, max(size.width, size.height)))
            guard size.width > 0, size.height > 0, scale > 0,
                  let rendered = WatchBitmapRenderer.render(document: document, size: size, scale: scale)
            else { return UnavailableActionFeedback.play() }
            canvasImage = rendered
        }
        showsCanvas.toggle()
    }
}

/// The reference's actions as the gallery's 1:1 photo panel (`GalleryMorphActions`):
/// the ellipsis sits on the native bottom slot under Back and expands to the trailing side
/// into Close, eyedropper, show canvas / reference, replace and remove.
private struct ReferenceMorphActions: View {
    let state: GalleryMorphState
    let canvasOrigin: CGPoint
    let size: CGSize
    let showsCanvas: Bool
    /// Nil when the eyedropper is not offered.
    let onEyedropper: (() -> Void)?
    let onToggleCanvas: () -> Void
    let onReplace: () -> Void
    /// Nil when there is no reference image left to remove.
    let onRemove: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Same geometry as the gallery: the native slot's height, Back's horizontal center,
        // and a panel as wide as the gallery's with equal screen-edge insets.
        let anchor = state.toolbarFrame.flatMap { frame -> CGPoint? in
            guard !frame.isEmpty else { return nil }
            return CGPoint(x: frame.midX - canvasOrigin.x, y: frame.midY - canvasOrigin.y)
        } ?? CGPoint(x: 30, y: size.height - 26)
        let diameter = GalleryMorphState.buttonDiameter
        let centerX = state.backButtonFrame.map { $0.midX - canvasOrigin.x } ?? anchor.x
        let left = centerX - diameter / 2
        // Close, show canvas and replace, plus the optional eyedropper and remove.
        let cellCount = 3 + (onEyedropper == nil ? 0 : 1) + (onRemove == nil ? 0 : 1)
        let expandedWidth = min(36 * CGFloat(cellCount), max(0, size.width - left * 2))
        let panelWidth = state.isExpanded ? expandedWidth : diameter
        panel(expandedWidth: expandedWidth)
            .position(x: left + panelWidth / 2, y: anchor.y)
    }

    private func toggle() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
            state.isExpanded.toggle()
        }
    }

    private func collapse() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
            state.isExpanded = false
        }
    }

    private func panel(expandedWidth: CGFloat) -> some View {
        CanvasMorphContent(isExpanded: state.isExpanded) {
            HStack(spacing: 0) {
                // Equal cells without spacers, as in the gallery: every point of the
                // interactive capsule belongs to the nearest action.
                Button(action: toggle) { icon("xmark", width: nil) }
                    .accessibilityLabel(L10n.text("Close"))
                if let onEyedropper {
                    Button(action: onEyedropper) { icon("eyedropper", width: nil) }
                        .accessibilityLabel(L10n.text("Eyedropper"))
                }
                // One icon in both states; green marks the canvas on screen, as the
                // canvas toolbar marks its active eyedropper.
                Button(action: onToggleCanvas) {
                    icon("square.on.square", width: nil)
                        .foregroundStyle(showsCanvas ? AnyShapeStyle(.green) : AnyShapeStyle(.primary))
                }
                .accessibilityLabel(L10n.text("Show canvas"))
                .accessibilityAddTraits(showsCanvas ? [.isSelected] : [])
                Button {
                    collapse()
                    onReplace()
                } label: {
                    // The same symbol as Choose image in the reference settings.
                    icon("photo.on.rectangle", width: nil)
                }
                .accessibilityLabel(L10n.text("Replace image"))
                if let onRemove {
                    Button(role: .destructive, action: onRemove) { icon("trash", width: nil) }
                        .accessibilityLabel(L10n.text("Remove image"))
                }
            }
            .frame(width: expandedWidth, height: GalleryMorphState.buttonDiameter)
        } collapsed: {
            Button(action: toggle) { icon("ellipsis", width: GalleryMorphState.buttonDiameter) }
                // The native bottom slot above it carries the label and the taps.
                .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .fixedSize()
        .modifier(GalleryMorphGlass())
    }

    /// `width: nil` fills an equal share of the expanded panel.
    private func icon(_ symbol: String, width: CGFloat?) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .medium))
            .frame(width: width, height: GalleryMorphState.buttonDiameter)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .contentShape(Rectangle())
    }
}

/// One eyedropper reading of a picture shown scaled to fit: the pixel under the finger,
/// its color, and the canvas eyedropper's 11 × 11 lens crop centered on it. Locations are
/// in the unzoomed frame; the view maps the Crown zoom in and out.
struct ReferenceColorSample {
    let color: SIMD4<Float>
    let lens: CGImage
    /// Center of the sampled pixel in the unzoomed frame.
    let point: CGPoint

    init?(image: CGImage, location: CGPoint, frame: CGSize) {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        guard width > 0, height > 0, frame.width > 0, frame.height > 0 else { return nil }
        // Points per pixel and the picture's rectangle inside the frame (scaledToFit).
        let fit = min(frame.width / width, frame.height / height)
        let origin = CGPoint(x: (frame.width - width * fit) / 2, y: (frame.height - height * fit) / 2)
        // Dragging beyond the picture keeps sampling its nearest edge pixel.
        let x = min(image.width - 1, max(0, Int(floor((location.x - origin.x) / fit))))
        let y = min(image.height - 1, max(0, Int(floor((location.y - origin.y) / fit))))
        point = CGPoint(x: origin.x + (CGFloat(x) + 0.5) * fit, y: origin.y + (CGFloat(y) + 0.5) * fit)

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        var rgba = [UInt8](repeating: 0, count: 4)
        let sampled = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            // Transparent pixels read as black over the cover's black backdrop.
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard sampled else { return nil }
        color = SIMD4(Float(rgba[0]) / 255, Float(rgba[1]) / 255, Float(rgba[2]) / 255, 1)

        guard let context = CGContext(data: nil, width: 11, height: 11, bitsPerComponent: 8,
            bytesPerRow: 44, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 0.16, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 11, height: 11))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: CGFloat(5 - x), y: CGFloat(5 - (image.height - 1 - y)),
                                       width: width, height: height))
        guard let lens = context.makeImage() else { return nil }
        self.lens = lens
    }
}

/// The canvas eyedropper's lens: 88 pt, white ring and the center pixel's frame.
private struct ReferenceLoupe: View {
    let sample: ReferenceColorSample
    /// The sampled pixel's center on screen, under the zoom.
    let point: CGPoint

    var body: some View {
        Image(decorative: sample.lens, scale: 1)
            .resizable().interpolation(.none)
            .frame(width: 88, height: 88)
            .clipShape(Circle())
            .overlay { Circle().strokeBorder(.white, lineWidth: 3) }
            .compositingGroup()
            .shadow(color: .black.opacity(0.4), radius: 3, x: 0, y: 0)
            .overlay {
                Rectangle().stroke(.black, lineWidth: 3).frame(width: 8, height: 8)
                    .overlay { Rectangle().stroke(.white, lineWidth: 1).frame(width: 8, height: 8) }
            }
            .position(point)
            .allowsHitTesting(false)
    }
}
