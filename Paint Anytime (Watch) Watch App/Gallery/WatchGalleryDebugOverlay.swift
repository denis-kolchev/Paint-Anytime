#if DEBUG
import SwiftUI

/// UI heartbeat is main-actor responsiveness, not GPU-presented FPS.
/// Sampling state belongs to this overlay, never the gallery's view model.
struct WatchGalleryDebugOverlay: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var uiText = "UI — Hz · gap — ms"
    @State private var galleryText = "geom —/s · — ms\nvisible — · empty —\nload —/s · pending —"
    @State private var cacheText = "cache —% · dec — ms\nwait — ms · held — MB"

    var body: some View {
        Text(verbatim: uiText + "\n" + galleryText + "\n" + cacheText)
            .font(.system(size: 8, weight: .medium, design: .monospaced))
            .foregroundStyle(.white)
            .padding(4)
            .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
            .fixedSize(horizontal: true, vertical: true)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: scenePhase) {
                guard scenePhase == .active, GalleryDebug.isEnabled else { return }
                await sampleUI()
            }
            .task(id: scenePhase) {
                guard scenePhase == .active, GalleryDebug.isEnabled else { return }
                await sampleDecoder()
            }
    }

    @MainActor
    private func sampleUI() async {
        let counters = WatchGalleryDiagnostics.shared
        var previousGeometry = counters.geometryUpdates
        var previousGeometryMS = counters.geometryMS
        var previousLoads = counters.loads
        var previousCancellations = counters.cancellations
        var start = ProcessInfo.processInfo.systemUptime
        var lastTick = start
        var ticks = 0
        var peakGap = 0.0
        var lifetimePeakGap = 0.0
        while !Task.isCancelled {
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            guard !Task.isCancelled else { return }
            let now = ProcessInfo.processInfo.systemUptime
            peakGap = max(peakGap, (now - lastTick) * 1000)
            lifetimePeakGap = max(lifetimePeakGap, peakGap)
            lastTick = now
            ticks += 1
            let elapsed = now - start
            guard elapsed >= 0.5 else { continue }
            let geometry = counters.geometryUpdates - previousGeometry
            let handlerMS = (counters.geometryMS - previousGeometryMS) / Double(max(1, geometry))
            uiText = String(format: "UI %.0f Hz gap %.0f/%.0f ms", Double(ticks) / elapsed, peakGap, lifetimePeakGap)
            galleryText = String(format: "%@ geom %.0f/s %.1f ms\nvis %d/%d empty %d\nload %.0f/s pending %d cancel %d",
                counters.mode, Double(geometry) / elapsed, handlerMS,
                counters.visible, counters.measured, counters.missing,
                Double(counters.loads - previousLoads) / elapsed, counters.pending,
                counters.cancellations - previousCancellations)
            previousGeometry = counters.geometryUpdates
            previousGeometryMS = counters.geometryMS
            previousLoads = counters.loads
            previousCancellations = counters.cancellations
            start = now
            ticks = 0
            peakGap = 0
        }
    }

    @MainActor
    private func sampleDecoder() async {
        var previous = await GalleryImageCache.shared.debugSnapshot()
        while !Task.isCancelled {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            let began = ProcessInfo.processInfo.systemUptime
            let snapshot = await GalleryImageCache.shared.debugSnapshot()
            guard !Task.isCancelled else { return }
            // Round-trip wait includes decoder-actor queueing and main-actor resumption.
            let waitMS = (ProcessInfo.processInfo.systemUptime - began) * 1000
            let requests = snapshot.requests - previous.requests
            let hits = snapshot.cacheHits - previous.cacheHits
            let decodes = snapshot.decodes - previous.decodes
            let average = (snapshot.decodeMS - previous.decodeMS) / Double(max(1, decodes))
            let hitRate = requests > 0 ? String(format: "%.0f%%", 100 * Double(hits) / Double(requests)) : "—"
            cacheText = String(format: "cache %@ dec %.1f/%.0f ms\nwait %.0f ms held %.1f MB err %d",
                hitRate,
                average, snapshot.maximumDecodeMS, waitMS,
                WatchGalleryDiagnostics.shared.heldMB, snapshot.failures - previous.failures)
            previous = snapshot
        }
    }
}
#endif
