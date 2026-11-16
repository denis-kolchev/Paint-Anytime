import SwiftUI
import UIKit

/// Reports whether the system places its vertical bar (iPhone Duo) on the
/// leading edge. SwiftUI has no environment value for
/// `UITraitCollection.verticalBarEdge`, so a hosted UIView reads it.
@available(iOS 27.1, *)
struct PhoneVerticalBarEdgeReader: UIViewRepresentable {
    @Binding var isLeading: Bool

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.isUserInteractionEnabled = false
        view.onChange = { isLeading = $0 }
        return view
    }

    func updateUIView(_ view: ReaderView, context: Context) {
        view.onChange = { isLeading = $0 }
    }

    final class ReaderView: UIView {
        var onChange: ((Bool) -> Void)?
        private var reported: Bool?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        // Rotation and folding resize this full-screen view and change the
        // safe area, so layout covers every change of the bar's edge.
        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            report()
        }

        private func report() {
            guard let window else { return }
            // The trait gives the system's preferred edge whether or not the bar
            // currently shows, so moving the button cannot flip the result.
            let isLeading = window.traitCollection.verticalBarEdge == .leading
            guard reported != isLeading else { return }
            reported = isLeading
            // UIKit layout can run during a SwiftUI update; publish afterwards.
            DispatchQueue.main.async { [weak self] in self?.onChange?(isLeading) }
        }
    }
}
