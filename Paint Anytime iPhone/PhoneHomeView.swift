import SwiftUI

struct PhoneHomeView: View {
    @ObservedObject var photoInbox: WatchPhotoInbox

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "applewatch.radiowaves.left.and.right")
                .font(.system(size: 52))
            Text("Paint Anytime")
                .font(.largeTitle.bold())
            Text("Drawings saved on Apple Watch appear in Photos on this iPhone.")
                .multilineTextAlignment(.center)

            if photoInbox.needsPhotoPermission {
                Button("Allow saving to Photos") {
                    if photoInbox.photoPermissionRequiresSettings {
                        if let settings = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(settings)
                        }
                    } else {
                        photoInbox.requestPhotoPermission()
                    }
                }
                .buttonStyle(.borderedProminent)
            } else if photoInbox.pendingCount > 0 {
                ProgressView("Saving drawings to Photos…")
            } else {
                Label("Ready to receive drawings", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            Link("Privacy Policy", destination: URL(string: "https://github.com/denis-kolchev/Paint-Anytime/blob/main/docs/PRIVACY.md")!)
                .font(.footnote)

            if photoInbox.pendingCount > 0 {
                Text("Waiting to save: \(photoInbox.pendingCount)")
                    .font(.footnote)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Could not save", isPresented: Binding(
            get: { photoInbox.errorMessage != nil },
            set: { if !$0 { photoInbox.clearError() } }
        )) {
            Button("OK") { photoInbox.clearError() }
        } message: {
            Text(photoInbox.errorMessage ?? "")
        }
    }
}
