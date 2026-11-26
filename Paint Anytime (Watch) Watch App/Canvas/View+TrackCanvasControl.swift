import SwiftUI

extension View {
    func trackCanvasControl(_ control: CanvasToolbarControl,
                            frames: Binding<[CanvasToolbarControl: CGRect]>) -> some View {
        onGeometryChange(for: CGRect.self) { geometry in
            // Toolbar items and the canvas have different local coordinate spaces.
            TutorialDebug.measure("toolbar.geometry.read") { geometry.frame(in: .global) }
        } action: { frame in
            guard frames.wrappedValue[control] != frame else { return }
            TutorialDebug.trace("toolbar.geometry.beforeWrite", "control=\(control) old=\(String(describing: frames.wrappedValue[control])) new=\(frame)")
            frames.wrappedValue[control] = frame
            TutorialDebug.trace("toolbar.geometry.afterWrite", "control=\(control)")
        }
    }
}
