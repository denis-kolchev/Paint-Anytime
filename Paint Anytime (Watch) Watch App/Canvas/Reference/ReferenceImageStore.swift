import Combine
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The picture shown over the canvas to draw from. It belongs to the app, not to a
/// drawing: documents and the project format never see it. The chosen gallery image is
/// copied downscaled, so a later deletion in the gallery does not take the reference away
/// and the canvas never holds a full-size gallery PNG in memory.
@MainActor
final class ReferenceImageStore: ObservableObject {
    static let shared = ReferenceImageStore()
    static let enabledKey = "watch.reference.enabled"
    /// Larger than the biggest watch screen (502 px tall on Ultra), so the full-screen
    /// view stays sharp; at most ~2.3 MB decoded.
    nonisolated static let maximumPixelSide = 768

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }
    @Published private(set) var image: CGImage?
    @Published private(set) var isImporting = false
    @Published var errorMessage: String?
    /// Bumped by every change, so a slower load never overwrites a newer choice.
    private var generation = 0

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        loadSaved()
    }

    private func loadSaved() {
        guard let url = Self.fileURL else { return }
        let expected = generation
        Task {
            let loaded = await Task.detached(priority: .utility) { Self.decode(url) }.value
            guard generation == expected else { return }
            image = loaded
        }
    }

    /// Copies a gallery image as the reference and turns the reference on.
    func setImage(from source: URL) async -> Bool {
        generation += 1
        let expected = generation
        isImporting = true
        defer { if generation == expected { isImporting = false } }
        let imported = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let image = Self.thumbnail(source, maxPixelSide: Self.maximumPixelSide),
                  let destination = Self.fileURL, Self.write(image, to: destination) else { return nil }
            return image
        }.value
        guard generation == expected else { return false }
        guard let imported else {
            errorMessage = L10n.text("Could not open the image.")
            return false
        }
        image = imported
        isEnabled = true
        return true
    }

    func remove() {
        generation += 1
        isImporting = false
        image = nil
        if let url = Self.fileURL { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Files

    nonisolated static var fileURL: URL? {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                         appropriateFor: nil, create: true) else { return nil }
        return support.appendingPathComponent("Reference", isDirectory: true)
            .appendingPathComponent("reference.png")
    }

    nonisolated private static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// A decoded copy no larger than `maxPixelSide`, upright and never enlarged.
    nonisolated static func thumbnail(_ url: URL, maxPixelSide: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSide)
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    nonisolated private static func write(_ image: CGImage, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        } catch { return false }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}
