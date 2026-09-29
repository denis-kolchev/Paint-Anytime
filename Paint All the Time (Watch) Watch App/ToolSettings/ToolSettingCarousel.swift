import SwiftUI

struct ToolSettingCarousel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let availableSettings: [ToolSetting]
    let selection: ToolSetting
    let isEnabled: (ToolSetting) -> Bool
    let onSelect: (ToolSetting) -> Void
    private var pageAnimation: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.3) }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(availableSettings, id: \.rawValue) { setting in
                            Button {
                                onSelect(setting)
                            } label: {
                                Text(setting.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(selection == setting ? .primary : .secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.65)
                                    .frame(width: 90, height: 30)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .disabled(!isEnabled(setting))
                            .accessibilityAddTraits(selection == setting ? [.isSelected] : [])
                            .id(setting)
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.7).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, max(0, (geometry.size.width - 90) / 2))
                    .animation(pageAnimation, value: availableSettings)
                }
                .scrollIndicators(.hidden)
                .scrollDisabled(true)
                .onAppear { proxy.scrollTo(selection, anchor: .center) }
                .onChange(of: selection) { _, setting in
                    withAnimation(pageAnimation) {
                        proxy.scrollTo(setting, anchor: .center)
                    }
                }
                .onChange(of: availableSettings) { _, _ in
                    withAnimation(pageAnimation) {
                        proxy.scrollTo(selection, anchor: .center)
                    }
                }
            }
        }
    }
}
