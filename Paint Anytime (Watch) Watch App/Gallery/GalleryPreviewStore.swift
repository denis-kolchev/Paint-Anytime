import CoreGraphics
import Foundation
import ImageIO
import Observation

/// A tiny, always-resident snapshot of a drawing. The gallery shows it
/// immediately while the sharp thumbnail decodes, so tiles never appear empty.
nonisolated struct GalleryPreview: @unchecked Sendable {
    let image: CGImage
    let originalSize: CGSize
    /// Modification date of the source image this preview was made from.
    let sourceModified: Double

    func bitmap(for url: URL) -> GalleryBitmap {
        GalleryBitmap(request: GalleryImageRequest(url: url, shortSidePixels: GalleryPreviewDisk.shortSide,
                                                   displayScale: 1),
                      image: image, originalSize: originalSize)
    }
}

nonisolated private struct GalleryPreviewSource: @unchecked Sendable {
    let image: CGImage
}

/// Observed by a single thumbnail, never by the grid.
@MainActor
@Observable
final class GalleryPreviewSlot {
    var preview: GalleryPreview?
    @ObservationIgnored private var cachedBitmap: GalleryBitmap?

    /// A stable bitmap identity, so views comparing bitmaps do not see a new one per render.
    func bitmap(for url: URL) -> GalleryBitmap? {
        guard let preview else { return nil }
        if let cachedBitmap, cachedBitmap.url == url, cachedBitmap.image === preview.image { return cachedBitmap }
        let bitmap = preview.bitmap(for: url)
        cachedBitmap = bitmap
        return bitmap
    }
}

/// Previews persist in Caches and load once per launch. A stale preview of an
/// edited drawing is still shown until its replacement is ready.
@MainActor
final class GalleryPreviewStore {
    static let shared = GalleryPreviewStore()

