import SwiftUI

struct InkComponentsEditor: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var crownFocused: Bool
    @Binding var values: [Double]
    let isHue: Bool
    let isActive: Bool
    @State private var selectedChannel = 0

    private var channels: [String] { isHue ? ["Hue", "Saturation", "Brightness"] : ["Red", "Green", "Blue"] }
    private var channelAnimation: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.3) }
    private func maximum(_ index: Int) -> Double { isHue ? (index == 0 ? 360 : 100) : 255 }
    private var color: Color { componentColor(values) }
    private func componentColor(_ components: [Double]) -> Color {
        if isHue {
            return Color(hue: components[0] / 360, saturation: components[1] / 100,
                         brightness: components[2] / 100)
        }
        return Color(.sRGB, red: components[0] / 255, green: components[1] / 255,
                     blue: components[2] / 255, opacity: 1)
    }
    private func valueLabel(_ index: Int) -> String {
        if isHue && index != 0 { return L10n.percent(values[index] / 100) }
        return "\(Int(values[index].rounded()))" + (isHue ? "°" : "")
    }
    private var channelValue: Binding<Double> {
        Binding { values[selectedChannel] } set: { value in
            guard isActive else { return }
            values[selectedChannel] = min(maximum(selectedChannel), max(0, value.rounded()))
        }
    }

    private var channelRows: some View {
        VStack(spacing: 6) {
            ForEach(channels.indices, id: \.self) { index in
                VStack(spacing: 2) {
                    Button { selectChannel(index) } label: {
                        HStack {
                            Text(L10n.text(channels[index]))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Spacer(minLength: 4)
                            Text(valueLabel(index)).monospacedDigit()
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .frame(height: 16)
                        .background(selectedChannel == index ? Color.white.opacity(0.16) : .clear,
                                    in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedChannel == index ? [.isSelected] : [])

                    HStack(spacing: 4) {
                        adjustmentButton("minus", amount: -1, channel: index).frame(width: 28)
                        channelSlider(index)
                        adjustmentButton("plus", amount: 1, channel: index).frame(width: 28)
                    }
                    // Keep the numeric scale increasing from left to right in every language.
                    .environment(\.layoutDirection, .leftToRight)
                    .frame(height: 18)
                }
                .frame(height: 36)
            }

        }
    }

    var body: some View {
        GeometryReader { geometry in
            // Three 36 pt rows and two 6 pt gaps. Scale the whole block only
            // when necessary, so labels and controls always fit together.
            let scale = min(1, max(0.01, geometry.size.height / 120))
            channelRows
                .frame(width: geometry.size.width / scale, height: 120)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .contentShape(Rectangle())
        .focusable(isActive)
        .focused($crownFocused)
        .modifier(SteppedCrownModifier(
            value: channelValue, range: 0...maximum(selectedChannel),
            context: selectedChannel * 2 + (isActive ? 1 : 0)))
        .onAppear { crownFocused = isActive }
        .onChange(of: isActive) { _, active in crownFocused = active }
    }

    private func endpointColor(_ value: Double, channel: Int) -> Color {
        var components = values
        components[channel] = value
        return componentColor(components)
    }

    private func gradientColors(_ index: Int) -> [Color] {
        if isHue && index == 0 {
            return (0...12).map { Color(hue: Double($0) / 12, saturation: 1, brightness: 1) }
        }
        return [endpointColor(0, channel: index), endpointColor(maximum(index), channel: index)]
    }

    private func channelSlider(_ index: Int) -> some View {
        WatchGradientSlider(
            value: Binding(get: { values[index] }, set: { value in
                selectedChannel = index
                channelValue.wrappedValue = value
                crownFocused = true
            }),
            maximum: maximum(index), colors: gradientColors(index), thumbColor: color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text(channels[index]))
        .accessibilityValue(valueLabel(index))
        .accessibilityAdjustableAction { direction in
            selectedChannel = index
            crownFocused = true
            switch direction {
            case .increment: channelValue.wrappedValue += 1
            case .decrement: channelValue.wrappedValue -= 1
            @unknown default: break
            }
        }
    }

    private func adjustmentButton(_ symbol: String, amount: Double, channel index: Int) -> some View {
        Button {
            selectedChannel = index
            channelValue.wrappedValue += amount
            crownFocused = true
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(amount > 0 ? values[index] >= maximum(index) : values[index] <= 0)
        .accessibilityLabel(L10n.text(channels[index]) + (amount > 0 ? " +1" : " −1"))
    }

    private func selectChannel(_ index: Int) {
        withAnimation(channelAnimation) { selectedChannel = index }
        crownFocused = true
    }

}
