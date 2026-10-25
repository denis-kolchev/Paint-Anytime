import SwiftUI

/// Preview, title, and settings share one compact, stable drag slot.
struct LayerCard<Preview: View>: View {
    let title: String
    let canvasSize: CGSize
    let onSelect: (() -> Void)?
    let onEdit: () -> Void
    @ViewBuilder let preview: () -> Preview

    private let previewHeight: CGFloat = 52

    var body: some View {
        GeometryReader { geometry in
            let ratio = canvasSize.width > 0 && canvasSize.height > 0
                ? canvasSize.width / canvasSize.height : 200.0 / 240.0
            let previewWidth = min(previewHeight * ratio, geometry.size.width * 0.45)
            HStack(spacing: 6) {
                selectionTarget {
                    preview()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .frame(width: previewWidth, height: previewHeight)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(title)

                selectionTarget {
                    Text(title)
                        .font(.system(size: 15))
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .frame(maxWidth: .infinity)

                Button(action: onEdit) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 30, height: previewHeight)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(L10n.text("Settings") + ": " + title)
            }
            .frame(height: previewHeight)
            .buttonStyle(.plain)
        }
        .frame(height: previewHeight)
        .padding(4)
        .background(.gray.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func selectionTarget<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        if let onSelect {
            Button(action: onSelect, label: label)
        } else {
            label()
        }
    }
}
