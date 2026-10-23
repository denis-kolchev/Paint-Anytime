import Foundation

/// Owns disposable copies only; bundle originals and the user's gallery stay outside this root.
struct TutorialWorkspace {
    let root: URL
    private let source: URL?

    init(root: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("PaintAnytimeTutorial", isDirectory: true),
         source: URL? = Bundle.main.url(forResource: "Preset Photos", withExtension: nil)) {
        self.root = root
        self.source = source
    }

    func prepare() throws -> URL {
        guard let source else { throw CocoaError(.fileNoSuchFile) }
        let files = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "png" }
        guard !files.isEmpty else { throw CocoaError(.fileNoSuchFile) }
        // Clear disposable sessions left by a previous or interrupted launch.
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            for file in files {
                try FileManager.default.copyItem(at: file, to: folder.appendingPathComponent(file.lastPathComponent))
            }
            return folder
        } catch {
            try? remove(folder)
            throw error
        }
    }

    func remove(_ folder: URL) throws {
        let resolved = folder.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.deletingLastPathComponent() == root.resolvingSymlinksInPath().standardizedFileURL else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.removeItem(at: resolved)
    }
}
