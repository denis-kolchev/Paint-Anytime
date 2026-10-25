import SwiftUI
import Combine
import WatchKit

struct WatchLayersView: View {
    @ObservedObject var controller: CanvasController
    let canvasSize: CGSize
    private let rowSpacing: CGFloat = 4
    @State private var editingLayer: UUID?
    @State private var pendingLayerDeletion: UUID?
    @State private var showsPaperEditor = false
    @GestureState private var isTouchingLayers = false
    @State private var pendingLayerHold: UUID?
    @State private var touchStart: CGPoint?
    @State private var touchLocation: CGPoint?
    @State private var fingerScrollStart: CGFloat = 0
    @State private var isFingerScrolling = false
    @State private var fingerScrollRequest: LayerFingerScrollRequest?
    @State private var scrollContentOffset: CGFloat?
    @State private var contentFrame: CGRect = .zero
    @State private var contentID = UUID()
    private var isReordering: Bool { draggedLayer != nil }
    @State private var draggedLayer: UUID?
    @State private var selectionBlockedUntil = Date.distantPast
    @State private var reorderTarget: UUID?
    @State private var dragOffset: CGFloat = 0
    @State private var dragLocationY: CGFloat?
    @State private var dragGrabOffset: CGFloat = 0
    @State private var canvasRowID = UUID()
    @State private var autoScrollRequest: CGFloat = 0
    @State private var heldEdge: Int?
    @State private var edgeEnteredAt: Date?
    @State private var lastScrollTick: Date?
    private let scrollClock = Timer.publish(every: 1.0 / 30, on: .main, in: .common).autoconnect()
    @State private var scrollViewport: CGRect = .zero
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
                            ZStack {
                                layerRow(layer)
                                    .offset(y: rowOffset(layer.id))
                                    .animation(
                                        layer.id == draggedLayer || reduceMotion ? nil : .easeInOut(duration: 0.18),
                                        value: reorderTarget
                                    )
                                    .scaleEffect(draggedLayer == layer.id && !reduceMotion ? 1.04 : 1)
                            }
                                // Scroll targets and measurements must use the stationary slot.
                                .id(layer.id)
                                // Measure the layout slot, outside the visual drag/preview transforms.
                                .background {
                                    GeometryReader { geometry in
                                        Color.clear.preference(key: LayerRowFrames.self,
                                            value: [layer.id: geometry.frame(in: .global)])
                                    }
                                }
                                .zIndex(draggedLayer == layer.id ? 1 : 0)
                        }
                        LayerCard(title: L10n.text("Canvas"), canvasSize: canvasSize,
                                  onSelect: nil,
                                  onEdit: { showsPaperEditor = true }) {
                            CanvasBackgroundPreview(color: controller.document.effectiveBackgroundColor)
                                .aspectRatio(previewAspectRatio, contentMode: .fit)
                        }
                        .id(canvasRowID)
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(key: LayerRowFrames.self,
                                    value: [canvasRowID: geometry.frame(in: .global)])
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
                    .id(contentID)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: LayerContentFrame.self,
                                                   value: geometry.frame(in: .global))
                        }
                    }
                }
                .onPreferenceChange(LayerContentFrame.self) { contentFrame = $0 }
                .scrollDisabled(isReordering)
                // One touch observer handles scrolling and held-layer movement
                // across the whole list, including card buttons and empty space.
                .simultaneousGesture(layerListGesture)
                .task(id: pendingLayerHold) {
                    guard let id = pendingLayerHold else { return }
                    do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
                    guard !Task.isCancelled, isTouchingLayers,
                          pendingLayerHold == id, let location = touchLocation,
                          let frame = rowFrames[id] else { return }
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        controller.selectLayer(id)
                        selectionBlockedUntil = .distantFuture
                        draggedLayer = id
                        dragGrabOffset = location.y - frame.midY
                        dragLocationY = location.y
                    }
                }
                .onGeometryChange(for: CGRect.self) { geometry in
                    let frame = geometry.frame(in: .global)
                    return CGRect(x: frame.minX, y: frame.minY + geometry.safeAreaInsets.top,
                                  width: frame.width,
                                  height: max(0, frame.height
                                      - geometry.safeAreaInsets.top - geometry.safeAreaInsets.bottom))
                } action: { scrollViewport = $0 }
                .onPreferenceChange(LayerRowFrames.self) {
                    rowFrames = $0
                    updateDragPosition()
                }
                .modifier(LayerScrollPositionModifier(request: autoScrollRequest,
                                                       fingerRequest: fingerScrollRequest,
                                                       currentOffset: $scrollContentOffset))
                .onChange(of: fingerScrollRequest) { _, request in
                    // Older watchOS can align the entire content to an arbitrary
                    // anchor, which also gives continuous finger scrolling.
                    if #available(watchOS 11.0, *) { return }
                    guard let request else { return }
                    let maximum = max(0, contentFrame.height - scrollViewport.height)
                    guard maximum > 0 else { return }
                    let fraction = min(1, max(0, request.offset / maximum))
                    withAnimation(request.animated && !reduceMotion ? .easeOut(duration: 0.25) : nil) {
                        proxy.scrollTo(contentID, anchor: UnitPoint(x: 0.5, y: fraction))
                    }
                }
                .onReceive(scrollClock) { now in
                    guard let velocity = autoScrollVelocity else {
                        heldEdge = nil
                        edgeEnteredAt = nil
                        lastScrollTick = nil
                        return
                    }
                    let direction = velocity < 0 ? -1 : 1
                    if heldEdge != direction {
                        heldEdge = direction
                        edgeEnteredAt = now
                        lastScrollTick = nil
                        return
                    }
                    guard let edgeEnteredAt, now.timeIntervalSince(edgeEnteredAt) >= 0.45 else { return }
                    if #available(watchOS 11.0, *) {
                        let elapsed = min(0.1, now.timeIntervalSince(lastScrollTick ?? now.addingTimeInterval(-1.0 / 30)))
                        autoScrollRequest += velocity * CGFloat(elapsed)
                        lastScrollTick = now
                    } else {
                        // Older watches scroll by rows; vary the interval with the same speed curve.
                        let rowHeight = draggedLayer.flatMap { rowFrames[$0]?.height } ?? 60
                        let interval = Double((rowHeight + rowSpacing) / abs(velocity))
                        guard now.timeIntervalSince(lastScrollTick ?? .distantPast) >= interval else { return }
                        scrollDuringDrag(direction: direction, proxy: proxy)
                        lastScrollTick = now
                    }
                }
            }
            .onChange(of: isTouchingLayers) { _, active in
                if !active {
                    if draggedLayer != nil {
                        selectionBlockedUntil = Date().addingTimeInterval(0.2)
                    }
                    resetDrag()
                }
            }
            .onDisappear { resetDrag() }
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
            .fullScreenCover(isPresented: Binding(
                get: { pendingLayerDeletion != nil },
                set: { if !$0 { pendingLayerDeletion = nil } }
            )) {
                DestructiveConfirmationView(title: L10n.text("Delete this layer?"), confirmTitle: L10n.text("Delete")) {
                    pendingLayerDeletion = nil
                } onConfirm: {
                    if let id = pendingLayerDeletion { controller.deleteLayer(id) }
                    pendingLayerDeletion = nil
                }
            }
            .navigationDestination(isPresented: $showsPaperEditor) {
                LayerSettingsView(controller: controller, layerID: nil, canvasSize: canvasSize)
            }
        }
    }

    private func layerRow(_ layer: CanvasLayer) -> some View {
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
        .accessibilityAddTraits(controller.selectedLayer.id == layer.id ? [.isSelected] : [])
        .accessibilityAction(named: Text(L10n.text("Move up"))) { move(layer.id, up: true) }
        .accessibilityAction(named: Text(L10n.text("Move down"))) { move(layer.id, up: false) }
        .accessibilityActions {
            if controller.document.layers.count > 1 {
                Button(L10n.text("Delete")) { pendingLayerDeletion = layer.id }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(controller.selectedLayer.id == layer.id ? Color.accentColor : .clear, lineWidth: 2)
                .transaction { $0.disablesAnimations = true }
                .allowsHitTesting(false)
        }
        .sensoryFeedback(.selection, trigger: draggedLayer) { oldValue, newValue in
            newValue == layer.id && oldValue != newValue
        }
    }

    private var layerListGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($isTouchingLayers) { _, state, _ in state = true }
            .onChanged { drag in
                if touchStart == nil {
                    touchStart = drag.startLocation
                    fingerScrollStart = max(0, scrollContentOffset
                        ?? (scrollViewport.minY - contentFrame.minY))
                    pendingLayerHold = rowFrames.first { id, frame in
                        id != canvasRowID && frame.contains(drag.startLocation)
                    }?.key
                }
                touchLocation = drag.location
                if draggedLayer != nil {
                    dragLocationY = drag.location.y
                    updateDragPosition()
                } else if isFingerScrolling || hypot(drag.translation.width, drag.translation.height) > 8 {
                    pendingLayerHold = nil
                    isFingerScrolling = true
                    selectionBlockedUntil = Date().addingTimeInterval(0.2)
                    // This recognizer may own the pan on watchOS. Drive the offset
                    // ourselves instead of waiting for a second scroll recognizer.
                    // An absolute target avoids adding native and custom deltas twice.
                    fingerScrollRequest = LayerFingerScrollRequest(
                        offset: fingerScrollStart - drag.translation.height)
                }
            }
            .onEnded { drag in
                defer { resetDrag() }
                if isFingerScrolling {
                    selectionBlockedUntil = Date().addingTimeInterval(0.2)
                    fingerScrollRequest = LayerFingerScrollRequest(
                        offset: fingerScrollStart - drag.predictedEndTranslation.height,
                        animated: !reduceMotion)
                    return
                }
                guard let id = draggedLayer else { return }
                selectionBlockedUntil = Date().addingTimeInterval(0.2)
                dragLocationY = drag.location.y
                updateDragPosition()
                guard let target = reorderTarget else { return }
                controller.moveLayer(id, to: target)
            }
    }

    // Card bounds activate scrolling; the finger's distance to the physical screen
    // edge controls speed. The viewport ends before the screen's safe-area margins.
    private var autoScrollVelocity: CGFloat? {
        guard let draggedLayer, let dragLocationY,
              let origin = rowFrames[draggedLayer], scrollViewport.height > 0 else { return nil }
        let edgeZone = min(origin.height / 2 + 20, scrollViewport.height / 2)
        let center = dragLocationY - dragGrabOffset
        let topDistance = center - scrollViewport.minY
        let bottomDistance = scrollViewport.maxY - center
        let screen = WKInterfaceDevice.current().screenBounds
        let direction: CGFloat
        let proximity: CGFloat
        if topDistance < edgeZone, topDistance <= bottomDistance {
            direction = -1
            let entryY = scrollViewport.minY + edgeZone + dragGrabOffset
            proximity = (entryY - dragLocationY) / max(1, entryY - screen.minY)
        } else if bottomDistance < edgeZone {
            direction = 1
            let entryY = scrollViewport.maxY - edgeZone + dragGrabOffset
            proximity = (dragLocationY - entryY) / max(1, screen.maxY - entryY)
        } else {
            return nil
        }
        let progress = min(1, max(0, proximity))
        // Restore the original speed range and reserve the fastest motion for the
        // screen edge, rather than saturating as soon as the card leaves the list.
        return direction * (24 + (180 - 24) * progress * progress)
    }

    private func scrollDuringDrag(direction: Int, proxy: ScrollViewProxy) {
        let ids = controller.document.layers.reversed().map(\.id) + [canvasRowID]
        let frames = ids.compactMap { id in
            rowFrames[id].map { (id: id, frame: $0) }
        }
        // Reveal the next clipped row using a standard anchor instead of deriving
        // a fractional anchor from the moving row's screen position.
        let target = direction < 0
            ? frames.last(where: { $0.frame.minY < scrollViewport.minY - 1 })
            : frames.first(where: { $0.frame.maxY > scrollViewport.maxY + 1 })
        guard let target else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(target.id, anchor: direction < 0 ? .top : .bottom)
        }
    }

    private func updateDragPosition() {
        guard let draggedLayer, let dragLocationY, let origin = rowFrames[draggedLayer] else { return }
        dragOffset = dragLocationY - dragGrabOffset - origin.midY
        reorderTarget = dropTarget(for: draggedLayer, translation: dragOffset)
    }

    private func resetDrag() {
        pendingLayerHold = nil
        touchStart = nil
        touchLocation = nil
        isFingerScrolling = false
        // Cancellation must not leave selection blocked indefinitely.
        if selectionBlockedUntil == .distantFuture {
            selectionBlockedUntil = Date().addingTimeInterval(0.2)
        }
        draggedLayer = nil
        reorderTarget = nil
        dragOffset = 0
        dragLocationY = nil
        dragGrabOffset = 0
        heldEdge = nil
        edgeEnteredAt = nil
        lastScrollTick = nil
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
        // The canvas is a scroll target, but never a layer reorder destination.
        let neighbors = rowFrames.filter { $0.key != id && $0.key != canvasRowID }
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

/// Keep the watchOS 11 scroll state out of the watchOS 10 view's stored properties.
private struct LayerScrollPositionModifier: ViewModifier {
    let request: CGFloat
    let fingerRequest: LayerFingerScrollRequest?
    @Binding var currentOffset: CGFloat?

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(watchOS 11.0, *) {
            content.modifier(LayerOffsetScrollModifier(request: request, fingerRequest: fingerRequest,
                                                       currentOffset: $currentOffset))
        } else {
            content
        }
    }
}

