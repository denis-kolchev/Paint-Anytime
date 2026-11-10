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
            let deleted = try (store as? IncomingDrawingStore)?.deletedNames() ?? []
            try session.updateApplicationContext(["galleryRequest": UUID().uuidString, "knownDrawings": names,
                                                  GalleryDeletionStore.contextKey: deleted])
            PhotoOriginalStore().prune(galleryImages: try store.pendingImages(), deleted: deleted)
        } catch { onReceive?(.failure(error)) }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            if let error { onReceive?(.failure(error)) }
            else {
                receiveDeletions(session.receivedApplicationContext)
                requestSync()
                // Once per launch, in case the watch app was reinstalled meanwhile.
                PhoneSketchAssist.shared.publishAvailability(force: true)
            }
        }
    }
    private func receiveDeletions(_ context: [String: Any]) {
        guard let names = context[GalleryDeletionStore.contextKey] as? [String],
              let gallery = store as? IncomingDrawingStore else { return }
        do {
            try gallery.applyDeletions(names)
            PhotoOriginalStore().prune(galleryImages: try gallery.pendingImages(), deleted: try gallery.deletedNames())
            onReceive?(.success(()))
        } catch { onReceive?(.failure(error)) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in receiveDeletions(applicationContext) }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        if fileTransfer.file.metadata?[SketchAssistProtocol.kindKey] as? String == SketchAssistProtocol.resultKind {
            try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
            return
        }
        if fileTransfer.file.metadata?[PhotoImportProtocol.kindKey] as? String == PhotoImportProtocol.kind {
            // Still report a failed photo transfer below.
            try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
        }
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
        if file.metadata?[SketchAssistProtocol.kindKey] as? String == SketchAssistProtocol.requestKind {
            let requestID = file.metadata?[SketchAssistProtocol.requestIDKey] as? String ?? ""
            let maximumPixels = file.metadata?[SketchAssistProtocol.maximumPixelsKey] as? Int ?? 512
            let imageData = (try? Data(contentsOf: file.fileURL)) ?? Data()
            Task { @MainActor in
                PhoneSketchAssist.shared.handle(imageData: imageData, requestID: requestID, maximumPixels: maximumPixels)
            }
            return
        }
        if file.metadata?[PhotoImportProtocol.kindKey] as? String == PhotoImportProtocol.overlayKind {
            let metadata = file.metadata ?? [:]
            let stem = metadata[PhotoImportProtocol.overlayForKey] as? String ?? ""
            do {
                // A deleted drawing must not keep its photo; prune removes the rest.
                let deleted = try (store as? IncomingDrawingStore)?.deletedNames() ?? []
                guard !deleted.contains(stem + ".png") else { return }
                try PhotoOriginalStore().receiveOverlay(file.fileURL, metadata: metadata)
            } catch {
                // Saving and sharing then use the watch's image of this drawing.
                NSLog("Photo overlay was not kept: %@", error.localizedDescription)
            }
            return
        }
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
                               receiver: WatchDrawingReceiver(store: store),
                               imageOutput: { try PhotoOriginalStore().outputImage(for: $0) })
    }()
}
