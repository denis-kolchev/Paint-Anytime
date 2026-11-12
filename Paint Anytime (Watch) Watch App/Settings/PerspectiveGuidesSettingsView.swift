import SwiftUI

/// Previews the guides over the current drawing. The carousel picks which value the
/// value row and the Digital Crown adjust; the column on the right picks the preset.
struct PerspectiveGuidesSettingsView: View {
    private enum Page: Int, CaseIterable {
        case viewAngle, tilt, rays

        var title: String {
            switch self {
            case .viewAngle: "View angle"
            case .tilt: "Tilt"
            case .rays: "Rays"
            }
        }

        var step: Double { self == .rays ? 2 : 5 }
        var unit: String { self == .rays ? "" : "°" }
    }

    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @ObservedObject var controller: CanvasController
    let viewportSize: CGSize
    @ObservedObject var guides = PerspectiveGuides.shared
    @FocusState private var crownFocused: Bool
    @State private var selectedPage = Page.viewAngle
    @State private var preview: CGImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection

    private static let tiltRange: ClosedRange<Double> = -180...180

    private var paperSize: CGSize {
        let size = controller.document.size(fallback: viewportSize)
        return size.width > 0 && size.height > 0 ? size : CGSize(width: 200, height: 240)
    }

    /// One vanishing point has no side points for the view angle to place.
    private var pages: [Page] { guides.preset == .one ? [.tilt, .rays] : Page.allCases }
    private var page: Page { pages.contains(selectedPage) ? selectedPage : pages[0] }
    private var pageIndex: Binding<Int> {
        Binding(get: { pages.firstIndex(of: page) ?? 0 },
                set: { selectedPage = pages[min(pages.count - 1, max(0, $0))] })
    }

    private var range: ClosedRange<Double> {
        switch page {
        case .viewAngle: PerspectiveGuides.viewAngleRange
        case .tilt: Self.tiltRange
        case .rays: Double(PerspectiveGuides.rayCountRange.lowerBound)...Double(PerspectiveGuides.rayCountRange.upperBound)
        }
    }

    private var value: Double {
        switch page {
        case .viewAngle: guides.viewAngle
        case .tilt: (guides.rotation * 180 / .pi).rounded()
        case .rays: Double(guides.rayCount)
        }
    }

    private var valueText: String { "\(Int(value))\(page.unit)" }

    private func setValue(_ next: Double) {
        let value = min(range.upperBound, max(range.lowerBound, next))
        switch page {
        case .viewAngle:
            guides.viewAngle = value
        case .tilt:
            guides.rotation = PerspectiveGuides.normalizedRotation(value * .pi / 180)
            guides.savePlacement()
        case .rays:
            guides.setRayCount(Int(value.rounded()))
        }
    }

    // The Crown moves in the same increments as the buttons.
    private var stepRange: ClosedRange<Double> { 0...((range.upperBound - range.lowerBound) / page.step) }
    private var stepValue: Binding<Double> {
        Binding(get: { ((value - range.lowerBound) / page.step).rounded() },
                set: { setValue(range.lowerBound + $0.rounded() * page.step) })
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let size = paperSize
                let slotHeight = max(0, geometry.size.height / 3)
                let availableWidth = max(0, geometry.size.width - 52)
                let scale = min(availableWidth / size.width, geometry.size.height / size.height)
                let previewSize = CGSize(width: size.width * scale, height: size.height * scale)
                // Anchor the paper's bottom edge to the value row, as in layer settings.
                let paperOrigin = CGPoint(x: (availableWidth - previewSize.width) / 2,
                                          y: geometry.size.height - previewSize.height)
                let previewRight = paperOrigin.x + previewSize.width
                let controlsCenterX = (previewRight + geometry.size.width + 8) / 2
                ZStack(alignment: .topLeading) {
                    paperPreview
                        .frame(width: previewSize.width, height: previewSize.height)
                        .overlay { Rectangle().strokeBorder(.white.opacity(0.25), lineWidth: 1) }
                        .offset(x: paperOrigin.x, y: paperOrigin.y)

                    // Guides continue past the paper, as on the canvas.
                    PerspectiveGuidesOverlay(layout: guides.layout(paperSize: size),
                        canvasToScreen: CGAffineTransform(translationX: paperOrigin.x, y: paperOrigin.y)
                            .scaledBy(x: scale, y: scale),
                        activeRuler: nil, showsHandles: false)
                        .frame(width: availableWidth, height: geometry.size.height)
                        .clipped()
                        .opacity(guides.isEnabled ? 1 : 0)

                    VStack(spacing: 0) {
                        presetButton(nil, height: slotHeight)
                        ForEach(PerspectivePreset.allCases) { preset in
                            presetButton(preset, height: slotHeight)
                        }
                    }
                    .frame(width: 44, height: geometry.size.height)
                    .buttonStyle(.plain)
                    .position(x: controlsCenterX, y: geometry.size.height / 2)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }

            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    stepButton("minus", by: -page.step)
                    Text(verbatim: valueText)
                        .font(.system(size: 14, weight: .semibold))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel(L10n.text(page.title))
                        .accessibilityValue(valueText)
                        .accessibilityAdjustableAction { direction in
                            switch direction {
                            case .increment: setValue(value + page.step)
                            case .decrement: setValue(value - page.step)
                            @unknown default: break
                            }
                        }
                    stepButton("plus", by: page.step)
                }
                .environment(\.layoutDirection, .leftToRight)
                .frame(height: 28)
                .padding(.top, 4)

