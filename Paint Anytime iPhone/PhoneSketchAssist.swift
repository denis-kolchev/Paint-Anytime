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
        let label: String?
        let maximumPixels: Int
    }

    private typealias Failure = SketchAssistProtocol.Failure

    /// Presented as soon as the app is on screen; requests that arrive in the
    /// background wait here until the user opens the app.
    @Published private(set) var pending: Request?
    private var preparing: Task<Void, Never>?
    private var publishedAvailability: Bool?

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
            pending = Request(id: requestID, sketch: UIImage(cgImage: sketch), label: label,
                              maximumPixels: min(1024, max(128, maximumPixels)))
        }
    }

    /// Called with the temporary file Image Playground created; read it before returning.
    func complete(with url: URL) {
        guard let request = pending else { return }
        pending = nil
        do {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { throw CocoaError(.fileReadCorruptFile) }
            try send(image, label: request.label, maximumPixels: request.maximumPixels, requestID: request.id)
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
            .imagePlaygroundGenerationStyle(.sketch)
        if #available(iOS 27.0, *) {
            sheet.imagePlaygroundOptions(Self.editingOptions)
        } else {
            sheet
        }
    }

    /// Complete the watch sketch instead of treating it as loose inspiration.
    @available(iOS 27.0, *)
    private static var editingOptions: ImagePlaygroundOptions {
        var options = ImagePlaygroundOptions()
        options.creationStrategy = .editExisting
        return options
    }
}
#endif
