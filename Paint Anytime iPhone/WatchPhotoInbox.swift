import Combine
import Foundation
import Photos
import WatchConnectivity

@MainActor
final class WatchPhotoInbox: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchPhotoInbox()

    @Published private(set) var needsPhotoPermission = false
    @Published private(set) var pendingCount = 0
    @Published private(set) var errorMessage: String?

    private var isSaving = false

    private override init() { super.init() }

    func start() {
        refresh()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func requestPhotoPermission() {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in
            Task { @MainActor in self.refresh() }
        }
    }

    func clearError() { errorMessage = nil }

    func refresh() {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        needsPhotoPermission = status != .authorized
        do {
            pendingCount = try pendingImages().count
            if status == .authorized { saveNextImage() }
        } catch {
            errorMessage = "Не удалось прочитать полученные рисунки: \(error.localizedDescription)"
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        do {
            let folder = try Self.inboxDirectory()
            let destination = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
            try FileManager.default.moveItem(at: file.fileURL, to: destination)
            Task { @MainActor in self.refresh() }
        } catch {
            Task { @MainActor in
                self.errorMessage = "Не удалось получить рисунок с часов: \(error.localizedDescription)"
            }
        }
    }

    nonisolated private static func inboxDirectory() throws -> URL {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
        let folder = documents.appendingPathComponent("IncomingWatchDrawings", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func pendingImages() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: Self.inboxDirectory(), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func saveNextImage() {
        guard !isSaving, PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized,
              let imageURL = try? pendingImages().first else { return }
        isSaving = true
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: imageURL)
        } completionHandler: { saved, error in
            Task { @MainActor in
                self.isSaving = false
                if saved {
                    do { try FileManager.default.removeItem(at: imageURL) }
                    catch {
                        self.errorMessage = "Рисунок сохранён в Фото, но временный файл не удалён: \(error.localizedDescription)"
                        return
                    }
                    self.refresh()
                } else {
                    self.errorMessage = "Не удалось сохранить рисунок в Фото: \(error?.localizedDescription ?? "Неизвестная ошибка")"
                }
            }
        }
    }
}