    private var slots: [String: GalleryPreviewSlot] = [:]
    /// Previews checked against their source during this launch.
    private var verified: Set<String> = []
    private var pending: Set<String> = []
    private var preloadTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    private init() {
        preloadTask = Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) {
                GalleryPreviewDisk.readAll()
            }.value
            guard let self else { return }
            for (key, preview) in loaded where self.slot(key).preview == nil {
                self.slot(key).preview = preview
            }
        }
    }

    /// Reads cached previews at launch, then fills in the ones the main gallery
    /// is missing, so they are ready before the gallery is first opened.
    func warmUp(urls: [URL], displayScale: CGFloat) {
        prepare(urls: urls, displayScale: displayScale, delay: .zero)
    }

    /// A freshly saved drawing gets its preview from the rendered image, without
    /// waiting for a gallery visit or decoding the PNG again.
    func store(image: CGImage, originalSize: CGSize, for url: URL) {
        let key = GalleryPreviewDisk.key(for: url)
        verified.remove(key)
        pending.insert(key)
        let source = GalleryPreviewSource(image: image)
        Task { [weak self] in
            let preview = await Task.detached(priority: .userInitiated) { () -> GalleryPreview? in
                guard let modified = GalleryPreviewDisk.modificationDate(of: url) else { return nil }
                return GalleryPreviewDisk.make(from: source.image, originalSize: originalSize,
                                               sourceModified: modified, key: key)
            }.value
            guard let self else { return }
            self.pending.remove(key)
            guard let preview else { return }
            self.verified.insert(key)
            self.slot(key).preview = preview
        }
    }

    func slot(for url: URL) -> GalleryPreviewSlot { slot(GalleryPreviewDisk.key(for: url)) }

    /// Builds a preview from an already decoded thumbnail when the cached one
    /// is missing or older than the file.
    func record(_ bitmap: GalleryBitmap) {
        let url = bitmap.url
        let key = GalleryPreviewDisk.key(for: url)
        guard !verified.contains(key), !pending.contains(key) else { return }
        pending.insert(key)
        let known = slot(key).preview?.sourceModified
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> GalleryPreview?? in
                guard let modified = GalleryPreviewDisk.modificationDate(of: url) else { return .some(nil) }
                if known == modified { return .none }
                return .some(GalleryPreviewDisk.make(from: bitmap.image, originalSize: bitmap.originalSize,
                                                     sourceModified: modified, key: key))
            }.value
            guard let self else { return }
            self.pending.remove(key)
            self.verified.insert(key)
            if case .some(let preview?) = result { self.slot(key).preview = preview }
        }
    }

    func remove(_ url: URL) {
        let key = GalleryPreviewDisk.key(for: url)
        slots[key]?.preview = nil
        verified.remove(key)
        Task.detached(priority: .utility) { GalleryPreviewDisk.delete(key: key) }
    }

    /// Fills in missing or stale previews for the gallery's drawings in the
    /// background and drops cached previews of drawings that no longer exist.
    func prepare(urls: [URL], displayScale: CGFloat, delay: Duration = .milliseconds(300)) {
        refreshTask?.cancel()
        let keys = urls.map(GalleryPreviewDisk.key(for:))
        let scopes = Set(keys.map(GalleryPreviewDisk.scope(of:)))
        let current = Set(keys)
        for key in slots.keys where scopes.contains(GalleryPreviewDisk.scope(of: key)) && !current.contains(key) {
            slots[key]?.preview = nil
            verified.remove(key)
        }
        refreshTask = Task { [weak self, preloadTask] in
            await preloadTask?.value
            // Let visible thumbnails start decoding first; they also produce previews.
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .background) {
                GalleryPreviewDisk.deleteAll(inScopes: scopes, except: current)
            }.value
            for (url, key) in zip(urls, keys) {
                guard !Task.isCancelled, let self else { return }
                guard !self.verified.contains(key), !self.pending.contains(key) else { continue }
                self.pending.insert(key)
                let known = self.slot(key).preview?.sourceModified
                // Background QoS can be starved for seconds on watch; previews must be ready on open.
                let result = await Task.detached(priority: .utility) { () -> GalleryPreview?? in
                    guard let modified = GalleryPreviewDisk.modificationDate(of: url) else { return .some(nil) }
                    if known == modified { return .none }
                    return .some(GalleryPreviewDisk.make(from: url, sourceModified: modified,
                                                         displayScale: displayScale, key: key))
                }.value
                self.pending.remove(key)
                if case .some(let preview) = result {
                    // A failed decode is retried on a later gallery visit.
                    guard let preview else { continue }
                    self.slot(key).preview = preview
                }
                self.verified.insert(key)
            }
        }
    }

    private func slot(_ key: String) -> GalleryPreviewSlot {
        if let existing = slots[key] { return existing }
        let value = GalleryPreviewSlot()
        slots[key] = value
        return value
    }
}

