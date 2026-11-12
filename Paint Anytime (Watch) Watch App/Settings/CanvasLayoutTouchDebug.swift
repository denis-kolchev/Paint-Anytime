import SwiftUI
import Observation

/// Debug builds only (`RenderDebug.isEnabled`): records which touches in the canvas layout
/// editor reach SwiftUI and which Button actions fire, and shows it on screen for screenshots.
/// Investigates Reset and the checkmark needing several taps on device.
@Observable
final class CanvasLayoutTouchDebug {
    private(set) var counts: [String: Int] = [:]
    private(set) var events: [String] = []
    var frames: [String: CGRect] = [:]
    var topControlMidY: CGFloat?
    private let start = Date()
    private static let eventLimit = 7

    /// `kind`: down, up, cancel or action.
    func record(_ probe: String, _ kind: String, at location: CGPoint? = nil) {
        counts["\(probe).\(kind)", default: 0] += 1
        let time = String(format: "%5.2f", Date().timeIntervalSince(start))
        let point = location.map { " @\(Self.format($0.x)),\(Self.format($0.y))" } ?? ""
        events.append("\(time) \(probe) \(kind)\(point)")
        if events.count > Self.eventLimit { events.removeFirst(events.count - Self.eventLimit) }
    }

    func count(_ probe: String, _ kind: String) -> Int { counts["\(probe).\(kind)"] ?? 0 }

    /// Pure formatting, callable from any isolation.
    nonisolated static func format(_ value: CGFloat) -> String { String(format: "%.0f", value) }
}

extension View {
    /// Records touch-down, release and system cancellation on this view without taking the
    /// touch from it (simultaneous), plus its global frame. No-op when `debug` is nil.
    @ViewBuilder
    func canvasLayoutTouchProbe(_ name: String, debug: CanvasLayoutTouchDebug?) -> some View {
        if let debug {
            modifier(CanvasLayoutTouchProbe(name: name, debug: debug))
        } else {
            self
        }
    }
}

private struct CanvasLayoutTouchProbe: ViewModifier {
    let name: String
    let debug: CanvasLayoutTouchDebug
    @GestureState private var isTouching = false
    @State private var isDown = false

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .updating($isTouching) { _, state, _ in state = true }
                .onChanged { value in
                    guard !isDown else { return }
                    isDown = true
                    debug.record(name, "down", at: value.startLocation)
                }
                .onEnded { value in
                    isDown = false
                    debug.record(name, "up", at: value.location)
                })
            .onChange(of: isTouching) { _, touching in
                // Released without onEnded: the system cancelled the touch.
                guard !touching, isDown else { return }
                isDown = false
                debug.record(name, "cancel")
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                debug.frames[name] = $0
            }
    }
}

/// The on-screen readout. Never takes touches.
struct CanvasLayoutTouchDebugPanel: View {
    let debug: CanvasLayoutTouchDebug
    let isClockHiddenRequested: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: "topMidY \(debug.topControlMidY.map { CanvasLayoutTouchDebug.format($0) } ?? "–")  clockReq \(isClockHiddenRequested ? 1 : 0)")
            ForEach(["reset", "save", "bg"], id: \.self) { probe in
                Text(verbatim: line(probe))
            }
            ForEach(debug.events.indices, id: \.self) { index in
                Text(verbatim: debug.events[index])
            }
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .foregroundStyle(.black)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .padding(4)
        .background(Color.yellow.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// d/u/c: touch down, release, cancel; A: Button actions; F: taps the content forwarded;
    /// then the global frame.
    private func line(_ probe: String) -> String {
        let counts = "d\(debug.count(probe, "down")) u\(debug.count(probe, "up")) c\(debug.count(probe, "cancel"))"
        let action = probe == "bg" ? "" : " A\(debug.count(probe, "action")) F\(debug.count(probe, "fwd"))"
        let frame = debug.frames[probe].map {
            " [\(CanvasLayoutTouchDebug.format($0.minX)),\(CanvasLayoutTouchDebug.format($0.minY)) \(CanvasLayoutTouchDebug.format($0.width))x\(CanvasLayoutTouchDebug.format($0.height))]"
        } ?? ""
        return "\(probe) \(counts)\(action)\(frame)"
    }
}
