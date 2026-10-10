import SwiftUI
import WatchKit

struct WatchLayersView: View {
    @ObservedObject var controller: CanvasController
    let canvasSize: CGSize
    private let rowSpacing: CGFloat = 4
    @State private var editingLayer: UUID?
    @State private var showsPaperEditor = false
    @GestureState private var isReordering = false
    @State private var draggedLayer: UUID?
    @State private var selectionBlockedUntil = Date.distantPast
    @State private var reorderTarget: UUID?
    @State private var dragOffset: CGFloat = 0
    @State private var rowFrames: [UUID: CGRect] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var previewAspectRatio: CGFloat {
        canvasSize.width > 0 && canvasSize.height > 0
            ? canvasSize.width / canvasSize.height : 200.0 / 240.0
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: rowSpacing) {
                        ForEach(Array(controller.document.layers.reversed())) { layer in
                            layerRow(layer, proxy: proxy)
                                .id(layer.id)
                                .offset(y: rowOffset(layer.id))
                                .animation(
                                    layer.id == draggedLayer || reduceMotion ? nil : .easeInOut(duration: 0.18),
                                    value: reorderTarget
                                )
                                .scaleEffect(draggedLayer == layer.id && !reduceMotion ? 1.04 : 1)
                                // Measure the layout slot, outside the visual drag/preview transforms.
                                .background {
                                    GeometryReader { geometry in
                                        Color.clear.preference(key: LayerRowFrames.self,
                                            value: [layer.id: geometry.frame(in: .named("layers"))])
                                    }
                                }
                                .zIndex(draggedLayer == layer.id ? 1 : 0)
                        }
                        LayerCard(title: L10n.text("Canvas"), canvasSize: canvasSize,
                                  onSelect: { showsPaperEditor = true },
                                  onEdit: { showsPaperEditor = true }) {
                            CanvasBackgroundPreview(color: controller.document.effectiveBackgroundColor)
                                .aspectRatio(previewAspectRatio, contentMode: .fit)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
                }
                .coordinateSpace(name: "layers")
                .scrollDisabled(draggedLayer != nil)
                .onPreferenceChange(LayerRowFrames.self) { rowFrames = $0 }
            }
            .onChange(of: isReordering) { _, active in
                if !active {
                    if draggedLayer != nil {
                        selectionBlockedUntil = Date().addingTimeInterval(0.2)
                    }
                    draggedLayer = nil
                    reorderTarget = nil
                    dragOffset = 0
                }
            }
            .navigationTitle(L10n.text("Layers"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        controller.addLayer()
                    } label: { Image(systemName: "plus") }
                    .accessibilityLabel(L10n.text("Add layer"))
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { editingLayer != nil }, set: { if !$0 { editingLayer = nil } }
            )) {
                if let id = editingLayer {
                    LayerSettingsView(controller: controller, layerID: id, canvasSize: canvasSize)
                }
            }
            .navigationDestination(isPresented: $showsPaperEditor) {
                LayerSettingsView(controller: controller, layerID: nil, canvasSize: canvasSize)
            }
        }
    }

    private func layerRow(_ layer: CanvasLayer, proxy: ScrollViewProxy) -> some View {
        LayerCard(title: layer.displayName, canvasSize: canvasSize, onSelect: {
            guard draggedLayer == nil, !isReordering,
                  Date() >= selectionBlockedUntil else { return }
            controller.selectLayer(layer.id)
        }, onEdit: {
            guard draggedLayer == nil, !isReordering,
                  Date() >= selectionBlockedUntil else { return }
            editingLayer = layer.id
        }) {
            LayerThumbnail(layer: layer, canvasSize: canvasSize)
        }
        .simultaneousGesture(reorderGesture(layer.id, proxy: proxy))
        .accessibilityAddTraits(controller.selectedLayer.id == layer.id ? [.isSelected] : [])
        .accessibilityAction(named: Text(L10n.text("Move up"))) { move(layer.id, up: true) }
        .accessibilityAction(named: Text(L10n.text("Move down"))) { move(layer.id, up: false) }
        .accessibilityAction(named: Text(L10n.text("Delete"))) { controller.deleteLayer(layer.id) }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(controller.selectedLayer.id == layer.id ? Color.accentColor : .clear, lineWidth: 2)
                .allowsHitTesting(false)
        }
    }

    private func reorderGesture(_ id: UUID, proxy: ScrollViewProxy) -> some Gesture {
        LongPressGesture(minimumDuration: 0.45)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("layers")))
            .updating($isReordering) { value, state, _ in
                if case .second(true, _) = value { state = true }
            }
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                selectionBlockedUntil = .distantFuture
                if draggedLayer == nil {
                    draggedLayer = id
                    WKInterfaceDevice.current().play(.click)
                }
                if let drag {
                    dragOffset = drag.translation.height
                    let target = dropTarget(for: id, translation: drag.translation.height)
                    if reorderTarget != target {
                        reorderTarget = target
                        if let target {
                            proxy.scrollTo(target, anchor: drag.translation.height < 0 ? .top : .bottom)
                        }
                    }
                }
            }
            .onEnded { value in
                defer {
                    draggedLayer = nil
                    reorderTarget = nil
                    dragOffset = 0
                }
                if case .second(true, _) = value {
                    // Button and gesture callbacks can finish in either order on release.
                    selectionBlockedUntil = Date().addingTimeInterval(0.2)
                }
                guard case .second(true, let drag?) = value else { return }
                guard let target = dropTarget(for: id, translation: drag.translation.height) else { return }
                controller.moveLayer(id, to: target)
            }
    }

    // Keep document order unchanged until release, so one drag produces one undo step.
    // Neighbors preview their destination using offsets from stable layout slots.
    private func rowOffset(_ id: UUID) -> CGFloat {
        guard let draggedLayer else { return 0 }
        if id == draggedLayer { return dragOffset }
        let ids = controller.document.layers.reversed().map(\.id)
        guard let reorderTarget,
              let source = ids.firstIndex(of: draggedLayer),
              let destination = ids.firstIndex(of: reorderTarget),
              let index = ids.firstIndex(of: id),
              let origin = rowFrames[draggedLayer] else { return 0 }
        let distance = origin.height + rowSpacing
        if destination < source, (destination..<source).contains(index) { return distance }
        if destination > source, ((source + 1)...destination).contains(index) { return -distance }
        return 0
    }

    private func dropTarget(for id: UUID, translation: CGFloat) -> UUID? {
        guard let origin = rowFrames[id] else { return nil }
        let center = origin.midY + translation
        let neighbors = rowFrames.filter { $0.key != id }
        if translation < 0 {
            return neighbors.filter { $0.value.midY < origin.midY && center <= $0.value.midY }
                .min { $0.value.midY < $1.value.midY }?.key
        }
        if translation > 0 {
            return neighbors.filter { $0.value.midY > origin.midY && center >= $0.value.midY }
                .max { $0.value.midY < $1.value.midY }?.key
        }
        return nil
    }

    private func move(_ id: UUID, up: Bool) {
        let layers = controller.document.layers
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        let target = index + (up ? 1 : -1)
        guard layers.indices.contains(target) else { return }
        controller.moveLayer(id, to: layers[target].id)
    }
}

