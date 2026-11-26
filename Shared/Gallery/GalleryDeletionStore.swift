import Foundation

/// Permanent tombstones prevent delayed file transfers from restoring deleted artwork.
/// Callers serialize access with their gallery's other file operations.
enum GalleryDeletionStore {
    nonisolated static let contextKey = "deletedDrawings"

    nonisolated static func names(in folder: URL) throws -> Set<String> {
        let url = folder.appendingPathComponent("deleted-drawings.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return Set(try JSONDecoder().decode([String].self, from: Data(contentsOf: url)))
    }

    nonisolated static func merge(_ names: [String], in folder: URL) throws {
        guard names.allSatisfy({ !$0.isEmpty && URL(fileURLWithPath: $0).lastPathComponent == $0 && URL(fileURLWithPath: $0).pathExtension == "png" }) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let existing = try self.names(in: folder)
        let merged = existing.union(names)
        guard merged != existing else { return }
        try JSONEncoder().encode(merged.sorted()).write(to: folder.appendingPathComponent("deleted-drawings.json"), options: .atomic)
    }

    nonisolated static func removeFiles(for name: String, in folder: URL) throws {
        let image = folder.appendingPathComponent(name)
        for url in [image, image.deletingPathExtension().appendingPathExtension(PaintProject.fileExtension),
                    image.deletingPathExtension().appendingPathExtension("json")] {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
}
