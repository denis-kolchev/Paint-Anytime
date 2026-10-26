import Foundation

protocol IncomingDrawingStoring: Sendable {
    nonisolated func receive(_ temporaryFile: URL) throws
    nonisolated func pendingImages() throws -> [URL]
    nonisolated func remove(_ image: URL) throws
}

/// Moves received files before WatchConnectivity invalidates its temporary URL.
struct IncomingDrawingStore: IncomingDrawingStoring {
    private static let fileLock = NSLock()
    private let folderOverride: URL?

    nonisolated init(folder: URL? = nil) { folderOverride = folder }

    nonisolated private func directory() throws -> URL {
        let folder: URL
        if let folderOverride { folder = folderOverride }
        else {
            folder = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
                .appendingPathComponent("IncomingWatchDrawings", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    nonisolated func receive(_ temporaryFile: URL) throws {
        try receive(temporaryFile, name: UUID().uuidString + ".png")
    }

    nonisolated func receive(_ temporaryFile: URL, name: String) throws {
        Self.fileLock.lock()
        defer { Self.fileLock.unlock() }
        let safeName = URL(fileURLWithPath: name).lastPathComponent
        guard safeName == name, ["png", PaintProject.fileExtension].contains(URL(fileURLWithPath: safeName).pathExtension.lowercased()) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let destination = try directory().appendingPathComponent(safeName)
        let imageName = destination.deletingPathExtension().appendingPathExtension("png").lastPathComponent
        if try GalleryDeletionStore.names(in: directory()).contains(imageName) {
            try FileManager.default.removeItem(at: temporaryFile)
            return
        }
        if destination.pathExtension == PaintProject.fileExtension {
            let project = try PaintProject.read(temporaryFile)
            try project.write(to: destination)
            try project.preview.write(to: destination.deletingPathExtension().appendingPathExtension("png"), options: .atomic)
        } else {
            try Data(contentsOf: temporaryFile).write(to: destination, options: .atomic)
        }
        try FileManager.default.removeItem(at: temporaryFile)
    }

    nonisolated func pendingImages() throws -> [URL] {
        Self.fileLock.lock()
        defer { Self.fileLock.unlock() }
        let deleted = try GalleryDeletionStore.names(in: directory())
        return try FileManager.default.contentsOfDirectory(at: directory(), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "png" && !deleted.contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    nonisolated func remove(_ image: URL) throws {
        guard image.deletingLastPathComponent().standardizedFileURL == (try directory()).standardizedFileURL else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try applyDeletions([image.lastPathComponent])
    }
    nonisolated func deletedNames() throws -> [String] {
        Self.fileLock.lock()
        defer { Self.fileLock.unlock() }
        return try GalleryDeletionStore.names(in: directory()).sorted()
    }

    nonisolated func applyDeletions(_ names: [String]) throws {
        Self.fileLock.lock()
        defer { Self.fileLock.unlock() }
        let folder = try directory()
        try GalleryDeletionStore.merge(names, in: folder)
        for name in try GalleryDeletionStore.names(in: folder) {
            try GalleryDeletionStore.removeFiles(for: name, in: folder)
        }
    }

}
