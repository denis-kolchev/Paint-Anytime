import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import WatchConnectivity

/// The iPhone only prepares and sends the photo; the drawing is created and edited
/// on Apple Watch (see `PhotoImportProtocol`).
nonisolated enum PhonePhotoImport {
    enum ImportError: LocalizedError {
        case unreadable, watchUnavailable
        var errorDescription: String? {
            switch self {
            case .unreadable: String(localized: "This photo could not be opened.")
            case .watchUnavailable: String(localized: "Connect your Apple Watch and install Paint Anytime before sending a project.")
            }
        }
    }

    /// An upright PNG whose longer side is at most the watch's photo detail limit.
    static func preparedPNG(from data: Data) throws -> Data {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Applies the EXIF orientation, so the watch receives upright pixels.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: PhotoImportProtocol.maximumPhotoPixelSide,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw ImportError.unreadable }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { throw ImportError.unreadable }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ImportError.unreadable }
        return output as Data
    }

    static func send(png: Data, fitsWatch: Bool) throws {
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled
        else { throw ImportError.watchUnavailable }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoImport-\(UUID().uuidString)")
            .appendingPathExtension("png")
        try png.write(to: url, options: .atomic)
        let name = PhotoImportProtocol.newDrawingName()
        // WatchDrawingReceiver removes the temporary file when the transfer finishes.
        session.transferFile(url, metadata: [PhotoImportProtocol.kindKey: PhotoImportProtocol.kind,
                                             PhotoImportProtocol.fitsWatchKey: fitsWatch,
                                             PhotoImportProtocol.nameKey: name])
        addToGallery(png, name: name)
    }

    /// Lists the photo in the phone gallery now, rather than only once the watch app
    /// has opened and sent the drawing back. That drawing, with its project, replaces
    /// this preview under the same name. Without it the photo still arrives that way.
    private static func addToGallery(_ png: Data, name: String) {
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoImportPreview-\(UUID().uuidString)")
            .appendingPathExtension("png")
        do {
            try png.write(to: copy, options: .atomic)
            try IncomingDrawingStore().receive(copy, name: name + ".png")
        } catch {
            try? FileManager.default.removeItem(at: copy)
            NSLog("Photo import gallery preview failed: %@", error.localizedDescription)
        }
    }
}

struct PhonePhotoImportView: View {
    /// Receives the confirmation or error text to show after the sheet closes.
    let onFinish: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("photoImportFitsWatch") private var fitsWatch = true
    @State private var selection: PhotosPickerItem?
    @State private var png: Data?
    @State private var preview: UIImage?
    @State private var loading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhotosPicker(selection: $selection, matching: .images) {
                        photoLabel
                    }
                }
                Section {
                    Toggle("Fit to Apple Watch screen", isOn: $fitsWatch)
                } footer: {
                    if fitsWatch {
                        Text("The canvas takes the photo's shape and fits your watch screen.")
                    } else {
                        Text("The canvas takes the photo's shape and resolution, up to 1024 pixels on the longer side, the largest canvas Apple Watch can edit. Larger photos keep twice that detail for zooming in.")
                    }
                }
                Section {
                    Text("The photo becomes a new drawing in your watch gallery. It has its own layer, with an empty layer above it for drawing. Edit it on Apple Watch.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New Drawing from Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send", action: send).disabled(png == nil || loading)
                }
            }
            .task(id: selection) { await load(selection) }
            .alert("Could not complete action",
                   isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    @ViewBuilder private var photoLabel: some View {
        if loading {
            HStack { ProgressView(); Text("Preparing Photo…") }
        } else if let preview {
            Image(uiImage: preview)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel(Text("Selected photo. Choose another photo"))
        } else {
            Label("Choose Photo", systemImage: "photo.on.rectangle")
        }
    }

    private func load(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        loading = true
        defer { loading = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw PhonePhotoImport.ImportError.unreadable
            }
            // Full camera photos are large; decode and encode away from the main actor.
            let prepared = try await Task.detached(priority: .userInitiated) {
                try PhonePhotoImport.preparedPNG(from: data)
            }.value
            guard !Task.isCancelled else { return }
            png = prepared
            preview = UIImage(data: prepared)
        } catch {
            guard !Task.isCancelled else { return }
            png = nil
            preview = nil
            errorMessage = error.localizedDescription
        }
    }

    private func send() {
        guard let png else { return }
        do {
            try PhonePhotoImport.send(png: png, fitsWatch: fitsWatch)
            dismiss()
            onFinish(String(localized: "Photo queued. It will appear in your watch gallery as a new drawing when the transfer finishes. Open it there to edit."))
        } catch { errorMessage = error.localizedDescription }
    }
}
