import Foundation

protocol IncomingDrawingStoring: Sendable {
    nonisolated func receive(_ temporaryFile: URL) throws
    nonisolated func pendingImages() throws -> [URL]
    nonisolated func remove(_ image: URL) throws
}

/// Moves received files before WatchConnectivity invalidates its temporary URL.
struct IncomingDrawingStore: IncomingDrawingStoring {
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
        let destination = try directory().appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        try FileManager.default.moveItem(at: temporaryFile, to: destination)
    }

    nonisolated func pendingImages() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory(), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    nonisolated func remove(_ image: URL) throws {
        try FileManager.default.removeItem(at: image)
    }
}