                CanvasResizeCarousel(selection: pageIndex, titles: pages.map(\.title))
                    .frame(height: 28)
            }
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 8)
        .ignoresSafeArea(.container, edges: .bottom)
        .contentShape(Rectangle())
        .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { value in
            guard abs(value.translation.width) > abs(value.translation.height) else { return }
            let forward = (value.translation.width < 0) == (layoutDirection == .leftToRight)
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                pageIndex.wrappedValue += forward ? 1 : -1
            }
        })
        .focusable()
        .focused($crownFocused)
        .modifier(SteppedCrownModifier(value: stepValue, range: stepRange,
                                      sensitivity: .low, crownUnitsPerStep: 1, context: page.rawValue))
        .onChange(of: page) { _, _ in crownFocused = true }
        .navigationTitle(L10n.text("Perspective"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    PerspectiveGuidesInformationView()
                } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel(L10n.text("About perspective guides"))
            }
        }
        .task {
            crownFocused = true
            guard preview == nil else { return }
            let size = paperSize
            preview = WatchBitmapRenderer.render(document: controller.document, size: size,
                scale: min(1, 200 / max(size.width, size.height)))
        }
    }

    @ViewBuilder
    private var paperPreview: some View {
        if let preview {
            Image(decorative: preview, scale: 1).resizable()
        } else {
            CanvasBackgroundPreview(color: controller.document.effectiveBackgroundColor)
        }
    }

    /// 0 hides the guides; any other number shows them with that many vanishing points.
    private func presetButton(_ preset: PerspectivePreset?, height: CGFloat) -> some View {
        let isSelected = preset.map { guides.isEnabled && guides.preset == $0 } ?? !guides.isEnabled
        return Button {
            if let preset { guides.preset = preset }
            guides.isEnabled = preset != nil
            crownFocused = true
        } label: {
            Text(verbatim: "\(preset?.rawValue ?? 0)")
                .font(.system(size: 15, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(isSelected ? Color.black : Color.white)
                .frame(width: 28, height: 28)
                .background {
                    Circle().fill(isSelected ? Color.accentColor : Color.white.opacity(0.12))
                }
                .overlay {
                    Circle().strokeBorder(isSelected ? Color.accentColor : Color.white.opacity(0.35),
                                          lineWidth: 1.5)
                }
                .frame(width: 44, height: height)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(preset?.title ?? L10n.text("Guides hidden"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func stepButton(_ symbol: String, by delta: Double) -> some View {
        Button {
            setValue(value + delta)
            crownFocused = true
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
        .disabled(!range.contains(value + delta))
        .accessibilityLabel(L10n.text(page.title) + (delta > 0 ? " +" : " −") + "\(Int(abs(delta)))\(page.unit)")
    }
}

private struct PerspectiveGuidesInformationView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode

    var body: some View {
        ScrollView {
            Text(L10n.text("Guides help you draw in perspective. A stroke that starts on a guide follows it or runs toward a vanishing point. The number sets how many vanishing points there are; 0 hides the guides."))
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
        }
        .navigationTitle(L10n.text("Perspective"))
    }
}
