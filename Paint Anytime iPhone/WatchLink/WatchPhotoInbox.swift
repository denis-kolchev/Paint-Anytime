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
    /// The file to save for a gallery image; the app composes imported photos at their
    /// original resolution here. May take a while, so it runs off the main actor.
    private let imageOutput: @Sendable (URL) throws -> URL

    init(store: any IncomingDrawingStoring, writer: any PhotoLibraryWriting,
         receiver: any WatchDrawingReceiving,
         imageOutput: @escaping @Sendable (URL) throws -> URL = { $0 }) {
        self.store = store
        self.writer = writer
        self.receiver = receiver
        self.imageOutput = imageOutput
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
                let output = imageOutput
                let file = try await Task.detached(priority: .userInitiated) { try output(image) }.value
                try await writer.save(file)
                savedToPhotos = true
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
