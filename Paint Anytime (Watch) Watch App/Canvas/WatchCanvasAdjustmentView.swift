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
    @State private var cropPercent = 90.0
    @State private var cropX = 50.0
    @State private var cropY = 50.0
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
    @State private var cropPage = 0
    @State private var resizePage = 0
    @State private var resizePercent = 100.0
    @State private var initialized = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection

    private var original: CGSize { controller.document.size(fallback: viewportSize) }
    private var ratio: Double { original.width / original.height }
    private var maximumPixels: Double { 1024 }
    private var validSize: Bool {
        width >= 1 && height >= 1 && width <= maximumPixels && height <= maximumPixels
    }
    private var cropSize: CGSize {
        CGSize(width: original.width * cropPercent / 100,
               height: original.height * cropPercent / 100)
    }
    private var cropOrigin: CGPoint {
        CGPoint(x: (original.width - cropSize.width) * cropX / 100,
                y: (original.height - cropSize.height) * cropY / 100)
    }

    var body: some View {
        GeometryReader { geometry in
            Group {
                if mode == 0 {
                    resizeEditor(height: geometry.size.height)
                } else if mode == 1 {
                    cropEditor(height: geometry.size.height)
                } else {
                    rotateEditor(height: geometry.size.height)
                }
            }
        }
        // The value row and carousel stay above the tutorial's lesson card.
        .padding(.bottom, tutorial.isActive ? tutorialHintReservedHeight : 0)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: applyChanges) {
                    Image(systemName: "checkmark").foregroundStyle(.green)
                        .tutorialHint(tutorial, steps: [.applyCrop])
                }
                .watchToolbarButtonStyle()
                .disabled((mode == 0 && !validSize) || !tutorial.permits([.applyCrop]))
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
            focusedAdjustment = mode == 0 ? "Resize" : mode == 1 ? "Crop" : nil
        }
    }

    private func canvasPreview(mode: Int) -> some View {
        GeometryReader { geometry in
            let target = mode == 0
                ? CGSize(width: width / displayScale, height: height / displayScale)
                : mode == 2 && turns % 2 != 0
                    ? CGSize(width: original.height, height: original.width) : original
            let previewBounds = mode == 0
                ? CGSize(width: max(original.width, target.width), height: max(original.height, target.height))
                : target
            let scale = min(geometry.size.width / max(1, previewBounds.width),
                            geometry.size.height / max(1, previewBounds.height))
            ZStack {
                // Rotate draws the bare image: the frame swaps its aspect while the
                // image turns, so a background, clip or border would show mid-animation.
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(.gray.opacity(mode == 2 ? 0 : 0.3))
                    if let preview {
                        Image(decorative: preview, scale: 1).resizable()
                            .frame(width: (mode == 0 && resample ? target.width : original.width) * scale,
                                   height: (mode == 0 && resample ? target.height : original.height) * scale)
                            .rotationEffect(.degrees(mode == 2 ? Double(rotationSteps * 90) : 0))
                            .frame(width: target.width * scale, height: target.height * scale,
                                   alignment: mode == 0 ? .topLeading : .center)
                    }
                    if mode == 1 {
                        Rectangle().stroke(.green, lineWidth: 1.5)
                            .frame(width: cropSize.width * scale, height: cropSize.height * scale)
                            .offset(x: cropOrigin.x * scale, y: cropOrigin.y * scale)
                    }
                }
                .frame(width: target.width * scale, height: target.height * scale)
                .modifier(PreviewClip(isEnabled: mode != 2))
                .overlay(Rectangle().stroke(.white.opacity(mode == 2 ? 0 : 0.5), lineWidth: 0.5))
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityLabel(L10n.text(mode == 1 ? "Crop area" : "Canvas size"))
    }

    private func applyChanges() {
        switch mode {
        case 0:
            guard validSize else { return }
            controller.adjustCanvas(from: original,
                to: CGSize(width: width / displayScale, height: height / displayScale),
                resample: resample, resolution: resolution)
        case 1:
            if cropPercent != 100 {
                controller.adjustCanvas(from: original, to: cropSize,
                                        resample: false, origin: cropOrigin)
            }
            // Apply completes the lesson even at 100%, so the tour never waits on this page.
            tutorial.record(.croppedCanvas)
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

    private var cropTitle: String { ["Keep", "Horizontal", "Vertical"][cropPage] }
    private var cropValue: Double {
        switch cropPage {
        case 0: cropPercent
        case 1: cropX
        default: cropY
        }
    }

    // Size and position both move in 1% increments.
    private var cropMinimum: Double { cropPage == 0 ? 10 : 0 }
    private var cropRange: ClosedRange<Double> { cropMinimum...100 }
    private var cropStepValue: Binding<Double> {
        Binding(get: { cropValue }, set: { next in
            let value = min(100, max(cropMinimum, next.rounded()))
            switch cropPage {
            case 0: cropPercent = value
            case 1: cropX = value
            default: cropY = value
            }
        })
    }

    private func cropEditor(height availableHeight: CGFloat) -> some View {
        VStack(spacing: 4) {
            // The cropped size stands beside the preview, as on the Resize page.
            HStack(spacing: 8) {
                canvasPreview(mode: 1)
                VStack(spacing: 1) {
                    Text(verbatim: "\(Int(cropSize.width * displayScale)) px")
                    Text(verbatim: "\(Int(cropSize.height * displayScale)) px")
                }
                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.6)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim:
                    "\(Int(cropSize.width * displayScale)) × \(Int(cropSize.height * displayScale)) px"))
                // Clear the toolbar's checkmark, which overlaps the top of this column.
                .padding(.top, 26)
                .frame(width: 48)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(maxHeight: .infinity)
            valueRow(value: cropStepValue, range: cropRange, valueTitle: L10n.percent(cropValue / 100),
                     title: cropTitle, focus: "Crop")
            CanvasResizeCarousel(selection: $cropPage, titles: ["Keep", "Horizontal", "Vertical"])
                .frame(height: 28)
        }
        .padding(.horizontal, 10)
        .padding(.top, 42)
        .padding(.bottom, 8)
        .frame(height: availableHeight)
        .contentShape(Rectangle())
        .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { value in
            guard abs(value.translation.width) > abs(value.translation.height) else { return }
            let forward = (value.translation.width < 0) == (layoutDirection == .leftToRight)
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                cropPage = min(2, max(0, cropPage + (forward ? 1 : -1)))
            }
        })
        .focusable()
        .focused($focusedAdjustment, equals: "Crop")
        .modifier(SteppedCrownModifier(value: cropStepValue, range: cropRange,
                                      sensitivity: .low, crownUnitsPerStep: 1, context: cropPage))
        .onChange(of: cropPage) { _, _ in focusedAdjustment = "Crop" }
    }

    private var resizeTitle: String {
        ["Percentage", "Canvas width", "Height", "Resolution"][resizePage]
    }

    private var resizeRange: ClosedRange<Double> {
        switch resizePage {
        case 0:
            let largest = max(original.width, original.height) * displayScale
            return 1...max(1, floor(maximumPixels / max(1, largest) * 100))
        case 3: return 18...300
        default: return 1...maximumPixels
        }
    }

    private var resizeValue: Binding<Double> {
        Binding(get: {
            switch resizePage {
            case 0: resizePercent
            case 1: width
            case 2: height
            default: resolution
            }
        }, set: { next in
            let value = min(resizeRange.upperBound, max(resizeRange.lowerBound, next.rounded()))
            switch resizePage {
            case 0:
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
            default:
                if resample {
                    width = max(1, (width * value / resolution).rounded())
                    height = max(1, (height * value / resolution).rounded())
                    resizePercent = width / max(1, original.width * displayScale) * 100
                }
                resolution = value
            }
        })
    }

    private var resizeValueTitle: String {
        if resizePage == 0 { return L10n.percent(resizePercent / 100) }
        return "\(Int(resizeValue.wrappedValue)) " + (resizePage == 3 ? "DPI" : "px")
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
                    resizeOption("Scale proportionally", symbol: "link", isSlashed: !proportional, value: $proportional)
                        .frame(maxHeight: .infinity)
                    resizeOption("Resample image", symbol: "arrow.up.left.and.arrow.down.right", value: $resample)
                        .frame(maxHeight: .infinity)
                }
                // Clear the toolbar's checkmark, which overlaps the top of this column.
                .padding(.top, 26)
                .frame(width: 48)
            }
            .frame(maxHeight: .infinity)
            valueRow(value: resizeValue, range: resizeRange, valueTitle: resizeValueTitle,
                     title: resizeTitle, focus: "Resize")
            CanvasResizeCarousel(selection: $resizePage)
                .frame(height: 28)
        }
        .padding(.horizontal, 10)
        .padding(.top, 42)
        .padding(.bottom, 8)
        .frame(height: availableHeight)
        .contentShape(Rectangle())
        .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { value in
            guard abs(value.translation.width) > abs(value.translation.height) else { return }
            let forward = (value.translation.width < 0) == (layoutDirection == .leftToRight)
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                resizePage = min(3, max(0, resizePage + (forward ? 1 : -1)))
            }
        })
        .focusable()
        .focused($focusedAdjustment, equals: "Resize")
        .modifier(SteppedCrownModifier(value: resizeValue, range: resizeRange,
                                      sensitivity: .low, crownUnitsPerStep: 1, context: resizePage))
        .onChange(of: resizePage) { _, _ in focusedAdjustment = "Resize" }
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
