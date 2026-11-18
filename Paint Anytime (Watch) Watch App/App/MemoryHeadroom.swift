import Foundation
import os

/// Logs this process's memory footprint and the room left before its limit. The sum
/// estimates the current limit, which watchOS does not publish and which differs in
/// the background (wrist down, autosave). Read with Console or the Xcode console,
/// category "memory". Nonisolated: called from autosave and transfer work off the main actor.
nonisolated enum MemoryHeadroom {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PaintAnytime",
                                       category: "memory")

    static func log(_ stage: StaticString) {
        let headroom = Double(os_proc_available_memory()) / 1_048_576
        let footprint = Double(physicalFootprint()) / 1_048_576
        logger.notice("""
            stage=\(String(describing: stage), privacy: .public) \
            footprint=\(footprint, format: .fixed(precision: 1), privacy: .public)MiB \
            headroom=\(headroom, format: .fixed(precision: 1), privacy: .public)MiB \
            limit≈\(footprint + headroom, format: .fixed(precision: 1), privacy: .public)MiB
            """)
    }

    /// What the system counts against the limit, as Xcode's memory gauge shows it.
    private static func physicalFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
