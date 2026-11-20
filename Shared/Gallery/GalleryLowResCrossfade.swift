import SwiftUI

/// Fades a gallery image in over its low-resolution stand-in, so a tile never
/// switches from the 32 px snapshot to the sharp thumbnail in a single frame.
/// Used by the watch and iPhone galleries.
///
/// A tile whose sharp image is already available when it appears shows it at
/// once; only a stand-in that was actually on screen fades out.
struct GalleryLowResCrossfade<Sharp: View, LowRes: View>: View {
    let showsSharp: Bool
    @ViewBuilder let sharp: () -> Sharp
    @ViewBuilder let lowRes: () -> LowRes
    /// Opacity target of the sharp layer.
    @State private var revealed: Bool
    /// Keeps the stand-in under the sharp layer until the fade completes.
    @State private var fading = false

    init(showsSharp: Bool, @ViewBuilder sharp: @escaping () -> Sharp,
         @ViewBuilder lowRes: @escaping () -> LowRes) {
        self.showsSharp = showsSharp
        self.sharp = sharp
        self.lowRes = lowRes
        _revealed = State(initialValue: showsSharp)
    }

    var body: some View {
        ZStack {
            if !showsSharp || fading || !revealed {
                lowRes()
            }
            if showsSharp {
                sharp()
                    .opacity(revealed ? 1 : 0)
            }
        }
        .onChange(of: showsSharp) { _, sharp in
            guard sharp else {
                revealed = false
                fading = false
                return
            }
            fading = true
            withAnimation(GalleryLowResFade.animation) {
                revealed = true
            } completion: {
                fading = false
            }
        }
    }
}

/// Timing shared by the SwiftUI crossfade and Canvas-drawn galleries.
enum GalleryLowResFade {
    static let duration = 0.25
    static var animation: Animation { .easeOut(duration: duration) }

    /// Opacity of a sharp image `elapsed` seconds after it arrived, with the
    /// same ease-out curve as `animation`.
    static func opacity(elapsed: Double) -> Double {
        let t = min(1, max(0, elapsed / duration))
        return 1 - (1 - t) * (1 - t)
    }
}
