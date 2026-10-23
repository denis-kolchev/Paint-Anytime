import Foundation
import WatchConnectivity

final class WatchPhotoTransfer: NSObject, WCSessionDelegate {
    static let shared = WatchPhotoTransfer()

    private override init() { super.init() }

    func start() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func queue(_ imageURL: URL) -> Bool {
        guard WCSession.isSupported() else { return false }
        let session = WCSession.default
        guard session.activationState == .activated, session.isCompanionAppInstalled else { return false }
        guard !session.outstandingFileTransfers.contains(where: { $0.file.metadata?["drawingName"] as? String == imageURL.lastPathComponent }) else { return true }
        session.transferFile(imageURL, metadata: ["drawingName": imageURL.lastPathComponent])
        return true
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if activationState == .activated { synchronize(session.receivedApplicationContext) }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        synchronize(applicationContext)
    }

    private func synchronize(_ context: [String: Any]) {
        guard context["galleryRequest"] != nil else { return }
        let known = Set(context["knownDrawings"] as? [String] ?? [])
        // Gallery access stays on the same actor as watch saves and deletions.
        Task { @MainActor in
            guard let drawings = try? CanvasExportStore.all() else { return }
            for drawing in drawings where !known.contains(drawing.url.lastPathComponent) {
                _ = queue(drawing.url)
            }
        }
    }
}
