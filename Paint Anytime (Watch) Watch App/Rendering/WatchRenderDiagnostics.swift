import Foundation
import CoreGraphics
import Dispatch

/// One switch for the canvas speed HUD and the per-stage render switches in the ⋯ menu.
/// Off: the menu and HUD disappear and every stage runs its shipping default, nothing
/// is measured. Release builds always compile it off.
nonisolated enum RenderDebug {
    #if DEBUG
    static let isEnabled = true
    #else
    static let isEnabled = false
    #endif
}

/// Latency optimizations of the live stroke. All ship on; in debug builds the
/// Render debug menu can switch each off to compare the result live.
nonisolated enum RenderStage: Int, CaseIterable, Sendable {
    /// Queue the live frame from the touch handler itself, skipping the
    /// body → `.task(id:)` hop (up to one run-loop pass, about one display frame).
    case directSubmit
    /// Draw the samples the displayed bitmap does not cover yet with the brush's vector
    /// geometry in the touch's own SwiftUI update (opaque vector brushes only).
    case inkTip
    /// Pencil and pastel keep one grain per paper cell for the gesture and
    /// recompute only cells near new polygons (`WatchStrokeDrawing.DryGrainField`).
    case incrementalDryGrains
    /// With incremental grains: write grain coverage straight into the float frame
    /// (`WatchStrokeDrawing.DryPixelFill`) instead of Core Graphics path fills.
    case pixelDryFill

    /// Shipping behaviour: every stage on (incremental grains and pixel fill since 2026-11-06).
    var isDefaultOn: Bool { true }

    var title: String {
        switch self {
        case .directSubmit: "Direct submit"
        case .inkTip: "Live ink tip"
        case .incrementalDryGrains: "Incremental dry grains"
        case .pixelDryFill: "Pixel dry fill"
        }
    }

    var detail: String {
        switch self {
        case .directSubmit: "Off: queue via body/.task"
        case .inkTip: "Off: tip waits for bitmap"
        case .incrementalDryGrains: "Off: per-tile grain search. From the next stroke"
        case .pixelDryFill: "With incremental grains. Off: Core Graphics fills grains. From the next stroke"
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
    /// Inside the renderer actor: the frame's own work.
    case work
    /// Renderer finished → the main-actor continuation started (waiting for the main thread).
    case back
    /// Pencil/pastel: dry geometry append and the changed-tile search.
    case dryPrep
    /// Pencil/pastel, incremental grains: updating the cells near new polygons.
    case dryUpdate
    /// Pencil/pastel: grain generation and contours for the changed tiles.
    case dryGrains
    /// Pencil/pastel: restoring and filling the changed tiles in the float frame.
    case dryDraw
    /// Pencil/pastel: snapshot and flatten of the changed tiles for display.
    case dryPublish
    /// Pencil/pastel: start of a live dry buffer (float frame + display copy of the
    /// committed ink, new geometry and grain field). Once per gesture unless the stroke
    /// stops extending the previous frame (a snapped shape being resized or turned).
    case dryBegin
    /// Main actor: `ShapeRecognizer` on the held stroke.
    case shapeRecognize
    /// Renderer: stroke-only image of the drawn shape, once per snapped shape.
    case shapeLayer
    /// Renderer: one moved-shape frame (background + transformed shape image).
    case shapePreview

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
        case .work: "work"
        case .back: "back"
        case .dryPrep: "prep"
        case .dryUpdate: "upd"
        case .dryGrains: "grain"
        case .dryDraw: "fill"
        case .dryPublish: "pub"
        case .dryBegin: "begin"
        case .shapeRecognize: "recog"
        case .shapeLayer: "layer"
        case .shapePreview: "prev"
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
    /// Main run loop: one slice per wake (wake → about to sleep), and their sum.
    private var mainSlices = Accumulator()
    private var wokeAt: UInt64 = 0
    /// First frame published since the main thread last went idle, and publish → idle.
    private var publishedAt: UInt64 = 0
    private var publishToIdle = Accumulator()
    /// End of the latest renderer-actor call, closed by `resumedOnMain`.
    private var workEndedAt: UInt64 = 0
    /// Tiles in each published frame (SwiftUI images over the background).
    private var shownTiles = 0
    private var shownTilesMax = 0
    private var shownFrames = 0
    private var runLoopObservers: [CFRunLoopObserver] = []
    private var probeUsers = 0
    private var probeTimer: DispatchSourceTimer?
    private var probeInFlight = false
    private var path = "—"
    /// Pencil/pastel work per live frame, summed over the HUD window.
    private var dryFrames = 0
    private var dryIncremental = false
    private var dryPixel = false
    private var drySamples = 0
    private var dryTiles = 0
    private var dryGrainsBuilt = 0
    private var dryGrainHits = 0
    private var dryProbes = 0
    private var dryContours = 0
    private var windowStart = RenderDiagnostics.now()
    /// Duration of the latest renderer-actor frame call.
    private var lastWorkNS: UInt64 = 0
    /// The latest hold-to-shape gesture; kept until the next snap.
    private var shape = ShapeTimeline()

    /// One hold-to-shape gesture, from the hold timer to the committed ink after the lift.
    /// All times in ms. "+N" values are measured from the snap (or from the lift).
    private struct ShapeTimeline {
        var kind = ""
        var points = 0
        /// Hold timer scheduled (finger stopped) → recognizer started: 500 ms sleep + main-actor delay.
        var waitMS = 0.0
        var recognizeMS = 0.0
        var snapAt: UInt64 = 0
        /// Snap → first live frame queued, and → that frame published.
        var snapQueuedMS: Double?
        var snapInkMS: Double?
        /// That frame: renderer work, dry buffer start, dry stages and grains (full rebuild).
        var snapWorkMS = 0.0
        var snapBeginMS = 0.0
        var snapDry = ""
        /// Dry buffer restarts after the snap frame (move not similar to the reference).
        var restarts = 0
        var restartMaxMS = 0.0
        /// Shape image for the move preview (once), and when it was built after the snap.
        var layerMS: Double?
        var layerAtMS = 0.0
        var previews = 0
        var previewMaxMS = 0.0
        /// Longest touch event → published live frame after the snap: lag the finger feels.
        var e2eMaxMS = 0.0
        var liftAt: UInt64 = 0
        /// Lift → first frame queued / committed frame published.
        var liftQueuedMS: Double?
        var liftInkMS: Double?
        var liftWorkMS = 0.0
        var liftBeginMS = 0.0
        var liftDry = ""
        /// How committed ink was produced on the lift and its duration.
        var commit = "—"
        /// Main thread from the snap until the lift's ink: longest probe wait and busy slice.
        var lagMaxMS = 0.0
        var sliceMaxMS = 0.0

        /// Snap seen, committed ink after the lift not yet published.
        func isOpen(_ now: UInt64) -> Bool {
            snapAt != 0 && liftInkMS == nil && now &- snapAt < 30_000_000_000
        }
    }

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
        guard RenderDebug.isEnabled else { return 0 }
        return shared.locked { () -> UInt64 in
            let time = now()
            if shared.shape.isOpen(time) {
                if shared.shape.liftAt != 0 {
                    if shared.shape.liftQueuedMS == nil { shared.shape.liftQueuedMS = ms(time &- shared.shape.liftAt) }
                } else if live, shared.shape.snapQueuedMS == nil {
                    shared.shape.snapQueuedMS = ms(time &- shared.shape.snapAt)
                }
            }
            guard live else { return 0 }
            if shared.lastAppliedAt != 0 {
                shared.spans[RenderSpan.dispatch.rawValue].add(now() &- shared.lastAppliedAt)
                shared.lastAppliedAt = 0 // Count each sample once, not its duplicate submits.
            }
            return shared.lastEventAt
        }
    }

    static func framePublished(live: Bool, submittedAt: UInt64, eventAt: UInt64 = 0, tiles: Int = 0) {
        guard RenderDebug.isEnabled else { return }
        let end = now()
        shared.locked {
            if live { shared.liveFrames += 1 } else { shared.committedFrames += 1 }
            if shared.shape.isOpen(end), submittedAt >= shared.shape.snapAt {
                let work = ms(shared.lastWorkNS)
                if shared.shape.liftAt != 0 {
                    if !live, submittedAt >= shared.shape.liftAt {
                        shared.shape.liftInkMS = ms(end &- shared.shape.liftAt)
                        shared.shape.liftWorkMS = work
                    }
                } else if live {
                    if shared.shape.snapInkMS == nil {
                        shared.shape.snapInkMS = ms(end &- shared.shape.snapAt)
                        shared.shape.snapWorkMS = work
                    }
                    if eventAt > shared.shape.snapAt, end > eventAt {
                        shared.shape.e2eMaxMS = max(shared.shape.e2eMaxMS, ms(end &- eventAt))
                    }
                }
            }
            if shared.publishedAt == 0 { shared.publishedAt = end }
            shared.shownTiles += tiles
            shared.shownTilesMax = max(shared.shownTilesMax, tiles)
            shared.shownFrames += 1
            if submittedAt != 0 { shared.latency.add(end &- submittedAt) }
            if eventAt != 0, end > eventAt { shared.endToEnd.add(end &- eventAt) }
        }
    }

    /// End of a renderer-actor frame call started at `start`.
    static func workEnded(_ start: UInt64) {
        guard RenderDebug.isEnabled, start != 0 else { return }
        let end = now()
        shared.locked {
            shared.spans[RenderSpan.work.rawValue].add(end &- start)
            shared.workEndedAt = end
            shared.lastWorkNS = end &- start
        }
    }

    /// The main-actor continuation after a renderer call started running.
    static func resumedOnMain() {
        guard RenderDebug.isEnabled else { return }
        let end = now()
        shared.locked {
            if shared.workEndedAt != 0, end > shared.workEndedAt {
                shared.spans[RenderSpan.back.rawValue].add(end &- shared.workEndedAt)
            }
            shared.workEndedAt = 0
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
            installRunLoopObservers()
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
            for observer in runLoopObservers {
                CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            }
            runLoopObservers = []
            wokeAt = 0
            publishedAt = 0
        }
    }

    /// Main run loop busy slices: wake (first observer) → about to sleep (last observer,
    /// after SwiftUI and Core Animation have committed). A frame published in a slice
    /// adds publish → sleep: the main-thread cost SwiftUI pays to show it.
    /// Called with the lock held.
    private func installRunLoopObservers() {
        let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue,
                                                      true, CFIndex.min) { [weak self] _, _ in
            guard let self else { return }
            let time = Self.now()
            self.locked { self.wokeAt = time }
        }
        let sleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue,
                                                       true, CFIndex.max) { [weak self] _, _ in
            guard let self else { return }
            let time = Self.now()
            self.locked {
                if self.wokeAt != 0, time > self.wokeAt {
                    self.mainSlices.add(time &- self.wokeAt)
                    if self.shape.isOpen(time) {
                        self.shape.sliceMaxMS = max(self.shape.sliceMaxMS, Self.ms(time &- self.wokeAt))
                    }
                }
                self.wokeAt = 0
                if self.publishedAt != 0, time > self.publishedAt { self.publishToIdle.add(time &- self.publishedAt) }
                self.publishedAt = 0
            }
        }
        for observer in [wake, sleep].compactMap({ $0 }) {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            runLoopObservers.append(observer)
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
                if self.shape.isOpen(sent) { self.shape.lagMaxMS = max(self.shape.lagMaxMS, Self.ms(lag)) }
            }
        }
    }

    /// One live pencil/pastel frame: stage boundaries (prep, upd, grain, fill, publish),
    /// new input samples, tiles redrawn and the geometry counters' deltas.
    /// `full`: the frame drew the whole stroke from a fresh buffer.
    static func dryFrame(stages: [UInt64], incremental: Bool, pixel: Bool = false, samples: Int, tiles: Int,
                         grainsBuilt: Int, grainHits: Int, probes: Int, contours: Int, full: Bool = false) {
        guard RenderDebug.isEnabled, stages.count == 6, stages[0] != 0 else { return }
        let spans: [RenderSpan] = [.dryPrep, .dryUpdate, .dryGrains, .dryDraw, .dryPublish]
        shared.locked {
            for (index, span) in spans.enumerated() {
                shared.spans[span.rawValue].add(stages[index + 1] &- stages[index])
            }
            shared.dryFrames += 1
            shared.dryIncremental = incremental
            shared.dryPixel = pixel
            shared.drySamples += samples
            shared.dryTiles += tiles
            shared.dryGrainsBuilt += grainsBuilt
            shared.dryGrainHits += grainHits
            shared.dryProbes += probes
            shared.dryContours += contours
            // Full redraws inside a shape gesture: the snap frame and the exact render on lift.
            guard full, shared.shape.isOpen(stages[0]), stages[0] >= shared.shape.snapAt else { return }
            let text = "\(Int(ms(stages[2] &- stages[0])))+\(Int(ms(stages[3] &- stages[2])))"
                + "+\(Int(ms(stages[4] &- stages[3])))+\(Int(ms(stages[5] &- stages[4])))"
                + " \(grainsBuilt / 1000)k"
            if shared.shape.liftAt != 0 {
                shared.shape.liftDry = text
            } else if shared.shape.snapInkMS == nil, shared.shape.snapDry.isEmpty {
                shared.shape.snapDry = text
            }
        }
    }

    /// A live dry buffer was set up (`start` from `begin()`).
    static func dryBegan(_ start: UInt64) {
        guard RenderDebug.isEnabled, start != 0 else { return }
        let end = now()
        shared.locked {
            shared.spans[RenderSpan.dryBegin.rawValue].add(end &- start)
            guard shared.shape.isOpen(end), start >= shared.shape.snapAt else { return }
            let value = ms(end &- start)
            if shared.shape.liftAt != 0 {
                shared.shape.liftBeginMS = value
            } else if shared.shape.snapInkMS == nil, shared.shape.snapBeginMS == 0 {
                shared.shape.snapBeginMS = value
            } else {
                shared.shape.restarts += 1
                shared.shape.restartMaxMS = max(shared.shape.restartMaxMS, value)
            }
        }
    }

    /// The hold recognizer ran. `scheduledAt`: when the hold timer was set (finger stopped).
    /// `kind` is nil when nothing snapped; a snap starts a new shape timeline.
    static func shapeRecognized(_ start: UInt64, scheduledAt: UInt64, kind: String?, points: Int) {
        guard RenderDebug.isEnabled, start != 0 else { return }
        let end = now()
        shared.locked {
            guard let kind else {
                shared.shape = ShapeTimeline(kind: "none", points: points,
                                             waitMS: ms(start &- min(start, scheduledAt)),
                                             recognizeMS: ms(end &- start))
                return
            }
            shared.shape = ShapeTimeline(kind: kind, points: points,
                                         waitMS: ms(start &- min(start, scheduledAt)),
                                         recognizeMS: ms(end &- start), snapAt: end)
        }
    }

    /// The finger lifted from a snapped shape.
    static func shapeLifted() {
        guard RenderDebug.isEnabled else { return }
        let time = now()
        shared.locked {
            guard shared.shape.isOpen(time), shared.shape.liftAt == 0 else { return }
            shared.shape.liftAt = time
        }
    }

    /// How the lifted shape became committed ink (`path`), from `start`. First call per lift wins.
    static func shapeCommitted(_ path: String, _ start: UInt64) {
        guard RenderDebug.isEnabled, start != 0 else { return }
        let end = now()
        shared.locked {
            guard shared.shape.isOpen(end), shared.shape.liftAt != 0, start >= shared.shape.liftAt,
                  shared.shape.commit == "—" else { return }
            shared.shape.commit = "\(path) \(Int(ms(end &- start)))"
        }
    }

    static func ms(_ nanoseconds: UInt64) -> Double { Double(nanoseconds) / 1_000_000 }

    /// Hold-to-shape timeline, kept until the next snap. Called with the lock held.
    private func shapeLines() -> [String] {
        let shape = self.shape
        guard !shape.kind.isEmpty else { return [] }
        func value(_ ms: Double?) -> String { ms.map { String(format: "%.0f", $0) } ?? "—" }
        let head = "hold \(shape.kind) \(shape.points)pt · wait \(value(shape.waitMS))"
            + String(format: " · recog %.1f", shape.recognizeMS)
        guard shape.snapAt != 0 else { return [head] }
        let snap = "snap q+\(value(shape.snapQueuedMS)) ink+\(value(shape.snapInkMS))"
            + " work \(value(shape.snapWorkMS)) begin \(value(shape.snapBeginMS))"
            + (shape.snapDry.isEmpty ? "" : " · \(shape.snapDry)")
        let move = "move layer " + (shape.layerMS.map { "\(Int($0))@+\(Int(shape.layerAtMS))" } ?? "—")
            + " · prev \(shape.previews)× max \(value(shape.previewMaxMS))"
            + " · rst \(shape.restarts) max \(value(shape.restartMaxMS)) · e2e max \(value(shape.e2eMaxMS))"
        let lift = shape.liftAt == 0 ? "lift —"
            : "lift q+\(value(shape.liftQueuedMS)) ink+\(value(shape.liftInkMS)) work \(value(shape.liftWorkMS))"
                + " begin \(value(shape.liftBeginMS)) · \(shape.commit)"
                + (shape.liftDry.isEmpty ? "" : " · \(shape.liftDry)")
        let main = "shape main lag max \(value(shape.lagMaxMS)) · slice max \(value(shape.sliceMaxMS))"
        return [head, snap, move, lift, main]
    }

    static func setPath(_ name: String) {
        guard RenderDebug.isEnabled else { return }
        shared.locked { shared.path = name }
    }

    private func record(_ span: RenderSpan, _ value: UInt64) {
        locked {
            spans[span.rawValue].add(value)
            let time = Self.now()
            guard shape.isOpen(time), shape.liftAt == 0 else { return }
            switch span {
            case .shapeLayer:
                shape.layerMS = Self.ms(value)
                shape.layerAtMS = Self.ms(time &- shape.snapAt)
            case .shapePreview:
                shape.previews += 1
                shape.previewMaxMS = max(shape.previewMaxMS, Self.ms(value))
            default: break
            }
        }
    }

    /// Shown only while a pencil or pastel stroke was drawn in the window.
    /// Per-frame averages: tiles, grains built/reused, coverage probes, contour rebuilds.
    private func dryLines(_ ms: (RenderSpan) -> String) -> [String] {
        guard dryFrames > 0 else { return [] }
        func perFrame(_ value: Int) -> String { String(format: "%.0f", Double(value) / Double(dryFrames)) }
        return [
            (dryPixel ? "dry·px " : dryIncremental ? "dry·inc " : "dry·old ") + [RenderSpan.dryUpdate, .dryGrains, .dryDraw, .dryPublish].map(ms).joined(separator: " "),
            "pts \(perFrame(drySamples)) · tiles \(perFrame(dryTiles)) · grains \(perFrame(dryGrainsBuilt)) new"
                + " \(perFrame(dryGrainHits)) \(dryPixel ? "drawn" : "hit")",
        ]
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
            func avgMax(_ value: Accumulator) -> String {
                String(format: "%.0f/%.0f", value.averageMS, value.maximumMS)
            }
            func avg(_ span: RenderSpan) -> String { String(format: "%.0f", spans[span.rawValue].averageMS) }
            // Frame = renderer work + waiting for the main thread after it + the rest
            // (hop to the renderer, setup on the main actor).
            let rest = max(0, frame.averageMS - spans[RenderSpan.work.rawValue].averageMS
                           - spans[RenderSpan.back.rawValue].averageMS)
            let busy = Double(mainSlices.total) / 1_000_000 / seconds / 10 // percent
            var extra: [String] = []
            for span in [RenderSpan.committed, .history, .composite] where spans[span.rawValue].averageMS >= 0.5 {
                extra.append(ms(span))
            }
            let tiles = shownFrames == 0 ? "—" : String(format: "%.0f/%d", Double(shownTiles) / Double(shownFrames), shownTilesMax)
            let text = ([
                "FPS \(rate(liveFrames)) live \(rate(committedFrames)) commit · drop \(coalescedFrames) · in \(rate(input.count))/s"
                    + (changed > 0 ? " · custom \(changed)" : ""),
                "e2e \(avgMax(endToEnd)) · ev \(avg(.event)) · q \(avg(.queue)) · in " + String(format: "%.1f", input.averageMS),
                "frame \(avgMax(frame)) = work \(avg(.work)) + back \(avg(.back)) + " + String(format: "%.0f", rest),
                String(format: "main busy %.0f%% · slice ", busy) + avgMax(mainSlices) + " · lag " + avgMax(mainLag),
                "pub→idle \(avgMax(publishToIdle)) · tiles \(tiles) · body \(rate(bodies[RenderCounter.raster.rawValue]))"
                    + "/\(rate(bodies[RenderCounter.canvas.rawValue]))/\(rate(bodies[RenderCounter.screen.rawValue]))",
            ] + (extra.isEmpty ? [] : [extra.joined(separator: " ") + " · \(path)"])
              + dryLines(ms)
              + shapeLines()).joined(separator: "\n")
            spans = Array(repeating: Accumulator(), count: RenderSpan.allCases.count)
            latency = Accumulator()
            endToEnd = Accumulator()
            liveFrames = 0
            committedFrames = 0
            coalescedFrames = 0
            bodies = Array(repeating: 0, count: RenderCounter.allCases.count)
            mainLag = Accumulator()
            mainSlices = Accumulator()
            publishToIdle = Accumulator()
            shownTiles = 0; shownTilesMax = 0; shownFrames = 0
            dryFrames = 0; drySamples = 0; dryTiles = 0; dryGrainsBuilt = 0
            dryGrainHits = 0; dryProbes = 0; dryContours = 0
            windowStart = now
            return text
        }
    }
}
