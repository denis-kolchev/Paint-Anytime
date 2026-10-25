import SwiftUI

struct WatchLassoToolbarTouchRegion: View {
    let input: WatchLassoToolbarInput
    @ObservedObject var lasso: WatchLassoController
    let controller: CanvasController
    let diameter: CGFloat
    @GestureState private var dragging = false
    @State private var gestureMapping: WatchLassoToolbarInput.Mapping?

    var body: some View {
        Color.clear
            .frame(width: diameter, height: diameter)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .updating($dragging) { _, state, _ in state = true }
                .onChanged { value in
                    guard lasso.isActive, input.mapping?.enabled == true else { return }
                    if gestureMapping == nil, let mapping = input.mapping {
                        gestureMapping = mapping
                        lasso.begin(at: mapping.point(value.startLocation),
                                    tolerance: WatchLassoGeometry.handleHitRadius / mapping.zoomScale,
                                    controller: controller)
                    }
                    guard let mapping = gestureMapping else { return }
                    lasso.update(at: mapping.point(value.location), pointSpacing: 1 / mapping.zoomScale)
                }
                .onEnded { value in
                    defer { gestureMapping = nil }
                    guard let mapping = gestureMapping else { return }
                    guard lasso.isActive, input.mapping?.enabled == true else {
                        lasso.cancelGesture()
                        return
                    }
                    lasso.end(at: mapping.point(value.location), controller: controller,
                              size: mapping.paperSize, scale: mapping.rasterScale)
                })
            .onChange(of: dragging) { _, active in
                if !active, gestureMapping != nil {
                    gestureMapping = nil
                    lasso.cancelGesture()
                }
            }
            .onDisappear {
                if gestureMapping != nil {
                    gestureMapping = nil
                    lasso.cancelGesture()
                }
            }
            .accessibilityHidden(true)
    }
}
