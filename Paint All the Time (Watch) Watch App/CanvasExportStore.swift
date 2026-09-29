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
        try FileManager.default.contentsOfDirectory(at: folder ?? directory(), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { drawingSortKey($0) > drawingSortKey($1) }
            .map { CanvasExport(url: $0) }
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
        return try JSONDecoder().decode(CanvasDocument.self, from: Data(contentsOf: url))
    }

    static func delete(_ drawing: CanvasExport, in destination: URL? = nil) throws {
        let folder = try (destination ?? directory()).resolvingSymlinksInPath().standardizedFileURL
        let file = drawing.url.resolvingSymlinksInPath().standardizedFileURL
        guard file.deletingLastPathComponent() == folder, file.pathExtension.lowercased() == "png"
        else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.removeItem(at: file)
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
        return CanvasExport(url: url)
    }
}
