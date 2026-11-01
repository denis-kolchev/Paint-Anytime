import SwiftUI

/// Hides the system clock over the canvas so strokes can start in its band.
/// The clock otherwise swallows touch-down there; toolbar items stay installed.
struct CanvasClockVisibility: ViewModifier {
    let isHidden: Bool
    // Hiding the clock while the app launches crashes on watchOS;
    // apply it only after the canvas has settled on screen.
    @State private var isSettled = false

    func body(content: Content) -> some View {
        content
            .task {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                isSettled = true
            }
            // watchOS keeps its clock visible with persistentSystemOverlays(.hidden).
            // Its SDK exposes status-bar visibility through this underscored modifier.
            ._statusBarHidden(isHidden && isSettled)
    }
}
