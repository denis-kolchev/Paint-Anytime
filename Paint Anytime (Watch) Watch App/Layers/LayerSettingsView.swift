import SwiftUI

struct LayerSettingsView: View {
    @ObservedObject var controller: CanvasController
    let layerID: UUID?
    let canvasSize: CGSize
    @FocusState private var crownFocused: Bool
    @State private var opacity: Double = 1
    @State private var previewSideInset: CGFloat = 0
    @State private var showsAllLayers = false
    @State private var transparencyFeedbackID: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var showsColorEditor = false
    @State private var showsDeleteConfirmation = false
    private var layer: CanvasLayer? {
        guard let layerID else {
            return CanvasLayer(name: L10n.text("Canvas"),
                               isVisible: controller.document.backgroundIsVisible,
                               opacity: controller.document.backgroundColor.w)
        }
        return controller.document.layers.first { $0.id == layerID }
    }

    private func updateLayer(_ edit: (inout CanvasLayer) -> Void) {
        if let layerID {
            controller.updateLayer(layerID, edit)
        } else if var updated = layer {
            edit(&updated)
            if updated.isVisible != controller.document.backgroundIsVisible {
                controller.setBackgroundVisible(updated.isVisible)
            }
            if updated.opacity != controller.document.backgroundColor.w {
                var color = controller.document.backgroundColor
                color.w = updated.opacity
                controller.setBackgroundColor(color)
            }
        }
    }

    var body: some View {
        if let layer {
            VStack(spacing: 0) {
                GeometryReader { geometry in
                    let size = canvasSize.width > 0 && canvasSize.height > 0
                        ? canvasSize : CGSize(width: 200, height: 240)
                    // The navigation safe area bounds the top; the opacity row bounds the bottom.
                    // Equal slots keep all three controls inside that space on every watch size.
                    let controlHeight = max(0, geometry.size.height / 3)
                    let availableWidth = max(0, geometry.size.width - 52)
                    let scale = min(availableWidth / size.width, geometry.size.height / size.height)
                    let previewWidth = size.width * scale
                    let previewRight = (availableWidth + previewWidth) / 2
                    // Include the outer horizontal padding in local coordinates so the
                    // controls travel with the menu throughout navigation and dismissal.
                    let menuRight = geometry.size.width + 8
                    let controlsCenterX = (previewRight + menuRight) / 2
                    ZStack(alignment: .topLeading) {
                        ZStack {
                            layerPreview(layer)
                        }
                            .frame(width: size.width * scale, height: size.height * scale)
                            .overlay { Rectangle().strokeBorder(.white.opacity(0.25), lineWidth: 1) }
                            .overlay {
                                if let transparencyFeedbackID {
                                    TransparencyBoundaryFeedback(layer: layer, canvasSize: size) {
                                        if self.transparencyFeedbackID == transparencyFeedbackID {
                                            self.transparencyFeedbackID = nil
                                        }
                                    }
                                        .id(transparencyFeedbackID)
                                        .allowsHitTesting(false)
                                        .accessibilityHidden(true)
                                }
                            }
                            .accessibilityLabel(showsAllLayers ? L10n.text("All layers") : layer.displayName)
                            // Anchor the paper's bottom edge to the spacing above the opacity row.
                            .position(x: availableWidth / 2,
                                      y: geometry.size.height - size.height * scale / 2)

                        VStack(spacing: 0) {
                            Button {
                                updateLayer { $0.isVisible.toggle() }
                                crownFocused = true
                            } label: {
                                Image(systemName: layer.isVisible ? "eye.fill" : "eye.slash.fill")
                                    .font(.system(size: 20))
                                    .frame(width: 44, height: controlHeight)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel(L10n.text("Visible"))
                            .accessibilityAddTraits(layer.isVisible ? [.isSelected] : [])

                            if layerID == nil {
                                Button { showsColorEditor = true } label: {
                                    let color = controller.document.backgroundColor
                                    Circle()
                                        .fill(Color(.sRGB, red: Double(color.x), green: Double(color.y), blue: Double(color.z)))
                                        .frame(width: 23, height: 23)
                                        .overlay { Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1) }
                                        .frame(width: 44, height: controlHeight)
                                        .contentShape(Rectangle())
                                }
                                .accessibilityLabel(L10n.text("Canvas color"))
                            } else {
                                Button {
                                    updateLayer { $0.locksTransparency.toggle() }
                                    transparencyFeedbackID = UUID()
                                    crownFocused = true
                                } label: {
                                    LayerTransparencyLockIcon(isLocked: layer.locksTransparency)
                                        .font(.system(size: 23))
                                        .foregroundStyle(.white)
                                        .frame(width: 44, height: controlHeight)
                                        .contentShape(Rectangle())
                                }
                                .accessibilityLabel(L10n.text("Lock transparency"))
                                .accessibilityAddTraits(layer.locksTransparency ? [.isSelected] : [])
                            }

                            Button {
                                transparencyFeedbackID = nil
                                showsAllLayers.toggle()
                                crownFocused = true
                            } label: {
                                Image(systemName: "square.3.layers.3d")
                                    .font(.system(size: 21))
                                    .foregroundStyle(showsAllLayers ? Color.white : Color.gray)
                                    .frame(width: 44, height: controlHeight)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel(L10n.text(showsAllLayers ? "Show only this layer" : "Show all layers"))
                            .accessibilityValue(L10n.text(showsAllLayers ? "All layers" : "Only this layer"))
                            .accessibilityAddTraits(showsAllLayers ? [.isSelected] : [])
                        }
                        .frame(width: 44, height: geometry.size.height)
                        .buttonStyle(.plain)
                        .position(x: controlsCenterX, y: geometry.size.height / 2)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        let width = max(0, proxy.size.width - 52)
                        let fit = min(width / size.width, proxy.size.height / size.height)
                        return max(0, (width - size.width * fit) / 2)
                    } action: { inset in
                        previewSideInset = inset
                    }
                }

                VStack(spacing: 0) {
                    HStack {
                        Text(L10n.text("Opacity"))
                        Spacer(minLength: 4)
                        Text(verbatim: L10n.percent(opacity))
                            .monospacedDigit()
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, previewSideInset)
                    .frame(height: 16)
                    .padding(.vertical, 4)

                    HStack(spacing: 4) {
                        opacityButton("minus", amount: -1)
                        WatchGradientSlider(
                            value: Binding(get: { opacity * 100 }, set: { setOpacity($0) }),
                            maximum: 100, colors: [.white, .black],
                            thumbColor: Color(white: 1 - opacity))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(L10n.text("Opacity"))
                            .accessibilityValue(L10n.percent(opacity))
                            .accessibilityAdjustableAction { direction in
                                switch direction {
                                case .increment: setOpacity(opacity * 100 + 1)
                                case .decrement: setOpacity(opacity * 100 - 1)
                                @unknown default: break
                                }
                            }
                        opacityButton("plus", amount: 1)
                    }
                    .environment(\.layoutDirection, .leftToRight)
                    .frame(height: 28)
                    .padding(.horizontal, 4)
                }
                .padding(.bottom, 8)
            }
            .padding(.horizontal, 8)
            .ignoresSafeArea(.container, edges: .bottom)
            .focusable()
            .focused($crownFocused)
            .modifier(SteppedCrownModifier(
                value: Binding(
                    get: { (opacity * 100).rounded() },
                    set: { opacity = $0 / 100 }),
                range: 0...100))
            .navigationTitle(layer.displayName)
            .toolbar {
                if layerID != nil, controller.document.layers.count > 1 {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .destructive) {
                            showsDeleteConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel(L10n.text("Delete"))
                    }
                }
            }
            .fullScreenCover(isPresented: $showsDeleteConfirmation) {
                DestructiveConfirmationView(title: L10n.text("Delete this layer?"), confirmTitle: L10n.text("Delete")) {
                    showsDeleteConfirmation = false
                } onConfirm: {
                    showsDeleteConfirmation = false
                    guard let layerID, controller.document.layers.count > 1 else { return }
                    controller.deleteLayer(layerID)
                    dismiss()
                }
            }
            .navigationDestination(isPresented: $showsColorEditor) {
                CustomInkEditor(initialColor: controller.document.backgroundColor, saveTitle: "Done") { preset in
                    var color = preset.rgba
                    color.w = Float(opacity)
                    controller.setBackgroundColor(color)
                }
            }
            .onAppear {
                opacity = Double(layer.opacity)
                crownFocused = true
            }
            .onDisappear {
                transparencyFeedbackID = nil
                if let currentLayer = self.layer, Float(opacity) != currentLayer.opacity {
                    updateLayer { $0.opacity = Float(opacity) }
                }
            }
        }
    }

