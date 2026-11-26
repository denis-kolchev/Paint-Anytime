import Foundation

/// Debug fixtures live outside the synchronized user gallery.
/// Per-file markers preserve test deletions and allow new fixtures to be added.
enum DebugGallerySamples {
    static func directory() throws -> URL {
        let folder = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("DebugGallerySamples-v1", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func contains(_ url: URL) -> Bool {
        #if DEBUG
        guard let folder = try? directory() else { return false }
        return url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL
        #else
        return false
        #endif
    }

    /// `GalleryDebug` lists every fixture. Without it, `includingTutorial` lists only the
    /// `TutorialSample_` images and the `ExampleSample_` projects
    /// (Watch: Render debug → Tutorial images in gallery).
    static func images(includingTutorial: Bool = false) throws -> [URL] {
        let includesProjects = GalleryDebug.isEnabled
        guard includesProjects || includingTutorial else { return [] }
        #if DEBUG
        func isListed(_ url: URL) -> Bool { includesProjects || isTutorialName(url) || isExampleName(url) }
        guard let resources = Bundle.main.resourceURL?.appendingPathComponent("DebugGallerySamples"),
              FileManager.default.fileExists(atPath: resources.path) else { return [] }
        let folder = try directory()
        let sources = try FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)
            .filter { [PaintProject.fileExtension, "png"].contains($0.pathExtension.lowercased()) && isListed($0) }
            .sorted(by: orderedBefore)
        for source in sources {
            let name = source.deletingPathExtension().lastPathComponent
            let marker = folder.appendingPathComponent("." + name + ".installed")
            guard !FileManager.default.fileExists(atPath: marker.path) else { continue }
            if source.pathExtension.lowercased() == "png" {
                try Data(contentsOf: source).write(to: folder.appendingPathComponent(name + ".png"), options: .atomic)
                try Data().write(to: marker, options: .atomic)
                continue
            }
            try autoreleasepool {
                let project = try PaintProject.read(source)
                // Keep both editable Watch data and the portable iPhone project.
                try project.document.write(to: folder.appendingPathComponent(name + ".json"), options: .atomic)
                try Data(contentsOf: source).write(to: folder.appendingPathComponent(name + ".paintanytime"), options: .atomic)
                try project.preview.write(to: folder.appendingPathComponent(name + ".png"), options: .atomic)
                try Data().write(to: marker, options: .atomic)
            }
        }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" && isListed($0) }
            .sorted(by: orderedBefore)
        #else
        return []
        #endif
    }

    /// Tutorial fixtures come first, then the example projects, then everything else,
    /// regardless of their dates. Examples keep their numbered `ExampleSample_<n>_` order;
    /// the other groups keep the ordinary descending filename order.
    nonisolated static func orderedBefore(_ lhs: URL, _ rhs: URL) -> Bool {
        func group(_ url: URL) -> Int {
            guard url.deletingLastPathComponent().lastPathComponent.hasPrefix("DebugGallerySamples") else { return 2 }
            if isTutorialName(url) { return 0 }
            if isExampleName(url) { return 1 }
            return 2
        }
        let leftGroup = group(lhs)
        let rightGroup = group(rhs)
        if leftGroup != rightGroup { return leftGroup < rightGroup }
        if leftGroup == 1 {
            return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
        }
        return lhs.lastPathComponent > rhs.lastPathComponent
    }

    nonisolated static func isTutorialName(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix("TutorialSample_")
    }

    nonisolated static func isExampleName(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix("ExampleSample_")
    }

    static func remove(_ image: URL) throws {
        guard contains(image) else { throw CocoaError(.fileWriteNoPermission) }
        for ext in ["png", "json", PaintProject.fileExtension] {
            let file = image.deletingPathExtension().appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }
}
