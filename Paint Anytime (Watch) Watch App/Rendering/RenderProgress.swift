import Foundation

/// How far one save has come, reported by the renderer it runs. Bound with
/// `RenderProgress.$current.withValue(_:)` around the save's work, so only that work
/// reports: the canvas's own renders run in other tasks and see nil.
///
/// Rendering counts layer units (strokes, blurs weigh more) as each layer of each strip
/// is drawn; encoding and writing are phases after it. Thread-safe: the save writes,
/// the main actor polls.
nonisolated final class RenderProgress: @unchecked Sendable {
    @TaskLocal static var current: RenderProgress?

    enum Phase: Int, Sendable { case rendering, encoding, writing, finished }

    struct Snapshot: Sendable {
        /// Share of the render done, 0…1; 0 until the render has counted its work.
        let renderFraction: Double
        /// Layer units of the whole render; 0 until known.
        let units: Double
        let phase: Phase
        /// Seconds since start, and how long rendering took once it ended.
        let elapsed: Double
        let renderSeconds: Double?
    }

    private let lock = NSLock()
    private let start = ProcessInfo.processInfo.systemUptime
    private var total = 0.0
    private var done = 0.0
    private var phase = Phase.rendering
    private var renderEnd: Double?

    /// The render's whole work. Only the first call counts: a strip render announces
    /// every strip's layers before the strips announce their own.
    func expect(_ units: Double) {
        lock.lock(); defer { lock.unlock() }
        if total == 0 { total = max(1, units) }
    }

    func complete(_ units: Double) {
        lock.lock(); defer { lock.unlock() }
        done = min(total, done + units)
    }

    func enter(_ next: Phase) {
        lock.lock(); defer { lock.unlock() }
        guard next.rawValue > phase.rawValue else { return }
        if phase == .rendering { renderEnd = ProcessInfo.processInfo.systemUptime }
        phase = next
    }

    var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(renderFraction: phase == .rendering ? (total > 0 ? done / total : 0) : 1,
                        units: total, phase: phase,
                        elapsed: ProcessInfo.processInfo.systemUptime - start,
                        renderSeconds: renderEnd.map { $0 - start })
    }

    /// Weight of one layer pass: its strokes, a blur costing about as much as eight
    /// ordinary strokes (it reads and writes float pixels around itself), and the pass.
    static func units(of layer: CanvasLayer) -> Double {
        let blurs = layer.strokes.reduce(0) { $0 + ($1.style.instrument == .blur ? 1 : 0) }
        return Double(1 + layer.strokes.count + 8 * blurs)
    }
}
