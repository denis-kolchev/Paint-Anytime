import SwiftUI

/// Stays outside the scroll content so the title never collapses into a toolbar.
struct PhoneGalleryHeader: View {
    /// The More menu when it sits beside the title rather than in a system bar.
    var menu: PhoneGalleryMoreMenu?

    var body: some View {
        HStack(spacing: 12) {
            title
            Spacer(minLength: 0)
            if let menu {
                PhoneGalleryHeaderButton(menu: menu)
            }
        }
        // Otherwise the menu is a navigation bar item placed over this header,
        // so iPhone Duo can move it into the vertical bar. Leave its width free.
        .padding(.trailing, menu == nil ? PhoneGalleryMoreMenu.reservedWidth : 0)
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
}

/// The More menu drawn like a navigation bar button, for the header.
private struct PhoneGalleryHeaderButton: View {
    let menu: PhoneGalleryMoreMenu

    /// Matches the height of system navigation bar buttons.
    private static let diameter: CGFloat = 44

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                label.glassEffect(.regular.interactive(), in: .circle)
            } else {
                label.background(.fill.tertiary, in: .circle)
            }
        }
        .font(.body.weight(.medium))
        .foregroundStyle(.primary)
        .fixedSize()
    }

    private var label: some View {
        menu
            .labelStyle(.iconOnly)
            .frame(width: Self.diameter, height: Self.diameter)
            .contentShape(.circle)
            .buttonStyle(.plain)
    }
}

/// The gallery's More menu, shown as a navigation bar item.
struct PhoneGalleryMoreMenu: View {
    let importPhoto: () -> Void
    let importProject: () -> Void
    let synchronize: () -> Void
    /// True while a picked photo is decoded and sent to the watch.
    var isPreparingPhoto = false

    /// Room the header keeps free beside the title for the bar button.
    static let reservedWidth: CGFloat = 56

    /// One button keeps the actions beside the title; menu items show titles.
    var body: some View {
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
            // Large camera photos take a moment to prepare; the spinner replaces
            // the icon so the button keeps its size.
            if isPreparingPhoto {
                ProgressView()
                    .accessibilityLabel(Text("Preparing Photo…"))
            } else {
                Label("More", systemImage: "ellipsis")
            }
        }
    }
}

extension View {
    /// Hides the navigation bar's own title; the gallery header draws it.
    /// The title stays set so pushed screens keep "Watch Gallery" as Back.
    @ViewBuilder
    func phoneGalleryBarTitleHidden() -> some View {
        if #available(iOS 18.0, *) {
            toolbar(removing: .title)
        } else {
            toolbar {
                ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
            }
        }
    }
}
