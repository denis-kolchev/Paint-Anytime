import SwiftUI

/// Collects requests to hide the system clock from anywhere below the root.
/// The canvas hides it so strokes can start in its band: the clock otherwise
/// swallows touch-down there. Toolbar items stay installed.
private struct ClockHiddenRequestKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

extension View {
    /// Asks the root `ClockVisibilityHost` to hide the system clock while `hidden` is true.
    func requestsHiddenClock(_ hidden: Bool) -> some View {
        // Combine with nested requests; preference(key:value:) would replace them.
        transformPreference(ClockHiddenRequestKey.self) { $0 = $0 || hidden }
    }
}

/// The single owner of status-bar visibility. Nested `_statusBarHidden`
/// modifiers conflict: the editor kept behind the tutorial showed the clock
/// over the lesson canvas. Views report requests; only this host applies them.
struct ClockVisibilityHost: ViewModifier {
    @State private var isRequested = false
    // Hiding the clock while the app launches crashes on watchOS;
    // apply it only after the content has settled on screen.
    @State private var isSettled = false

    func body(content: Content) -> some View {
        content
            // Animated, so the clock fades in and out with the pages that request it
            // instead of appearing or vanishing in one frame.
            .onPreferenceChange(ClockHiddenRequestKey.self) { requested in
                withAnimation(.easeInOut(duration: 0.25)) { isRequested = requested }
            }
            .task {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                isSettled = true
            }
            // watchOS keeps its clock visible with persistentSystemOverlays(.hidden).
            // Its SDK exposes status-bar visibility through this underscored modifier.
            ._statusBarHidden(isRequested && isSettled)
    }
}
