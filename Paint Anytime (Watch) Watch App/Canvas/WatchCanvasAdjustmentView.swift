import SwiftUI

/// Canvas size: one page that turns, resizes and places the drawing.
/// Draft values stay local until Apply, so leaving the page keeps the drawing intact.
struct WatchCanvasAdjustmentView: View {
    @ObservedObject var controller: CanvasController
    let viewportSize: CGSize
    let displayScale: CGFloat
    @Environment(\.dismiss) private var dismiss
    @State private var width: Double = 1
    @State private var height: Double = 1
    @State private var resolution: Double = 72
    @State private var proportional = true
    @State private var resample = true
    /// Where the drawing sits when the canvas changes size without resampling, in percent:
    /// 0 keeps the leading or top edge, 100 the trailing or bottom one.
    @State private var positionX = 50.0
    @State private var positionY = 50.0
    /// The position at the start of a drag, so translation stays relative to it.
    @State private var dragStartPosition: CGPoint?
    /// Set while the preview itself is being dragged, so the page-switch swipe below yields.
    @State private var isDraggingFrame = false
    /// Unbounded quarter-turn count, clockwise, so the preview always animates the short way.
    @State private var rotationSteps = 0
    private var turns: Int { ((rotationSteps % 4) + 4) % 4 }
    @ObservedObject var tutorial = TutorialSession.inactive
    /// The tutorial hosts this page itself, so Apply must not dismiss its presentation.
    var onApplied: (() -> Void)? = nil
    @Environment(\.tutorialHintReservedHeight) private var tutorialHintReservedHeight
    @FocusState private var focusedAdjustment: String?
    @State private var preview: CGImage?
    @State private var resizePage = 0
    @State private var resizePercent = 100.0
    @State private var initialized = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection

    /// The tutorial's page stays on screen while ✓ returns to the canvas; it keeps the size it
    /// was adjusted from, or the whole page re-laid out around the new, smaller canvas.
    @State private var appliedOriginal: CGSize?
    private var original: CGSize { appliedOriginal ?? controller.document.size(fallback: viewportSize) }
    /// The canvas after the chosen turns; size and position apply to it.
    private var turned: CGSize {
        turns % 2 == 0 ? original : CGSize(width: original.height, height: original.width)
    }
    private var ratio: Double { turned.width / turned.height }
    private var maximumPixels: Double { Double(PhotoImportProtocol.maximumCanvasPixelSide) }
    private var validSize: Bool {
        width >= 1 && height >= 1 && width <= maximumPixels && height <= maximumPixels
    }
    private var targetSize: CGSize { CGSize(width: width / displayScale, height: height / displayScale) }
    /// The new canvas's top-left corner in the turned canvas's points; negative where it grows.
    private var targetOrigin: CGPoint {
        guard !resample else { return .zero }
        return CGPoint(x: (turned.width - targetSize.width) * positionX / 100,
                       y: (turned.height - targetSize.height) * positionY / 100)
    }

    var body: some View {
        GeometryReader { geometry in
            editor(height: geometry.size.height)
        }
        // The value row and carousel stay above the tutorial's lesson card.
        .padding(.bottom, tutorial.isActive ? tutorialHintReservedHeight : 0)
        // A new lesson card changes its height; the page follows it instead of jumping.
        .animation(tutorial.isActive && !reduceMotion ? .easeInOut(duration: 0.3) : nil,
                   value: tutorialHintReservedHeight)
        .toolbar {
            if tutorial.isActive {
                // The page has no Back in the tour; an empty leading slot keeps the clock
                // centred, where the editor's Back leaves it, instead of at the edge.
                ToolbarItem(placement: .topBarLeading) {
                    Button {} label: { Image(systemName: "chevron.backward").opacity(0) }
                        .disabled(true)
                        .watchToolbarButtonStyle(hidesNativeChrome: true)
                        .accessibilityHidden(true)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: applyChanges) {
                    Image(systemName: "checkmark").foregroundStyle(.green)
                        .tutorialHint(tutorial, steps: [.applyCanvasSize])
                }
                .watchToolbarButtonStyle()
                .disabled(!validSize || !tutorial.permits([.applyCanvasSize]))
                .accessibilityLabel(L10n.text("Apply"))
                .accessibilityHint(!validSize ? L10n.text("Choose dimensions from 1 to 2048 pixels.") : "")
            }
        }
        .ignoresSafeArea()
        .task {
            guard !initialized else { return }
            initialized = true
            preview = WatchBitmapRenderer.render(document: controller.document, size: original,
                scale: min(1, 160 / max(original.width, original.height)))
            width = (original.width * displayScale).rounded()
            height = (original.height * displayScale).rounded()
            resolution = controller.document.resolution
            if tutorial.isActive {
                // The tour keeps the drawing's size and starts slightly smaller, so the
                // frame can always move and the Crown only shrinks it further.
                resample = false
                resizePercent = 90
                width = max(1, (original.width * displayScale * 0.9).rounded())
                height = max(1, (original.height * displayScale * 0.9).rounded())
            }
            focusedAdjustment = "Resize"
        }
    }

