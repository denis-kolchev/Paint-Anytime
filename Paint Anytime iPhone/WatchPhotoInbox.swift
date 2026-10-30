import Combine
import Foundation

@MainActor
protocol WatchDrawingReceiving {
    func start(onReceive: @escaping @MainActor (Result<Void, Error>) -> Void)
    func requestSync()
}

extension WatchDrawingReceiving {
    func requestSync() {}
}

@MainActor
final class WatchPhotoInbox: ObservableObject {
    @Published private(set) var images: [URL] = []
    @Published private(set) var isSaving = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var savedToPhotos = false
    @Published private(set) var photoPermissionRequiresSettings = false

    private var hasStarted = false

    private let store: any IncomingDrawingStoring
    private let writer: any PhotoLibraryWriting
    private let receiver: any WatchDrawingReceiving

    init(store: any IncomingDrawingStoring, writer: any PhotoLibraryWriting,
         receiver: any WatchDrawingReceiving) {
        self.store = store
        self.writer = writer
        self.receiver = receiver
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        refresh()
        receiver.start { [weak self] result in
            switch result {
            case .success: self?.refresh()
            case .failure(let error): self?.errorMessage = error.localizedDescription
            }
        }
    }

    @discardableResult
    func delete(_ image: URL) -> Bool {
        do {
            if DebugGallerySamples.contains(image) {
                try DebugGallerySamples.remove(image)
                refresh()
                return true
            }
            try store.remove(image)
            refresh()
            receiver.requestSync()
            return true
        } catch {
            errorMessage = error.localizedDescription
            refresh()
            receiver.requestSync()
            return false
        }
    }

    func synchronize() { receiver.requestSync() }
    func clearError() {
        guard errorMessage != nil else { return }
        errorMessage = nil
    }
    func clearConfirmation() {
        guard savedToPhotos else { return }
        savedToPhotos = false
    }

    func refresh() {
        do {
            let received = try store.pendingImages()
            images = received.sorted { $0.lastPathComponent > $1.lastPathComponent }
            let samples = try DebugGallerySamples.images()
            images = (received + samples).sorted(by: DebugGallerySamples.orderedBefore)
        }
        catch { errorMessage = error.localizedDescription }
        photoPermissionRequiresSettings = writer.permissionRequiresSettings
    }

    func saveToPhotos(_ image: URL) {
        guard !isSaving else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            if !writer.canSave { await writer.requestPermission() }
            photoPermissionRequiresSettings = writer.permissionRequiresSettings
            guard writer.canSave else {
                errorMessage = String(localized: "Allow access in Settings to save drawings to Photos.")
                return
            }
            do {
                try await writer.save(image)
                savedToPhotos = true
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
