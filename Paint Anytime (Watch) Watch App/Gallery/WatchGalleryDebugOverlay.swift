#if DEBUG
import SwiftUI

/// Poll isolated diagnostic state; never invalidate the gallery for a label tick.
struct WatchGalleryDebugOverlay: View {
    let snapshot: () -> String
    @ObservedObject private var renderDebug = RenderDebugSettings.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var text = "Input —"

    var body: some View {
        if renderDebug.showsDebugInfo {
            panel
        }
    }

    private var panel: some View {
        Text(verbatim: text)
            .font(.system(size: 8, weight: .medium, design: .monospaced))
            .foregroundStyle(.white)
            .padding(4)
            .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
            .fixedSize(horizontal: true, vertical: true)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: scenePhase) {
                guard scenePhase == .active, GalleryDebug.isEnabled else { return }
                while !Task.isCancelled {
                    text = snapshot()
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                }
            }
    }
}
/// Tap/Back responsiveness, drawn at the app root above `MenuGalleryTransitionHUD`
/// so neither the gallery stack nor the menu timeline covers it.
struct WatchGalleryTapHUD: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var renderDebug = RenderDebugSettings.shared
    @State private var text: String?

    var body: some View {
        // A real container, not Group: modifiers on an empty Group are dropped,
        // so `.task` never started and the panel stayed hidden.
        ZStack {
            if let text, renderDebug.showsDebugInfo {
                Text(verbatim: text)
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(.yellow)
                    .padding(4)
                    .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
                    .fixedSize()
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: TaskKey(phase: scenePhase, isShown: renderDebug.showsDebugInfo)) {
            guard scenePhase == .active, renderDebug.showsDebugInfo,
                  WatchGalleryDiagnostics.tapPanelEnabled else { return }
            while !Task.isCancelled {
                let next = WatchGalleryDiagnostics.shared.tapSnapshot?()
                if next != text { text = next }
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            }
        }
    }

    private struct TaskKey: Equatable {
        let phase: ScenePhase
        let isShown: Bool
    }
}
#endif
