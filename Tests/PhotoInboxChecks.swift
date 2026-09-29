import Foundation

@MainActor
private final class TestPhotoWriter: PhotoLibraryWriting {
    var canSave = false
    var permissionRequiresSettings = false
    var calls: [URL] = []
    var pending: CheckedContinuation<Void, Error>?

    func requestPermission() async { canSave = true }
    func save(_ image: URL) async throws {
        calls.append(image)
        try await withCheckedThrowingContinuation { pending = $0 }
    }
    func finish(_ result: Result<Void, Error>) {
        let continuation = pending
        pending = nil
        continuation?.resume(with: result)
    }
}

@MainActor
private final class TestReceiver: WatchDrawingReceiving {
    var onReceive: (@MainActor (Result<Void, Error>) -> Void)?
    func start(onReceive: @escaping @MainActor (Result<Void, Error>) -> Void) {
        self.onReceive = onReceive
    }
}

private struct FailingStore: IncomingDrawingStoring {
    let base: IncomingDrawingStore
    var failsRead = false
    func receive(_ temporaryFile: URL) throws { try base.receive(temporaryFile) }
    func pendingImages() throws -> [URL] {
        if failsRead { throw CocoaError(.fileReadNoPermission) }
        return try base.pendingImages()
    }
    func remove(_ image: URL) throws { throw CocoaError(.fileWriteNoPermission) }
}

@main
struct PhotoInboxChecks {
    @MainActor static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        preconditionFailure("Timed out waiting for queue processing")
    }

    @MainActor static func main() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = base.appendingPathComponent("inbox")
        let store = IncomingDrawingStore(folder: folder)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        func receive() throws {
            let source = base.appendingPathComponent(UUID().uuidString)
            try Data([1, 2, 3]).write(to: source)
            try store.receive(source)
            precondition(!FileManager.default.fileExists(atPath: source.path))
        }
        try receive()
        try receive()
        try Data().write(to: folder.appendingPathComponent("ignored.json"))
        let files = try store.pendingImages()
        precondition(files.count == 2)
        precondition(files.map(\.lastPathComponent) == files.map(\.lastPathComponent).sorted())
        let writer = TestPhotoWriter()
        let receiver = TestReceiver()
        let inbox = WatchPhotoInbox(store: store, writer: writer, receiver: receiver)
        inbox.start()
        precondition(inbox.needsPhotoPermission && inbox.pendingCount == 2 && writer.calls.isEmpty)
        writer.permissionRequiresSettings = true
        inbox.refresh()
        precondition(inbox.photoPermissionRequiresSettings)
        inbox.requestPhotoPermission()
        try await waitUntil { writer.pending != nil }
        precondition(!inbox.needsPhotoPermission && writer.calls.count == 1)
        inbox.refresh()
        inbox.refresh()
        try receive()
        receiver.onReceive?(.success(()))
        precondition(inbox.pendingCount == 3 && writer.calls.count == 1, "No overlapping saves")
        writer.finish(.failure(CocoaError(.fileWriteUnknown)))
        try await waitUntil { inbox.errorMessage != nil }
        let afterFailure = try store.pendingImages()
        precondition(afterFailure.count == 3, "Failed images stay queued")
        inbox.clearError()
        inbox.refresh()
        try await waitUntil { writer.calls.count == 2 && writer.pending != nil }
        // The newly arrived UUID may sort before the failed file, as in the existing queue.
        writer.finish(.success(()))
        try await waitUntil { writer.calls.count == 3 && writer.pending != nil }
        writer.finish(.success(()))
        try await waitUntil { writer.calls.count == 4 && writer.pending != nil }
        writer.finish(.success(()))
        try await waitUntil { inbox.pendingCount == 0 }
        let remaining = try store.pendingImages()
        precondition(remaining.isEmpty && writer.calls.count == 4)
        receiver.onReceive?(.failure(CocoaError(.fileReadUnknown)))
        precondition(inbox.errorMessage?.contains("получить") == true)
        try receive()
        let cleanupWriter = TestPhotoWriter()
        cleanupWriter.canSave = true
        let cleanupInbox = WatchPhotoInbox(store: FailingStore(base: store), writer: cleanupWriter,
                                          receiver: TestReceiver())
        cleanupInbox.refresh()
        try await waitUntil { cleanupWriter.pending != nil }
        cleanupWriter.finish(.success(()))
        try await waitUntil { cleanupInbox.errorMessage != nil }
        precondition(cleanupInbox.errorMessage?.contains("временный файл") == true)
        let afterCleanupFailure = try store.pendingImages()
        precondition(afterCleanupFailure.count == 1 && cleanupWriter.calls.count == 1)
        let readInbox = WatchPhotoInbox(store: FailingStore(base: store, failsRead: true), writer: cleanupWriter,
                                       receiver: TestReceiver())
        readInbox.refresh()
        precondition(readInbox.errorMessage?.contains("прочитать") == true)
        print("PASS: incoming file ownership, queue ordering, permission, serial writes, retry, receive/read/cleanup errors")
    }
}
