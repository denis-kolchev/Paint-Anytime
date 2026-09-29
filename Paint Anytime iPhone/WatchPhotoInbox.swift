import Combine
import Foundation

@MainActor
protocol WatchDrawingReceiving {
    func start(onReceive: @escaping @MainActor (Result<Void, Error>) -> Void)
}

/// Coordinates permission, a persistent queue, and one-at-a-time library writes.
@MainActor
final class WatchPhotoInbox: ObservableObject {
    @Published private(set) var needsPhotoPermission = false
    @Published private(set) var photoPermissionRequiresSettings = false
    @Published private(set) var pendingCount = 0
    @Published private(set) var errorMessage: String?

    private let store: any IncomingDrawingStoring
    private let writer: any PhotoLibraryWriting
    private let receiver: any WatchDrawingReceiving
    private var isSaving = false

    init(store: any IncomingDrawingStoring, writer: any PhotoLibraryWriting,
         receiver: any WatchDrawingReceiving) {
        self.store = store
        self.writer = writer
        self.receiver = receiver
    }

    func start() {
        refresh()
        receiver.start { [weak self] result in
            switch result {
            case .success: self?.refresh()
            case .failure(let error):
                self?.errorMessage = "Не удалось получить рисунок с часов: \(error.localizedDescription)"
            }
        }
    }

    func requestPhotoPermission() {
        Task {
            await writer.requestPermission()
            refresh()
        }
    }

    func clearError() { errorMessage = nil }

    func refresh() {
        needsPhotoPermission = !writer.canSave
        photoPermissionRequiresSettings = writer.permissionRequiresSettings
        do {
            let images = try store.pendingImages()
            pendingCount = images.count
            if writer.canSave, let next = images.first { save(next) }
        } catch {
            errorMessage = "Не удалось прочитать полученные рисунки: \(error.localizedDescription)"
        }
    }

    private func save(_ image: URL) {
        guard !isSaving else { return }
        isSaving = true
        Task {
            do { try await writer.save(image) }
            catch {
                isSaving = false
                errorMessage = "Не удалось сохранить рисунок в Фото: \(error.localizedDescription)"
                return
            }
            isSaving = false
            do { try store.remove(image) }
            catch {
                errorMessage = "Рисунок сохранён в Фото, но временный файл не удалён: \(error.localizedDescription)"
                return
            }
            refresh()
        }
    }
}
