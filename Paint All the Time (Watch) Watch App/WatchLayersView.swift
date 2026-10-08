import SwiftUI
import WatchKit

struct WatchLayersView: View {
    @ObservedObject var controller: CanvasController
    let canvasSize: CGSize
    @State private var editingLayer: UUID?
    @State private var showsPaperEditor = false
    @State private var revealedLayer: UUID?
    @GestureState private var isReordering = false
    @State private var draggedLayer: UUID?
    @State private var dragOffset: CGFloat = 0
    @State private var rowFrames: [UUID: CGRect] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(Array(controller.document.layers.reversed())) { layer in
                            layerRow(layer)
                                .id(layer.id)
                                .background {
                                    GeometryReader { geometry in
                                        Color.clear.preference(key: LayerRowFrames.self,
                                            value: [layer.id: geometry.frame(in: .named("layers"))])
                                    }
                                }
                                .offset(y: draggedLayer == layer.id ? dragOffset : 0)
                                .scaleEffect(draggedLayer == layer.id && !reduceMotion ? 1.04 : 1)
                                .zIndex(draggedLayer == layer.id ? 1 : 0)
                                .simultaneousGesture(reorderGesture(layer.id, proxy: proxy))
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
                if !active { draggedLayer = nil; dragOffset = 0 }
            }
            .navigationTitle(L10n.text("Layers"))
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        revealedLayer = nil
                        controller.addLayer()
                    } label: { Image(systemName: "plus") }
                    .accessibilityLabel(L10n.text("Add layer"))
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { editingLayer != nil }, set: { if !$0 { editingLayer = nil } }
            )) {
                if let id = editingLayer {
                    LayerSettingsView(controller: controller, layerID: id)
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

    private func layerRow(_ layer: CanvasLayer) -> some View {
        HStack(spacing: 4) {
            Button {
                guard draggedLayer == nil else { return }
                if revealedLayer != nil { revealedLayer = nil; return }
                controller.selectLayer(layer.id)
                editingLayer = layer.id
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
                .background(.gray.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(controller.selectedLayer.id == layer.id ? Color.accentColor : .clear, lineWidth: 2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(controller.selectedLayer.id == layer.id ? [.isSelected] : [])
            .accessibilityAction(named: Text(L10n.text("Move up"))) { move(layer.id, up: true) }
            .accessibilityAction(named: Text(L10n.text("Move down"))) { move(layer.id, up: false) }
            .accessibilityAction(named: Text(L10n.text("Delete"))) { controller.deleteLayer(layer.id) }
            if revealedLayer == layer.id {
                Button(role: .destructive) {
                    controller.deleteLayer(layer.id)
                    revealedLayer = nil
                } label: {
                    Image(systemName: "trash").frame(width: 38, height: 54)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .accessibilityLabel(L10n.text("Delete"))
            }
        }
        .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { value in
            guard draggedLayer == nil, abs(value.translation.width) > abs(value.translation.height) else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                revealedLayer = value.translation.width < 0 ? layer.id : nil
            }
        })
    }

    private func reorderGesture(_ id: UUID, proxy: ScrollViewProxy) -> some Gesture {
        LongPressGesture(minimumDuration: 0.45)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("layers")))
            .updating($isReordering) { value, state, _ in
                if case .second(true, _) = value { state = true }
            }
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if draggedLayer == nil {
                    draggedLayer = id
                    revealedLayer = nil
                    WKInterfaceDevice.current().play(.click)
                }
                if let drag {
                    dragOffset = drag.translation.height
                    // Follow the next row when the finger approaches the viewport edge.
                    if let target = rowFrames.first(where: { $0.key != id && $0.value.contains(drag.location) }) {
                        proxy.scrollTo(target.key, anchor: drag.translation.height < 0 ? .top : .bottom)
                    }
                }
            }
            .onEnded { value in
                defer { draggedLayer = nil; dragOffset = 0 }
                guard case .second(true, let drag?) = value else { return }
                let candidates = rowFrames.filter { $0.key != id }
                guard let target = candidates.min(by: {
                    abs($0.value.midY - drag.location.y) < abs($1.value.midY - drag.location.y)
                }), let origin = rowFrames[id], abs(drag.location.y - origin.midY) > origin.height / 2 else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    controller.moveLayer(id, to: target.key)
                }
            }
    }

    private func move(_ id: UUID, up: Bool) {
        let layers = controller.document.layers
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        let target = index + (up ? 1 : -1)
        guard layers.indices.contains(target) else { return }
        controller.moveLayer(id, to: layers[target].id)
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
    @State private var opacity: Double = 1
    private var layer: CanvasLayer? { controller.document.layers.first { $0.id == layerID } }

    var body: some View {
        if let layer {
            Form {
                Toggle(L10n.text("Visible"), isOn: Binding(
                    get: { layer.isVisible },
                    set: { value in controller.updateLayer(layerID) { $0.isVisible = value } }
                ))
                Toggle(L10n.text("Lock transparency"), isOn: Binding(
                    get: { layer.locksTransparency },
                    set: { value in controller.updateLayer(layerID) { $0.locksTransparency = value } }
                ))
                VStack(alignment: .leading) {
                    Text(L10n.text("Opacity") + " \(Int(opacity * 100))%")
                    Slider(value: $opacity, in: 0...1, step: 0.01)
                }
            }
            .navigationTitle(layer.displayName)
            .onAppear { opacity = Double(layer.opacity) }
            .onDisappear {
                if Float(opacity) != self.layer?.opacity {
                    controller.updateLayer(layerID) { $0.opacity = Float(opacity) }
                }
            }
        }
    }
}

private struct LayerThumbnail: View {
    let layer: CanvasLayer
    let canvasSize: CGSize
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Canvas { context, size in
                for y in 0..<7 { for x in 0..<8 {
                    let rect = CGRect(x: CGFloat(x) * 8, y: CGFloat(y) * 8, width: 8, height: 8)
                    context.fill(Path(rect), with: .color((x + y).isMultiple(of: 2) ? .white : Color(white: 0.78)))
                } }
            }
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            }
        }
        .task(id: layer.strokes.map(\.geometryRevision)) {
            let strokes = layer.strokes
            let size = canvasSize.width > 0 && canvasSize.height > 0 ? canvasSize : CGSize(width: 200, height: 240)
            let task = Task.detached(priority: .utility) {
                WatchBitmapRenderer.layerThumbnail(strokes: strokes, size: size, scale: min(1, 124 / size.width))
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
