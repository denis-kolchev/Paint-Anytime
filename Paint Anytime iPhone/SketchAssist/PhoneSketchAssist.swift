import Combine
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WatchConnectivity
#if canImport(ImagePlayground)
import ImagePlayground
#endif
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Experimental: recognizes a sketch sent from the watch and offers Image Playground
/// to complete it. Headless `ImageCreator` reports `notSupported` on iOS 27.2, so the
/// user picks the result in the system sheet while this app is on screen.
@MainActor
final class PhoneSketchAssist: ObservableObject {
    static let shared = PhoneSketchAssist()

    struct Request {
        let id: String
        let sketch: UIImage
        /// Pixel size of the sent crop; the result is returned with the same aspect.
        let sketchSize: CGSize
        /// Pixel bounds of the drawn strokes inside the crop, top-left origin.
        let sketchContent: CGRect?
        let label: String?
        let maximumPixels: Int
    }

    private typealias Failure = SketchAssistProtocol.Failure

    /// Presented as soon as the app is on screen; requests that arrive in the
    /// background wait here until the user opens the app.
    @Published private(set) var pending: Request?
    private var preparing: Task<Void, Never>?
    private var publishedAvailability: Bool?
    private var reportedChoosingID: String?

    private init() {}

    func handle(imageData: Data, requestID: String, maximumPixels: Int) {
        // The watch only waits for its latest request.
        preparing?.cancel()
        preparing = Task {
            guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
                  let sketch = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { return fail(.unsupportedDrawing, detail: "Unreadable sketch image", requestID: requestID) }
            guard Self.isPlaygroundAvailable else {
                return fail(.unavailable, detail: Self.diagnostics("Image Playground is unavailable"),
                            requestID: requestID)
            }
            let label = await recognize(sketch)
            guard !Task.isCancelled else { return }
            pending = Request(id: requestID, sketch: UIImage(cgImage: sketch),
                              sketchSize: CGSize(width: sketch.width, height: sketch.height),
                              sketchContent: Self.contentBounds(of: sketch), label: label,
                              maximumPixels: min(1024, max(128, maximumPixels)))
            reportChoosingIfOnScreen()
        }
    }

    /// Tells the watch that Image Playground is up; call when the app becomes active.
    func reportChoosingIfOnScreen() {
        guard let request = pending, reportedChoosingID != request.id,
              UIApplication.shared.applicationState == .active else { return }
        reportedChoosingID = request.id
        report(.choosing, requestID: request.id)
    }

    /// Live message when the watch app is open, queued user info otherwise.
    private func report(_ stage: SketchAssistProtocol.Stage, requestID: String) {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        let info = [SketchAssistProtocol.stageKey: stage.rawValue, SketchAssistProtocol.requestIDKey: requestID]
        guard session.isReachable else {
            session.transferUserInfo(info)
            return
        }
        // The error handler runs on a WatchConnectivity queue.
        session.sendMessage(info, replyHandler: nil) { @Sendable _ in WCSession.default.transferUserInfo(info) }
    }

    /// Called with the temporary file Image Playground created; read it before returning.
    func complete(with url: URL) {
        guard let request = pending else { return }
        pending = nil
        do {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { throw CocoaError(.fileReadCorruptFile) }
            // Image Playground reframes the drawing and picks its own aspect; put the
            // generated subject back where the strokes were, in a frame of the crop's size.
            let placed = request.sketchContent.flatMap {
                Self.aligned(image, contentTo: $0, canvas: request.sketchSize)
            } ?? image
            try send(placed, label: request.label, maximumPixels: request.maximumPixels, requestID: request.id)
        } catch {
            fail(.failed, detail: Self.diagnostics(String(reflecting: error)), requestID: request.id)
        }
    }

    func cancel() {
        guard let request = pending else { return }
        pending = nil
        fail(.cancelled, detail: nil, requestID: request.id)
    }

    /// Lets the watch show Sketch assist only when the phone can complete sketches.
    /// Apple Intelligence can be turned off in Settings, so recheck on activation.
    func publishAvailability(force: Bool = false) {
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        let available = Self.isPlaygroundAvailable
        guard force || available != publishedAvailability else { return }
        // Only the latest value matters; drop queued ones.
        for transfer in session.outstandingUserInfoTransfers
        where transfer.userInfo[SketchAssistProtocol.availabilityKey] != nil {
            transfer.cancel()
        }
        session.transferUserInfo([SketchAssistProtocol.availabilityKey: available])
        publishedAvailability = available
    }

    private static var isPlaygroundAvailable: Bool {
        #if canImport(ImagePlayground)
        if #available(iOS 18.4, *) { return ImagePlaygroundViewController.isAvailable }
        #endif
        return false
    }