/// Preview, title, and settings share one compact, stable drag slot.
private struct LayerCard<Preview: View>: View {
    let title: String
    let canvasSize: CGSize
    let onSelect: () -> Void
    let onEdit: () -> Void
    @ViewBuilder let preview: () -> Preview

    private let previewHeight: CGFloat = 52

    var body: some View {
        GeometryReader { geometry in
            let ratio = canvasSize.width > 0 && canvasSize.height > 0
                ? canvasSize.width / canvasSize.height : 200.0 / 240.0
            let previewWidth = min(previewHeight * ratio, geometry.size.width * 0.45)
            HStack(spacing: 6) {
                Button(action: onSelect) {
                    preview()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .frame(width: previewWidth, height: previewHeight)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(title)

                Button(action: onSelect) {
                    Text(title)
                        .font(.system(size: 15))
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .frame(maxWidth: .infinity)

                Button(action: onEdit) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 30, height: previewHeight)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(L10n.text("Settings") + ": " + title)
            }
            .frame(height: previewHeight)
            .buttonStyle(.plain)
        }
        .frame(height: previewHeight)
        .padding(4)
        .background(.gray.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct LayerRowFrames: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct LayerSettingsView: View {
    @ObservedObject var controller: CanvasController
    let layerID: UUID?
    let canvasSize: CGSize
    @FocusState private var crownFocused: Bool
    @State private var opacity: Double = 1
    @State private var previewSideInset: CGFloat = 0
    @State private var showsAllLayers = false
    @State private var transparencyFeedbackID: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var showsColorEditor = false
    private var layer: CanvasLayer? {
        guard let layerID else {
            return CanvasLayer(name: L10n.text("Canvas"),
                               isVisible: controller.document.backgroundIsVisible,
                               opacity: controller.document.backgroundColor.w)
        }
        return controller.document.layers.first { $0.id == layerID }
    }

    private func updateLayer(_ edit: (inout CanvasLayer) -> Void) {
        if let layerID {
            controller.updateLayer(layerID, edit)
        } else if var updated = layer {
            edit(&updated)
            if updated.isVisible != controller.document.backgroundIsVisible {
                controller.setBackgroundVisible(updated.isVisible)
            }
            if updated.opacity != controller.document.backgroundColor.w {
                var color = controller.document.backgroundColor
                color.w = updated.opacity
                controller.setBackgroundColor(color)
            }
        }
    }

    var body: some View {
        if let layer {
            VStack(spacing: 0) {
                GeometryReader { geometry in
                    let size = canvasSize.width > 0 && canvasSize.height > 0
                        ? canvasSize : CGSize(width: 200, height: 240)
                    // The navigation safe area bounds the top; the opacity row bounds the bottom.
                    // Equal slots keep all three controls inside that space on every watch size.
                    let controlHeight = max(0, geometry.size.height / 3)
                    let availableWidth = max(0, geometry.size.width - 52)
                    let scale = min(availableWidth / size.width, geometry.size.height / size.height)
                    let previewWidth = size.width * scale
                    let previewRight = (availableWidth + previewWidth) / 2
                    let screenRight = WKInterfaceDevice.current().screenBounds.maxX
                        - geometry.frame(in: .global).minX
                    let controlsCenterX = (previewRight + screenRight) / 2
                    ZStack(alignment: .topLeading) {
                        ZStack {
                            layerPreview(layer)
                        }
                            .frame(width: size.width * scale, height: size.height * scale)
                            .overlay { Rectangle().strokeBorder(.white.opacity(0.25), lineWidth: 1) }
                            .overlay {
                                if let transparencyFeedbackID {
                                    TransparencyBoundaryFeedback(layer: layer, canvasSize: size) {
                                        if self.transparencyFeedbackID == transparencyFeedbackID {
                                            self.transparencyFeedbackID = nil
                                        }
                                    }
                                        .id(transparencyFeedbackID)
                                        .allowsHitTesting(false)
                                        .accessibilityHidden(true)
                                }
                            }
                            .accessibilityLabel(showsAllLayers ? L10n.text("All layers") : layer.displayName)
                            // Anchor the paper's bottom edge to the spacing above the opacity row.
                            .position(x: availableWidth / 2,
                                      y: geometry.size.height - size.height * scale / 2)

                        VStack(spacing: 0) {
                            Button {
                                updateLayer { $0.isVisible.toggle() }
                                crownFocused = true
                            } label: {
                                Image(systemName: layer.isVisible ? "eye.fill" : "eye.slash.fill")
                                    .font(.system(size: 20))
                                    .frame(width: 44, height: controlHeight)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel(L10n.text("Visible"))
                            .accessibilityAddTraits(layer.isVisible ? [.isSelected] : [])

                            if layerID == nil {
                                Button { showsColorEditor = true } label: {
                                    let color = controller.document.backgroundColor
                                    Circle()
                                        .fill(Color(.sRGB, red: Double(color.x), green: Double(color.y), blue: Double(color.z)))
                                        .frame(width: 23, height: 23)
                                        .overlay { Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1) }
                                        .frame(width: 44, height: controlHeight)
                                        .contentShape(Rectangle())
                                }
                                .accessibilityLabel(L10n.text("Canvas color"))
                            } else {
                                Button {
                                    updateLayer { $0.locksTransparency.toggle() }
                                    transparencyFeedbackID = UUID()
                                    crownFocused = true
                                } label: {
                                    Image(systemName: layer.locksTransparency ? "lock.square.dashed" : "square.dashed")
                                        .font(.system(size: 23))
                                        .foregroundStyle(.white)
                                        .frame(width: 44, height: controlHeight)
                                        .contentShape(Rectangle())
                                }
                                .accessibilityLabel(L10n.text("Lock transparency"))
                                .accessibilityAddTraits(layer.locksTransparency ? [.isSelected] : [])
                            }

                            Button {
                                transparencyFeedbackID = nil
                                showsAllLayers.toggle()
                                crownFocused = true
                            } label: {
                                Image(systemName: "square.3.layers.3d")
                                    .font(.system(size: 21))
                                    .foregroundStyle(showsAllLayers ? Color.white : Color.gray)
                                    .frame(width: 44, height: controlHeight)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel(L10n.text(showsAllLayers ? "Show only this layer" : "Show all layers"))
                            .accessibilityValue(L10n.text(showsAllLayers ? "All layers" : "Only this layer"))
                            .accessibilityAddTraits(showsAllLayers ? [.isSelected] : [])
                        }
                        .frame(width: 44, height: geometry.size.height)
                        .buttonStyle(.plain)
                        .position(x: controlsCenterX, y: geometry.size.height / 2)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        let width = max(0, proxy.size.width - 52)
                        let fit = min(width / size.width, proxy.size.height / size.height)
                        return max(0, (width - size.width * fit) / 2)
                    } action: { inset in
                        previewSideInset = inset
                    }
                }

                VStack(spacing: 0) {
                    HStack {
                        Text(L10n.text("Opacity"))
                        Spacer(minLength: 4)
                        Text("\(Int((opacity * 100).rounded()))%")
                            .monospacedDigit()
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, previewSideInset)
                    .frame(height: 16)
                    .padding(.vertical, 4)

                    HStack(spacing: 4) {
                        opacityButton("minus", amount: -1)
                        WatchGradientSlider(
                            value: Binding(get: { opacity * 100 }, set: { setOpacity($0) }),
                            maximum: 100, colors: [.white, .black],
                            thumbColor: Color(white: 1 - opacity))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(L10n.text("Opacity"))
                            .accessibilityValue("\(Int((opacity * 100).rounded()))%")
                            .accessibilityAdjustableAction { direction in
                                switch direction {
                                case .increment: setOpacity(opacity * 100 + 1)
                                case .decrement: setOpacity(opacity * 100 - 1)
                                @unknown default: break
                                }
                            }
                        opacityButton("plus", amount: 1)
                    }
                    .environment(\.layoutDirection, .leftToRight)
                    .frame(height: 28)
                    .padding(.horizontal, 4)
                }
                .padding(.bottom, 8)
            }
            .padding(.horizontal, 8)
            .ignoresSafeArea(.container, edges: .bottom)
            .focusable()
            .focused($crownFocused)
            .modifier(SteppedCrownModifier(
                value: Binding(
                    get: { (opacity * 100).rounded() },
                    set: { opacity = $0 / 100 }),
                range: 0...100))
            .navigationTitle(layer.displayName)
            .toolbar {
                if let layerID {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .destructive) {
                            controller.deleteLayer(layerID)
                            dismiss()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel(L10n.text("Delete"))
                    }
                }
            }
            .navigationDestination(isPresented: $showsColorEditor) {
                CustomInkEditor(initialColor: controller.document.backgroundColor, saveTitle: "Done") { preset in
                    var color = preset.rgba
                    color.w = Float(opacity)
                    controller.setBackgroundColor(color)
                }
            }
            .onAppear {
                opacity = Double(layer.opacity)
                crownFocused = true
            }
            .onDisappear {
                transparencyFeedbackID = nil
                if let currentLayer = self.layer, Float(opacity) != currentLayer.opacity {
                    updateLayer { $0.opacity = Float(opacity) }
                }
            }
        }
    }

    @ViewBuilder
    private func layerPreview(_ layer: CanvasLayer) -> some View {
        if showsAllLayers {
            ZStack {
                CanvasBackgroundPreview(color: previewBackgroundColor)
                ForEach(controller.document.layers) { previewLayer in
                    LayerThumbnail(
                        layer: previewLayer, canvasSize: canvasSize,
                        previewOpacity: previewLayer.isVisible
                            ? (previewLayer.id == layerID ? opacity : Double(previewLayer.opacity)) : 0,
                        maximumPixelDimension: 400, showsCheckerboard: false)
                }
            }
        } else if layerID == nil {
            CanvasBackgroundPreview(color: previewBackgroundColor)
        } else {
            LayerThumbnail(layer: layer, canvasSize: canvasSize,
                           previewOpacity: layer.isVisible ? opacity : 0,
                           maximumPixelDimension: 400)
        }
    }

    private var previewBackgroundColor: SIMD4<Float> {
        var color = controller.document.effectiveBackgroundColor
        if layerID == nil, controller.document.backgroundIsVisible { color.w = Float(opacity) }
        return color
    }

    private func setOpacity(_ percent: Double) {
        opacity = min(100, max(0, percent.rounded())) / 100
        crownFocused = true
    }

    private func opacityButton(_ symbol: String, amount: Double) -> some View {
        Button { setOpacity(opacity * 100 + amount) } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(amount > 0 ? opacity >= 1 : opacity <= 0)
        .accessibilityLabel(L10n.text("Opacity") + (amount > 0 ? " +1" : " −1"))
    }

}

private struct CanvasBackgroundPreview: View {
    let color: SIMD4<Float>

    var body: some View {
        ZStack {
            TransparencyCheckerboard()
            Color(.sRGB, red: Double(color.x), green: Double(color.y),
                  blue: Double(color.z), opacity: Double(color.w))
        }
        .clipped()
    }
}

private struct LayerThumbnail: View {
    let layer: CanvasLayer
    let canvasSize: CGSize
    var previewOpacity: Double = 1
    var maximumPixelDimension: CGFloat = 124
    var showsCheckerboard = true
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if showsCheckerboard {
                TransparencyCheckerboard()
            }
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
                    .opacity(previewOpacity)
            }
        }
        .aspectRatio(canvasSize.width > 0 && canvasSize.height > 0
            ? canvasSize.width / canvasSize.height : 200.0 / 240.0, contentMode: .fit)
        .clipped()
        .task(id: layer.strokes.map(\.geometryRevision)) {
            let strokes = layer.strokes
            let size = canvasSize.width > 0 && canvasSize.height > 0 ? canvasSize : CGSize(width: 200, height: 240)
            let scale = min(1, maximumPixelDimension / max(size.width, size.height))
            let task = Task.detached(priority: .utility) {
                WatchBitmapRenderer.layerThumbnail(strokes: strokes, size: size, scale: scale)
            }
            let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            guard !Task.isCancelled else { return }
            image = result
        }
    }
}

private extension CanvasLayer {
    var displayName: String {
        if name.hasPrefix("Layer "), let number = Int(name.dropFirst(6)) {
            return L10n.format("Layer %d", number)
        }
        return name
    }
}

/// A short, view-only cue; the mask uses the same ink replay as the layer preview.
private struct TransparencyBoundaryFeedback: View {
    let layer: CanvasLayer
    let canvasSize: CGSize
    let onFinished: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var boundary: Path?
    @State private var startedAt = Date()
    @State private var finished = false

