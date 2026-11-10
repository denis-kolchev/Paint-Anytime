import SwiftUI

struct PhoneGalleryEmptyState: View {
    let synchronize: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Your Watch Gallery", systemImage: "applewatch")
        } description: {
            Text("Save a drawing in Paint Anytime on your Apple Watch. Open the watch app to sync your existing drawings. Transfers may take a few minutes.")
        } actions: {
            Button("Sync with Apple Watch", action: synchronize)
        }
        .padding(.top, 80)
        Text("Deleting a drawing removes it from both Apple Watch and iPhone. Save a copy to Photos, Files, or another app before deleting.")
            .font(.footnote).foregroundStyle(.secondary).padding()
    }
}
