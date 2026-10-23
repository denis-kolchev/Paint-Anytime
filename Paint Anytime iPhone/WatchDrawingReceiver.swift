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

    func requestSync() {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        do {
            let names = try store.pendingImages().map(\.lastPathComponent)
            try session.updateApplicationContext(["galleryRequest": UUID().uuidString, "knownDrawings": names])
        } catch { onReceive?(.failure(error)) }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            if let error { onReceive?(.failure(error)) }
            else { requestSync() }
        }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // Capture the file synchronously: the system deletes it after this delegate call returns.
        let result = Result {
            if let gallery = store as? IncomingDrawingStore, let name = file.metadata?["drawingName"] as? String {
                try gallery.receive(file.fileURL, name: name)
            } else { try store.receive(file.fileURL) }
        }
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