    /// The drawing at the chosen turn, laid out in `size`, the turned frame it fills.
    private func turnedImage(_ preview: CGImage, size: CGSize, scale: CGFloat) -> some View {
        let unturned = turns % 2 == 0 ? size : CGSize(width: size.height, height: size.width)
        return Image(decorative: preview, scale: 1).resizable()
            .frame(width: unturned.width * scale, height: unturned.height * scale)
            .rotationEffect(.degrees(Double(rotationSteps * 90)))
            .frame(width: size.width * scale, height: size.height * scale)
    }

    private var canvasPreview: some View {
        GeometryReader { geometry in
            let target = targetSize
            let bounds = CGSize(width: max(turned.width, target.width), height: max(turned.height, target.height))
            let scale = min(geometry.size.width / max(1, bounds.width),
                            geometry.size.height / max(1, bounds.height))
            ZStack {
                if resample {
                    ZStack {
                        Rectangle().fill(.gray.opacity(0.3))
                        if let preview { turnedImage(preview, size: target, scale: scale) }
                    }
                    .frame(width: target.width * scale, height: target.height * scale)
                    .overlay(Rectangle().stroke(.white.opacity(0.5), lineWidth: 0.5))
                    .overlay { sizeLabel }
                } else {
                    positionedPreview(target: target, bounds: bounds, scale: scale)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("Canvas size"))
        .accessibilityValue(Text(verbatim: "\(Int(width)) × \(Int(height)) px, \(Int(resolution)) DPI"))
    }

    /// The new size, centred on the canvas it describes.
    private var sizeLabel: some View {
        VStack(spacing: 0) {
            Text(verbatim: "\(Int(width)) × \(Int(height)) px")
            Text(verbatim: "\(Int(resolution)) DPI")
        }
        .font(.system(size: 11, weight: .semibold)).monospacedDigit()
        .foregroundStyle(validSize ? Color.white : .orange)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 5))
        .allowsHitTesting(false)
    }

