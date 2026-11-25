import Combine
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import WatchConnectivity

/// Experimental round trip to the iPhone app, which recognizes the sketch and lets the
/// user complete it in Image Playground (see `SketchAssistProtocol`). The watch has no
/// on-device image generation or system language model.
@MainActor
final class WatchSketchAssist: ObservableObject {
    static let shared = WatchSketchAssist()
    /// Last availability reported by the iPhone app; false until it has run once.
    nonisolated static let phoneAvailabilityKey = "watch.sketchAssist.phoneAvailable"

    enum Phase: Equatable {
        case idle
        case waiting(SketchAssistProtocol.Stage)
        /// `applied` is false when the drawing changed while the user was on the phone.
        case completed(applied: Bool)
        case failed(String, detail: String? = nil)

        var isWaiting: Bool {
            if case .waiting = self { true } else { false }
        }
    }

    @Published private(set) var phase = Phase.idle
    private var requestID: String?
    private var timeout: Task<Void, Never>?
    /// Replaces the sent strokes with the PNG of the given pixel size; false if it no longer can.
    private var apply: ((Data, CGSize) -> Bool)?

    private init() {}

    func send(_ image: CGImage, apply: @escaping (Data, CGSize) -> Bool) {
        let session = WCSession.default
        guard session.activationState == .activated, session.isCompanionAppInstalled else {
            return fail(L10n.text("Install Paint Anytime on your iPhone."))
        }
        guard session.isReachable else {
            return fail(L10n.text("Your iPhone is not reachable. Keep it nearby with Bluetooth on."))
        }
        let id = UUID().uuidString
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SketchAssist-\(id)").appendingPathExtension("png")
        do {
            guard let data = Self.png(image) else { return fail(Self.message(for: .unsupportedDrawing)) }
            try data.write(to: url, options: .atomic)
        } catch { return fail(Self.message(for: .failed)) }
        requestID = id
        self.apply = apply
        phase = .waiting(.sending)
        // Match the result to the sent pixels, capped to keep saved documents small.
        let pixels = min(1024, max(image.width, image.height))
        // WatchPhotoTransfer removes the temporary file when the transfer finishes.
        session.transferFile(url, metadata: [SketchAssistProtocol.kindKey: SketchAssistProtocol.requestKind,
                                             SketchAssistProtocol.requestIDKey: id,
                                             SketchAssistProtocol.maximumPixelsKey: pixels])
        timeout?.cancel()
        timeout = Task { [weak self] in
            // The user opens the app and picks an image on the phone, which takes a while.
            try? await Task.sleep(for: .seconds(600))
            guard !Task.isCancelled, let self, self.requestID == id else { return }
            self.fail(L10n.text("Your iPhone did not respond. Tap ✓ to try again."))
            // Close a forgotten Image Playground, so a late result is not generated for nothing.
            Self.sendCancel(requestID: id)
        }
    }

    func receive(imageData: Data?, label: String?, requestID: String) {
        guard requestID == self.requestID else { return }
        guard let imageData, let image = UIImage(data: imageData), image.size.width > 0, image.size.height > 0
        else { return fail(Self.message(for: .failed)) }
        let applied = apply?(imageData, image.size) ?? false
        finish()
        phase = .completed(applied: applied)
    }

    /// Moves the notice forward; stale or earlier stages are ignored.
    func receive(stage: SketchAssistProtocol.Stage, requestID: String) {
        guard requestID == self.requestID, case .waiting(let current) = phase, stage.order > current.order
        else { return }
        phase = .waiting(stage)
    }

    func receive(failure: String, detail: String?, requestID: String) {
        guard requestID == self.requestID else { return }
        let failure = SketchAssistProtocol.Failure(rawValue: failure) ?? .failed
        fail(Self.message(for: failure), detail: detail)
        if failure == .unavailable { updatePhoneAvailability(false) }
    }

    /// Locks the lasso mode button. Reports come from the iPhone app, from failed
    /// requests and from the companion app being removed.
    func updatePhoneAvailability(_ available: Bool) {
        UserDefaults.standard.set(available, forKey: Self.phoneAvailabilityKey)
    }

    /// Stops waiting for the current request and asks the phone to close Image Playground.
    /// `showsNotice` is false when the lasso closes, so nothing points at its ✓ any more.
    func cancel(showsNotice: Bool) {
        guard let id = requestID else { return }
        finish()
        phase = showsNotice ? .failed(L10n.text("Cancelled. Tap ✓ to send again.")) : .idle
        Self.sendCancel(requestID: id)
    }

    private static func sendCancel(requestID id: String) {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        let info = [SketchAssistProtocol.cancelKey: id]
        guard session.isReachable else {
            session.transferUserInfo(info)
            return
        }
        // The error handler runs on a WatchConnectivity queue.
        session.sendMessage(info, replyHandler: nil) { @Sendable _ in WCSession.default.transferUserInfo(info) }
    }

    /// Clears a finished notice; a pending request stays visible.
    func dismissNotice() {
        guard !phase.isWaiting else { return }
        phase = .idle
    }

    private func fail(_ message: String, detail: String? = nil) {
        finish()
        phase = .failed(message, detail: detail)
    }

