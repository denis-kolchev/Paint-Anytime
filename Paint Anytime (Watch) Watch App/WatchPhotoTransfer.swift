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
        session.transferFile(imageURL, metadata: nil)
        return true
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
}