    /// Without resampling the whole drawing stays visible, dimmed where the new canvas
    /// leaves it out. A drag moves whichever is smaller on each axis: the canvas frame
    /// over the drawing, or the drawing inside the larger canvas.
    private func positionedPreview(target: CGSize, bounds: CGSize, scale: CGFloat) -> some View {
        let origin = targetOrigin
        let image = CGPoint(x: -min(0, origin.x), y: -min(0, origin.y))
        let canvas = CGPoint(x: origin.x + image.x, y: origin.y + image.y)
        // Room the drawing and the canvas can move against each other, in canvas points.
        let roomX = abs(turned.width - target.width)
        let roomY = abs(turned.height - target.height)
        return ZStack(alignment: .topLeading) {
            if let preview {
                turnedImage(preview, size: turned, scale: scale)
                    .opacity(0.35)
                    .offset(x: image.x * scale, y: image.y * scale)
            }
            ZStack(alignment: .topLeading) {
                Rectangle().fill(.gray.opacity(0.3))
                if let preview {
                    turnedImage(preview, size: turned, scale: scale)
                        .offset(x: (image.x - canvas.x) * scale, y: (image.y - canvas.y) * scale)
                }
            }
            .frame(width: target.width * scale, height: target.height * scale, alignment: .topLeading)
            .clipped()
            .overlay(Rectangle().stroke(.green, lineWidth: 1.5))
            .overlay {
                if !(tutorial.isActive && tutorial.step == .moveCanvasFrame) { sizeLabel }
            }
            .offset(x: canvas.x * scale, y: canvas.y * scale)
            if tutorial.isActive && tutorial.step == .moveCanvasFrame {
                // From the frame's centre, a short way inside the preview.
                TutorialMoveGuide(distance: min(10, max(4, min(roomX, roomY) * scale / 2)),
                                  isHidden: isDraggingFrame)
                    .position(x: (canvas.x + target.width / 2) * scale,
                              y: (canvas.y + target.height / 2) * scale)
                    .transition(.opacity)
            }
        }
        .frame(width: bounds.width * scale, height: bounds.height * scale, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    isDraggingFrame = true
                    let start = dragStartPosition ?? CGPoint(x: positionX, y: positionY)
                    if dragStartPosition == nil { dragStartPosition = start }
                    // The frame or the drawing follows the finger on either axis.
                    if roomX > 0 {
                        positionX = min(100, max(0, start.x + value.translation.width / scale / roomX * 100)).rounded()
                    }
                    if roomY > 0 {
                        positionY = min(100, max(0, start.y + value.translation.height / scale / roomY * 100)).rounded()
                    }
                }
                .onEnded { value in
                    isDraggingFrame = false
                    dragStartPosition = nil
                    if hypot(value.translation.width, value.translation.height) > 4 {
                        tutorial.record(.movedCanvasFrame)
                    }
                }
        )
    }

    /// Turns the canvas a quarter to the left; width and height trade places, and so do
    /// the position values, which follow the drawing's own edges.
    private func rotateLeft() {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
            rotationSteps -= 1
            (width, height) = (height, width)
            (positionX, positionY) = (positionY, 100 - positionX)
        }
        focusedAdjustment = "Resize"
    }

    private func applyChanges() {
        guard validSize else { return }
        if tutorial.isActive { appliedOriginal = original }
        controller.adjustCanvas(from: original, to: targetSize, resample: resample,
                                origin: targetOrigin, quarterTurns: turns, resolution: resolution)
        // Apply completes the lesson even unchanged, so the tour never waits on this page.
        tutorial.record(.resizedCanvas)
        if let onApplied { onApplied() } else { dismiss() }
    }

    /// Horizontal and Vertical place the drawing only when it keeps its size.
    private var resizeTitles: [String] {
        let titles = ["Percentage", "Canvas width", "Height", "Resolution"]
        return resample ? titles : titles + ["Horizontal", "Vertical"]
    }

    private var resizeTitle: String { resizeTitles[min(resizePage, resizeTitles.count - 1)] }

    private var resizeRange: ClosedRange<Double> {
        switch resizePage {
        case 0:
            // The tour starts at 90% and only shrinks further, so the frame can always move.
            if tutorial.isActive { return 10...90 }
            let largest = max(turned.width, turned.height) * displayScale
            return 1...max(1, floor(maximumPixels / max(1, largest) * 100))
        case 3: return 18...300
        case 4, 5: return 0...100
        default: return 1...maximumPixels
        }
    }

    private var resizeValue: Binding<Double> {
        Binding(get: {
            switch resizePage {
            case 0: resizePercent
            case 1: width
            case 2: height
            case 3: resolution
            case 4: positionX
            default: positionY
            }
        }, set: { next in
            let value = min(resizeRange.upperBound, max(resizeRange.lowerBound, next.rounded()))
            switch resizePage {
            case 0:
                // The first change completes the lesson's step; a page swipe never counts.
                if value != resizePercent { tutorial.record(.changedCanvasSize) }
                resizePercent = value
                width = max(1, (turned.width * displayScale * value / 100).rounded())
                height = max(1, (turned.height * displayScale * value / 100).rounded())
            case 1:
                width = value
                if proportional { height = max(1, (value / ratio).rounded()) }
                resizePercent = width / max(1, turned.width * displayScale) * 100
            case 2:
                height = value
                if proportional { width = max(1, (value * ratio).rounded()) }
                resizePercent = height / max(1, turned.height * displayScale) * 100
            case 3:
                if resample {
                    width = max(1, (width * value / resolution).rounded())
                    height = max(1, (height * value / resolution).rounded())
                    resizePercent = width / max(1, turned.width * displayScale) * 100
                }
                resolution = value
            case 4: positionX = value
            default: positionY = value
            }
        })
    }

    private var resizeValueTitle: String {
        switch resizePage {
        case 0: return L10n.percent(resizePercent / 100)
        case 4: return L10n.percent(positionX / 100)
        case 5: return L10n.percent(positionY / 100)
        default: return "\(Int(resizeValue.wrappedValue)) " + (resizePage == 3 ? "DPI" : "px")
        }
    }

    private func editor(height availableHeight: CGFloat) -> some View {
        VStack(spacing: 4) {
            // Options stand beside the preview, as the presets do in perspective guides.
            HStack(spacing: 8) {
                canvasPreview
                // The tour teaches only the size and the frame; the options stay as set.
                VStack(spacing: 0) {
                    roundButton("Scale proportionally", symbol: "link", isOn: proportional,
                                isSlashed: !proportional) { proportional.toggle() }
                        .frame(maxHeight: .infinity)
                    roundButton("Resample image", symbol: "arrow.up.left.and.arrow.down.right",
                                isOn: resample) { resample.toggle() }
                        .frame(maxHeight: .infinity)
                    roundButton("Rotate", symbol: "rotate.left", isOn: false, action: rotateLeft)
                        .frame(maxHeight: .infinity)
                }
                .disabled(tutorial.isActive)
                // Clear the toolbar's checkmark, which overlaps the top of this column.
                .padding(.top, 26)
                .frame(width: 48)
            }
            .frame(maxHeight: .infinity)
            valueRow(value: resizeValue, range: resizeRange, valueTitle: resizeValueTitle,
                     title: resizeTitle, focus: "Resize")
            if !tutorial.isActive {
                CanvasResizeCarousel(selection: $resizePage, titles: resizeTitles)
                    .frame(height: 28)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: tutorial.step == .moveCanvasFrame)
        .padding(.horizontal, 10)
        .padding(.top, 42)
        .padding(.bottom, 8)
        .frame(height: availableHeight)
        .contentShape(Rectangle())
        .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { value in
            // A drag that moved the frame itself must not also flip the page.
            guard !isDraggingFrame, !tutorial.isActive else { return }
            guard abs(value.translation.width) > abs(value.translation.height) else { return }
            let forward = (value.translation.width < 0) == (layoutDirection == .leftToRight)
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                resizePage = min(resizeTitles.count - 1, max(0, resizePage + (forward ? 1 : -1)))
            }
        })
        .focusable()
        .focused($focusedAdjustment, equals: "Resize")
        .modifier(SteppedCrownModifier(value: resizeValue, range: resizeRange,
                                      sensitivity: .low, crownUnitsPerStep: 1, context: resizePage,
                                      onChange: { [step = tutorial.step] event in
                                          // Hides the Crown hint once the user turns it.
                                          tutorial.usedCrown(in: step, velocity: event.velocity)
                                      }))
        .onChange(of: resizePage) { _, _ in focusedAdjustment = "Resize" }
        // Resampling drops the position pages; the carousel falls back to the last one left.
        .onChange(of: resample) { _, _ in
            resizePage = min(resizePage, resizeTitles.count - 1)
        }
    }

    /// A horizontal − value + row above the carousel, as in perspective guides.
    private func valueRow(value: Binding<Double>, range: ClosedRange<Double>, valueTitle: String,
                          title: String, focus: String) -> some View {
        HStack(spacing: 4) {
            stepButton("minus", by: -1, value: value, range: range, title: title, focus: focus)
            Text(verbatim: valueTitle)
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(L10n.text(title))
                .accessibilityValue(valueTitle)
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: value.wrappedValue += 1
                    case .decrement: value.wrappedValue -= 1
                    @unknown default: break
                    }
                }
            stepButton("plus", by: 1, value: value, range: range, title: title, focus: focus)
        }
        .environment(\.layoutDirection, .leftToRight)
        .frame(height: 28)
    }

    private func stepButton(_ symbol: String, by delta: Double, value: Binding<Double>,
                            range: ClosedRange<Double>, title: String, focus: String) -> some View {
        Button {
            value.wrappedValue += delta
            focusedAdjustment = focus
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
        .disabled(!range.contains(value.wrappedValue + delta))
        .accessibilityLabel(L10n.text(title) + (delta > 0 ? " +1" : " −1"))
    }


    /// The same round button as the perspective guide presets; filled while its option is on.
    private func roundButton(_ title: String, symbol: String, isOn: Bool, isSlashed: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                // SF Symbols has no "link.slash"; cut a gap and draw the slash like system slash symbols.
                .mask {
                    Rectangle()
                        .overlay {
                            if isSlashed {
                                Capsule().frame(width: 5, height: 24).rotationEffect(.degrees(-45))
                                    .blendMode(.destinationOut)
                            }
                        }
                        .compositingGroup()
                }
                .overlay {
                    if isSlashed {
                        Capsule().frame(width: 1.75, height: 20).rotationEffect(.degrees(-45))
                    }
                }
                .foregroundStyle(isOn ? Color.black : Color.white)
                .frame(width: 28, height: 28)
                .background {
                    Circle().fill(isOn ? Color.accentColor : Color.white.opacity(0.12))
                }
                .overlay {
                    Circle().strokeBorder(isOn ? Color.accentColor : Color.white.opacity(0.35), lineWidth: 1.5)
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text(title))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
