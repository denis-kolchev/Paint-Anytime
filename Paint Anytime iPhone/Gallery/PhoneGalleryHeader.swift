import SwiftUI
import UIKit

/// Stays outside the scroll content so the title never collapses into a toolbar.
struct PhoneGalleryHeader: View {
    /// The More menu when it sits beside the title rather than in a system bar.
    var menu: PhoneGalleryMoreMenu?
    /// Window-space center of the navigation bar's More button. When set, the
    /// header ignores the top safe area and centers the title on that line.
    var titleMidY: CGFloat?
    @State private var titleHeight: CGFloat = 0

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
        .padding(.top, titleMidY.map { max(0, $0 - titleHeight / 2) } ?? 8)
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
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { titleHeight = $0 }
            .accessibilityAddTraits(.isHeader)
            .layoutPriority(1)
    }
}

/// Reports the vertical center of the enclosing navigation bar in window
/// coordinates, where its bar buttons are centered. SwiftUI hosts toolbar
/// menus as UIKit bar buttons, so the button itself cannot be measured.
struct PhoneNavigationBarMidYReader: UIViewRepresentable {
    @Binding var midY: CGFloat?

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.isUserInteractionEnabled = false
        view.onChange = { midY = $0 }
        return view
    }

    func updateUIView(_ view: ReaderView, context: Context) {
        view.onChange = { midY = $0 }
        view.report()
    }

    final class ReaderView: UIView {
        var onChange: ((CGFloat) -> Void)?
        private var reported: CGFloat?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
            // The bar may finish its own layout after this view appears.
            DispatchQueue.main.async { [weak self] in self?.report() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        // Showing the bar, rotating or folding changes the top safe area.
        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            report()
        }

        func report() {
            guard window != nil else { return }
            let controller = sequence(first: self as UIResponder, next: \.next)
                .lazy.compactMap { ($0 as? UIViewController)?.navigationController }.first
            guard let bar = controller?.navigationBar, !bar.isHidden, bar.window != nil else { return }
            let midY = bar.convert(CGPoint(x: bar.bounds.midX, y: bar.bounds.midY), to: nil).y
            guard reported.map({ abs($0 - midY) > 0.5 }) ?? true else { return }
            reported = midY
            // UIKit layout can run during a SwiftUI update; publish afterwards.
            DispatchQueue.main.async { [weak self] in self?.onChange?(midY) }
        }
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
    /// True while a Photoshop file is converted; its progress shows in the gallery.
    var isImportingProject = false
    /// Debug builds only: one zoom step (5 → 3 → 1 columns and back). Nil hides the
    /// item; a nil step in the other direction still shows it, disabled at the limit.
    var zoomIn: (() -> Void)?
    var zoomOut: (() -> Void)?
    var showsZoomItems = false

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
                Label("Import File", systemImage: "square.and.arrow.down")
            }
            .disabled(isImportingProject)
            Divider()
            Button(action: synchronize) {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
            }
            if showsZoomItems {
                Divider()
                Button { zoomIn?() } label: {
                    Label("Zoom In", systemImage: "plus.magnifyingglass")
                }
                .disabled(zoomIn == nil)
                Button { zoomOut?() } label: {
                    Label("Zoom Out", systemImage: "minus.magnifyingglass")
                }
                .disabled(zoomOut == nil)
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
