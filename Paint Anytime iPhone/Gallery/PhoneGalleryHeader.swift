import SwiftUI

/// Stays outside the scroll content so the title never collapses into a toolbar.
struct PhoneGalleryHeader: View {
    let importPhoto: () -> Void
    let importProject: () -> Void
    let synchronize: () -> Void
    /// True while a picked photo is decoded and sent to the watch.
    var isPreparingPhoto = false

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

    /// Matches the height of system navigation bar buttons such as Cancel and
    /// Send in sheets, so the header button reads as part of the same family.
    private static let buttonDiameter: CGFloat = 44

    private var actions: some View {
        Group {
            if #available(iOS 26.0, *) {
                actionButtons
                    .glassEffect(.regular.interactive(), in: .circle)
            } else {
                actionButtons
                    .background(.fill.tertiary, in: .circle)
            }
        }
        .font(.body.weight(.medium))
        .foregroundStyle(.primary)
        .fixedSize()
    }

    /// One button keeps the actions beside the title; three icon buttons no longer
    /// fitted, so `ViewThatFits` moved them below it. Menu items also show titles.
    private var actionButtons: some View {
        Menu {
            Button(action: importPhoto) {
                Label("Import Photo", systemImage: "photo.badge.plus")
            }
            .disabled(isPreparingPhoto)
            Button(action: importProject) {
                Label("Import Project", systemImage: "square.and.arrow.down")
            }
            Divider()
            Button(action: synchronize) {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
            }
        } label: {
            // Only the header button is icon-only; menu items keep their titles.
            // A fixed frame gives the exact system bar height; button styles add
            // their own padding around the icon and come out smaller.
            Group {
                // Large camera photos take a moment to prepare; the spinner replaces
                // the icon so the button keeps its size.
                if isPreparingPhoto {
                    ProgressView()
                        .accessibilityLabel(Text("Preparing Photo…"))
                } else {
                    Label("More", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                }
            }
            .frame(width: Self.buttonDiameter, height: Self.buttonDiameter)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
    }
}
