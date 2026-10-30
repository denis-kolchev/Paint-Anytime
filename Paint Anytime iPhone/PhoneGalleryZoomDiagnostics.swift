#if DEBUG
import Foundation
import QuartzCore

/// Milestones are retained after release; synchronous stalls cannot display
/// their intermediate state while the main thread is busy.
struct PhoneGalleryZoomDiagnostics {
    var session = 0
    var startedAt: CFTimeInterval?
    var movementMS: Double?
    var recognizedMS: Double?
    var appliedMS: Double?
    var preparationMS: Double?
    var slotsMS: Double?
    var backdropMS: Double?
    var loadingMS: Double?
    var slotCount = 0
    var missingCount = 0

    mutating func begin() {
        let next = session + 1
        self = Self()
        session = next
        startedAt = CACurrentMediaTime()
    }

    func elapsedMS() -> Double? {
        startedAt.map { (CACurrentMediaTime() - $0) * 1000 }
    }

    private func ms(_ value: Double?) -> String {
        value.map { String(format: "%.1f", $0) } ?? "—"
    }

    var text: String {
        "Pinch #\(session) · ms from 2 touches\n"
        + "move \(ms(movementMS)) · gesture \(ms(recognizedMS)) · apply \(ms(appliedMS))\n"
        + "prep \(ms(preparationMS)) ms · slots \(ms(slotsMS)) ms\n"
        + "backdrop(bg) \(ms(backdropMS)) ms · load \(ms(loadingMS)) ms\n"
        + "slots \(slotCount) · missing snapshots \(missingCount)"
    }
}
#endif
