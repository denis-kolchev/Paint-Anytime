import SwiftUI

/// The selection check over a grid tile in selection mode.
struct GallerySelectionMark: View {
    let isSelected: Bool
    let side: CGFloat

    var body: some View {
        let diameter = min(18, side * 0.4)
        ZStack {
            if isSelected {
                Color.black.opacity(0.25)
            }
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: diameter, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, isSelected ? Color.accentColor : .clear)
                .shadow(color: .black.opacity(0.4), radius: 1)
                .padding(3)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
