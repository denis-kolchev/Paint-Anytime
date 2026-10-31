import SwiftUI

/// The selected title stays centered with its neighboring settings visible,
/// matching the brush editor's carousel.
struct CanvasResizeCarousel: View {
    @Binding var selection: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let titles = ["Percentage", "Canvas width", "Height", "Resolution"]

    var body: some View {
        GeometryReader { geometry in
            let itemWidth = min(90, geometry.size.width / 2 - 8)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(titles.indices, id: \.self) { index in
                            Button {
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                                    selection = index
                                }
                            } label: {
                                Text(L10n.text(titles[index]))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(selection == index ? .primary : .secondary)
                                    .lineLimit(1).minimumScaleFactor(0.65)
                                    .frame(width: itemWidth, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selection == index ? .isSelected : [])
                            .id(index)
                        }
                    }
                    .padding(.horizontal, max(0, (geometry.size.width - itemWidth) / 2))
                }
                .scrollIndicators(.hidden)
                .scrollDisabled(true)
                .onAppear { proxy.scrollTo(selection, anchor: .center) }
                .onChange(of: selection) { _, index in
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
                .onChange(of: geometry.size.width) { _, _ in proxy.scrollTo(selection, anchor: .center) }
            }
        }
    }
}
