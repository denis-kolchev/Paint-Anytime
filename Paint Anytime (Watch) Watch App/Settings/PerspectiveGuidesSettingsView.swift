import SwiftUI

/// Previews the guides over the current drawing. The carousel picks which angle the
/// value row and the Digital Crown adjust; the column on the right picks the preset.
struct PerspectiveGuidesSettingsView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @ObservedObject var controller: CanvasController
    let viewportSize: CGSize
    @ObservedObject var guides = PerspectiveGuides.shared
    @FocusState private var crownFocused: Bool
    @State private var page = 0
    @State private var preview: CGImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection

    private static let titles = ["View angle", "Tilt"]
    private static let step = 5.0
    private static let tiltRange: ClosedRange<Double> = -180...180

    private var paperSize: CGSize {
        let size = controller.document.size(fallback: viewportSize)
        return size.width > 0 && size.height > 0 ? size : CGSize(width: 200, height: 240)
    }

    private var range: ClosedRange<Double> { page == 0 ? PerspectiveGuides.viewAngleRange : Self.tiltRange }

    private var degrees: Double {
        page == 0 ? guides.viewAngle : (guides.rotation * 180 / .pi).rounded()
    }

    private func setDegrees(_ next: Double) {
        let value = min(range.upperBound, max(range.lowerBound, next))
        if page == 0 {
            guides.viewAngle = value
        } else {
            guides.rotation = PerspectiveGuides.normalizedRotation(value * .pi / 180)
            guides.savePlacement()
        }
    }

    // The Crown moves in the same 5° increments as the buttons.
    private var stepRange: ClosedRange<Double> { 0...((range.upperBound - range.lowerBound) / Self.step) }
    private var stepValue: Binding<Double> {
        Binding(get: { ((degrees - range.lowerBound) / Self.step).rounded() },
                set: { setDegrees(range.lowerBound + $0.rounded() * Self.step) })
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
                    stepButton("minus", by: -Self.step)
                    Text(verbatim: "\(Int(degrees))°")
                        .font(.system(size: 14, weight: .semibold))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel(L10n.text(Self.titles[page]))
                        .accessibilityValue("\(Int(degrees))°")
                        .accessibilityAdjustableAction { direction in
                            switch direction {
                            case .increment: setDegrees(degrees + Self.step)
                            case .decrement: setDegrees(degrees - Self.step)
                            @unknown default: break
                            }
                        }
                    stepButton("plus", by: Self.step)
                }
                .environment(\.layoutDirection, .leftToRight)
                .frame(height: 28)
                .padding(.top, 4)

                CanvasResizeCarousel(selection: $page, titles: Self.titles)
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
                page = min(Self.titles.count - 1, max(0, page + (forward ? 1 : -1)))
            }
        })
        .focusable()
        .focused($crownFocused)
        .modifier(SteppedCrownModifier(value: stepValue, range: stepRange,
                                      sensitivity: .low, crownUnitsPerStep: 1, context: page))
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
            setDegrees(degrees + delta)
            crownFocused = true
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
        .disabled(!range.contains(degrees + delta))
        .accessibilityLabel(L10n.text(Self.titles[page]) + (delta > 0 ? " +5°" : " −5°"))
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
