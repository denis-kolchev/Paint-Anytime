import SwiftUI

struct WatchAppSettingsView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @ObservedObject var controller: CanvasController
    var onOpenDrawings: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Button(L10n.text("Gallery")) { onOpenDrawings() }
                NavigationLink {
                    AppLanguageSelectionView()
                } label: {
                    Label(L10n.text("Language"), systemImage: "globe")
                }
                NavigationLink {
                    ToolSynchronizationView(controller: controller)
                } label: {
                    Text(L10n.text("Tool synchronization"))
                }
            }
            .navigationTitle(L10n.text("More"))
        }
    }
}

private struct ToolSynchronizationView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @ObservedObject var controller: CanvasController

    var body: some View {
        List {
            Section {
                Toggle(L10n.text("Shared width"), isOn: Binding(
                    get: { controller.synchronization.width },
                    set: { controller.setSynchronizeWidth($0) }
                ))
                Toggle(L10n.text("Shared color"), isOn: Binding(
                    get: { controller.synchronization.color },
                    set: { controller.setSynchronizeColor($0) }
                ))
            } footer: {
                Text(L10n.text("Selected settings are shared across tools. Color does not apply to the eraser."))
            }
        }
        .navigationTitle(L10n.text("Synchronization"))
    }
}

private struct AppLanguageSelectionView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @State private var pendingLanguageCode: String?

    var body: some View {
        List(AppLanguage.displayOrder) { language in
            Button {
                guard pendingLanguageCode == nil, language.id != AppLanguage.currentCode else { return }
                pendingLanguageCode = language.id
            } label: {
                HStack {
                    Text(verbatim: language.nativeName)
                    Spacer()
                    if AppLanguage.currentCode == language.id {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.green)
                    }
                }
            }
            .accessibilityAddTraits(AppLanguage.currentCode == language.id ? .isSelected : [])
        }
        .disabled(pendingLanguageCode != nil)
        .accessibilityHidden(pendingLanguageCode != nil)
        .overlay {
            if pendingLanguageCode != nil {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text(L10n.text("Changing language…"))
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.9))
                .accessibilityElement(children: .combine)
            }
        }
        .navigationBarBackButtonHidden(pendingLanguageCode != nil)
        .interactiveDismissDisabled(pendingLanguageCode != nil)
        .navigationTitle(L10n.text("Language"))
        .task(id: pendingLanguageCode) {
            guard let code = pendingLanguageCode else { return }
            defer { pendingLanguageCode = nil }
            do {
                // Let the indicator render before invalidating all localized views.
                try await Task.sleep(for: .milliseconds(100))
                try Task.checkCancellation()
                languageCode = code
                // Keep the overlay through the first layout of the updated interface.
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                // SwiftUI cancels this task if the selection screen disappears.
            }
        }
    }
}
