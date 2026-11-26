import SwiftUI

/// A short notice over the canvas, such as a saved artwork or a layer move.
struct CanvasNoticeLabel: View {
    let text: String
    var minimumScaleFactor: CGFloat = 1

    var body: some View {
        Text(text)
            .font(.headline)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .minimumScaleFactor(minimumScaleFactor)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 42)
    }
}
