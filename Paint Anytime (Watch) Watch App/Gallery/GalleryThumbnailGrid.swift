import SwiftUI

/// Keep tile identities and offscreen positions alive across column changes.
/// Bitmap loading remains limited to the viewport and its prefetch margin.
struct GalleryThumbnailGrid: Layout {
    let columns: Int
    let spacing: CGFloat
    let side: CGFloat
    let leading: Int

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = (subviews.count + leading + columns - 1) / columns
        return CGSize(width: CGFloat(columns) * side + CGFloat(columns - 1) * spacing,
                      height: CGFloat(rows) * side + CGFloat(max(0, rows - 1)) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + CGFloat((index + leading) % columns) * (side + spacing),
                                     y: bounds.minY + CGFloat((index + leading) / columns) * (side + spacing)),
                          anchor: .topLeading,
                          proposal: ProposedViewSize(width: side, height: side))
        }
    }
}
