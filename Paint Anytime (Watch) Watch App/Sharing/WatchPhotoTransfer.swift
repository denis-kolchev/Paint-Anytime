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
    func queue(_ imageURL: URL) -> Bool {
        guard WCSession.isSupported() else { return false }
        do {
            let deleted = try GalleryDeletionStore.names(in: CanvasExportStore.directory())
            guard !deleted.contains(imageURL.deletingPathExtension().appendingPathExtension("png").lastPathComponent) else { return false }
        } catch { return false }
        let session = WCSession.default
        guard session.activationState == .activated, session.isCompanionAppInstalled else { return false }
        guard !session.outstandingFileTransfers.contains(where: { $0.file.metadata?["drawingName"] as? String == imageURL.lastPathComponent }) else { return true }
        if imageURL.pathExtension == "png" {
            let projectURL = imageURL.deletingPathExtension().appendingPathExtension(PaintProject.fileExtension)
            do {
                let document = try CanvasExportStore.loadDocument(at: imageURL)
                try PaintProject(document: JSONEncoder().encode(document), preview: Data(contentsOf: imageURL)).write(to: projectURL)
                if !session.outstandingFileTransfers.contains(where: { $0.file.fileURL == projectURL }) {
                    session.transferFile(projectURL, metadata: ["drawingName": projectURL.lastPathComponent])
                }
            } catch { NSLog("Project transfer preparation failed: %@", error.localizedDescription) }
        }
        session.transferFile(imageURL, metadata: ["drawingName": imageURL.lastPathComponent])
        return true
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if activationState == .activated { synchronize(session.receivedApplicationContext) }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        synchronize(applicationContext)
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
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
