import SwiftUI
import Foundation
import Darwin
import WatchConnectivity

/// Canvas speed HUD. Polls the isolated counters, so recording a frame never
/// invalidates the canvas; only this label re-renders, twice a second.
struct RenderDebugOverlay: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var text = "Render —"

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 7, weight: .medium, design: .monospaced))
            .foregroundStyle(.white)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(4)
            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
            // Stay inside the round screen instead of clipping the line starts.
            .padding(.horizontal, 8)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: scenePhase) {
                guard scenePhase == .active, RenderDebug.isEnabled else { return }
                let diagnostics = RenderDiagnostics.shared
                diagnostics.startMainProbe()
                defer { diagnostics.stopMainProbe() }
                _ = diagnostics.snapshot() // Start a fresh window.
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                    text = diagnostics.snapshot() + "\n" + Self.systemLine()
                }
            }
    }

    /// System conditions outside the app's control that throttle drawing:
    /// thermal throttling, Low Power Mode, memory pressure and iPhone transfers.
    private static func systemLine() -> String {
        let info = ProcessInfo.processInfo
        let thermal = switch info.thermalState {
        case .nominal: "ok"
        case .fair: "fair"
        case .serious: "SERIOUS"
        case .critical: "CRITICAL"
        @unknown default: "?"
        }
        let memory = memoryFootprintMB().map { String(format: "%.0fMB", $0) } ?? "—"
        var transfers = "—"
        if WCSession.isSupported(), WCSession.default.activationState == .activated {
            transfers = "\(WCSession.default.outstandingFileTransfers.count)"
        }
        return "heat \(thermal) · LPM \(info.isLowPowerModeEnabled ? "ON" : "off") · mem \(memory) · WC \(transfers)"
    }

    /// Physical footprint, the figure watchOS uses for its memory limit.
    private static func memoryFootprintMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / 1_048_576
    }
}
