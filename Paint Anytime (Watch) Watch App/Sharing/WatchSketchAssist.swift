import Combine
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import WatchConnectivity

/// Experimental round trip to the iPhone app, which recognizes and completes the
/// sketch with Apple Intelligence (see `SketchAssistProtocol`). The watch has no
/// on-device image generation or system language model.
@MainActor
final class WatchSketchAssist: ObservableObject {
    static let shared = WatchSketchAssist()

    enum Phase: Equatable {
        case idle
        case waiting
        /// `replacedCanvas` is false when the user switched drawings meanwhile.
        case completed(UIImage, label: String?, replacedCanvas: Bool)
        case failed(String, detail: String? = nil)
    }

    @Published private(set) var phase = Phase.idle
    private var requestID: String?
    private var timeout: Task<Void, Never>?
    /// The canvas the request came from; the result replaces its content.
    private weak var controller: CanvasController?
    private var documentID: UUID?
    private var canvasSize = CGSize.zero

    private init() {}

    func send(from controller: CanvasController, viewportSize: CGSize, scale: CGFloat) {
        let document = controller.document
        let size = document.size(fallback: viewportSize)
        let session = WCSession.default
        guard session.activationState == .activated, session.isCompanionAppInstalled else {
            return fail(L10n.text("Install Paint Anytime on your iPhone."))
        }
        guard session.isReachable else { return fail(L10n.text("Your iPhone is not reachable.")) }
        let id = UUID().uuidString
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SketchAssist-\(id)").appendingPathExtension("png")
        do {
            guard let image = WatchBitmapRenderer.render(document: document, size: size, scale: scale),
                  let data = Self.png(image) else { return fail(Self.message(for: .unsupportedDrawing)) }
            try data.write(to: url, options: .atomic)
        } catch { return fail(Self.message(for: .failed)) }
        requestID = id
        self.controller = controller
        documentID = document.id
        canvasSize = size
        phase = .waiting
        // WatchPhotoTransfer removes the temporary file when the transfer finishes.
        // Match the result to the canvas pixels, capped to keep saved documents small.
        let pixels = min(1024, Int((max(size.width, size.height) * scale).rounded(.up)))
        session.transferFile(url, metadata: [SketchAssistProtocol.kindKey: SketchAssistProtocol.requestKind,
                                             SketchAssistProtocol.requestIDKey: id,
                                             SketchAssistProtocol.maximumPixelsKey: pixels])
        timeout?.cancel()
        timeout = Task { [weak self] in
            // The user opens the app and picks an image on the phone, which takes a while.
            try? await Task.sleep(for: .seconds(600))
            guard !Task.isCancelled, let self, self.requestID == id else { return }
            self.fail(L10n.text("Your iPhone did not respond. Open Paint Anytime on iPhone and try again."))
        }
    }

    func receive(imageData: Data?, label: String?, requestID: String) {
        guard requestID == self.requestID else { return }
        guard let imageData, let image = UIImage(data: imageData), image.size.width > 0, image.size.height > 0
        else { return fail(Self.message(for: .failed)) }
        var replaced = false
        if let controller, controller.document.id == documentID {
            // One undoable edit, stored like a lasso area selection.
            controller.replaceContent(with: Self.rasterStroke(png: imageData, imageSize: image.size,
                                                              canvasSize: canvasSize))
            replaced = true
        }
        finish()
        phase = .completed(image, label: label, replacedCanvas: replaced)
    }

    func receive(failure: String, detail: String?, requestID: String) {
        guard requestID == self.requestID else { return }
        fail(Self.message(for: SketchAssistProtocol.Failure(rawValue: failure) ?? .failed), detail: detail)
    }

    private func fail(_ message: String, detail: String? = nil) {
        finish()
        phase = .failed(message, detail: detail)
    }

    private func finish() {
        requestID = nil
        controller = nil
        documentID = nil
        timeout?.cancel()
        timeout = nil
    }

    private static func message(for failure: SketchAssistProtocol.Failure) -> String {
        switch failure {
        case .unavailable: L10n.text("Apple Intelligence is not available on your iPhone.")
        case .cancelled: L10n.text("Cancelled on iPhone.")
        case .unsupportedDrawing: L10n.text("This drawing could not be used. Try another sketch.")
        case .failed: L10n.text("Could not complete the sketch. Please try again.")
        }
    }

    /// Fits the whole image into the canvas, centered; the paper shows in any margin.
    private static func rasterStroke(png: Data, imageSize: CGSize, canvasSize: CGSize) -> Stroke {
        let scale = min(canvasSize.width / imageSize.width, canvasSize.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let bounds = CGRect(x: (canvasSize.width - size.width) / 2, y: (canvasSize.height - size.height) / 2,
                            width: size.width, height: size.height)
        var style = PencilStyle()
        style.blendingMode = .normal
        var stroke = Stroke(points: [], style: style)
        stroke.raster = StrokeRaster(png: png, bounds: bounds)
        return stroke
    }

    private static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

struct SketchAssistView: View {
    @ObservedObject var controller: CanvasController
    let viewportSize: CGSize
    @ObservedObject private var assist = WatchSketchAssist.shared
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                switch assist.phase {
                case .idle:
                    Text(L10n.text("Image Playground on your iPhone completes this sketch. After sending, open Paint Anytime on iPhone and choose an image."))
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                case .waiting:
                    ProgressView()
                    Text(L10n.text("Open Paint Anytime on iPhone and choose an image…"))
                        .font(.footnote)
                case .completed(let image, let label, let replacedCanvas):
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel(label ?? L10n.text("Completed sketch"))
                    if let label {
                        Text(verbatim: label)
                            .font(.headline)
                    }
                    Text(L10n.text(replacedCanvas
                                   ? "The canvas was replaced. Use Undo to bring back your sketch."
                                   : "You opened another drawing, so the canvas was not changed."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .failed(let message, let detail):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(verbatim: detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Button(L10n.text(assist.phase == .idle ? "Send to iPhone" : "Try again"),
                       systemImage: "iphone.and.arrow.forward") {
                    controller.cancelStroke()
                    assist.send(from: controller, viewportSize: viewportSize, scale: displayScale)
                }
                .disabled(assist.phase == .waiting || controller.document.strokes.isEmpty)
            }
            .padding(.horizontal)
        }
        .navigationTitle(L10n.text("Sketch assist"))
    }
}
