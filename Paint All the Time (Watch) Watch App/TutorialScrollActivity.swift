import SwiftUI

// Observe content movement on watchOS 10 without intercepting touch or Crown scrolling.
private struct LegacyScrollPositionKey: PreferenceKey {
    static var defaultValue: CGFloat? { nil }

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() { value = next }
    }
}

extension View {
    @ViewBuilder
    func reportLegacyScrollPosition() -> some View {
        if #available(watchOS 11.0, *) {
            self
        } else {
            background {
                GeometryReader { geometry in
                    Color.clear.preference(key: LegacyScrollPositionKey.self,
                                           value: geometry.frame(in: .global).minY)
                }
            }
        }
    }

    @ViewBuilder
    func onTutorialScrollActivity(_ activity: @escaping () -> Void) -> some View {
        if #available(watchOS 11.0, *) {
            onScrollPhaseChange { _, _ in activity() }
                .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, _ in
                    activity()
                }
        } else {
            onPreferenceChange(LegacyScrollPositionKey.self) { position in
                if position != nil { activity() }
            }
        }
    }
}
