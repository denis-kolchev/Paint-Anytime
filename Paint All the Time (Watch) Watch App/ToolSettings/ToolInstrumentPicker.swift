import SwiftUI

struct ToolInstrumentPicker: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var choiceAnimation: Animation? { reduceMotion ? nil : .easeOut(duration: 0.18) }
    let instruments: [DrawingInstrument]
    let instrumentIndex: Int
    let isActive: Bool
    let isEnabled: Bool
    var extendsBeyondViewport = false
    var showsNavigationHints = true
    let onSelect: (DrawingInstrument) -> Void

    private var rowHeight: CGFloat { 36 }

    var body: some View {
        VStack(spacing: 2) {
            if showsNavigationHints {
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(instrumentIndex > 0 ? 1 : 0.25)
                    .accessibilityHidden(true)
            }
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(spacing: 4) {
                            ForEach(instruments.indices, id: \.self) { index in
                                let instrument = instruments[index]
                                Button {
                                    onSelect(instrument)
                                } label: {
                                    ToolIcon(instrument: instrument)
                                        .scaleEffect(reduceMotion ? 1 : !isActive ? 0.35
                                                     : instrumentIndex == index ? 1 : 0.72)
                                        .animation(choiceAnimation, value: instrumentIndex)
                                        .frame(width: 40, height: rowHeight)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.borderless)
                                .disabled(!isEnabled)
                                .accessibilityLabel(instrument.title)
                                .accessibilityAddTraits(instrumentIndex == index ? [.isSelected] : [])
                                .id(index)
                            }
                        }
                        .padding(.vertical, max(0, (geometry.size.height - rowHeight) / 2))
                    }
                    .scrollIndicators(.hidden)
                    .scrollClipDisabled(extendsBeyondViewport)
                    .scrollDisabled(true)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.white, lineWidth: 1.5)
                            .frame(width: rowHeight, height: rowHeight)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    .onAppear { proxy.scrollTo(instrumentIndex, anchor: .center) }
                    .onChange(of: geometry.size.height) { _, _ in
                        proxy.scrollTo(instrumentIndex, anchor: .center)
                    }
                    .onChange(of: instrumentIndex) { _, index in
                        withAnimation(choiceAnimation) { proxy.scrollTo(index, anchor: .center) }
                    }
                }
            }
            if showsNavigationHints {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(instrumentIndex < instruments.count - 1 ? 1 : 0.25)
                    .accessibilityHidden(true)
                Text("\(instrumentIndex + 1)/\(instruments.count)")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
