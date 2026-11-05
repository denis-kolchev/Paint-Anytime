import Foundation
import Dispatch

/// One switch for the canvas speed HUD and the per-stage render switches in the ⋯ menu.
/// Off: the menu and HUD disappear and every stage runs its shipping default, nothing
/// is measured. Release builds always compile it off.
nonisolated enum RenderDebug {
    #if DEBUG
    static let isEnabled = false
    #else
    static let isEnabled = false
    #endif
}

/// Latency optimizations of the live stroke. Both ship on; in debug builds the
/// Render debug menu can switch each off to compare the result live.
nonisolated enum RenderStage: Int, CaseIterable, Sendable {
    /// Queue the live frame from the touch handler itself, skipping the
    /// body → `.task(id:)` hop (up to one run-loop pass, about one display frame).
    case directSubmit
    /// Draw the samples the displayed bitmap does not cover yet with the brush's vector
    /// geometry in the touch's own SwiftUI update (opaque vector brushes only).
    case inkTip

    /// Shipping behaviour.
    var isDefaultOn: Bool { true }

    var title: String {
        switch self {
        case .directSubmit: "Direct submit"
        case .inkTip: "Live ink tip"
        }
    }

    var detail: String {
        switch self {
        case .directSubmit: "Off: queue via body/.task"
        case .inkTip: "Off: tip waits for bitmap"
        }
    }
}

/// Lock-protected switches, read by the renderer actor and written by the menu.
nonisolated final class RenderStageSwitches: @unchecked Sendable {
    static let shared = RenderStageSwitches()
    private let lock = NSLock()
    private var disabled = Set(RenderStage.allCases.filter { !$0.isDefaultOn })

    static func isOn(_ stage: RenderStage) -> Bool {
        guard RenderDebug.isEnabled else { return stage.isDefaultOn }
        return !shared.disabledStages.contains(stage)
    }

    /// Stages switched away from their default.
    var changedCount: Int {
        let disabled = disabledStages
        return RenderStage.allCases.filter { disabled.contains($0) == $0.isDefaultOn }.count
    }

    var disabledStages: Set<RenderStage> {
        lock.lock(); defer { lock.unlock() }
        return disabled
    }

    func set(_ stage: RenderStage, isOn: Bool) {
        lock.lock(); defer { lock.unlock() }
        if isOn { disabled.remove(stage) } else { disabled.insert(stage) }
    }
}

/// Timed parts of one canvas frame, from touch sample to published image.
nonisolated enum RenderSpan: Int, CaseIterable, Sendable {
    /// System touch timestamp → start of the gesture handler.
    case event
    /// Main actor: gesture handler, stroke geometry and object erasing per sample.
    case input
    /// Sample applied in the handler → its live frame submitted to the queue.
    case dispatch
    /// Wait between submitting a frame and the renderer starting it.
    case queue
    /// Undo/Redo frame lookup, including its key.
    case history
    /// Committed ink: cache hit, promotion, snapshot or replay.
    case committed
    /// The stroke under the finger.
    case live
    /// Layer compositing and the final image.
    case composite
    /// Whole renderer call as seen from the main actor.
    case render

    var label: String {
        switch self {
        case .event: "ev"
        case .input: "in"
        case .dispatch: "disp"
        case .queue: "q"
        case .history: "hist"
        case .committed: "ink"
        case .live: "live"
        case .composite: "comp"
        case .render: "frame"
        }
    }
}

/// View bodies counted per second: invalidations beyond the raster view show
/// SwiftUI work that runs alongside drawing.
nonisolated enum RenderCounter: Int, CaseIterable, Sendable {
    /// The raster view that presents canvas frames.
    case raster
    /// The canvas view: gestures, overlays, zoom.
    case canvas
    /// The whole canvas screen with toolbar and menus.
    case screen
}

