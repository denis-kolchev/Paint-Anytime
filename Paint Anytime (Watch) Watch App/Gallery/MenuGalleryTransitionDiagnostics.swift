import Observation
import SwiftUI

/// Animated state of the menu → gallery transition, observed only where it is drawn.
@MainActor
@Observable
final class MenuGalleryTransitionState {
    var galleryOpacity: Double = 1
    /// The menu's system blur vanishes in one frame when its sheet is removed. The gallery
    /// carries its own blur and dim under the menu instead, then clears them gradually.
    var galleryBlur: CGFloat = 0
    var galleryDim: Double = 0
    var hidesMenuContent = false
    /// False while the gallery is only prewarmed under the menu: no Crown, no input.
    var galleryActive = true
    /// The grid has built its first tiles, so the transition will not stall on them.
    @ObservationIgnored private(set) var galleryReady = false
    @ObservationIgnored private var pendingStart: (@MainActor () -> Void)?

    /// A new gallery is being mounted invisibly, active or prewarmed.
    func prepareForMount(active: Bool) {
        galleryReady = false
        pendingStart = nil
        galleryOpacity = 0
        galleryBlur = Self.menuBlurRadius
        galleryDim = Self.menuDim
        hidesMenuContent = false
        galleryActive = active
    }

    /// Roughly the menu sheet's material over the gallery (tuned by eye on watch).
    static let menuBlurRadius: CGFloat = 20
    static let menuDim = 0.3

    func reset() {
        galleryReady = false
        pendingStart = nil
        galleryOpacity = 1
        galleryBlur = 0
        galleryDim = 0
        hidesMenuContent = false
        galleryActive = true
    }

    func markGalleryReady() {
        guard !galleryReady else { return }
        galleryReady = true
        MenuGalleryTransitionDiagnostics.shared.mark("ready")
        guard let start = pendingStart else { return }
        pendingStart = nil
        DispatchQueue.main.async { start() }
    }

    /// Runs `start` on the next run-loop turn once the grid is ready, or after `timeout`.
    func whenGalleryReady(timeout: Double, _ start: @escaping @MainActor () -> Void) {
        if galleryReady {
            DispatchQueue.main.async { start() }
            return
        }
        pendingStart = start
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, let start = self.pendingStart else { return }
            self.pendingStart = nil
            MenuGalleryTransitionDiagnostics.shared.mark("ready timeout")
            start()
        }
    }
}

/// Gives the Crown to the gallery when a prewarmed gallery becomes the active screen,
/// without making the gallery's own body depend on the flag.
struct GalleryActivationObserver: View {
    let state: MenuGalleryTransitionState
    let onActivate: () -> Void

    var body: some View {
        Color.clear
            .onChange(of: state.galleryActive) { _, active in
                if active { onActivate() }
            }
    }
}

struct GalleryRevealOpacity: ViewModifier {
    let state: MenuGalleryTransitionState
    func body(content: Content) -> some View {
        content
            // Skipped entirely at zero, so the open gallery pays nothing for it.
            .blur(radius: state.galleryBlur, opaque: true)
            .overlay {
                if state.galleryDim > 0 {
                    Color.black.opacity(state.galleryDim).allowsHitTesting(false)
                }
            }
            .opacity(state.galleryOpacity)
    }
}

/// Timeline of the menu → gallery transition, in milliseconds from the tap,
/// plus frame gaps while it runs. Debug builds only; release calls do nothing.
@MainActor
@Observable
final class MenuGalleryTransitionDiagnostics {
    static let shared = MenuGalleryTransitionDiagnostics()
    #if DEBUG
    /// Separate from `GalleryDebug`, which also installs fixture images.
    nonisolated static let isEnabled = true
    #else
    nonisolated static let isEnabled = false
    #endif

    /// Only this flag is observed: it unpauses the HUD's frame clock.
    private(set) var isRecording = false

    @ObservationIgnored private var run = 0
    @ObservationIgnored private var start: Double = 0
    @ObservationIgnored private var events: [(String, Double)] = []
    @ObservationIgnored private var lastFrame: Double?
    @ObservationIgnored private var frames = 0
    @ObservationIgnored private var longFrames: [(at: Double, gap: Double)] = []
    @ObservationIgnored private var firstFrameAfter: [String: Double] = [:]
    @ObservationIgnored private var awaitingFrame: [String] = []
    @ObservationIgnored private var tiles: [URL: String] = [:]
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var marked: Set<String> = []
    @ObservationIgnored private var loads = 0
    @ObservationIgnored private var loadSpan: (first: Double, last: Double)?