@available(watchOS 11.0, *)
private struct LayerOffsetScrollModifier: ViewModifier {
    let request: CGFloat
    let fingerRequest: LayerFingerScrollRequest?
    @Binding var currentOffset: CGFloat?
    @State private var position = ScrollPosition()
    @State private var geometry: ScrollGeometry?

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, newGeometry in
                geometry = newGeometry
                currentOffset = newGeometry.contentOffset.y + newGeometry.contentInsets.top
            }
            .onChange(of: fingerRequest) { _, newRequest in
                guard let newRequest, let geometry else { return }
                let maximum = max(0, geometry.contentSize.height
                    + geometry.contentInsets.top + geometry.contentInsets.bottom
                    - geometry.containerSize.height)
                let target = min(maximum, max(0, newRequest.offset))
                if newRequest.animated {
                    withAnimation(.easeOut(duration: 0.25)) { position.scrollTo(y: target) }
                } else {
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { position.scrollTo(y: target) }
                }
            }
            .onChange(of: request) { oldRequest, newRequest in
                guard let geometry else { return }
                // ScrollPosition uses distance from the top, whereas ScrollGeometry's
                // resting contentOffset includes the negative top inset. Normalize both
                // the current position and the range before requesting either direction.
                let current = geometry.contentOffset.y + geometry.contentInsets.top
                let maximum = max(0, geometry.contentSize.height
                    + geometry.contentInsets.top + geometry.contentInsets.bottom
                    - geometry.containerSize.height)
                let next = min(maximum, max(0,
                    current + newRequest - oldRequest))
                guard abs(next - current) > 0.01 else { return }
                // Drive the actual offset, independently of row IDs and drop targets.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    position.scrollTo(y: next)
                }
            }
    }
}

private struct LayerRowFrames: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct LayerFingerScrollRequest: Equatable {
    let offset: CGFloat
    var animated = false
}

private struct LayerContentFrame: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}