/// Non-observable counters: recording must never invalidate the canvas. The HUD polls
/// `snapshot()`, which summarizes the interval since the previous poll and resets it.
nonisolated final class RenderDiagnostics: @unchecked Sendable {
    static let shared = RenderDiagnostics()

    private struct Accumulator {
        var total: UInt64 = 0
        var count = 0
        var maximum: UInt64 = 0
        mutating func add(_ value: UInt64) {
            total &+= value
            count += 1
            maximum = max(maximum, value)
        }
        var averageMS: Double { count == 0 ? 0 : Double(total) / Double(count) / 1_000_000 }
        var maximumMS: Double { Double(maximum) / 1_000_000 }
    }

    private let lock = NSLock()
    private var spans = Array(repeating: Accumulator(), count: RenderSpan.allCases.count)
    /// Submit → publish.
    private var latency = Accumulator()
    /// Touch event → publish. The screen shows it 1–2 vsyncs later.
    private var endToEnd = Accumulator()
    /// Uptime of the latest touch event and of the handler applying it; read by the next submit.
    private var lastEventAt: UInt64 = 0
    private var lastAppliedAt: UInt64 = 0
    private var liveFrames = 0
    private var committedFrames = 0
    private var coalescedFrames = 0
    private var bodies = Array(repeating: 0, count: RenderCounter.allCases.count)
    private var mainLag = Accumulator()
    private var probeUsers = 0
    private var probeTimer: DispatchSourceTimer?
    private var probeInFlight = false
    private var path = "—"
    private var windowStart = RenderDiagnostics.now()

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// Start of a span; 0 when diagnostics are compiled out.
    @inline(__always) static func begin() -> UInt64 {
        RenderDebug.isEnabled ? now() : 0
    }

    @inline(__always) static func end(_ span: RenderSpan, _ start: UInt64) {
        guard RenderDebug.isEnabled, start != 0 else { return }
        shared.record(span, now() &- start)
    }

    @inline(__always) static func measure<T>(_ span: RenderSpan, _ body: () throws -> T) rethrows -> T {
        guard RenderDebug.isEnabled else { return try body() }
        let start = now()
        defer { shared.record(span, now() &- start) }
        return try body()
    }

    /// Start of the gesture handler: records how old the system touch event already is.
    /// Returns the start of the `.input` span.
    static func inputBegan(eventTime: Date) -> UInt64 {
        guard RenderDebug.isEnabled else { return 0 }
        let start = now()
        let ageNS = UInt64(eventAge(eventTime) * 1_000_000_000)
        shared.locked {
            shared.spans[RenderSpan.event.rawValue].add(ageNS)
            shared.lastEventAt = start &- min(start, ageNS)
        }
        return start
    }

    /// watchOS stamps gesture values with the touch's uptime (seconds since boot) wrapped
    /// in a Date, not wall-clock time: `Date().timeIntervalSince(time)` then reads ~25 years.
    /// Accept either clock and reject anything outside one second.
    static func eventAge(_ eventTime: Date) -> TimeInterval {
        let stamp = eventTime.timeIntervalSinceReferenceDate
        let wall = Date().timeIntervalSinceReferenceDate - stamp
        let uptime = ProcessInfo.processInfo.systemUptime - stamp
        let age = abs(wall) < abs(uptime) ? wall : uptime
        return (0..<1).contains(age) ? age : 0
    }

    /// The handler applied the sample to the stroke; the next live submit closes `.dispatch`.
    static func sampleApplied() {
        guard RenderDebug.isEnabled else { return }
        shared.locked { shared.lastAppliedAt = now() }
    }

    /// Called when a frame is queued. Returns the touch-event time the frame answers
    /// (0 for frames without a live stroke) for the end-to-end figure.
    static func frameSubmitted(live: Bool) -> UInt64 {
        guard RenderDebug.isEnabled, live else { return 0 }
        return shared.locked { () -> UInt64 in
            if shared.lastAppliedAt != 0 {
                shared.spans[RenderSpan.dispatch.rawValue].add(now() &- shared.lastAppliedAt)
                shared.lastAppliedAt = 0 // Count each sample once, not its duplicate submits.
            }
            return shared.lastEventAt
        }
    }

    static func framePublished(live: Bool, submittedAt: UInt64, eventAt: UInt64 = 0) {
        guard RenderDebug.isEnabled else { return }
        let end = now()
        shared.locked {
            if live { shared.liveFrames += 1 } else { shared.committedFrames += 1 }
            if submittedAt != 0 { shared.latency.add(end &- submittedAt) }
            if eventAt != 0, end > eventAt { shared.endToEnd.add(end &- eventAt) }
        }
    }

    /// A pending frame was replaced by a newer one before rendering started.
    static func frameCoalesced() {
        guard RenderDebug.isEnabled else { return }
        shared.locked { shared.coalescedFrames += 1 }
    }

    /// One evaluation of a view body that the canvas depends on.
    static func bodyEvaluated(_ counter: RenderCounter = .raster) {
        guard RenderDebug.isEnabled else { return }
        shared.locked { shared.bodies[counter.rawValue] += 1 }
    }

    /// Main-thread responsiveness: every 50 ms a utility queue posts a block to the main
    /// queue and records how long it waited. Catches any main-actor work, not only drawing.
    func startMainProbe() {
        guard RenderDebug.isEnabled else { return }
        locked {
            probeUsers += 1
            guard probeTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
            timer.setEventHandler { [weak self] in self?.sendProbe() }
            probeTimer = timer
            timer.resume()
        }
    }

    func stopMainProbe() {
        locked {
            probeUsers = max(0, probeUsers - 1)
            guard probeUsers == 0 else { return }
            probeTimer?.cancel()
            probeTimer = nil
            probeInFlight = false
        }
    }

    private func sendProbe() {
        // One probe at a time: a stalled main thread then reports its full stall once.
        let send = locked { () -> Bool in
            guard !probeInFlight else { return false }
            probeInFlight = true
            return true
        }
        guard send else { return }
        let sent = Self.now()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let lag = Self.now() &- sent
            self.locked {
                self.probeInFlight = false
                self.mainLag.add(lag)
            }
        }
    }

    static func setPath(_ name: String) {
        guard RenderDebug.isEnabled else { return }
        shared.locked { shared.path = name }
    }

    private func record(_ span: RenderSpan, _ value: UInt64) {
        locked { spans[span.rawValue].add(value) }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    func snapshot() -> String {
        let changed = RenderStageSwitches.shared.changedCount
        return locked {
            let now = Self.now()
            let seconds = max(0.001, Double(now &- windowStart) / 1_000_000_000)
            func rate(_ count: Int) -> String { String(format: "%.0f", Double(count) / seconds) }
            func ms(_ span: RenderSpan) -> String {
                "\(span.label) " + String(format: "%.1f", spans[span.rawValue].averageMS)
            }
            let frame = spans[RenderSpan.render.rawValue]
            let input = spans[RenderSpan.input.rawValue]
            let text = [
                "FPS \(rate(liveFrames)) live · \(rate(committedFrames)) commit · drop \(coalescedFrames)",
                "in \(rate(input.count))/s " + String(format: "%.2fms", input.averageMS)
                    + " · " + [RenderSpan.event, .dispatch].map(ms).joined(separator: " "),
                String(format: "pub %.0f/%.0f · e2e %.0f/%.0fms +vsync", latency.averageMS, latency.maximumMS,
                       endToEnd.averageMS, endToEnd.maximumMS),
                String(format: "frame %.1f/%.1fms", frame.averageMS, frame.maximumMS),
                [RenderSpan.queue, .history, .committed].map(ms).joined(separator: " "),
                [RenderSpan.live, .composite].map(ms).joined(separator: " ")
                    + " · \(path)" + (changed > 0 ? " · custom \(changed)" : ""),
                String(format: "main lag %.0f/%.0fms", mainLag.averageMS, mainLag.maximumMS),
                "body raster \(rate(bodies[RenderCounter.raster.rawValue])) canvas "
                    + "\(rate(bodies[RenderCounter.canvas.rawValue])) screen \(rate(bodies[RenderCounter.screen.rawValue]))/s",
            ].joined(separator: "\n")
            spans = Array(repeating: Accumulator(), count: RenderSpan.allCases.count)
            latency = Accumulator()
            endToEnd = Accumulator()
            liveFrames = 0
            committedFrames = 0
            coalescedFrames = 0
            bodies = Array(repeating: 0, count: RenderCounter.allCases.count)
            mainLag = Accumulator()
            windowStart = now
            return text
        }
    }
}
