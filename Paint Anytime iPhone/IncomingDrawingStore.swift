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
        try receive(temporaryFile, name: UUID().uuidString + ".png")
    }

    nonisolated func receive(_ temporaryFile: URL, name: String) throws {
        let safeName = URL(fileURLWithPath: name).lastPathComponent
        guard safeName == name, safeName.lowercased().hasSuffix(".png") else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let destination = try directory().appendingPathComponent(safeName)
        try Data(contentsOf: temporaryFile).write(to: destination, options: .atomic)
        try FileManager.default.removeItem(at: temporaryFile)
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
