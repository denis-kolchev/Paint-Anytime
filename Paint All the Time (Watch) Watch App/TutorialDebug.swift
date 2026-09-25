import Foundation
import OSLog
import CoreFoundation

/// A bounded, debug-only trace armed by Next on lesson 2.
enum TutorialDebug {
    #if DEBUG
    private final class TraceState: @unchecked Sendable {
        let lock = NSLock()
        var started: TimeInterval = 0
        var run = 0
        var sequence = 0
        var counts: [String: Int] = [:]
        var lastEvent = "none"
        var acknowledgedProbe = 0
        var lastMainEvent = "none"
        var loopPhase = "not observed"
        var loopPhaseAt: TimeInterval = 0
    }
    private static let state = TraceState()
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PaintAnytime",
                                       category: "Lesson2Next")
    #endif

    @MainActor
    static func startNextTrace() {
        #if DEBUG
        state.lock.lock()
        state.started = ProcessInfo.processInfo.systemUptime
        state.run += 1
        let run = state.run
        state.sequence = 0
        state.counts = [:]
        state.lastEvent = "trace.start"
        state.acknowledgedProbe = 0
        state.lastMainEvent = "trace.start"
        state.loopPhase = "trace.start"
        state.loopPhaseAt = state.started
        state.lock.unlock()
        trace("trace.start")
        // Observe loop boundaries without printing every iteration.
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.allActivities.rawValue,
                                                         true, 0) { _, activity in
            let phase: String
            switch activity {
            case .entry: phase = "entry"
            case .beforeTimers: phase = "beforeTimers"
            case .beforeSources: phase = "beforeSources"
            case .beforeWaiting: phase = "beforeWaiting"
            case .afterWaiting: phase = "afterWaiting"
            case .exit: phase = "exit"
            default: phase = "unknown"
            }
            state.lock.lock()
            guard state.run == run else { state.lock.unlock(); return }
            state.loopPhase = phase
            state.loopPhaseAt = ProcessInfo.processInfo.systemUptime
            state.lock.unlock()
        }
        if let observer {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            }
        }
        // Sample every 100 ms for three seconds. Each probe measures queue wait,
        // and its background deadline can report even if the main thread stalls.
        for probe in 1...30 {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Double(probe) * 0.1) {
                state.lock.lock()
                guard state.run == run else { state.lock.unlock(); return }
                let sent = ProcessInfo.processInfo.systemUptime
                let scheduledDelay = sent - state.started - Double(probe) * 0.1
                state.lock.unlock()
                trace("main.probe.sent", "probe=\(probe) schedulerDelayMs=\(scheduledDelay * 1000)", always: true)
                DispatchQueue.main.async {
                    state.lock.lock()
                    guard state.run == run else { state.lock.unlock(); return }
                    state.acknowledgedProbe = probe
                    state.lock.unlock()
                    trace("main.probe.ack", "probe=\(probe) queueWaitMs=\((ProcessInfo.processInfo.systemUptime - sent) * 1000)", always: true)
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
                    state.lock.lock()
                    guard state.run == run else { state.lock.unlock(); return }
                    let acknowledged = state.acknowledgedProbe >= probe
                    let last = state.lastMainEvent
                    let phase = state.loopPhase
                    let phaseAge = ProcessInfo.processInfo.systemUptime - state.loopPhaseAt
                    state.lock.unlock()
                    if !acknowledged {
                        trace("main.probe.delayed", "probe=\(probe) waitMs=\((ProcessInfo.processInfo.systemUptime - sent) * 1000) lastMain=\(last) loopPhase=\(phase) phaseAgeMs=\(phaseAge * 1000)", always: true)
                    }
                }
            }
        }
        #endif
    }

    static func timestamp() -> TimeInterval {
        #if DEBUG
        ProcessInfo.processInfo.systemUptime
        #else
        0
        #endif
    }

    static func finish(_ event: String, since started: TimeInterval) {
        #if DEBUG
        let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000
        trace("\(event).exit", "durationMs=\(elapsed)", always: elapsed > 50)
        #endif
    }

    /// Measures only synchronous app work; it does not include GPU presentation.
    static func measure<T>(_ event: String, _ work: () -> T) -> T {
        #if DEBUG
        let started = ProcessInfo.processInfo.systemUptime
        trace("\(event).enter")
        defer {
            let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000
            trace("\(event).exit", "durationMs=\(elapsed)", always: elapsed > 50)
        }
        #endif
        return work()
    }

    static func trace(_ event: String, _ details: @autoclosure () -> String = "", always: Bool = false) {
        #if DEBUG
        state.lock.lock()
        let elapsed = ProcessInfo.processInfo.systemUptime - state.started
        guard state.run > 0, elapsed < 15 else { state.lock.unlock(); return }
        state.sequence += 1
        let sequence = state.sequence
        let run = state.run
        let count = (state.counts[event] ?? 0) + 1
        state.counts[event] = count
        state.lastEvent = "\(event) #\(sequence) count=\(count)"
        if Thread.isMainThread && !event.hasPrefix("main.probe") { state.lastMainEvent = state.lastEvent }
        // Capture loop evidence without logging every SwiftUI layout pass.
        let emit = always || count <= 8 || count.nonzeroBitCount == 1
        state.lock.unlock()
        guard emit else { return }
        let text = details()
        logger.notice("[Lesson2Next] run=\(run) #\(sequence) +\(elapsed)s \(event, privacy: .public) count=\(count) main=\(Thread.isMainThread) \(text, privacy: .public)")
        #endif
    }
}
