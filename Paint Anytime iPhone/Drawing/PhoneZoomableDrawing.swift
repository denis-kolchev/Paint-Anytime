import ImageIO
import SwiftUI
import UIKit

/// The opened drawing, fitted to the screen, with pinch zoom, panning and
/// double-tap zoom. Zooming happens inside the same layout: the toolbar and
/// navigation bar of `PhoneDrawingView` stay where they are.
struct PhoneZoomableDrawing: View {
    let url: URL
    var maximumSize = 2400
    /// A single tap while the drawing is zoomed in.
    var onZoomedTap: () -> Void = {}
    /// True once the drawing is zoomed in past its fitted size.
    var onZoomedChange: (Bool) -> Void = { _ in }
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                PhoneZoomableImage(image: image, onZoomedTap: onZoomedTap, onZoomedChange: onZoomedChange)
            } else if failed {
                Label("Preview unavailable", systemImage: "photo")
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            failed = false
            let sourceURL = url
            let size = maximumSize
            let loaded = await Task.detached(priority: .userInitiated) {
                guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else { return Optional<CGImage>.none }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: size
                ] as CFDictionary)
            }.value
            guard !Task.isCancelled else { return }
            if let loaded { image = UIImage(cgImage: loaded) } else { failed = true }
        }
    }
}

private struct PhoneZoomableImage: UIViewRepresentable {
    let image: UIImage
    let onZoomedTap: () -> Void
    let onZoomedChange: (Bool) -> Void

    func makeUIView(context: Context) -> ZoomView {
        let view = ZoomView()
        view.image = image
        updateCallbacks(view)
        return view
    }

    func updateUIView(_ view: ZoomView, context: Context) {
        updateCallbacks(view)
        if view.image !== image { view.image = image }
    }

    private func updateCallbacks(_ view: ZoomView) {
        view.onZoomedTap = onZoomedTap
        view.onZoomedChange = onZoomedChange
    }

    final class ZoomView: UIScrollView, UIScrollViewDelegate {
        private let imageView = UIImageView()
        /// Bounds the image was last fitted to; a new size refits at 100%.
        private var fittedSize: CGSize = .zero
        private static let doubleTapScale: CGFloat = 3
        var onZoomedTap: (() -> Void)?
        var onZoomedChange: ((Bool) -> Void)?
        private var isZoomed = false {
            didSet { if isZoomed != oldValue { onZoomedChange?(isZoomed) } }
        }

        var image: UIImage? {
            get { imageView.image }
            set {
                imageView.image = newValue
                fittedSize = .zero
                setNeedsLayout()
            }
        }

        init() {
            super.init(frame: .zero)
            delegate = self
            backgroundColor = .clear
            // The drawing extends beneath the bars; insets only center it.
            contentInsetAdjustmentBehavior = .never
            showsHorizontalScrollIndicator = false
            showsVerticalScrollIndicator = false
            decelerationRate = .fast
            bouncesZoom = true
            alwaysBounceVertical = false
            alwaysBounceHorizontal = false
            minimumZoomScale = 1
            maximumZoomScale = 8
            imageView.isAccessibilityElement = true
            imageView.accessibilityLabel = L10n.text("Drawing")
            addSubview(imageView)
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
            doubleTap.numberOfTapsRequired = 2
            addGestureRecognizer(doubleTap)
            // Waits for the double tap to fail, so zooming out never also
            // toggles the bars.
            let singleTap = UITapGestureRecognizer(target: self, action: #selector(singleTapped))
            singleTap.require(toFail: doubleTap)
            addGestureRecognizer(singleTap)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            if bounds.size != fittedSize { fitImage() }
            centerImage()
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerImage()
            // A small tolerance: the rubber band settles near, not at, 1.
            isZoomed = zoomScale > minimumZoomScale * 1.01
        }

        @objc private func singleTapped() {
            if isZoomed { onZoomedTap?() }
        }

        private func fitImage() {
            guard let size = imageView.image?.size, size.width > 0, size.height > 0,
                  bounds.width > 0, bounds.height > 0 else { return }
            fittedSize = bounds.size
            // Reset before setting the frame: it is defined at identity transform.
            zoomScale = 1
            let scale = min(bounds.width / size.width, bounds.height / size.height)
            imageView.frame = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
            contentSize = imageView.frame.size
            contentOffset = .zero
        }

        /// Keeps a drawing smaller than the screen in the middle.
        private func centerImage() {
            let horizontal = max(0, (bounds.width - contentSize.width) / 2)
            let vertical = max(0, (bounds.height - contentSize.height) / 2)
            let inset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
            if contentInset != inset { contentInset = inset }
        }

        @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
            if zoomScale > minimumZoomScale {
                setZoomScale(minimumZoomScale, animated: true)
                return
            }
            let point = recognizer.location(in: imageView)
            let scale = min(Self.doubleTapScale, maximumZoomScale)
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                            width: size.width, height: size.height), animated: true)
        }
    }
}
