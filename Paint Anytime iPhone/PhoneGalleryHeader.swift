import SwiftUI

/// Stays outside the scroll content so the title never collapses into a toolbar.
struct PhoneGalleryHeader: View {
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
                .ignoresSafeArea(edges: .top)
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
        .labelStyle(.iconOnly)
        .font(.title2)
        .buttonBorderShape(.circle)
        .tint(.primary)
        .fixedSize()
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button(action: importProject) {
                Label("Import Project", systemImage: "square.and.arrow.down")
                    .frame(minWidth: 44, minHeight: 44)
            }
            Button(action: synchronize) {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                    .frame(minWidth: 44, minHeight: 44)
            }
        }
    }
}
