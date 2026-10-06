import SwiftUI

struct SavedDrawingView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    let drawing: CanvasExport
    @Environment(\.tutorialHintReservedHeight) private var tutorialHintReservedHeight
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var scrollFocused: Bool
    @ObservedObject var tutorial = TutorialSession.inactive
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let image = UIImage(contentsOfFile: drawing.url.path) {
                    Image(uiImage: image).resizable().scaledToFit()
                }
                ShareLink(item: DrawingShareItem(url: drawing.url),
                          preview: SharePreview("Paint All the Time", image: DrawingShareItem(url: drawing.url))) {
                    Label(L10n.text("Share"), systemImage: "square.and.arrow.up")
                }
                .simultaneousGesture(TapGesture().onEnded { tutorial.activity() })
                Text(drawing.url.lastPathComponent).font(.caption2)
            }
            .watchActionButtonStyle()
            .padding(.horizontal)
            .reportLegacyScrollPosition()
        }
        .padding(.bottom, tutorialHintReservedHeight)
        // Give the visible page Crown focus after the canvas releases it.
        .focusable()
        .focused($scrollFocused)
        .task(id: scenePhase) {
            scrollFocused = false
            guard scenePhase == .active else { return }
            // Wait until the scroll view is installed in the watchOS focus tree.
            do {
                try await Task.sleep(for: .milliseconds(100))
                try Task.checkCancellation()
                scrollFocused = true
            } catch {}
        }
        .onDisappear { scrollFocused = false }
        .onTutorialScrollActivity { tutorial.activity() }
        .navigationTitle(L10n.text("Saved"))
    }
}

