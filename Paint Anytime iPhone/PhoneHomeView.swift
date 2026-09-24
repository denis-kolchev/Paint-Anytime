import Photos
import SwiftUI

struct PhoneHomeView: View {
    @ObservedObject var photoInbox: WatchPhotoInbox

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "applewatch.radiowaves.left.and.right")
                .font(.system(size: 52))
            Text("Paint Anytime")
                .font(.largeTitle.bold())
            Text("Рисунки, сохранённые на Apple Watch, появляются в приложении «Фото» на этом iPhone.")
                .multilineTextAlignment(.center)

            if photoInbox.needsPhotoPermission {
                Button("Разрешить сохранение в Фото") {
                    if [.denied, .restricted].contains(PHPhotoLibrary.authorizationStatus(for: .addOnly)) {
                        if let settings = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(settings)
                        }
                    } else {
                        photoInbox.requestPhotoPermission()
                    }
                }
                .buttonStyle(.borderedProminent)
            } else if photoInbox.pendingCount > 0 {
                ProgressView("Сохраняем рисунки в Фото…")
            } else {
                Label("Готово к приёму рисунков", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            VStack(spacing: 12) {
                Link("Политика конфиденциальности", destination: URL(string: "https://github.com/denis-kolchev/Paint-Anytime/blob/main/docs/PRIVACY.md")!)
                Link("Условия использования", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
            }
            .font(.footnote)

            if photoInbox.pendingCount > 0 {
                Text("Ожидают сохранения: \(photoInbox.pendingCount)")
                    .font(.footnote)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Ошибка сохранения", isPresented: Binding(
            get: { photoInbox.errorMessage != nil },
            set: { if !$0 { photoInbox.clearError() } }
        )) {
            Button("ОК") { photoInbox.clearError() }
        } message: {
            Text(photoInbox.errorMessage ?? "")
        }
    }
}
