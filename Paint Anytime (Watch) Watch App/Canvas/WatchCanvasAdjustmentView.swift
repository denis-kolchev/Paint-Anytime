import SwiftUI

/// Draft values stay local until Apply, so dismissing the sheet leaves the drawing intact.
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
    /// Unbounded quarter-turn count so the preview always animates the short way.
    @State private var rotationSteps = 0
    private var turns: Int { ((rotationSteps % 4) + 4) % 4 }
    let mode: Int
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
    private var ratio: Double { original.width / original.height }
    private var maximumPixels: Double { 1024 }
    private var validSize: Bool {
        width >= 1 && height >= 1 && width <= maximumPixels && height <= maximumPixels
    }
    private var targetSize: CGSize { CGSize(width: width / displayScale, height: height / displayScale) }
    /// The new canvas's top-left corner in the old canvas's points; negative where it grows.
    private var targetOrigin: CGPoint {
        guard !resample else { return .zero }
        return CGPoint(x: (original.width - targetSize.width) * positionX / 100,
                       y: (original.height - targetSize.height) * positionY / 100)
    }

    var body: some View {
        GeometryReader { geometry in
            Group {
                if mode == 0 {
                    resizeEditor(height: geometry.size.height)
                } else {
                    rotateEditor(height: geometry.size.height)
                }
            }
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
                .disabled((mode == 0 && !validSize) || !tutorial.permits([.applyCanvasSize]))
                .accessibilityLabel(L10n.text("Apply"))
                .accessibilityHint(mode == 0 && !validSize
                    ? L10n.text("Choose dimensions from 1 to 1024 pixels.") : "")
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
            if mode == 0 && tutorial.isActive {
                // The tour keeps the drawing's size and starts slightly smaller, so the
                // frame can always move and the Crown only shrinks it further.
                resample = false
                resizePercent = 90
                width = max(1, (original.width * displayScale * 0.9).rounded())
                height = max(1, (original.height * displayScale * 0.9).rounded())
            }
            focusedAdjustment = mode == 0 ? "Resize" : nil
        }
    }

    private func canvasPreview(mode: Int) -> some View {
        GeometryReader { geometry in
            let target = mode == 0
                ? targetSize
                : turns % 2 != 0 ? CGSize(width: original.height, height: original.width) : original
            let previewBounds = mode == 0
                ? CGSize(width: max(original.width, target.width), height: max(original.height, target.height))
                : target
            let scale = min(geometry.size.width / max(1, previewBounds.width),
                            geometry.size.height / max(1, previewBounds.height))
            ZStack {
                if mode == 0 && !resample {
                    positionedPreview(target: target, bounds: previewBounds, scale: scale)
                } else {
                    // Rotate draws the bare image: the frame swaps its aspect while the
                    // image turns, so a background, clip or border would show mid-animation.
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(.gray.opacity(mode == 2 ? 0 : 0.3))
                        if let preview {
                            Image(decorative: preview, scale: 1).resizable()
                                .frame(width: (mode == 0 ? target.width : original.width) * scale,
                                       height: (mode == 0 ? target.height : original.height) * scale)
                                .rotationEffect(.degrees(mode == 2 ? Double(rotationSteps * 90) : 0))
                                .frame(width: target.width * scale, height: target.height * scale)
                        }
                    }
                    .frame(width: target.width * scale, height: target.height * scale)
                    .modifier(PreviewClip(isEnabled: mode != 2))
                    .overlay(Rectangle().stroke(.white.opacity(mode == 2 ? 0 : 0.5), lineWidth: 0.5))
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityLabel(L10n.text("Canvas size"))
    }

    /// Without resampling the whole drawing stays visible, dimmed where the new canvas
    /// leaves it out. A drag moves whichever is smaller on each axis: the canvas frame
    /// over the drawing, or the drawing inside the larger canvas.
    private func positionedPreview(target: CGSize, bounds: CGSize, scale: CGFloat) -> some View {
        let origin = targetOrigin
        let image = CGPoint(x: -min(0, origin.x), y: -min(0, origin.y))
        let canvas = CGPoint(x: origin.x + image.x, y: origin.y + image.y)
        // Room the drawing and the canvas can move against each other, in canvas points.
        let roomX = abs(original.width - target.width)
        let roomY = abs(original.height - target.height)
        return ZStack(alignment: .topLeading) {
            if let preview {
                Image(decorative: preview, scale: 1).resizable()
                    .frame(width: original.width * scale, height: original.height * scale)
                    .opacity(0.35)
                    .offset(x: image.x * scale, y: image.y * scale)
            }
            ZStack(alignment: .topLeading) {
                Rectangle().fill(.gray.opacity(0.3))
                if let preview {
                    Image(decorative: preview, scale: 1).resizable()
                        .frame(width: original.width * scale, height: original.height * scale)
                        .offset(x: (image.x - canvas.x) * scale, y: (image.y - canvas.y) * scale)
                }
            }
            .frame(width: target.width * scale, height: target.height * scale, alignment: .topLeading)
            .clipped()
            .overlay(Rectangle().stroke(.green, lineWidth: 1.5))
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
        .accessibilityHidden(true)
    }

    private func applyChanges() {
        switch mode {
        case 0:
            guard validSize else { return }
            if tutorial.isActive { appliedOriginal = original }
            controller.adjustCanvas(from: original, to: targetSize, resample: resample,
                                    origin: targetOrigin, resolution: resolution)
            // Apply completes the lesson even unchanged, so the tour never waits on this page.
            tutorial.record(.resizedCanvas)
        default:
            if turns != 0 {
                let size = turns % 2 == 0 ? original : CGSize(width: original.height, height: original.width)
                controller.adjustCanvas(from: original, to: size, resample: false, quarterTurns: turns)
            }
        }
        if let onApplied { onApplied() } else { dismiss() }
    }

    // MARK: Rotate

    private var rotatedPixelSize: String {
        let size = turns % 2 == 0 ? original : CGSize(width: original.height, height: original.width)
        return "\(Int(size.width * displayScale)) × \(Int(size.height * displayScale)) px · \(Int(resolution)) DPI"
    }

    /// Large centered preview with its caption, then two round glass buttons.
    /// The preview gets every point the buttons do not need, so both portrait and
    /// landscape canvases grow compared to the old list layout.
    private func rotateEditor(height availableHeight: CGFloat) -> some View {
        VStack(spacing: 6) {
            canvasPreview(mode: 2)
                .padding(.horizontal, 6)
                .frame(maxHeight: .infinity)
                .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: rotationSteps)
            Text(rotatedPixelSize)
                .font(.system(size: 12, weight: .medium)).monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.7)
            HStack(spacing: 24) {
                rotateButton(step: -1, symbol: "arrow.counterclockwise", label: "90° ↺")
                rotateButton(step: 1, symbol: "arrow.clockwise", label: "90° ↻")
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 40)
        .padding(.bottom, 12)
        .frame(height: availableHeight)
    }

    private func rotateButton(step: Int, symbol: String, label: String) -> some View {
        Button { rotationSteps += step } label: {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .modifier(RotateGlassCircle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: label))
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
            let largest = max(original.width, original.height) * displayScale
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
                width = max(1, (original.width * displayScale * value / 100).rounded())
                height = max(1, (original.height * displayScale * value / 100).rounded())
            case 1:
                width = value
                if proportional { height = max(1, (value / ratio).rounded()) }
                resizePercent = width / max(1, original.width * displayScale) * 100
            case 2:
                height = value
                if proportional { width = max(1, (value * ratio).rounded()) }
                resizePercent = height / max(1, original.height * displayScale) * 100
            case 3:
                if resample {
                    width = max(1, (width * value / resolution).rounded())
                    height = max(1, (height * value / resolution).rounded())
                    resizePercent = width / max(1, original.width * displayScale) * 100
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

    private func resizeEditor(height availableHeight: CGFloat) -> some View {
        VStack(spacing: 4) {
            // Options stand beside the preview, as the presets do in perspective guides.
            HStack(spacing: 8) {
                canvasPreview(mode: 0)
                VStack(spacing: 0) {
                    // Width, height and resolution, one per line above the options.
                    VStack(spacing: 1) {
                        Text(verbatim: "\(Int(width)) px")
                        Text(verbatim: "\(Int(height)) px")
                        Text(verbatim: "\(Int(resolution)) DPI")
                    }
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(validSize ? Color.secondary : .orange)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: "\(Int(width)) × \(Int(height)) px, \(Int(resolution)) DPI"))
                    // The tour teaches only the size and the frame; the options stay as set.
                    resizeOption("Scale proportionally", symbol: "link", isSlashed: !proportional, value: $proportional)
                        .disabled(tutorial.isActive)
                        .frame(maxHeight: .infinity)
                    resizeOption("Resample image", symbol: "arrow.up.left.and.arrow.down.right", value: $resample)
                        .disabled(tutorial.isActive)
                        .frame(maxHeight: .infinity)
                }
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

    private func resizeOption(_ title: String, symbol: String, isSlashed: Bool = false,
                              value: Binding<Bool>) -> some View {
        // The same round toggle as the perspective guide presets.
        let isOn = value.wrappedValue
        return Button { value.wrappedValue.toggle() } label: {
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
        .accessibilityAddTraits(value.wrappedValue ? .isSelected : [])
    }

}

/// Liquid Glass circle on watchOS 26+; a material circle on earlier systems.
private struct RotateGlassCircle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(watchOS 26, *) {
            content
                .glassEffect(.regular.interactive(), in: Circle())
                .environment(\.colorScheme, .dark)
        } else {
            content.background(.ultraThinMaterial, in: Circle())
        }
    }
}

/// Clips the preview to its canvas bounds except while rotating, where the
/// turning image must not be cut by the interpolating frame.
private struct PreviewClip: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled { content.clipped() } else { content }
    }
}
