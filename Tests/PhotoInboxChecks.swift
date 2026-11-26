import Foundation
import Combine

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
    var startCount = 0
    var onReceive: (@MainActor (Result<Void, Error>) -> Void)?
    func start(onReceive: @escaping @MainActor (Result<Void, Error>) -> Void) {
        startCount += 1
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
        var publications = 0
        let observation = inbox.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }
        inbox.clearError()
        inbox.clearConfirmation()
        precondition(publications == 0, "Dismissing inactive alerts must not publish")
        inbox.start()
        let afterStart = publications
        inbox.start()
        precondition(receiver.startCount == 1 && publications == afterStart, "Repeated view tasks must not restart the receiver")
        precondition(inbox.images.count == 2 && writer.calls.isEmpty)
        let selected = inbox.images[0]
        inbox.saveToPhotos(selected)
        try await waitUntil { writer.pending != nil }
        inbox.saveToPhotos(selected)
        precondition(writer.calls.count == 1, "No overlapping writes")
        writer.finish(.failure(CocoaError(.fileWriteUnknown)))
        try await waitUntil { inbox.errorMessage != nil }
        let afterFailure = try store.pendingImages()
        precondition(afterFailure.count == 2, "Failure preserves gallery")
        inbox.clearError()
        let afterClear = publications
        inbox.clearError()
        precondition(publications == afterClear, "Repeated error dismissal must not publish")
        inbox.saveToPhotos(selected)
        try await waitUntil { writer.pending != nil }
        writer.finish(.success(()))
        try await waitUntil { inbox.savedToPhotos }
        inbox.clearConfirmation()
        let afterConfirmation = publications
        inbox.clearConfirmation()
        precondition(publications == afterConfirmation, "Repeated confirmation dismissal must not publish")
        let afterExport = try store.pendingImages()
        precondition(afterExport.count == 2, "Export preserves gallery")
        let source = base.appendingPathComponent("transfer")
        try Data([4]).write(to: source)
        try store.receive(source, name: "drawing.png")
        try Data([5]).write(to: source)
        try store.receive(source, name: "drawing.png")
        let afterSync = try store.pendingImages()
        precondition(afterSync.count == 3, "Repeated sync replaces the same drawing")
        try Data([6]).write(to: source)
        do {
            try store.receive(source, name: "../escape.png")
            preconditionFailure("Unsafe name accepted")
        } catch {}
        inbox.refresh()
        precondition(inbox.images.count == 3)
        print("PASS: persistent gallery, explicit export, serial writes, failed export retention, sync deduplication")
    }
}
