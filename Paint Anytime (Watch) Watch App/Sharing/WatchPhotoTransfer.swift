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

    @MainActor
    func queue(_ imageURL: URL, replacingPending: Bool = false) -> Bool {
        guard WCSession.isSupported() else { return false }
        do {
            let deleted = try GalleryDeletionStore.names(in: CanvasExportStore.directory())
            guard !deleted.contains(imageURL.deletingPathExtension().appendingPathExtension("png").lastPathComponent) else { return false }
        } catch { return false }
        let session = WCSession.default
        guard session.activationState == .activated, session.isCompanionAppInstalled else { return false }
        if replacingPending {
            let stem = imageURL.deletingPathExtension().lastPathComponent
            for transfer in session.outstandingFileTransfers {
                if transfer.file.metadata?[PhotoImportProtocol.overlayForKey] as? String == stem {
                    // Superseded by the overlay of this save; its file is temporary.
                    transfer.cancel()
                    try? FileManager.default.removeItem(at: transfer.file.fileURL)
                    continue
                }
                guard let name = transfer.file.metadata?["drawingName"] as? String,
                      URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent == stem else { continue }
                transfer.cancel()
            }
        }
        guard replacingPending || !session.outstandingFileTransfers.contains(where: { $0.file.metadata?["drawingName"] as? String == imageURL.lastPathComponent }) else { return true }
        var photoDocument: CanvasDocument?
        if imageURL.pathExtension == "png" {
            let projectURL = imageURL.deletingPathExtension().appendingPathExtension(PaintProject.fileExtension)
            do {
                let document = try CanvasExportStore.loadDocument(at: imageURL)
                photoDocument = document
                try PaintProject(document: JSONEncoder().encode(document), preview: Data(contentsOf: imageURL)).write(to: projectURL)
                if replacingPending || !session.outstandingFileTransfers.contains(where: { $0.file.fileURL == projectURL }) {
                    session.transferFile(projectURL, metadata: ["drawingName": projectURL.lastPathComponent])
                }
            } catch { NSLog("Project transfer preparation failed: %@", error.localizedDescription) }
        }
        session.transferFile(imageURL, metadata: ["drawingName": imageURL.lastPathComponent])
        if let photoDocument {
            WatchPhotoOverlay.send(document: photoDocument, imageURL: imageURL, session: session)
        }
        return true
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if activationState == .activated { synchronize(session.receivedApplicationContext) }
        if activationState == .activated && !session.isCompanionAppInstalled {
            Task { @MainActor in WatchSketchAssist.shared.updatePhoneAvailability(false) }
        }
    }

    func sessionCompanionAppInstalledDidChange(_ session: WCSession) {
        // A reinstalled iPhone app reports availability again when it launches.
        guard !session.isCompanionAppInstalled else { return }
        Task { @MainActor in WatchSketchAssist.shared.updatePhoneAvailability(false) }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        synchronize(applicationContext)
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        if file.metadata?[SketchAssistProtocol.kindKey] as? String == SketchAssistProtocol.resultKind {
            // Read now: the system deletes the file after this delegate call returns.
            let imageData = try? Data(contentsOf: file.fileURL)
            let label = file.metadata?[SketchAssistProtocol.labelKey] as? String
            let requestID = file.metadata?[SketchAssistProtocol.requestIDKey] as? String ?? ""
            Task { @MainActor in
                WatchSketchAssist.shared.receive(imageData: imageData, label: label, requestID: requestID)
            }
            return
        }
        if file.metadata?[PhotoImportProtocol.kindKey] as? String == PhotoImportProtocol.kind {
            let imageData = try? Data(contentsOf: file.fileURL)
            let fitsWatch = file.metadata?[PhotoImportProtocol.fitsWatchKey] as? Bool ?? true
            let name = (file.metadata?[PhotoImportProtocol.nameKey] as? String)
                .flatMap { PhotoImportProtocol.isValidDrawingName($0) ? $0 : nil }
            let photoID = (file.metadata?[PhotoImportProtocol.photoIDKey] as? String)
                .flatMap(UUID.init(uuidString:)).flatMap { PhotoImportProtocol.isPhotoID($0) ? $0 : nil }
            Task { @MainActor in
                do {
                    guard let drawing = try WatchPhotoImport.save(imageData: imageData, fitsWatch: fitsWatch,
                                                                  name: name, photoID: photoID) else { return }
                    NotificationCenter.default.post(name: .paintProjectImported, object: nil)
                    // The phone holds only a preview; send the drawing with its project.
                    _ = WatchPhotoTransfer.shared.queue(drawing.url)
                } catch { session.transferUserInfo(["projectImportError": error.localizedDescription]) }
            }
            return
        }
        do {
            let project = try PaintProject.read(file.fileURL)
            var document = try JSONDecoder().decode(CanvasDocument.self, from: project.document)
            document.id = UUID() // Imported projects are independent copies.
            let imported = document
            Task { @MainActor in
                do {
                    _ = try CanvasExportStore.save(document: imported, imageData: project.preview,
                                                   name: "Imported_" + UUID().uuidString)
                    NotificationCenter.default.post(name: .paintProjectImported, object: nil)
                } catch { session.transferUserInfo(["projectImportError": error.localizedDescription]) }
            }
        } catch { session.transferUserInfo(["projectImportError": error.localizedDescription]) }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        receiveSketchAssistStage(message)
    }

    /// True when `info` carried a sketch assist stage.
    @discardableResult
    private func receiveSketchAssistStage(_ info: [String: Any]) -> Bool {
        guard let raw = info[SketchAssistProtocol.stageKey] as? String,
              let stage = SketchAssistProtocol.Stage(rawValue: raw) else { return false }
        let requestID = info[SketchAssistProtocol.requestIDKey] as? String ?? ""
        Task { @MainActor in WatchSketchAssist.shared.receive(stage: stage, requestID: requestID) }
        return true
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        if receiveSketchAssistStage(userInfo) { return }
        if let available = userInfo[SketchAssistProtocol.availabilityKey] as? Bool {
            Task { @MainActor in WatchSketchAssist.shared.updatePhoneAvailability(available) }
            return
        }
        guard let failure = userInfo[SketchAssistProtocol.failureKey] as? String else { return }
        let requestID = userInfo[SketchAssistProtocol.requestIDKey] as? String ?? ""
        let detail = userInfo[SketchAssistProtocol.detailKey] as? String
        Task { @MainActor in WatchSketchAssist.shared.receive(failure: failure, detail: detail, requestID: requestID) }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        if fileTransfer.file.metadata?[PhotoImportProtocol.kindKey] as? String == PhotoImportProtocol.overlayKind {
            // A lost overlay only means the phone uses this save's watch image.
            try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
            return
        }
        guard fileTransfer.file.metadata?[SketchAssistProtocol.kindKey] as? String == SketchAssistProtocol.requestKind
        else { return }
        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
        let requestID = fileTransfer.file.metadata?[SketchAssistProtocol.requestIDKey] as? String ?? ""
        guard error != nil else {
            Task { @MainActor in WatchSketchAssist.shared.receive(stage: .delivered, requestID: requestID) }
            return
        }
        Task { @MainActor in
            WatchSketchAssist.shared.receive(failure: SketchAssistProtocol.Failure.failed.rawValue,
                                             detail: error?.localizedDescription, requestID: requestID)
        }
    }

    @MainActor
    func publishDeletions() {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        do {
            let names = try GalleryDeletionStore.names(in: CanvasExportStore.directory())
            for transfer in session.outstandingFileTransfers {
                guard let name = transfer.file.metadata?["drawingName"] as? String else { continue }
                let imageName = URL(fileURLWithPath: name).deletingPathExtension().appendingPathExtension("png").lastPathComponent
                if names.contains(imageName) { transfer.cancel() }
            }
            try session.updateApplicationContext([GalleryDeletionStore.contextKey: names.sorted()])
        } catch { NSLog("Gallery deletion sync failed: %@", error.localizedDescription) }
    }

    private func synchronize(_ context: [String: Any]) {
        let known = Set(context["knownDrawings"] as? [String] ?? [])
        // Serialize deletions and transfers with watch gallery saves.
        Task { @MainActor in
            do {
                let folder = try CanvasExportStore.directory()
                try GalleryDeletionStore.merge(context[GalleryDeletionStore.contextKey] as? [String] ?? [], in: folder)
                let deleted = try GalleryDeletionStore.names(in: folder)
                for name in deleted {
                    let url = folder.appendingPathComponent(name)
                    try CanvasExportStore.delete(CanvasExport(url: url), in: folder)
                    await GalleryImageCache.shared.remove(url)
                }
                if !deleted.isEmpty {
                    try CanvasExportStore.refreshWidgets()
                    NotificationCenter.default.post(name: .galleryDrawingsDeleted, object: nil)
                }
                publishDeletions()
                guard context["galleryRequest"] != nil else { return }
                for drawing in try CanvasExportStore.all() where !known.contains(drawing.url.deletingPathExtension().appendingPathExtension(PaintProject.fileExtension).lastPathComponent) {
                    _ = queue(drawing.url)
                }
            } catch { NSLog("Gallery synchronization failed: %@", error.localizedDescription) }
        }
    }
}

extension Notification.Name {
    static let galleryDrawingsDeleted = Notification.Name("galleryDrawingsDeleted")
}
