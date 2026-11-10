import SwiftUI

struct DestructiveConfirmationView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @Environment(\.layoutDirection) private var layoutDirection
    let title: String
    let confirmTitle: String
    var cancelTitle: String = L10n.text("No")
    /// Fit one screen: no scrolling, and the title shrinks so both buttons stay visible.
    var fitsScreen = false
    var onCancel: () -> Void
    var onConfirm: () -> Void

    var body: some View {
        if fitsScreen {
            VStack(spacing: 12) {
                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.5)
                    .allowsTightening(true)
                    // Take only the height the buttons leave; the text scales into it.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                buttons
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .background(.black)
        } else {
            ScrollView {
                VStack(spacing: 20) {
                    Text(title)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    buttons
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 16)
            }
            .background(.black)
        }
    }

    private var buttons: some View {
        ConfirmationButtonsLayout(layoutDirection: layoutDirection) {
            Button(action: onCancel) {
                Text(cancelTitle)
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .watchActionButtonStyle()

            Button(role: .destructive, action: onConfirm) {
                Text(confirmTitle)
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .watchActionButtonStyle()
            .tint(.red)
            .foregroundStyle(.red)
        }
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }
}

/// Share spare width equally after measuring the localized button labels.
private struct ConfirmationButtonsLayout: Layout {
    let layoutDirection: LayoutDirection
    private let spacing: CGFloat = 8

    private func widths(for proposedWidth: CGFloat?, subviews: Subviews) -> [CGFloat] {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }
        guard ideal.count == 2 else { return ideal }
        let available = max(0, (proposedWidth ?? (ideal[0] + ideal[1] + spacing)) - spacing)
        let minimum = min(44, available / 2)
        let first = min(available - minimum, max(minimum, (available + ideal[0] - ideal[1]) / 2))
        return [first, available - first]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths = widths(for: proposal.width, subviews: subviews)
        let height = zip(subviews, widths).map { view, width in
            view.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }.max() ?? 0
        return CGSize(width: widths.reduce(0, +) + spacing, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = widths(for: bounds.width, subviews: subviews)
        var offset: CGFloat = 0
        for (view, width) in zip(subviews, widths) {
            let x = layoutDirection == .rightToLeft
                ? bounds.maxX - offset - width / 2
                : bounds.minX + offset + width / 2
            view.place(at: CGPoint(x: x, y: bounds.midY), anchor: .center,
                       proposal: ProposedViewSize(width: width, height: bounds.height))
            offset += width + spacing
        }
    }
}
