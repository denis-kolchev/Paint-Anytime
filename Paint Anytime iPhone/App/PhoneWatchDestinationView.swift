import SwiftUI

/// These features live on the watch. A phone URL cannot foreground its companion.
struct PhoneWatchDestinationView: View {
    let destination: PaintDeepLink
    let onClose: () -> Void

    private var title: LocalizedStringKey {
        switch destination {
        case .newCanvas: "New Drawing on Apple Watch"
        case .settings: "Settings on Apple Watch"
        default: "Canvas on Apple Watch"
        }
    }

    private var instruction: LocalizedStringKey {
        switch destination {
        case .newCanvas: "Open Paint Anytime on your Apple Watch. Save your current drawing if needed, then use Clear in the canvas controls to start a new drawing."
        case .settings: "Open Paint Anytime on your Apple Watch and tap the three dots to open settings."
        default: "Open Paint Anytime on your Apple Watch to continue drawing on the canvas."
        }
    }

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label(title, systemImage: "applewatch")
            } description: {
                Text(instruction)
                Text("This link opens the iPhone companion. It cannot automatically open the app on your Apple Watch.")
            } actions: {
                Button("Back to Gallery", action: onClose)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose)
                }
            }
        }
        .background(Color(uiColor: .systemBackground))
    }
}