    /// Optional: a short English label guides Image Playground, but its absence
    /// must not block completion on devices without the vision model.
    private func recognize(_ sketch: CGImage) async -> String? {
        #if canImport(FoundationModels)
        guard #available(iOS 27.0, *) else { return nil }
        let model = SystemLanguageModel.default
        guard model.isAvailable, model.capabilities.contains(.vision) else {
            NSLog("Sketch recognition skipped: %@",
                  "model available \(model.isAvailable), vision \(model.capabilities.contains(.vision))")
            return nil
        }
        let session = LanguageModelSession(
            model: model,
            instructions: "You name what a quick hand-drawn sketch shows. Answer with one to three English words and no punctuation."
        )
        do {
            let response = try await session.respond {
                "What does this sketch show?"
                Attachment(sketch)
            }
            let label = response.content.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            return label.isEmpty ? nil : String(label.prefix(40))
        } catch {
            NSLog("Sketch recognition failed: %@", String(reflecting: error))
            return nil
        }
        #else
        return nil
        #endif
    }

    private func send(_ image: CGImage, label: String?, maximumPixels: Int, requestID: String) throws {
        let session = WCSession.default
        guard session.activationState == .activated else { throw CocoaError(.featureUnsupported) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SketchAssist-\(UUID().uuidString)")
            .appendingPathExtension("png")
        try Self.encodedForWatch(image, maximumPixels: maximumPixels).write(to: url, options: .atomic)
        var metadata: [String: Any] = [SketchAssistProtocol.kindKey: SketchAssistProtocol.resultKind,
                                       SketchAssistProtocol.requestIDKey: requestID]
        if let label { metadata[SketchAssistProtocol.labelKey] = label }
        report(.returning, requestID: requestID)
        // WatchDrawingReceiver removes the temporary file when the transfer finishes.
        session.transferFile(url, metadata: metadata)
    }

    private func fail(_ failure: Failure, detail: String?, requestID: String) {
        if let detail { NSLog("Sketch assist failed: %@", detail) }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        var userInfo = [SketchAssistProtocol.failureKey: failure.rawValue,
                        SketchAssistProtocol.requestIDKey: requestID]
        if let detail { userInfo[SketchAssistProtocol.detailKey] = detail }
        session.transferUserInfo(userInfo)
    }

    /// Prototype diagnostics shown on the watch: one failure code covers several causes.
    private static func diagnostics(_ reason: String) -> String {
        ["iOS " + UIDevice.current.systemVersion, reason,
         "locale " + Locale.current.identifier + ", language " + (Locale.preferredLanguages.first ?? "?")]
            .joined(separator: " · ")
    }

    /// Redraws `result` into a `canvas`-sized image so the bounds of its subject fit
    /// `target` (top-left pixel coordinates), keeping the subject's aspect. The margin
    /// takes the result's own background. Nil when the subject cannot be told apart.
    nonisolated static func aligned(_ result: CGImage, contentTo target: CGRect, canvas: CGSize) -> CGImage? {
        guard let source = contentBounds(of: result), !target.isEmpty,
              canvas.width >= 1, canvas.height >= 1,
              let raster = RGBARaster(result) else { return nil }
        let scale = min(target.width / source.width, target.height / source.height)
        let drawn = CGSize(width: CGFloat(result.width) * scale, height: CGFloat(result.height) * scale)
        let left = target.midX - source.midX * scale
        let top = target.midY - source.midY * scale
        let width = Int(canvas.width.rounded()), height = Int(canvas.height.rounded())
        guard let context = RGBARaster.context(width: width, height: height) else { return nil }
        let background = raster.background
        context.setFillColor(red: CGFloat(background.0) / 255, green: CGFloat(background.1) / 255,
                             blue: CGFloat(background.2) / 255, alpha: CGFloat(background.3) / 255)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        // Core Graphics draws from the bottom-left corner.
        context.draw(result, in: CGRect(x: left, y: CGFloat(height) - top - drawn.height,
                                        width: drawn.width, height: drawn.height))
        return context.makeImage()
    }

    /// Pixel bounds (top-left origin) of what differs from the background, sampled at
    /// the corners. Nil when nothing differs or the picture runs to every edge.
    nonisolated static func contentBounds(of image: CGImage) -> CGRect? {
        guard let raster = RGBARaster(image) else { return nil }
        let width = raster.width, height = raster.height
        let background = raster.background
        // Generated images carry soft gradients and compression noise near the background.
        let tolerance = 40
        var rows = [Int](repeating: 0, count: height)
        var columns = [Int](repeating: 0, count: width)
        raster.pixels.withUnsafeBufferPointer { pixels in
            for y in 0..<height {
                var offset = y * width * 4
                for x in 0..<width {
                    let differs = abs(Int(pixels[offset]) - Int(background.0)) > tolerance
                        || abs(Int(pixels[offset + 1]) - Int(background.1)) > tolerance
                        || abs(Int(pixels[offset + 2]) - Int(background.2)) > tolerance
                        || abs(Int(pixels[offset + 3]) - Int(background.3)) > tolerance
                    if differs {
                        rows[y] += 1
                        columns[x] += 1
                    }
                    offset += 4
                }
            }
        }
        // Ignore isolated specks so noise does not stretch the bounds.
        let minimum = 2
        guard let top = rows.firstIndex(where: { $0 >= minimum }),
              let bottom = rows.lastIndex(where: { $0 >= minimum }),
              let left = columns.firstIndex(where: { $0 >= minimum }),
              let right = columns.lastIndex(where: { $0 >= minimum }) else { return nil }
        let bounds = CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
        let fillsImage = bounds.width >= CGFloat(width) * 0.98 && bounds.height >= CGFloat(height) * 0.98
        return fillsImage ? nil : bounds
    }

    /// Generated images are 1024 px and larger; the watch canvas usually needs less.
    private static func encodedForWatch(_ image: CGImage, maximumPixels: Int) throws -> Data {
        let scale = min(1, CGFloat(maximumPixels) / CGFloat(max(image.width, image.height)))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CocoaError(.coderInvalidValue) }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        guard let scaled = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.coderInvalidValue) }
        CGImageDestinationAddImage(destination, scaled, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.coderInvalidValue) }
        return data as Data
    }
}

