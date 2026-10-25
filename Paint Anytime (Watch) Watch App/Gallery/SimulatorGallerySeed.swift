import Foundation

#if targetEnvironment(simulator)
/// Install the sample once per simulator app container, preserving edits and deletions.
@MainActor
enum SimulatorGallerySeed {
    static func installIfNeeded() {
        do {
            let folder = try CanvasExportStore.directory()
            let marker = folder.appendingPathComponent(".simulator-gallery-sample-v1")
            guard !FileManager.default.fileExists(atPath: marker.path) else { return }
            guard let source = Bundle.main.url(forResource: "SimulatorGallerySample", withExtension: "paintanytime") else {
                throw CocoaError(.fileNoSuchFile)
            }
            let project = try PaintProject.read(source)
            let document = try JSONDecoder().decode(CanvasDocument.self, from: project.document)
            let name = "Paint-Anytime_2026-10-24_16-56-12_764_592E35C4"
            let image = folder.appendingPathComponent(name).appendingPathExtension("png")
            let drawing = folder.appendingPathComponent(name).appendingPathExtension("json")
            // Previously imported drawings belong to the user; never overwrite them.
            if !FileManager.default.fileExists(atPath: image.path),
               !FileManager.default.fileExists(atPath: drawing.path) {
                _ = try CanvasExportStore.save(document: document, imageData: project.preview,
                                               name: name, in: folder)
            }
            try Data().write(to: marker, options: .atomic)
        } catch {
            NSLog("Simulator gallery sample import failed: %@", error.localizedDescription)
        }
    }
}
#endif