    var body: some View {
        GeometryReader { geometry in
            if let boundary, !finished {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                    let elapsed = timeline.date.timeIntervalSince(startedAt)
                    let progress = min(1, max(0, elapsed / 1.1))
                    let fade = min(1, elapsed / 0.08) * min(1, (1.3 - elapsed) / 0.25)
                    // Only the paper border is inset; ink uses the full preview coordinates.
                    let inset: CGFloat = layer.locksTransparency ? 0 : 1.5
                    let path = boundary.applying(CGAffineTransform(
                        scaleX: max(0, geometry.size.width - inset * 2),
                        y: max(0, geometry.size.height - inset * 2)))
                        .applying(CGAffineTransform(translationX: inset, y: inset))
                    let highlight = reduceMotion ? path : path.trimmedPath(
                        from: max(0, progress * 1.25 - 0.25), to: min(1, progress * 1.25))
                    ZStack {
                        path.stroke(.cyan.opacity(0.35), lineWidth: 1)
                        highlight.stroke(.cyan, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                            .blur(radius: 3)
                        highlight.stroke(.white, style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                    }
                    .opacity(max(0, fade))
                }
            }
        }
        .task {
            if layer.locksTransparency {
                let strokes = layer.strokes
                let size = canvasSize
                let work = Task.detached(priority: .userInitiated) {
                    Self.inkBoundary(strokes: strokes, size: size)
                }
                let result = await withTaskCancellationHandler {
                    await work.value
                } onCancel: { work.cancel() }
                guard !Task.isCancelled else { return }
                boundary = result
            } else {
                boundary = Path(CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            startedAt = Date()
            do {
                try await Task.sleep(for: .milliseconds(1300))
                finished = true
                onFinished()
            } catch { }
        }
    }

    private static func inkBoundary(strokes: [Stroke], size: CGSize) -> Path? {
        let scale = min(1, 400 / max(size.width, size.height))
        guard !Task.isCancelled,
              let image = WatchBitmapRenderer.layerThumbnail(strokes: strokes, size: size, scale: scale)
        else { return nil }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            // Copy the CGImage without flipping: its first pixel row already
            // corresponds to the top of the image displayed by SwiftUI.
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered, !Task.isCancelled else { return nil }
        func occupied(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && x < width && y >= 0 && y < height && pixels[(y * width + x) * 4 + 3] > 8
        }
        // Directed pixel edges form closed loops, including holes left by the eraser.
        let stride = width + 1
        var edges: [Int: [Int]] = [:]
        func edge(_ x: Int, _ y: Int, _ endX: Int, _ endY: Int) {
            edges[y * stride + x, default: []].append(endY * stride + endX)
        }
        for y in 0..<height {
            guard !Task.isCancelled else { return nil }
            for x in 0..<width where occupied(x, y) {
                if !occupied(x, y - 1) { edge(x, y, x + 1, y) }
                if !occupied(x + 1, y) { edge(x + 1, y, x + 1, y + 1) }
                if !occupied(x, y + 1) { edge(x + 1, y + 1, x, y + 1) }
                if !occupied(x - 1, y) { edge(x, y + 1, x, y) }
            }
        }
        func point(_ vertex: Int) -> CGPoint {
            CGPoint(x: CGFloat(vertex % stride) / CGFloat(width),
                    y: CGFloat(vertex / stride) / CGFloat(height))
        }
        var path = Path()
        while let start = edges.keys.min() {
            var current = start
            path.move(to: point(start))
            while var outgoing = edges[current], let next = outgoing.popLast() {
                edges[current] = outgoing.isEmpty ? nil : outgoing
                path.addLine(to: point(next))
                current = next
                if current == start { path.closeSubpath(); break }
            }
        }
        return path
    }
}
