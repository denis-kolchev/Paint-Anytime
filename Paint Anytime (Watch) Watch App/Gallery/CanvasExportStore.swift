import Foundation
import os

enum CanvasExportStore {
    /// Remove gallery copies installed by the temporary App Store screenshot setup.
    /// The bundled tutorial pictures and user artwork remain in their own locations.
    private nonisolated static func removeLegacyTutorialPreviews(in folder: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("TutorialPreview_") && $0.pathExtension.lowercased() == "png" }
        for file in files {
            try FileManager.default.removeItem(at: file)
        }
        let favorites = try favoriteNames(in: folder)
        let remaining = favorites.filter { !$0.hasPrefix("TutorialPreview_") }
        if remaining != favorites { try writeFavorites(remaining, in: folder) }
        let marker = folder.appendingPathComponent(".tutorial-previews-v1")
        if FileManager.default.fileExists(atPath: marker.path) {
            try FileManager.default.removeItem(at: marker)
        }
    }

    nonisolated static func directory() throws -> URL {
        let folder = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
            .appendingPathComponent("Drawings", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    nonisolated static func all(in folder: URL? = nil) throws -> [CanvasExport] {
        let targetFolder = try (folder ?? directory())
        if folder == nil { try removeLegacyTutorialPreviews(in: targetFolder) }
        let deleted = try GalleryDeletionStore.names(in: targetFolder)
        for name in deleted { try GalleryDeletionStore.removeFiles(for: name, in: targetFolder) }
        let images = try FileManager.default.contentsOfDirectory(at: targetFolder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { drawingSortKey($0) > drawingSortKey($1) }
        return try exports(for: images, in: targetFolder)
    }

    /// Attach Watch metadata to an authoritative image list, including the
    /// shared debug fixtures used by the iPhone gallery.
    nonisolated static func exports(for images: [URL], in folder: URL) throws -> [CanvasExport] {
        let favorites = try favoriteNames(in: folder)
        return images.map { CanvasExport(url: $0, isFavorite: favorites.contains($0.lastPathComponent)) }
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
        if destination == nil { refreshWidgets() }
    }

    /// Favorite filenames of the gallery, which the iPhone widgets also show.
    nonisolated static func favoriteNames() throws -> Set<String> {
        try favoriteNames(in: directory())
    }

    private nonisolated static func favoriteNames(in folder: URL) throws -> Set<String> {
        let url = folder.appendingPathComponent("favorites.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return Set(try JSONDecoder().decode([String].self, from: Data(contentsOf: url)))
    }

    private nonisolated static func writeFavorites(_ names: Set<String>, in folder: URL) throws {
        try JSONEncoder().encode(names.sorted()).write(to: folder.appendingPathComponent("favorites.json"), options: .atomic)
    }

    /// The gallery's background file work: widget refreshes and iPhone transfers run here
    /// one at a time, so two refreshes never write the widget folder at once and their
    /// memory peaks never add up.
    nonisolated static let backgroundQueue = DispatchQueue(label: "PaintAnytime.galleryBackground", qos: .utility)
    /// A refresh waits to start on `backgroundQueue`; requests made meanwhile join it.
    private nonisolated static let widgetRefreshQueued = OSAllocatedUnfairLock(initialState: false)

    /// Rebuilds the widget previews in the background. It lists every drawing and
    /// re-encodes changed previews, which on the main thread held the canvas after
    /// each save. A request made while a refresh runs starts another one after it.
    nonisolated static func refreshWidgets() {
        let schedules = widgetRefreshQueued.withLock { queued -> Bool in
            guard !queued else { return false }
            queued = true
            return true
        }
        guard schedules else { return }
        backgroundQueue.async {
            widgetRefreshQueued.withLock { $0 = false }
            autoreleasepool {
                do {
                    try GalleryWidgetStore.publish(widgetDrawings().map { ($0.url, $0.isFavorite) })
                } catch {
                    NSLog("Widget refresh failed: %@", error.localizedDescription)
                }
            }
        }
    }

    /// The gallery's drawings without `all()`'s cleanup: the background queue only reads
    /// the drawings folder, so it never races the main thread's deletions there.
    private nonisolated static func widgetDrawings() throws -> [CanvasExport] {
        let folder = try directory()
        let deleted = try GalleryDeletionStore.names(in: folder)
        let images = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "png" && !deleted.contains($0.lastPathComponent) }
            .sorted { drawingSortKey($0) > drawingSortKey($1) }
        return try exports(for: images, in: folder)
    }

    private nonisolated static func drawingSortKey(_ url: URL) -> String {
        // Both naming formats have the same date suffix after the first underscore.
        // Keep old and new drawings together in chronological order.
        let name = url.lastPathComponent
        guard let separator = name.firstIndex(of: "_") else { return name }
        return String(name[name.index(after: separator)...])
    }

    static func loadDocument(for drawing: CanvasExport) throws -> CanvasDocument {
        try loadDocument(at: drawing.url)
    }

    nonisolated static func loadDocument(at imageURL: URL) throws -> CanvasDocument {
        let url = imageURL.deletingPathExtension().appendingPathExtension("json")
        let originalData = try Data(contentsOf: url)
        let preview = (try? Data(contentsOf: imageURL)) ?? Data()
        let data = PaintProject.restoringCanvasSize(in: originalData, preview: preview)
        let document = try JSONDecoder().decode(CanvasDocument.self, from: data)
        if data != originalData {
            try data.write(to: url, options: .atomic)
        }
        // Migrate legacy files once so even drawings without layer IDs retain their identity.
        // The pool frees the parsed tree at once; see PaintProject.decode.
        let lacksID = try autoreleasepool {
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            // Only a JSON object without an id migrates, as before.
            return object.map { $0["id"] == nil } ?? false
        }
        if lacksID {
            try JSONEncoder().encode(document).write(to: url, options: .atomic)
        }
        // Drawings saved before metadata existed: estimate the start from the file name,
        // in memory only. The next save stores it.
        guard document.metadata == nil else { return document }
        var estimated = document
        var metadata = ProjectMetadata()
        metadata.createdAt = ProjectMetadata.fileDate(ofStem: imageURL.deletingPathExtension().lastPathComponent)
        estimated.metadata = metadata
        return estimated
    }

    static func delete(_ drawing: CanvasExport, in destination: URL? = nil) throws {
        let folder = try (destination ?? directory()).resolvingSymlinksInPath().standardizedFileURL
        let file = drawing.url.resolvingSymlinksInPath().standardizedFileURL
        guard file.deletingLastPathComponent() == folder, file.pathExtension.lowercased() == "png"
        else { throw CocoaError(.fileWriteNoPermission) }
        if destination == nil {
            try GalleryDeletionStore.merge([file.lastPathComponent], in: folder)
        }
        try GalleryDeletionStore.removeFiles(for: file.lastPathComponent, in: folder)
        var favorites = try favoriteNames(in: folder)
        favorites.remove(file.lastPathComponent)
        try writeFavorites(favorites, in: folder)
        if destination == nil { refreshWidgets() }

    }

    static func save(document: CanvasDocument, imageData: Data, name: String,
                     in folder: URL? = nil) throws -> CanvasExport {
        let url = try (folder ?? directory()).appendingPathComponent(name).appendingPathExtension("png")
        try write(document: document, imageData: imageData, to: url)
        if folder == nil { refreshWidgets() }
        return CanvasExport(url: url)
    }

    /// Writes the document and its PNG; safe off the main thread. Callers on the
    /// default folder refresh widgets afterwards on the main actor.
    nonisolated static func write(document: CanvasDocument, imageData: Data, to url: URL) throws {
        let documentData = try JSONEncoder().encode(document)
        let documentURL = url.deletingPathExtension().appendingPathExtension("json")
        let previousDocument = FileManager.default.fileExists(atPath: documentURL.path)
            ? try Data(contentsOf: documentURL) : nil
        try documentData.write(to: documentURL, options: .atomic)
        do { try imageData.write(to: url, options: .atomic) }
        catch {
            if let previousDocument {
                try previousDocument.write(to: documentURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: documentURL)
            }
            throw error
        }
    }
}

extension Notification.Name {
    static let galleryDrawingSaved = Notification.Name("galleryDrawingSaved")
}