/// Premultiplied sRGB RGBA pixels, top row first.
nonisolated private struct RGBARaster {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init?(_ image: CGImage) {
        width = image.width
        height = image.height
        guard width > 2, height > 2, let context = Self.context(width: width, height: height) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        pixels = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self),
                                           count: width * height * 4))
    }

    static func context(width: Int, height: Int) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                         space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// The corner closest to the other three, so one corner the subject reaches does not count.
    var background: (UInt8, UInt8, UInt8, UInt8) {
        let corners = [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)].map { x, y in
            let offset = (y * width + x) * 4
            return (pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3])
        }
        func distance(_ a: (UInt8, UInt8, UInt8, UInt8), _ b: (UInt8, UInt8, UInt8, UInt8)) -> Int {
            abs(Int(a.0) - Int(b.0)) + abs(Int(a.1) - Int(b.1)) + abs(Int(a.2) - Int(b.2)) + abs(Int(a.3) - Int(b.3))
        }
        return corners.min { a, b in
            corners.reduce(0) { $0 + distance(a, $1) } < corners.reduce(0) { $0 + distance(b, $1) }
        } ?? corners[0]
    }
}

/// Presents Image Playground for pending watch requests on supported systems.
struct SketchAssistSheet: ViewModifier {
    @ObservedObject var assist: PhoneSketchAssist

    func body(content: Content) -> some View {
        #if canImport(ImagePlayground)
        if #available(iOS 18.4, *) {
            content.modifier(SketchAssistPlaygroundSheet(assist: assist))
        } else {
            content
        }
        #else
        content
        #endif
    }
}

#if canImport(ImagePlayground)
@available(iOS 18.4, *)
private struct SketchAssistPlaygroundSheet: ViewModifier {
    @ObservedObject var assist: PhoneSketchAssist

    func body(content: Content) -> some View {
        let request = assist.pending
        let sheet = content
            .imagePlaygroundSheet(
                isPresented: Binding(
                    get: { assist.pending != nil },
                    // Completion clears the request first, so only a dismissal remains here.
                    set: { if !$0 { assist.cancel() } }
                ),
                concepts: request?.label.map { [.text($0)] } ?? [],
                sourceImage: request.map { Image(uiImage: $0.sketch) },
                onCompletion: { assist.complete(with: $0) },
                onCancellation: { assist.cancel() }
            )
            // `.all` includes iOS 27's automatic `.any` style, which the sheet can pick
            // instead of the preferred one; list the styles explicitly, Illustration first.
            .imagePlaygroundGenerationStyle(.illustration, in: [.illustration, .sketch, .animation])
        if #available(iOS 27.0, *) {
            sheet.imagePlaygroundOptions(Self.editingOptions(for: request))
        } else {
            sheet
        }
    }

    /// Complete the watch sketch instead of treating it as loose inspiration, in a
    /// frame close to the selection's shape so less of it is cropped away.
    @available(iOS 27.0, *)
    private static func editingOptions(for request: PhoneSketchAssist.Request?) -> ImagePlaygroundOptions {
        var options = ImagePlaygroundOptions()
        options.creationStrategy = .editExisting
        if let request { options.sizeSpecification = .closest(to: request.sketchSize) }
        return options
    }
}
#endif
