import SwiftUI
import UniformTypeIdentifiers
import ImageIO

struct PhoneHomeView: View {
    @ObservedObject var photoInbox: WatchPhotoInbox

    var body: some View {
        NavigationStack {
            ScrollView {
                if photoInbox.images.isEmpty {
                    ContentUnavailableView {
                        Label("Your Watch Gallery", systemImage: "applewatch")
                    } description: {
                        Text("Save a drawing in Paint Anytime on your Apple Watch. Open the watch app to sync your existing drawings. Transfers may take a few minutes.")
                    } actions: {
                        Button("Sync with Apple Watch") { photoInbox.synchronize() }
                    }
                    .padding(.top, 80)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 12) {
                        ForEach(photoInbox.images, id: \.self) { url in
                            NavigationLink {
                                PhoneDrawingView(url: url, inbox: photoInbox)
                            } label: {
                                DrawingPreview(url: url, maximumSize: 500)
                                    .frame(height: 170)
                                    .frame(maxWidth: .infinity)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                            }
                            .accessibilityLabel(Text(url.deletingPathExtension().lastPathComponent))
                        }
                    }
                    .padding()
                    Text("Drawings are copied from your Apple Watch and kept on this iPhone.")
                        .font(.footnote).foregroundStyle(.secondary).padding()
                }
            }
            .navigationTitle("Watch Gallery")
            .toolbar {
                Button { photoInbox.synchronize() } label: { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
            }
            .refreshable { photoInbox.synchronize() }
            .alert("Could not complete action", isPresented: Binding(
                get: { photoInbox.errorMessage != nil },
                set: { if !$0 { photoInbox.clearError() } }
            )) {
                if photoInbox.photoPermissionRequiresSettings {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                Button("OK", role: .cancel) { photoInbox.clearError() }
            } message: { Text(photoInbox.errorMessage ?? "") }
        }
    }
}

private struct PhoneDrawingView: View {
    let url: URL
    @ObservedObject var inbox: WatchPhotoInbox
    @State private var exporting = false
    @State private var exportError: String?

    var body: some View {
        VStack(spacing: 20) {
            DrawingPreview(url: url, maximumSize: 2400)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 24) {
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                Button { inbox.saveToPhotos(url) } label: { Label("Photos", systemImage: "photo.badge.plus") }
                    .disabled(inbox.isSaving)
                Button { exporting = true } label: { Label("Save File", systemImage: "folder") }
            }
            .labelStyle(.iconOnly).font(.title2)
            if inbox.isSaving { ProgressView("Saving…") }
        }
        .padding()
        .navigationTitle("Drawing")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(isPresented: $exporting, document: DrawingPNG(url: url), contentType: .png,
                      defaultFilename: url.deletingPathExtension().lastPathComponent) { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
        .alert("Saved to Photos", isPresented: Binding(get: { inbox.savedToPhotos }, set: { if !$0 { inbox.clearConfirmation() } })) {
            Button("OK") { inbox.clearConfirmation() }
        }
        .alert("Could not export", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") { exportError = nil }
        } message: { Text(exportError ?? "") }
    }
}

private struct DrawingPNG: FileDocument {
    static var readableContentTypes: [UTType] { [.png] }
    let url: URL?
    let data: Data?
    init(url: URL) { self.url = url; data = nil }
    init(configuration: ReadConfiguration) throws { url = nil; data = configuration.file.regularFileContents }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        if let url { return try FileWrapper(url: url, options: .immediate) }
        return FileWrapper(regularFileWithContents: data ?? Data())
    }
}

private struct DrawingPreview: View {
    let url: URL
    let maximumSize: Int
    @State private var preview: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let preview { Image(uiImage: preview).resizable().scaledToFit() }
            else if failed { Label("Preview unavailable", systemImage: "photo") }
            else { ProgressView() }
        }
        .task(id: url) {
            let sourceURL = url
            let size = maximumSize
            let image = await Task.detached(priority: .userInitiated) {
                guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else { return Optional<CGImage>.none }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: size
                ] as CFDictionary)
            }.value
            if !Task.isCancelled {
                if let image { preview = UIImage(cgImage: image) }
                else { failed = true }
            }
        }
    }
}