    @ViewBuilder
    private func layerPreview(_ layer: CanvasLayer) -> some View {
        if showsAllLayers {
            ZStack {
                CanvasBackgroundPreview(color: previewBackgroundColor)
                ForEach(controller.document.layers) { previewLayer in
                    LayerThumbnail(
                        layer: previewLayer, canvasSize: canvasSize,
                        previewOpacity: previewLayer.isVisible
                            ? (previewLayer.id == layerID ? opacity : Double(previewLayer.opacity)) : 0,
                        maximumPixelDimension: 400, showsCheckerboard: false)
                }
            }
        } else if layerID == nil {
            CanvasBackgroundPreview(color: previewBackgroundColor)
        } else {
            LayerThumbnail(layer: layer, canvasSize: canvasSize,
                           previewOpacity: layer.isVisible ? opacity : 0,
                           maximumPixelDimension: 400)
        }
    }

    private var previewBackgroundColor: SIMD4<Float> {
        var color = controller.document.effectiveBackgroundColor
        if layerID == nil, controller.document.backgroundIsVisible { color.w = Float(opacity) }
        return color
    }

    private func setOpacity(_ percent: Double) {
        opacity = min(100, max(0, percent.rounded())) / 100
        crownFocused = true
    }

    private func opacityButton(_ symbol: String, amount: Double) -> some View {
        Button { setOpacity(opacity * 100 + amount) } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(amount > 0 ? opacity >= 1 : opacity <= 0)
        .accessibilityLabel(L10n.text("Opacity") + (amount > 0 ? " +1" : " −1"))
    }

}