    private func finish() {
        requestID = nil
        apply = nil
        timeout?.cancel()
        timeout = nil
    }

    private static func message(for failure: SketchAssistProtocol.Failure) -> String {
        switch failure {
        case .unavailable: L10n.text("Apple Intelligence is not available on your iPhone.")
        case .cancelled: L10n.text("Closed on iPhone. Tap ✓ to try again.")
        case .unsupportedDrawing: L10n.text("These strokes could not be used. Circle other strokes and try again.")
        case .failed: L10n.text("Could not complete the strokes. Tap ✓ to try again.")
        }
    }

    /// Fits the whole image into `rect`, centered; existing paint shows in any margin.
    static func rasterStroke(png: Data, imageSize: CGSize, in rect: CGRect, id: UUID = UUID()) -> Stroke {
        let scale = min(rect.width / imageSize.width, rect.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let bounds = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                            width: size.width, height: size.height)
        var style = PencilStyle()
        style.blendingMode = .normal
        var stroke = Stroke(points: [], style: style, id: id)
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

/// Center-screen status and hints for Complete strokes: what to do next while the
/// outlined strokes wait for ✓, progress while the request is out (✕ cancels it),
/// and the outcome.
struct SketchAssistNotice: View {
    @ObservedObject var lasso: WatchLassoController
    @ObservedObject private var assist = WatchSketchAssist.shared
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Set when freshly outlined strokes wait for ✓; cleared after a few seconds.
    @State private var confirmationHintID: UUID?

    var body: some View {
        ZStack {
            if let content {
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        if assist.phase.isWaiting { ProgressView().frame(width: 18, height: 18) }
                        Text(content.text)
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .lineLimit(4)
                            .minimumScaleFactor(0.6)
                    }
                    if assist.phase.isWaiting {
                        Text(L10n.text("Tap ✕ to cancel"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 24)
                .id(content.id)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.85).combined(with: .opacity))
                .task(id: content.id) {
                    guard let duration = content.duration else { return }
                    do { try await Task.sleep(for: .seconds(duration)) } catch { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        if assist.phase == .idle { confirmationHintID = nil } else { assist.dismissNotice() }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8), value: assist.phase)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8), value: confirmationHintID)
        .onChange(of: lasso.sketchAssistStage) { old, stage in
            // Only a new selection; a failure brings its own next step.
            confirmationHintID = old == .idle && stage == .awaitingConfirmation ? UUID() : nil
        }
    }

    /// `duration` nil keeps the notice until the phase changes.
    private var content: (id: String, text: String, duration: Double?)? {
        switch assist.phase {
        case .idle:
            guard let confirmationHintID, lasso.awaitsSketchAssistConfirmation else { return nil }
            return (confirmationHintID.uuidString, L10n.text("Tap ✓ to send the strokes to iPhone"), 3)
        case .waiting(let stage):
            let text = switch stage {
            case .sending: L10n.text("Sending to iPhone…")
            case .delivered: L10n.text("Open Paint Anytime on iPhone")
            case .preparing: L10n.text("Opening Image Playground on iPhone…")
            case .choosing: L10n.text("Image Playground is drawing on iPhone. Tap Done there to keep the result.")
            case .returning: L10n.text("Adding the image…")
            }
            return ("waiting", text, nil)
        case .completed(let applied):
            if applied { return ("completed", L10n.text("Done! Use Undo to get your strokes back."), 3) }
            return ("notApplied", L10n.text("The drawing changed, so the image was not added. Tap ✓ to try again."), 5)
        case .failed(let message, _):
            // Failures say what to do next; give them time to be read on the wrist.
            return ("failed-" + message, message, 5)
        }
    }
}

/// Explains what Complete strokes needs, from the lasso and from canvas actions.
struct SketchAssistRequirementsAlert: ViewModifier {
    @Binding var isPresented: Bool

    /// No report yet: most often the iPhone app was never opened, not a missing feature.
    private var phoneHasReported: Bool {
        UserDefaults.standard.object(forKey: WatchSketchAssist.phoneAvailabilityKey) != nil
    }

    func body(content: Content) -> some View {
        content.alert(L10n.text(phoneHasReported ? "Image Playground is unavailable" : "Open Paint Anytime on iPhone"),
                      isPresented: $isPresented) {
            Button(L10n.text("OK"), role: .cancel) {}
        } message: {
            if phoneHasReported {
                Text(L10n.text("To complete strokes, you need an iPhone that supports Apple Intelligence (iPhone 15 Pro or later) with iOS 18.4 or later, Apple Intelligence turned on in Settings, and Image Playground available. Install Paint Anytime on iPhone and open it once so your watch can check."))
            } else {
                Text(L10n.text("Your watch checks Image Playground through the iPhone app. Install Paint Anytime on iPhone, open it once, then try again."))
            }
        }
    }
}

/// Dims Complete strokes and adds a lock until the iPhone reports support.
struct SketchAssistLock: ViewModifier {
    let isLocked: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isLocked ? 0.45 : 1)
            .overlay(alignment: .bottomTrailing) {
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .bold))
                        .offset(x: 5, y: 3)
                }
            }
    }
}
