import SwiftUI

/// Keeps the palette draft alive while sampling the composited canvas.
struct PaletteEyedropperView: View {
    @ObservedObject var controller: CanvasController
    let onCancel: () -> Void
    let onConfirm: (SIMD4<Float>) -> Void
    @State private var isMoving = true
    @State private var color: SIMD4<Float>?
    @State private var controls: [CanvasToolbarControl: CGRect] = [:]

    var body: some View {
        NavigationStack {
            WatchCanvasView(controller: controller, protectedControls: controls,
                isMovingCanvas: $isMoving, isEyedropperActive: true,
                onSampleColor: { color = $0 })
                .ignoresSafeArea()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        // Styled like the canvas camera tool's Done: canvas glass,
                        // not the native chrome that renders as a ring over the drawing.
                        Button { if let color { onConfirm(color) } } label: {
                            Image(systemName: "checkmark")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.green)
                                .frame(width: 18, height: 18)
                        }
                        .disabled(color == nil)
                        .watchToolbarButtonStyle(usesCanvasMaterial: true)
                        .accessibilityLabel(L10n.text("Done"))
                        .trackCanvasControl(.tools, frames: $controls)
                    }
                }
        }
        // A full-screen cover can suppress the native leading toolbar slot on
        // older watchOS. Place Cancel explicitly and align it with Done.
        .overlay {
            GeometryReader { geometry in
                let origin = geometry.frame(in: .global).origin
                let doneFrame = controls[.tools]
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                }
                .watchToolbarButtonStyle(usesCanvasMaterial: true)
                .accessibilityLabel(L10n.text("Cancel"))
                .trackCanvasControl(.more, frames: $controls)
                .position(x: doneFrame.map { geometry.size.width - ($0.midX - origin.x) } ?? 30,
                          y: doneFrame.map { $0.midY - origin.y } ?? 30)
            }
        }
        // A cover nested in another cover does not reliably keep the canvas's
        // dark appearance; light glass dimmed the icons over a pale drawing.
        .environment(\.colorScheme, .dark)
    }

}
