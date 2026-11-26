import SwiftUI

/// Keeps the palette draft alive while sampling the composited canvas.
/// ✕ and ✓ match the free camera's controls: the native toolbar slot only
/// anchors and takes taps, and the visible circle is canvas glass drawn on top.
struct PaletteEyedropperView: View {
    @ObservedObject var controller: CanvasController
    let onCancel: () -> Void
    let onConfirm: (SIMD4<Float>) -> Void
    @State private var isMoving = true
    @State private var color: SIMD4<Float>?
    @State private var controls: [CanvasToolbarControl: CGRect] = [:]
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        NavigationStack {
            WatchCanvasView(controller: controller, protectedControls: controls,
                isMovingCanvas: $isMoving, isEyedropperActive: true,
                onSampleColor: { color = $0 })
                .ignoresSafeArea()
                .toolbar {
                    // Occupies the cover's cancellation slot. Left empty, watchOS
                    // inserts its own close button under the glass ✕ and the two
                    // circles stack. Like Done, only its slot and tap are used.
                    ToolbarItem(placement: .cancellationAction) {
                        Button(action: onCancel) {
                            Color.clear.frame(width: 18, height: 18)
                        }
                        .watchToolbarButtonStyle(usesCanvasMaterial: true, hidesNativeChrome: true)
                        .accessibilityLabel(L10n.text("Cancel"))
                        .trackCanvasControl(.more, frames: $controls)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { if let color { onConfirm(color) } } label: {
                            Color.clear.frame(width: 18, height: 18)
                        }
                        .disabled(color == nil)
                        .watchToolbarButtonStyle(usesCanvasMaterial: true, hidesNativeChrome: true)
                        .accessibilityLabel(L10n.text("Done"))
                        .trackCanvasControl(.tools, frames: $controls)
                    }
                }
        }
        .overlay {
            GeometryReader { geometry in
                let origin = geometry.frame(in: .global).origin
                let panel = MorphPanelGeometry(size: geometry.size, layoutDirection: layoutDirection)
                let done = controls[.tools].map { CGPoint(x: $0.midX - origin.x, y: $0.midY - origin.y) }
                    ?? CGPoint(x: panel.trailingX, y: panel.top + 18)
                ZStack {
                    // The native slot under it takes the tap.
                    glassIcon("checkmark", style: .green, diameter: panel.diameter)
                        .opacity(color == nil ? 0.45 : 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .position(done)
                    // Drawn at the cancellation slot. If an older watchOS drops that
                    // slot in a full-screen cover, it mirrors Done and takes the tap itself.
                    let cancel = controls[.more].map { CGPoint(x: $0.midX - origin.x, y: $0.midY - origin.y) }
                    Button(action: onCancel) {
                        glassIcon("xmark", style: .primary, diameter: panel.diameter)
                    }
                    .buttonStyle(CanvasMorphButtonStyle())
                    .allowsHitTesting(cancel == nil)
                    .accessibilityHidden(cancel != nil)
                    .accessibilityLabel(L10n.text("Cancel"))
                    .position(cancel ?? CGPoint(x: geometry.size.width - done.x, y: done.y))
                }
            }
            .ignoresSafeArea()
        }
        // A cover nested in another cover does not reliably keep the canvas's
        // dark appearance; light glass dimmed the icons over a pale drawing.
        .environment(\.colorScheme, .dark)
    }

    /// The free camera's icon: same symbol weight, diameter and adaptive glass.
    private func glassIcon(_ symbol: String, style: Color, diameter: CGFloat) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            // Inside the glass modifier, which otherwise sets its own foreground.
            .foregroundStyle(style)
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
            .modifier(CanvasMorphGlass(adaptsToCanvas: true, isInteractive: false))
    }

}
