import SwiftUI

/// Canvas → Reference: turns the reference on or off and picks its image.
struct ReferenceSettingsView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @ObservedObject var store = ReferenceImageStore.shared

    var body: some View {
        List {
            Toggle(L10n.text("Show reference"), isOn: $store.isEnabled)
            if store.isEnabled {
                if let image = store.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .listRowBackground(Color.clear)
                        .accessibilityLabel(L10n.text("Reference image"))
                }
                NavigationLink {
                    ReferencePickerView()
                } label: {
                    Label(L10n.text(store.image == nil ? "Choose image" : "Replace image"),
                          systemImage: "photo.on.rectangle")
                }
                if store.image != nil {
                    Button(role: .destructive) {
                        store.remove()
                    } label: {
                        Label(L10n.text("Remove image"), systemImage: "trash")
                    }
                }
            }
        }
        .labelStyle(CenteredMenuLabelStyle())
        .navigationTitle(L10n.text("Reference"))
        .toolbarTitleDisplayMode(.inline)
    }
}

/// The gallery's images as a plain grid to choose the reference from. Pops back once
/// the copy is stored; the gallery itself stays as it is.
struct ReferencePickerView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @ObservedObject var store = ReferenceImageStore.shared
    @StateObject private var gallery = GalleryController()
    @Environment(\.dismiss) private var dismiss
    /// Called after a successful choice, before this page pops.
    var onChoose: () -> Void = {}

    private let spacing: CGFloat = 3

    var body: some View {
        GeometryReader { geometry in
            let side = max(1, (geometry.size.width - spacing * 2) / 3)
            ScrollView {
                if gallery.hasLoaded && gallery.drawings.isEmpty {
                    Text(gallery.errorMessage ?? L10n.text("No images in the gallery"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                } else if !gallery.hasLoaded {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 24)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: spacing), count: 3),
                              spacing: spacing) {
                        ForEach(gallery.drawings) { drawing in
                            Button {
                                choose(drawing.url)
                            } label: {
                                ReferencePickerTile(url: drawing.url, side: side)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .disabled(store.isImporting)
        .overlay {
            if store.isImporting { LoadingDimOverlay().ignoresSafeArea() }
        }
        .navigationTitle(L10n.text("Reference"))
        .toolbarTitleDisplayMode(.inline)
        .task { gallery.reloadInBackground() }
        .alert(L10n.text("Could not open the image."), isPresented: Binding(
            get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button(L10n.text("OK"), role: .cancel) { store.errorMessage = nil }
        }
    }

    private func choose(_ url: URL) {
        guard !store.isImporting else { return }
        Task {
            guard await store.setImage(from: url) else { return }
            onChoose()
            dismiss()
        }
    }
}

private struct ReferencePickerTile: View {
    let url: URL
    let side: CGFloat
    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color.white.opacity(0.08)
            if let image {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: side, height: side)
        .clipped()
        .contentShape(Rectangle())
        .task(id: url) {
            let pixels = Int((side * displayScale).rounded(.up))
            let url = url
            image = await Task.detached(priority: .userInitiated) {
                ReferenceImageStore.thumbnail(url, maxPixelSide: pixels)
            }.value
        }
    }
}
