import Foundation
import WatchConnectivity

@MainActor
final class WatchDrawingReceiver: NSObject, WatchDrawingReceiving, WCSessionDelegate {
    nonisolated private let store: any IncomingDrawingStoring
    private var onReceive: (@MainActor (Result<Void, Error>) -> Void)?

    init(store: any IncomingDrawingStoring) {
        self.store = store
        super.init()
    }

    func start(onReceive: @escaping @MainActor (Result<Void, Error>) -> Void) {
        self.onReceive = onReceive
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // Capture the file synchronously: the system deletes it after this delegate call returns.
        let result = Result { try store.receive(file.fileURL) }
        Task { @MainActor in onReceive?(result) }
    }
}

extension WatchPhotoInbox {
    static let shared: WatchPhotoInbox = {
        let store = IncomingDrawingStore()
        return WatchPhotoInbox(store: store, writer: PhotoLibraryWriter(),
                               receiver: WatchDrawingReceiver(store: store))
    }()
}
