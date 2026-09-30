import SwiftUI

struct SavedDrawingView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    let drawing: CanvasExport
    @State var photoTransferStatus: String
    @State var canRetryPhotoTransfer: Bool
    @Environment(\.tutorialHintReservedHeight) private var tutorialHintReservedHeight
    @ObservedObject var tutorial = TutorialSession.inactive
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let image = UIImage(contentsOfFile: drawing.url.path) {
                    Image(uiImage: image).resizable().scaledToFit()
                }
                ShareLink(item: drawing.url, preview: SharePreview("Paint All the Time", image: Image(systemName: "photo"))) {
                    Label(L10n.text("Share"), systemImage: "square.and.arrow.up")
                }
                .simultaneousGesture(TapGesture().onEnded { tutorial.activity() })
                if AppReleaseFeatures.current.showsPhotoTransferControls && !tutorial.isActive {
                    Text(photoTransferStatus).font(.caption2)
                    if canRetryPhotoTransfer {
                        Button(L10n.text("Retry sending to iPhone")) {
                            let queued = WatchPhotoTransfer.shared.queue(drawing.url)
                            canRetryPhotoTransfer = !queued
                            photoTransferStatus = queued
                            ? L10n.text("Your drawing is being sent to Photos on iPhone.")
                            : L10n.text("The iPhone app is currently unavailable.")
                        }
                    }
                } else {
                    Text(L10n.text("Sharing options depend on watchOS. Saving directly to Photos on iPhone requires a companion iPhone app; it is not available with the watch app alone."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(drawing.url.lastPathComponent).font(.caption2)
            }
            .watchActionButtonStyle()
            .padding(.horizontal)
            .reportLegacyScrollPosition()
        }
        .padding(.bottom, tutorialHintReservedHeight)
        .scrollDisabled(tutorial.isActive && !tutorial.permits([.shareDrawing]))
        .onTutorialScrollActivity { tutorial.activity() }
        .navigationTitle(L10n.text("Saved"))
    }
}