/// File format: magic, source date, canvas size, pixel size, key, RGBA8 pixels.
nonisolated enum GalleryPreviewDisk {
    static let shortSide = 32
    private static let magic: UInt32 = 0x4750_5631 // "GPV1"
    private static let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue

    private static var directory: URL? {
        guard let caches = try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true) else { return nil }
        let folder = caches.appendingPathComponent("GalleryPreviews-v1", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Container paths can change between launches, and every tutorial session
    /// copies its images into a new UUID folder. Key by stable folder name instead.
    static func key(for url: URL) -> String {
        var folder = url.deletingLastPathComponent()
        if UUID(uuidString: folder.lastPathComponent) != nil { folder = folder.deletingLastPathComponent() }
        return folder.lastPathComponent + "/" + url.lastPathComponent
    }

    static func scope(of key: String) -> Substring {
        key.split(separator: "/", maxSplits: 1).first ?? ""
    }

    static func modificationDate(of url: URL) -> Double? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)?
            .timeIntervalSinceReferenceDate
    }

    static func make(from url: URL, sourceModified: Double, displayScale: CGFloat, key: String) -> GalleryPreview? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        let maximum = Int(min(max(width, height),
                              ceil(Double(shortSide * 2) * max(width, height) / min(width, height))))
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximum
        ] as CFDictionary) else { return nil }
        let size = GalleryImageMetadata.originalSize(properties: properties, pixelWidth: width,
                                                     pixelHeight: height, scale: displayScale)
        return make(from: image, originalSize: size, sourceModified: sourceModified, key: key)
    }

    static func make(from image: CGImage, originalSize: CGSize, sourceModified: Double, key: String) -> GalleryPreview? {
        let width = Double(image.width), height = Double(image.height)
        guard width > 0, height > 0 else { return nil }
        let factor = min(1, Double(shortSide) / min(width, height))
        let pixelWidth = max(1, Int((width * factor).rounded()))
        let pixelHeight = max(1, Int((height * factor).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                                      bytesPerRow: pixelWidth * 4, space: space, bitmapInfo: bitmapInfo),
              let bytes = context.data else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        let pixels = Data(bytes: bytes, count: pixelWidth * pixelHeight * 4)
        guard let preview = preview(pixels: pixels, width: pixelWidth, height: pixelHeight,
                                    originalSize: originalSize, sourceModified: sourceModified) else { return nil }
        write(preview: preview, pixels: pixels, key: key)
        return preview
    }

    static func readAll() -> [String: GalleryPreview] {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [:] }
        var result: [String: GalleryPreview] = [:]
        for file in files {
            guard let data = try? Data(contentsOf: file), let (key, preview) = decode(data) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            result[key] = preview
        }
        return result
    }

    static func delete(key: String) {
        guard let file = file(for: key) else { return }
        try? FileManager.default.removeItem(at: file)
    }

    static func deleteAll(inScopes scopes: Set<Substring>, except keys: Set<String>) {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return }
        let keptFiles = Set(keys.compactMap { file(for: $0)?.lastPathComponent })
        let prefixes = scopes.map { String($0) + "-" }
        for file in files where !keptFiles.contains(file.lastPathComponent)
            && prefixes.contains(where: file.lastPathComponent.hasPrefix) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func file(for key: String) -> URL? {
        // FNV-1a keeps filenames short and stable; the scope prefix allows pruning by name.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return directory?.appendingPathComponent(scope(of: key) + "-" + String(hash, radix: 16) + ".preview")
    }

    private static func preview(pixels: Data, width: Int, height: Int,
                                originalSize: CGSize, sourceModified: Double) -> GalleryPreview? {
        guard pixels.count == width * height * 4,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider,
                                  decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return GalleryPreview(image: image, originalSize: originalSize, sourceModified: sourceModified)
    }

    private static func write(preview: GalleryPreview, pixels: Data, key: String) {
        guard let file = file(for: key) else { return }
        let keyData = Data(key.utf8)
        var data = Data()
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        append(magic.littleEndian)
        append(preview.sourceModified.bitPattern.littleEndian)
        append(Double(preview.originalSize.width).bitPattern.littleEndian)
        append(Double(preview.originalSize.height).bitPattern.littleEndian)
        append(UInt32(preview.image.width).littleEndian)
        append(UInt32(preview.image.height).littleEndian)
        append(UInt32(keyData.count).littleEndian)
        data.append(keyData)
        data.append(pixels)
        try? data.write(to: file, options: .atomic)
    }

    private static func decode(_ data: Data) -> (String, GalleryPreview)? {
        var offset = 0
        func read<T: FixedWidthInteger>(_: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.count else { return nil }
            var value: T = 0
            _ = withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0, from: data.startIndex + offset ..< data.startIndex + offset + size) }
            offset += size
            return T(littleEndian: value)
        }
        guard read(UInt32.self) == magic,
              let modified = read(UInt64.self).map(Double.init(bitPattern:)),
              let canvasWidth = read(UInt64.self).map(Double.init(bitPattern:)),
              let canvasHeight = read(UInt64.self).map(Double.init(bitPattern:)),
              let width = read(UInt32.self).map(Int.init), let height = read(UInt32.self).map(Int.init),
              let keyLength = read(UInt32.self).map(Int.init),
              width > 0, height > 0, width <= 256, height <= 256,
              offset + keyLength + width * height * 4 == data.count,
              let key = String(data: data.subdata(in: data.startIndex + offset ..< data.startIndex + offset + keyLength),
                               encoding: .utf8)
        else { return nil }
        offset += keyLength
        let pixels = data.subdata(in: data.startIndex + offset ..< data.endIndex)
        guard let preview = preview(pixels: pixels, width: width, height: height,
                                    originalSize: CGSize(width: canvasWidth, height: canvasHeight),
                                    sourceModified: modified) else { return nil }
        return (key, preview)
    }
}
