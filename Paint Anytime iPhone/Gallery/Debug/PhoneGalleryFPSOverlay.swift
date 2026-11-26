#if DEBUG
import SwiftUI
import UIKit

/// Main-run-loop display cadence, not a count of GPU-presented frames.
struct PhoneGalleryFPSOverlay: UIViewRepresentable {
    func makeUIView(context: Context) -> FPSLabel { FPSLabel() }
    func updateUIView(_ uiView: FPSLabel, context: Context) {}

    static func dismantleUIView(_ uiView: FPSLabel, coordinator: ()) {
        uiView.stop()
    }

    final class FPSLabel: UILabel {
        private var displayLink: CADisplayLink?
        private var sampleStart: CFTimeInterval?
        private var frames = 0
        private var lastCallback: CFTimeInterval?
        private var peakGapMS: Double = 0

        init() {
            super.init(frame: .zero)
            text = "FPS: —"
            numberOfLines = 2
            font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            textColor = .white
            textAlignment = .center
            backgroundColor = UIColor.black.withAlphaComponent(0.75)
            layer.cornerRadius = 6
            clipsToBounds = true
            isUserInteractionEnabled = false
            accessibilityElementsHidden = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            stop()
            guard window != nil else { return }
            let target = TickTarget(label: self)
            let link = CADisplayLink(target: target, selector: #selector(TickTarget.tick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        func stop() {
            displayLink?.invalidate()
            displayLink = nil
            sampleStart = nil
            frames = 0
            lastCallback = nil
            peakGapMS = 0
        }

        func tick(_ link: CADisplayLink) {
            guard UIApplication.shared.applicationState == .active else {
                sampleStart = nil
                frames = 0
                lastCallback = nil
                return
            }
            let now = CACurrentMediaTime()
            if let lastCallback {
                peakGapMS = max(peakGapMS, (now - lastCallback) * 1000)
            }
            lastCallback = now
            guard let sampleStart else {
                self.sampleStart = link.timestamp
                return
            }
            frames += 1
            let elapsed = link.timestamp - sampleStart
            guard elapsed >= 0.5 else { return }
            text = "FPS: \(Int((Double(frames) / elapsed).rounded()))\npeak gap: \(Int(peakGapMS.rounded())) ms"
            self.sampleStart = link.timestamp
            frames = 0
        }
    }

    // CADisplayLink retains its target; keep the view reference weak so removing
    // the gallery cannot leave a running display link and retained view behind.
    final class TickTarget: NSObject {
        weak var label: FPSLabel?
        init(label: FPSLabel) { self.label = label }

        @objc func tick(_ link: CADisplayLink) {
            guard let label else {
                link.invalidate()
                return
            }
            label.tick(link)
        }
    }
}
#endif
