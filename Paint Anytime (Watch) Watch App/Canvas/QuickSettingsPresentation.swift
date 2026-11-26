import SwiftUI

/// Presents a quick action's settings. Kept out of `ContentView.body`, which is
/// already at the type checker's limit.
struct QuickSettingsPresentation: ViewModifier {
    @Binding var action: CanvasQuickAction?
    // Not observed: the presented views observe it themselves, and drawing must not
    // re-evaluate this modifier.
    let controller: CanvasController
    let viewportSize: CGSize

    private var settingsAction: Binding<CanvasQuickAction?> {
        Binding(get: { action == .canvasEditor ? nil : action }, set: { action = $0 })
    }

    private var showsEditor: Binding<Bool> {
        Binding(get: { action == .canvasEditor }, set: { if !$0 { action = nil } })
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: settingsAction) { action in
                CanvasQuickSettingsView(action: action, controller: controller, viewportSize: viewportSize)
            }
            // The editor opens directly, full screen: a sheet's clock band would take
            // the taps of its Reset and Save buttons.
            .fullScreenCover(isPresented: showsEditor) {
                CanvasLayoutEditorView(instrument: controller.pencilStyle.instrument)
            }
    }
}