    private var now: Double { ProcessInfo.processInfo.systemUptime }
    private func ms(_ time: Double) -> Double { (time - start) * 1000 }

    func begin() {
        guard Self.isEnabled else { return }
        run += 1
        start = now
        events = [("tap", 0)]
        lastFrame = nil
        frames = 0
        longFrames = []
        firstFrameAfter = [:]
        awaitingFrame = []
        tiles = [:]
        marked = []
        loads = 0
        loadSpan = nil
        isRecording = true
        stopTask?.cancel()
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.isRecording = false
        }
    }

    /// `awaitsFrame` also records when the next frame after this event was drawn.
    func mark(_ name: String, awaitsFrame: Bool = false) {
        guard Self.isEnabled, isRecording else { return }
        events.append((name, ms(now)))
        if awaitsFrame { awaitingFrame.append(name) }
    }

    func markOnce(_ name: String) {
        guard Self.isEnabled, isRecording, !marked.contains(name) else { return }
        marked.insert(name)
        mark(name, awaitsFrame: true)
    }

    /// A sharp thumbnail arrived on the main actor during the transition.
    func loadFinished() {
        guard Self.isEnabled, isRecording else { return }
        let time = ms(now)
        loads += 1
        loadSpan = (loadSpan?.first ?? time, time)
    }

    func note(_ name: String, value: Double) {
        guard Self.isEnabled, isRecording else { return }
        events.append((name, value))
    }

    /// What a grid tile showed during the transition: sharp, low-res preview or gray.
    func tile(_ url: URL, _ kind: String) {
        guard Self.isEnabled, isRecording else { return }
        tiles[url] = kind
    }

    /// Called by every HUD on every frame; two HUDs in one frame count once.
    func frame() {
        guard Self.isEnabled, isRecording else { return }
        let time = now
        if let lastFrame {
            let gap = (time - lastFrame) * 1000
            guard gap > 4 else { return }
            if gap > 25 { longFrames.append((ms(time), gap)) }
        }
        lastFrame = time
        frames += 1
        for name in awaitingFrame { firstFrameAfter[name] = ms(time) }
        awaitingFrame = []
    }

    var text: String {
        guard run > 0 else { return "menu→gallery: tap Gallery" }
        var lines = ["MENU→GALLERY #\(run)\(isRecording ? " ●" : "")"]
        for (name, value) in events {
            var line = name.padding(toLength: 10, withPad: " ", startingAt: 0) + String(format: "%5.0f", value)
            if let drawn = firstFrameAfter[name] { line += String(format: " →frame %.0f", drawn) }
            lines.append(line)
        }
        let worst = longFrames.max { $0.gap < $1.gap }
        lines.append(String(format: "frames %d  long>25ms %d", frames, longFrames.count))
        if let worst { lines.append(String(format: "worst %.0fms @%.0f", worst.gap, worst.at)) }
        if !longFrames.isEmpty {
            lines.append(longFrames.prefix(5).map { String(format: "%.0f@%.0f", $0.gap, $0.at) }.joined(separator: " "))
        }
        if let loadSpan {
            lines.append(String(format: "sharp loads %d  %.0f…%.0f", loads, loadSpan.first, loadSpan.last))
        }
        let counts = Dictionary(grouping: tiles.values, by: { $0 }).mapValues(\.count)
        lines.append("tiles sharp \(counts["sharp"] ?? 0) low \(counts["low"] ?? 0) gray \(counts["gray"] ?? 0)")
        return lines.joined(separator: "\n")
    }
}

/// Drawn both inside the menu sheet (which covers the app) and over the canvas
/// stack, so the timeline stays visible across the whole transition.
struct MenuGalleryTransitionHUD: View {
    var body: some View {
        if MenuGalleryTransitionDiagnostics.isEnabled {
            let diagnostics = MenuGalleryTransitionDiagnostics.shared
            TimelineView(.animation(minimumInterval: nil, paused: !diagnostics.isRecording)) { _ in
                let _ = diagnostics.frame()
                Text(verbatim: diagnostics.text)
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
                    .fixedSize()
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
