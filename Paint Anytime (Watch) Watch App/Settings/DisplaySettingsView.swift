import SwiftUI

/// How the canvas is shown on screen, without changing the drawing or its saved file.
/// App-wide options; more display aids belong here as they appear.
struct DisplaySettingsView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @AppStorage(CanvasPixelView.storageKey) private var showsPixels = false

    var body: some View {
        List {
            Section {
                Toggle(isOn: $showsPixels) {
                    Label(L10n.text("Pixel view"), systemImage: "square.grid.3x3")
                }
            } footer: {
                Text(L10n.text("When zoomed in, shows the drawing's pixels as squares."))
            }
        }
        .labelStyle(CenteredMenuLabelStyle())
        .navigationTitle(L10n.text("Display"))
        .toolbarTitleDisplayMode(.inline)
    }
}
