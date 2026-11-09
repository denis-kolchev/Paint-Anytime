import SwiftUI

/// Stays outside the scroll content so the title never collapses into a toolbar.
struct PhoneGalleryHeader: View {
    let importPhoto: () -> Void
    let importProject: () -> Void
    let synchronize: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                title
                Spacer(minLength: 0)
                actions
            }
            VStack(alignment: .leading, spacing: 8) {
                title
                actions
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask {
                    VStack(spacing: 0) {
                        Rectangle()
                            .fill(.black)
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black.opacity(0.85), location: 0.25),
                                .init(color: .black.opacity(0.5), location: 0.5),
                                .init(color: .black.opacity(0.15), location: 0.75),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom)
                            .frame(height: 48)
                    }
                }
                // Extend only the backdrop, preserving the header's layout and
                // fading across the artwork instead of ending at its top edge.
                .padding(.bottom, -40)
                .ignoresSafeArea(.container, edges: [.top, .horizontal])
                .allowsHitTesting(false)
        }
    }

    private var title: some View {
        Text("Watch Gallery")
            .font(.largeTitle.bold())
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            .layoutPriority(1)
    }

    private var actions: some View {
        Group {
            if #available(iOS 26.0, *) {
                actionButtons.buttonStyle(.glass)
            } else {
                actionButtons.buttonStyle(.bordered)
            }
        }
        .font(.body)
        .controlSize(.large)
        .buttonBorderShape(.circle)
        .tint(.primary)
        .fixedSize()
    }

    /// One button keeps the actions beside the title; three icon buttons no longer
    /// fitted, so `ViewThatFits` moved them below it. Menu items also show titles.
    private var actionButtons: some View {
        Menu {
            Button(action: importPhoto) {
                Label("New Drawing from Photo", systemImage: "photo.badge.plus")
            }
            Button(action: importProject) {
                Label("Import Project", systemImage: "square.and.arrow.down")
            }
            Divider()
            Button(action: synchronize) {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
            }
        } label: {
            // Only the header button is icon-only; menu items keep their titles.
            Label("More", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
        }
    }
}
