import SwiftUI
import WatchConnectivity
import UniformTypeIdentifiers

struct PhoneDrawingView: View {
    let url: URL
    @ObservedObject var inbox: WatchPhotoInbox
    var closeDrawing: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDeletion = false
    @State private var exporting = false
    @State private var showingPhotoConfirmation = false
    @State private var exportingProject = false
    @State private var exportingPhotoshop = false
    @State private var exportingJPEG = false
    @State private var transferMessage: String?
    /// Toggled by a tap while zoomed in; zooming back out shows the bars.
    @State private var barsHidden = false
    private var projectURL: URL { url.deletingPathExtension().appendingPathExtension(PaintProject.fileExtension) }
    private var hasProject: Bool { FileManager.default.fileExists(atPath: projectURL.path) }
    @State private var exportError: String?

    private var drawingContent: some View {
        // Zooming stays in this layout, so the bars keep their place.
        PhoneZoomableDrawing(
            url: url, maximumSize: 2400,
            onZoomedTap: {
                withAnimation(.easeInOut(duration: 0.2)) { barsHidden.toggle() }
            },
            onZoomedChange: { zoomed in
                // Back at the fitted size, the bars always return.
                if !zoomed, barsHidden {
                    withAnimation(.easeInOut(duration: 0.2)) { barsHidden = false }
                }
            })
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container)
        .overlay(alignment: .bottom) {
            if inbox.isSaving {
                ProgressView("Saving…")
                    .padding(12)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 12)
            }
        }
    }

    private var drawingNavigation: some View {
        drawingContent
        .toolbarBackground(.hidden, for: .bottomBar)
        .toolbar(barsHidden ? .hidden : .visible, for: .bottomBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationTitle("Drawing")
        .toolbar(barsHidden ? .hidden : .visible, for: .navigationBar)
        .statusBarHidden(barsHidden)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
                PhoneDrawingActions(
                    url: url,
                    projectURL: projectURL,
                    hasProject: hasProject,
                    hasPhotoOriginal: PhotoOriginalStore().hasOriginal(for: url),
                    isSaving: inbox.isSaving,
                    saveToPhotos: { inbox.saveToPhotos(url) },
                    exportImage: { exporting = true },
                    exportJPEG: { exportingJPEG = true },
                    exportProject: { exportingProject = true },
                    exportPhotoshop: { exportingPhotoshop = true },
                    synchronize: { inbox.synchronize() },
                    sendToWatch: sendToWatch,
                    delete: { confirmingDeletion = true }
                )

            if let closeDrawing {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: closeDrawing) {
                        Label("Back", systemImage: "chevron.backward")
                    }
                }
            }
        }
    }

    private var drawingExports: some View {
        drawingNavigation
        .confirmationDialog("Delete from Apple Watch and iPhone?", isPresented: $confirmingDeletion, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if inbox.delete(url) { close() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Save a copy to Photos, Files, or another app first. Deletion will sync when your devices reconnect.")
        }
        .onChange(of: inbox.images) { _, images in
            if !images.contains(url) { close() }
        }
        .fileExporter(isPresented: $exporting, document: DrawingFile(url: url, fullResolution: true), contentType: .png,
                      defaultFilename: url.deletingPathExtension().lastPathComponent) { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
        .fileExporter(isPresented: $exportingJPEG, document: DrawingFile(jpegFrom: url), contentType: .jpeg,
                      defaultFilename: url.deletingPathExtension().lastPathComponent) { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
        .fileExporter(isPresented: $exportingProject, document: DrawingFile(url: projectURL), contentType: .paintAnytimeProject,
                      defaultFilename: projectURL.deletingPathExtension().lastPathComponent) { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
        .fileExporter(isPresented: $exportingPhotoshop, document: DrawingFile(photoshopFrom: projectURL),
                      contentType: .photoshopImage,
                      defaultFilename: projectURL.deletingPathExtension().lastPathComponent) { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
    }

    var body: some View {
        drawingExports
        .alert("Project queued", isPresented: showingTransferMessage) {
            Button("OK") { transferMessage = nil }
        } message: { Text(transferMessage ?? "") }
        .onChange(of: inbox.savedToPhotos, initial: true) { _, saved in
            showingPhotoConfirmation = saved
        }
        .onChange(of: showingPhotoConfirmation) { _, presented in
            if !presented { inbox.clearConfirmation() }
        }
        .alert("Saved to Photos", isPresented: $showingPhotoConfirmation) {
            Button("OK") { showingPhotoConfirmation = false }
        }
        .alert("Could not export", isPresented: showingExportError) {
            Button("OK") { exportError = nil }
        } message: { Text(exportError ?? "") }
    }

    private var showingTransferMessage: Binding<Bool> {
        Binding(get: { transferMessage != nil }, set: { if !$0 { transferMessage = nil } })
    }

    private var showingExportError: Binding<Bool> {
        Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
    }

    private func sendToWatch() {
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else {
            exportError = L10n.text("Connect your Apple Watch and install Paint Anytime before sending a project.")
            return
        }
        session.transferFile(projectURL, metadata: ["project": true])
        transferMessage = L10n.text("Project queued. It will appear in your watch gallery when the transfer finishes. Open it there to edit.")
    }

    private func close() {
        if let closeDrawing {
            closeDrawing()
        } else {
            dismiss()
        }
    }
}
