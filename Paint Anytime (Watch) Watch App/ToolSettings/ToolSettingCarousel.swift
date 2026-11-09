import SwiftUI

struct ToolSettingCarousel: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @State private var measuredTitleWidth: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let availableSettings: [ToolSetting]
    let selection: ToolSetting
    let isEnabled: (ToolSetting) -> Bool
    let onSelect: (ToolSetting) -> Void
    var tutorial: TutorialSession = .inactive
    var trailingInset: CGFloat = 0
    private var pageAnimation: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.3) }

    private func hintSteps(for setting: ToolSetting) -> Set<TutorialStep> {
        guard setting != selection else { return [] }
        switch setting {
        case .width: return [.openWidth]
        case .opacity: return [.openOpacity]
        case .instrument: return [.openTool, .selectReed, .chooseReed]
        case .direction: return [.openAngle]
        default: return []
        }
    }

    /// A position counted from the Tool title, so switching brushes keeps every slot in place
    /// and only changes the title it shows.
    private struct Slot: Identifiable {
        let id: Int
        let setting: ToolSetting
    }

    private var anchorIndex: Int { availableSettings.firstIndex(of: .instrument) ?? 0 }

    private var slots: [Slot] {
        let anchor = anchorIndex
        return availableSettings.enumerated().map { Slot(id: $0.offset - anchor, setting: $0.element) }
    }

    private func slotID(of setting: ToolSetting) -> Int {
        (availableSettings.firstIndex(of: setting) ?? anchorIndex) - anchorIndex
    }

    private let titleFont = Font.caption.weight(.semibold)
    private let titleHorizontalPadding: CGFloat = 4

    private func itemWidth(in viewportWidth: CGFloat) -> CGFloat {
        // Keep the neighboring title's center at least 8 pt inside the viewport,
        // so even a short translation remains visible beside a longer title.
        let maximum = min(100, max(0, viewportWidth / 2 - 8))
        return min(maximum, max(44, ceil(measuredTitleWidth) + 2 * titleHorizontalPadding))
    }

    private var titleMeasurements: some View {
        // Measure the actual localized SwiftUI font before scaling or constraining it.
        ZStack {
            ForEach(availableSettings, id: \.rawValue) { setting in
                Text(setting.title)
                    .font(titleFont)
                    .fixedSize()
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: ToolSettingTitleWidthKey.self,
                                                   value: geometry.size.width)
                        }
                    }
            }
        }
        .hidden()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = itemWidth(in: geometry.size.width)
            let titleWidth = max(0, width - 2 * titleHorizontalPadding)
            // Reserve space for angle controls without resizing the titles.
            let viewportWidth = max(0, geometry.size.width - trailingInset)
            let sideInset = max(0, (viewportWidth - width) / 2)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(slots) { slot in
                            let setting = slot.setting
                            Button {
                                onSelect(setting)
                            } label: {
                                Text(setting.title)
                                    .font(titleFont)
                                    .foregroundStyle(selection == setting ? .primary : .secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.1)
                                    // A slot that now names another setting cross-fades in place.
                                    .contentTransition(.opacity)
                                    .frame(width: titleWidth, height: 30)
                                    .clipped()
                                    .padding(.horizontal, titleHorizontalPadding)
                                    .frame(width: width, height: 30)
                                    .contentShape(Rectangle())
                                    .tutorialHint(tutorial, steps: hintSteps(for: setting))
                            }
                            .buttonStyle(.borderless)
                            .disabled(!isEnabled(setting))
                            .accessibilityAddTraits(selection == setting ? [.isSelected] : [])
                            .id(slot.id)
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.7).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, sideInset)
                    .animation(pageAnimation, value: availableSettings)
                }
                .scrollIndicators(.hidden)
                .scrollDisabled(true)
                .onAppear { proxy.scrollTo(slotID(of: selection), anchor: .center) }
                .onChange(of: width) { _, _ in
                    proxy.scrollTo(slotID(of: selection), anchor: .center)
                }
                .onChange(of: viewportWidth) { _, _ in
                    withAnimation(tutorial.isActive ? pageAnimation : nil) {
                        proxy.scrollTo(slotID(of: selection), anchor: .center)
                    }
                }
                .onChange(of: selection) { _, setting in
                    withAnimation(pageAnimation) {
                        proxy.scrollTo(slotID(of: setting), anchor: .center)
                    }
                }
                .onChange(of: availableSettings) { _, _ in
                    withAnimation(pageAnimation) {
                        proxy.scrollTo(slotID(of: selection), anchor: .center)
                    }
                }
            }
            .padding(.trailing, trailingInset)
        }
        .background { titleMeasurements.id(languageCode) }
        .onPreferenceChange(ToolSettingTitleWidthKey.self) { measuredTitleWidth = $0 }
    }
}

private struct ToolSettingTitleWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
