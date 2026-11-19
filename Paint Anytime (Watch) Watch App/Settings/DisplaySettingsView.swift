import SwiftUI

/// How the canvas is shown on screen, without changing the drawing or its saved file.
/// App-wide options; more display aids belong here as they appear.
struct DisplaySettingsView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @AppStorage(CanvasPixelView.storageKey) private var pixelMode = CanvasPixelView.Mode.smooth

    var body: some View {
        List {
            Section {
                ForEach(CanvasPixelView.Mode.allCases, id: \.rawValue) { mode in
                    Button {
                        pixelMode = mode
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(mode.title)
                                Text(mode.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            if pixelMode == mode {
                                Image(systemName: "checkmark").foregroundStyle(.green)
                            }
                        }
                    }
                    .accessibilityAddTraits(pixelMode == mode ? .isSelected : [])
                }
            } header: {
                Text(L10n.text("When zoomed in"))
            }
        }
        .navigationTitle(L10n.text("Display"))
        .toolbarTitleDisplayMode(.inline)
    }
}
