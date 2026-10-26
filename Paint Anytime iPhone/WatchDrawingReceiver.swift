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
            let names = try store.pendingImages().flatMap { image -> [String] in
                let project = image.deletingPathExtension().appendingPathExtension(PaintProject.fileExtension)
                return [image.lastPathComponent] + (FileManager.default.fileExists(atPath: project.path) ? [project.lastPathComponent] : [])
            }
            try session.updateApplicationContext(["galleryRequest": UUID().uuidString, "knownDrawings": names,
                                                  GalleryDeletionStore.contextKey: try (store as? IncomingDrawingStore)?.deletedNames() ?? []])
        } catch { onReceive?(.failure(error)) }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            if let error { onReceive?(.failure(error)) }
            else {
                receiveDeletions(session.receivedApplicationContext)
                requestSync()
            }
        }
    }
    private func receiveDeletions(_ context: [String: Any]) {
        guard let names = context[GalleryDeletionStore.contextKey] as? [String],
              let gallery = store as? IncomingDrawingStore else { return }
        do {
            try gallery.applyDeletions(names)
            onReceive?(.success(()))
        } catch { onReceive?(.failure(error)) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in receiveDeletions(applicationContext) }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        guard let error else { return }
        Task { @MainActor in onReceive?(.failure(error)) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let message = userInfo["projectImportError"] as? String else { return }
        let error = NSError(domain: "PaintAnytime.ProjectImport", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: message])
        Task { @MainActor in onReceive?(.failure(error)) }
    }

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
