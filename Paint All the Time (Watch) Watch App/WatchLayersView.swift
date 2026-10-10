import SwiftUI
import WatchKit

struct WatchLayersView: View {
    @ObservedObject var controller: CanvasController
    let canvasSize: CGSize
    @State private var editingLayer: UUID?
    @State private var showsPaperEditor = false
    @GestureState private var isReordering = false
    @State private var draggedLayer: UUID?
    @State private var selectionBlockedUntil = Date.distantPast
    @State private var reorderTarget: UUID?
    @State private var dragOffset: CGFloat = 0
    @State private var rowFrames: [UUID: CGRect] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 8) {
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
                        Button { showsPaperEditor = true } label: {
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(paperColor)
                                    .frame(width: 62, height: 54)
                                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.gray, lineWidth: 1) }
                                Text(L10n.text("Canvas color"))
                                    .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(6)
                        }
                        .buttonStyle(.plain)
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
                CustomInkEditor(initialColor: controller.document.backgroundColor,
                                saveTitle: "Done") { preset in
                    controller.setBackgroundColor(preset.rgba)
                }
            }
        }
    }

    private var paperColor: Color {
        let c = controller.document.backgroundColor
        return Color(.sRGB, red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }

    private func layerRow(_ layer: CanvasLayer, proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 4) {
            Button {
                guard draggedLayer == nil, !isReordering,
                      Date() >= selectionBlockedUntil else { return }
                controller.selectLayer(layer.id)
            } label: {
                HStack(spacing: 10) {
                    LayerThumbnail(layer: layer, canvasSize: canvasSize)
                        .frame(width: 62, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Text(layer.displayName)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(2)
                }
                .padding(6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Let the button recognize taps without waiting for the hold-and-drag sequence.
            .simultaneousGesture(reorderGesture(layer.id, proxy: proxy))
            .accessibilityLabel(layer.displayName)
            .accessibilityAddTraits(controller.selectedLayer.id == layer.id ? [.isSelected] : [])
            .accessibilityAction(named: Text(L10n.text("Move up"))) { move(layer.id, up: true) }
            .accessibilityAction(named: Text(L10n.text("Move down"))) { move(layer.id, up: false) }
            .accessibilityAction(named: Text(L10n.text("Delete"))) { controller.deleteLayer(layer.id) }

            Button {
                guard draggedLayer == nil else { return }
                editingLayer = layer.id
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(LayerSettingsIconStyle())
            .accessibilityLabel(L10n.text("Settings") + ": " + layer.displayName)
        }
        .background(.gray.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
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
        let distance = origin.height + 8
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

private struct LayerSettingsIconStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 44, height: 54)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.45 : 1)
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
    let layerID: UUID
    let canvasSize: CGSize
    @FocusState private var crownFocused: Bool
    @State private var opacity: Double = 1
    @Environment(\.dismiss) private var dismiss
    private var layer: CanvasLayer? { controller.document.layers.first { $0.id == layerID } }

    var body: some View {
        if let layer {
            VStack(spacing: 6) {
                GeometryReader { geometry in
                    let size = canvasSize.width > 0 && canvasSize.height > 0
                        ? canvasSize : CGSize(width: 200, height: 240)
                    let availableWidth = max(0, geometry.size.width - 52)
                    let scale = min(availableWidth / size.width, geometry.size.height / size.height)
                    HStack(spacing: 8) {
                        LayerThumbnail(layer: layer, canvasSize: canvasSize,
                                       previewOpacity: layer.isVisible ? opacity : 0,
                                       maximumPixelDimension: 400)
                            .frame(width: size.width * scale, height: size.height * scale)
                            .overlay { Rectangle().strokeBorder(.white.opacity(0.25), lineWidth: 1) }
                            .accessibilityLabel(layer.displayName)
                            .frame(width: availableWidth, height: geometry.size.height)

                        VStack(spacing: 0) {
                            Button {
                                controller.updateLayer(layerID) { $0.isVisible.toggle() }
                                crownFocused = true
                            } label: {
                                Image(systemName: layer.isVisible ? "eye.fill" : "eye.slash.fill")
                                    .font(.system(size: 20))
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel(L10n.text("Visible"))
                            .accessibilityAddTraits(layer.isVisible ? [.isSelected] : [])

                            Button {
                                controller.updateLayer(layerID) { $0.locksTransparency.toggle() }
                                crownFocused = true
                            } label: {
                                Image(systemName: "square.dashed")
                                    .font(.system(size: 23))
                                    .overlay(alignment: .bottomTrailing) {
                                        if layer.locksTransparency {
                                            Image(systemName: "lock.fill")
                                                .font(.system(size: 11, weight: .bold))
                                                .padding(3)
                                                .background(.black, in: Circle())
                                                .offset(x: 5, y: 5)
                                        }
                                    }
                                    .foregroundStyle(layer.locksTransparency ? Color.accentColor : .white)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel(L10n.text("Lock transparency"))
                            .accessibilityAddTraits(layer.locksTransparency ? [.isSelected] : [])
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }

                VStack(spacing: 2) {
                    HStack {
                        Text(L10n.text("Opacity"))
                        Spacer(minLength: 4)
                        Text("\(Int((opacity * 100).rounded()))%")
                            .monospacedDigit()
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 8)
                    .frame(height: 16)

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
                }
                .padding(.horizontal, 4)
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
            .onAppear {
                opacity = Double(layer.opacity)
                crownFocused = true
            }
            .onDisappear {
                if let currentLayer = self.layer, Float(opacity) != currentLayer.opacity {
                    controller.updateLayer(layerID) { $0.opacity = Float(opacity) }
                }
            }
        }
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

private struct LayerThumbnail: View {
    let layer: CanvasLayer
    let canvasSize: CGSize
    var previewOpacity: Double = 1
    var maximumPixelDimension: CGFloat = 124
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Canvas { context, size in
                for y in 0..<Int(ceil(size.height / 8)) { for x in 0..<Int(ceil(size.width / 8)) {
                    let rect = CGRect(x: CGFloat(x) * 8, y: CGFloat(y) * 8, width: 8, height: 8)
                    context.fill(Path(rect), with: .color((x + y).isMultiple(of: 2) ? .white : Color(white: 0.78)))
                } }
            }
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
                    .opacity(previewOpacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
