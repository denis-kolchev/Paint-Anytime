import Foundation
import CoreGraphics
import Dispatch

/// One switch for the canvas speed HUD and the per-stage render switches in the ⋯ menu.
/// Off: the menu and HUD disappear and every stage runs its shipping default, nothing
/// is measured. Release builds always compile it off.
nonisolated enum RenderDebug {
    static let isEnabled = false
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
    /// One-layer dry path: merging > 16 screen tiles into one background image.
    case screenMerge
    /// Main actor: `ShapeRecognizer` on the held stroke.
    case shapeRecognize
    /// Main actor: one sample of a snapped shape (scale/rotate of every shape point).
    case shapeAdjust
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
        case .screenMerge: "merge"
        case .shapeRecognize: "recog"
        case .shapeAdjust: "adj"
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
    /// Dry frames that redrew the whole stroke (no previous frame to extend).
    private var dryFullFrames = 0
    /// Changed pixels (union of dirty rectangles, may overlap) over the window's dry frames.
    private var dryDirtyPixels = 0
    /// Live dry buffers started for a new gesture / restarted inside the same gesture.
    private var dryStarts = 0
    private var dryRestarts = 0
    /// Bytes allocated by those buffer starts.
    private var dryAllocBytes = 0
    /// Snapped shape: samples that moved it / samples inside the hold tolerance.
    private var shapeMoves = 0
    private var shapeIdle = 0
    /// Kept across windows: the hold happens once per stroke.
    private var shapeKind = "—"
    private var shapePoints = 0
    private var shapeSeenAt: UInt64 = 0
    private var lastRecognizeNS: UInt64 = 0
    private var windowStart = RenderDiagnostics.now()
    /// Touch log, kept across HUD windows: the open touch and the latest finished ones.
    private var touchSerial = 0
    private var openTouch: TouchRecord?
    private var recentTouches: [TouchRecord] = []
    private var touchTotals: [String: Int] = [:]
    /// Touches seen by a debug-only simultaneous gesture on the canvas that is never masked:
    /// it counts touches that reach the canvas even while the drawing gesture is switched off.
    private var rawTouches = 0
    private var rawOpen = false
    private var rawSeenAt: UInt64 = 0
    private var rawLocation: CGPoint?
    /// Same probe on the whole canvas screen (canvas plus the controls drawn over it):
    /// root counts but raw does not → a view over the canvas took the touch;
    /// neither counts → the touch never reached the app's canvas screen.
    private var rootTouches = 0
    private var rootOpen = false
    private var rootLocation: CGPoint?
    /// Same probe around the whole app window (navigation, native toolbar, sheets).
    private var appTouches = 0
    private var appOpen = false
    private var appLocation: CGPoint?
    /// Whether the canvas screen probe saw the open window touch; window touches it never
    /// saw ("lost" before the canvas screen), newest first, with their start and length.
    private var appReachedRoot = false
    private var appStartedAt: UInt64 = 0
    private var lostTouches: [(location: CGPoint, endedAt: UInt64, ms: Double)] = []
    private var lostCount = 0
    /// Nearest canvas control to the latest screen touch: "in name" or "name +distance pt".
    private var rootNear = "—"
    /// Drawing gesture mask from the latest canvas body, and the screen's reasons for no input.
    private var touchGate = "—"
    private var inputBlockers = "—"

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

    static func framePublished(live: Bool, submittedAt: UInt64, eventAt: UInt64 = 0, tiles: Int = 0) {
        guard RenderDebug.isEnabled else { return }
        let end = now()
        shared.locked {
            if live { shared.liveFrames += 1 } else { shared.committedFrames += 1 }
            if live, shared.openTouch?.outcome == "draw", shared.openTouch?.firstInkAt == 0 {
                shared.openTouch?.firstInkAt = end
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
                if self.wokeAt != 0, time > self.wokeAt { self.mainSlices.add(time &- self.wokeAt) }
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
            }
        }
    }

    /// One live pencil/pastel frame: stage boundaries (prep, upd, grain, fill, publish),
    /// new input samples, tiles redrawn and the geometry counters' deltas.
    static func dryFrame(stages: [UInt64], incremental: Bool, pixel: Bool = false, samples: Int, tiles: Int,
                         grainsBuilt: Int, grainHits: Int, probes: Int, contours: Int,
                         full: Bool = false, dirtyPixels: [CGRect] = []) {
        guard RenderDebug.isEnabled, stages.count == 6, stages[0] != 0 else { return }
        let dirty = dirtyPixels.reduce(0) { $0 + Int($1.width * $1.height) }
        shared.locked {
            if full { shared.dryFullFrames += 1 }
            shared.dryDirtyPixels += dirty
        }
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
        }
    }

    /// A live dry buffer was set up (`start` from `begin()`). `restart`: the same gesture
    /// already had one, but the stroke stopped extending it (snapped shape moved).
    static func dryBegan(_ start: UInt64, restart: Bool, bytes: Int) {
        guard RenderDebug.isEnabled, start != 0 else { return }
        let end = now()
        shared.locked {
            shared.spans[RenderSpan.dryBegin.rawValue].add(end &- start)
            if restart { shared.dryRestarts += 1 } else { shared.dryStarts += 1 }
            shared.dryAllocBytes += bytes
        }
    }

    /// The hold recognizer ran; `kind` is nil when nothing snapped.
    static func shapeRecognized(_ start: UInt64, kind: String?, points: Int) {
        guard RenderDebug.isEnabled, start != 0 else { return }
        let end = now()
        shared.locked {
            shared.lastRecognizeNS = end &- start
            shared.shapeKind = kind ?? "none"
            shared.shapePoints = kind == nil ? 0 : points
            shared.shapeSeenAt = end
        }
    }

    /// One sample applied to a snapped shape; `moved` when its points changed.
    static func shapeAdjusted(_ start: UInt64, moved: Bool, points: Int) {
        guard RenderDebug.isEnabled, start != 0 else { return }
        let end = now()
        shared.locked {
            shared.spans[RenderSpan.shapeAdjust.rawValue].add(end &- start)
            if moved { shared.shapeMoves += 1 } else { shared.shapeIdle += 1 }
            shared.shapePoints = points
            shared.shapeSeenAt = end
        }
    }

    /// One canvas touch from its first gesture sample to onEnded / cancellation.
    /// `outcome` is the first decision the handler made about it; nil until one is made.
    private struct TouchRecord {
        var id: Int
        var startedAt: UInt64
        var eventAt: UInt64
        /// Start of the touch, global points.
        var start: CGPoint
        var samples = 0
        var outcome: String?
        var firstInkAt: UInt64 = 0
        var endedAt: UInt64 = 0
        var end = ""
    }

    /// Every canvas gesture sample, before any guard. A sample without an open touch opens one.
    static func touchSample(eventTime: Date, location: () -> CGPoint) {
        guard RenderDebug.isEnabled else { return }
        let time = now()
        let ageNS = UInt64(eventAge(eventTime) * 1_000_000_000)
        shared.locked {
            if shared.openTouch == nil {
                shared.touchSerial += 1
                shared.openTouch = TouchRecord(id: shared.touchSerial, startedAt: time,
                                               eventAt: time &- min(time, ageNS), start: location())
            }
            shared.openTouch?.samples += 1
        }
    }

    /// Why the open touch draws or does not; the first call per touch wins.
    static func touchOutcome(_ outcome: String) {
        guard RenderDebug.isEnabled else { return }
        shared.locked {
            guard shared.openTouch != nil, shared.openTouch?.outcome == nil else { return }
            shared.openTouch?.outcome = outcome
        }
    }

    /// The touch finished: `onEnded` ran (`cancelled` false) or the gesture state reset
    /// without it (system cancellation). `kept`: whether a drawn stroke entered the document.
    static func touchEnded(cancelled: Bool, kept: Bool? = nil) {
        guard RenderDebug.isEnabled else { return }
        let time = now()
        shared.locked {
            guard var touch = shared.openTouch else { return }
            shared.openTouch = nil
            touch.endedAt = time
            touch.end = cancelled ? "CANCEL" : kept == false ? "LOST" : ""
            let key = cancelled ? "cancel" : touch.outcome.map { String($0.prefix { $0 != ":" }) } ?? "none"
            shared.touchTotals[key, default: 0] += 1
            shared.recentTouches.insert(touch, at: 0)
            if shared.recentTouches.count > 3 { shared.recentTouches.removeLast() }
        }
    }

    /// Debug-only gesture that is never masked: one call per sample, `ended` on its end.
    /// `location` in global coordinates.
    static func rawTouch(ended: Bool, location: CGPoint) {
        guard RenderDebug.isEnabled else { return }
        let time = now()
        shared.locked {
            if ended { shared.rawOpen = false; return }
            if !shared.rawOpen { shared.rawTouches += 1; shared.rawOpen = true; shared.rawLocation = location }
            shared.rawSeenAt = time
        }
    }

    /// Window-level probe; `location` in global coordinates.
    static func appTouch(ended: Bool, location: CGPoint) {
        guard RenderDebug.isEnabled else { return }
        shared.locked {
            if ended {
                guard shared.appOpen else { return }
                shared.appOpen = false
                if !shared.appReachedRoot, let start = shared.appLocation {
                    let end = now()
                    shared.lostCount += 1
                    shared.lostTouches.insert((start, end, Double(end &- shared.appStartedAt) / 1_000_000), at: 0)
                    if shared.lostTouches.count > 4 { shared.lostTouches.removeLast() }
                }
                return
            }
            if !shared.appOpen {
                shared.appTouches += 1
                shared.appOpen = true
                shared.appLocation = location
                // The probes fire in either order for one touch: the screen probe may be first.
                shared.appReachedRoot = shared.rootOpen
                shared.appStartedAt = now()
            }
        }
    }

    /// Screen-level probe; `location` in global coordinates.
    /// `controls`: the canvas control frames in global coordinates, read only on the touch's first sample.
    static func rootTouch(ended: Bool, location: CGPoint, controls: () -> [(String, CGRect)]) {
        guard RenderDebug.isEnabled else { return }
        let isNew = shared.locked { () -> Bool in
            if ended { shared.rootOpen = false; return false }
            guard !shared.rootOpen else { return false }
            shared.rootTouches += 1
            shared.rootOpen = true
            shared.appReachedRoot = true
            shared.rootLocation = location
            return true
        }
        guard isNew else { return }
        var near = "none"
        var best = CGFloat.infinity
        for (name, frame) in controls() where !frame.isNull && !frame.isEmpty {
            let dx = max(frame.minX - location.x, 0, location.x - frame.maxX)
            let dy = max(frame.minY - location.y, 0, location.y - frame.maxY)
            let distance = hypot(dx, dy)
            if distance < best {
                best = distance
                near = distance == 0 ? "in \(name)" : String(format: "%@ +%.0fpt", name, distance)
                    + String(format: " %.0fx%.0f", frame.width, frame.height)
            }
        }
        shared.locked { shared.rootNear = near }
    }

    /// The canvas body's gesture mask inputs. Evaluated with the body, so it is current
    /// whenever any of them changes.
    static func setTouchGate(_ gate: String) {
        guard RenderDebug.isEnabled else { return }
        shared.locked { shared.touchGate = gate }
    }

    /// Screen-level reasons `acceptsInput` is false ("" when it is true).
    static func setInputBlockers(_ blockers: [String]) {
        guard RenderDebug.isEnabled else { return }
        shared.locked { shared.inputBlockers = blockers.isEmpty ? "none" : blockers.joined(separator: ",") }
    }

    /// Touch log for the HUD: totals by outcome, then the open touch and the latest three
    /// (newest first) with outcome, samples, first live frame after the touch and age.
    /// Called with the lock held.
    private func touchLines(now: UInt64) -> [String] {
        func describe(_ touch: TouchRecord) -> String {
            var text = "#\(touch.id) " + (touch.outcome ?? "none") + " \(touch.samples)s"
            if touch.outcome == "draw" {
                text += touch.firstInkAt == 0 ? " NOINK"
                    : String(format: " %.0fms", Double(touch.firstInkAt &- touch.eventAt) / 1_000_000)
            }
            if !touch.end.isEmpty { text += " " + touch.end }
            // Where the touches that did not end as a kept stroke started.
            if touch.outcome != "draw" || !touch.end.isEmpty {
                text += String(format: " @%.0f,%.0f", touch.start.x, touch.start.y)
            }
            let reference = touch.endedAt == 0 ? touch.startedAt : touch.endedAt
            return text + String(format: " %.0fs", Double(now &- reference) / 1_000_000_000)
        }
        let totals = touchTotals.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }
        let header = "touch \(touchSerial)" + (totals.isEmpty ? "" : ": " + totals.joined(separator: " "))
            + " · raw \(rawTouches)" + (rawOpen ? " DOWN" : "")
            + " · root \(rootTouches)" + (rootOpen ? " DOWN" : "")
            + " · app \(appTouches)" + (appOpen ? " DOWN" : "")
        func point(_ location: CGPoint?) -> String {
            location.map { String(format: "%.0f,%.0f", $0.x, $0.y) } ?? "—"
        }
        let places = "at app \(point(appLocation)) · root \(point(rootLocation)) \(rootNear) · raw \(point(rawLocation))"
        let gate = "gate \(touchGate) · block \(inputBlockers)"
        let open = openTouch.map { ["now " + describe($0)] } ?? []
        // Window touches that never reached the canvas screen: start point, length, age.
        let lost = lostTouches.isEmpty ? [] : ["lost \(lostCount): " + lostTouches.map {
            String(format: "@%.0f,%.0f %.0fms %.0fs", $0.location.x, $0.location.y, $0.ms,
                   Double(now &- $0.endedAt) / 1_000_000_000)
        }.joined(separator: " · ")]
        return [header, places, gate] + lost + (open + recentTouches.map(describe)).chunked(2).map { $0.joined(separator: " · ") }
    }

    static func setPath(_ name: String) {
        guard RenderDebug.isEnabled else { return }
        shared.locked { shared.path = name }
    }

    private func record(_ span: RenderSpan, _ value: UInt64) {
        locked { spans[span.rawValue].add(value) }
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

    /// Shown for 3 s after shape activity, or while dry buffers restart mid-gesture.
    /// Called with the lock held.
    private func shapeLines(seconds: Double, now: UInt64) -> [String] {
        let recent = shapeSeenAt != 0 && now &- shapeSeenAt < 3_000_000_000
        guard recent || dryRestarts > 0 else { return [] }
        func rate(_ count: Int) -> String { String(format: "%.0f", Double(count) / seconds) }
        func avgMax(_ span: RenderSpan) -> String {
            let value = spans[span.rawValue]
            return String(format: "%.1f/%.1f", value.averageMS, value.maximumMS)
        }
        let frames = max(1, dryFrames)
        let begins = dryStarts + dryRestarts
        let alloc = Double(dryAllocBytes) / 1_048_576 / seconds
        let dirty = Double(dryDirtyPixels) / Double(frames) / 1000
        let merges = spans[RenderSpan.screenMerge.rawValue]
        let previews = spans[RenderSpan.shapePreview.rawValue]
        let layers = spans[RenderSpan.shapeLayer.rawValue]
        return [
            "prev \(rate(previews.count))/s " + (previews.count == 0 ? "—" : avgMax(.shapePreview))
                + " · layer " + (layers.count == 0 ? "—" : avgMax(.shapeLayer)),
            "shape \(shapeKind) \(shapePoints)pt · recog " + String(format: "%.1f", Double(lastRecognizeNS) / 1_000_000)
                + " · adj \(rate(shapeMoves))/s idle \(rate(shapeIdle)) · \(avgMax(.shapeAdjust))",
            "restart \(rate(dryRestarts))/s new \(dryStarts) · begin \(begins == 0 ? "—" : avgMax(.dryBegin))"
                + String(format: " · alloc %.0fMB/s", alloc),
            "full \(dryFullFrames)/\(dryFrames) fr · dirty " + String(format: "%.0fk px/fr", dirty)
                + " · merge \(rate(merges.count))/s " + (merges.count == 0 ? "—" : avgMax(.screenMerge)) + " · \(path)",
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
              + shapeLines(seconds: seconds, now: now)
              + touchLines(now: now)).joined(separator: "\n")
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
            dryFullFrames = 0; dryDirtyPixels = 0; dryStarts = 0; dryRestarts = 0; dryAllocBytes = 0
            shapeMoves = 0; shapeIdle = 0
            windowStart = now
            return text
        }
    }
}

// The target defaults to MainActor isolation; the HUD text is built under the
// diagnostics lock off the main actor.
nonisolated private extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
