import Foundation

enum CanvasExportStore {
    static func directory() throws -> URL {
        let folder = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
            .appendingPathComponent("Drawings", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func all(in folder: URL? = nil) throws -> [CanvasExport] {
        let targetFolder = try (folder ?? directory())
        let favorites = try favoriteNames(in: targetFolder)
        return try FileManager.default.contentsOfDirectory(at: targetFolder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { drawingSortKey($0) > drawingSortKey($1) }
            .map { CanvasExport(url: $0, isFavorite: favorites.contains($0.lastPathComponent)) }
    }

    /// Persistent metadata API for a future favorite toggle. Existing drawings default to false.
    static func setFavorite(_ isFavorite: Bool, for drawing: CanvasExport, in destination: URL? = nil) throws {
        let folder = try (destination ?? directory()).resolvingSymlinksInPath().standardizedFileURL
        let file = drawing.url.resolvingSymlinksInPath().standardizedFileURL
        guard file.deletingLastPathComponent() == folder,
              file.pathExtension.lowercased() == "png", FileManager.default.fileExists(atPath: file.path)
        else { throw CocoaError(.fileNoSuchFile) }
        var favorites = try favoriteNames(in: folder)
        if isFavorite { favorites.insert(file.lastPathComponent) }
        else { favorites.remove(file.lastPathComponent) }
        try writeFavorites(favorites, in: folder)
        if destination == nil { try? refreshWidgets() }
    }

    private static func favoriteNames(in folder: URL) throws -> Set<String> {
        let url = folder.appendingPathComponent("favorites.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return Set(try JSONDecoder().decode([String].self, from: Data(contentsOf: url)))
    }

    private static func writeFavorites(_ names: Set<String>, in folder: URL) throws {
        try JSONEncoder().encode(names.sorted()).write(to: folder.appendingPathComponent("favorites.json"), options: .atomic)
    }

    static func refreshWidgets() throws {
        let drawings = try all()
        try GalleryWidgetStore.publish(drawings.map { ($0.url, $0.isFavorite) })
    }

    private static func drawingSortKey(_ url: URL) -> String {
        // Both naming formats have the same date suffix after the first underscore.
        // Keep old and new drawings together in chronological order.
        let name = url.lastPathComponent
        guard let separator = name.firstIndex(of: "_") else { return name }
        return String(name[name.index(after: separator)...])
    }

    static func loadDocument(for drawing: CanvasExport) throws -> CanvasDocument {
        let url = drawing.url.deletingPathExtension().appendingPathExtension("json")
        let data = try Data(contentsOf: url)
        let document = try JSONDecoder().decode(CanvasDocument.self, from: data)
        // Migrate legacy files once so even drawings without layer IDs retain their identity.
        if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["id"] == nil {
            try JSONEncoder().encode(document).write(to: url, options: .atomic)
        }
        return document
    }

    static func delete(_ drawing: CanvasExport, in destination: URL? = nil) throws {
        let folder = try (destination ?? directory()).resolvingSymlinksInPath().standardizedFileURL
        let file = drawing.url.resolvingSymlinksInPath().standardizedFileURL
        guard file.deletingLastPathComponent() == folder, file.pathExtension.lowercased() == "png"
        else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.removeItem(at: file)
        var favorites = try favoriteNames(in: folder)
        favorites.remove(file.lastPathComponent)
        try writeFavorites(favorites, in: folder)
        if destination == nil { try? refreshWidgets() }
        let source = file.deletingPathExtension().appendingPathExtension("json")
        if FileManager.default.fileExists(atPath: source.path) {
            try FileManager.default.removeItem(at: source)
        }
    }

    static func save(document: CanvasDocument, imageData: Data, name: String,
                     in folder: URL? = nil) throws -> CanvasExport {
        let url = try (folder ?? directory()).appendingPathComponent(name).appendingPathExtension("png")
        let documentData = try JSONEncoder().encode(document)
        try documentData.write(to: url.deletingPathExtension().appendingPathExtension("json"), options: .atomic)
        do { try imageData.write(to: url, options: .atomic) }
        catch {
            try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("json"))
            throw error
        }
        if folder == nil { try? refreshWidgets() }
        return CanvasExport(url: url)
    }
}
