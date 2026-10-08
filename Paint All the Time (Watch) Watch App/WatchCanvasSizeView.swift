import SwiftUI

/// Draft values stay local until Apply, so dismissing the sheet leaves the drawing intact.
struct WatchCanvasSizeView: View {
    @ObservedObject var controller: CanvasController
    let viewportSize: CGSize
    let displayScale: CGFloat
    @Environment(\.dismiss) private var dismiss
    @State private var width: Double = 1
    @State private var height: Double = 1
    @State private var resolution: Double = 72
    @State private var proportional = true
    @State private var resample = true
    @State private var cropPercent = 90.0
    @State private var cropX = 50.0
    @State private var cropY = 50.0
    @State private var turns = 1
    @State private var preview: CGImage?

    private var original: CGSize { controller.document.size(fallback: viewportSize) }
    private var ratio: Double { original.width / original.height }
    private var maximumPixels: Double { 1024 }
    private var validSize: Bool {
        width >= 1 && height >= 1 && width <= maximumPixels && height <= maximumPixels
    }
    private var cropSize: CGSize {
        CGSize(width: original.width * cropPercent / 100,
               height: original.height * cropPercent / 100)
    }
    private var cropOrigin: CGPoint {
        CGPoint(x: (original.width - cropSize.width) * cropX / 100,
                y: (original.height - cropSize.height) * cropY / 100)
    }

    var body: some View {
        NavigationStack {
            TabView {
                page("Adjust size", icon: "arrow.up.left.and.arrow.down.right") {
                    HStack {
                        Button("50%") { setScale(0.5) }
                        Button("100%") { setScale(1) }
                    }
                    dimension("Width", value: Binding(get: { width }, set: {
                        width = $0
                        if proportional { height = ($0 / ratio).rounded() }
                    }))
                    dimension("Height", value: Binding(get: { height }, set: {
                        height = $0
                        if proportional { width = ($0 * ratio).rounded() }
                    }))
                    Toggle(L10n.text("Scale proportionally"), isOn: $proportional)
                    Toggle(L10n.text("Resample image"), isOn: $resample)
                    Text(L10n.text(resample ? "Scale drawing with canvas" : "Keep drawing at original size"))
                        .font(.caption2).foregroundStyle(.secondary)
                    Stepper(value: Binding(get: { resolution }, set: { next in
                        if resample {
                            width = (width * next / resolution).rounded()
                            height = (height * next / resolution).rounded()
                        }
                        resolution = next
                    }), in: 18...300, step: 18) {
                        Text("\(L10n.text("Resolution")): \(Int(resolution)) DPI")
                    }
                    Text("\(Int(width)) × \(Int(height)) px")
                        .font(.caption).monospacedDigit()
                    if !validSize {
                        Text(L10n.text("Choose dimensions from 1 to 1024 pixels."))
                            .font(.caption2).foregroundStyle(.orange)
                    }
                    Button(L10n.text("Apply")) {
                        controller.adjustCanvas(from: original,
                            to: CGSize(width: width / displayScale, height: height / displayScale),
                            resample: resample, resolution: resolution)
                        dismiss()
                    }.disabled(!validSize)
                }
                page("Crop", icon: "crop") {
                    cropPreview
                    Stepper("\(L10n.text("Keep")): \(Int(cropPercent))%", value: $cropPercent, in: 10...100, step: 5)
                    Stepper("\(L10n.text("Horizontal")): \(Int(cropX))%", value: $cropX, in: 0...100, step: 10)
                    Stepper("\(L10n.text("Vertical")): \(Int(cropY))%", value: $cropY, in: 0...100, step: 10)
                    Text("\(Int(cropSize.width * displayScale)) × \(Int(cropSize.height * displayScale)) px")
                        .font(.caption).monospacedDigit()
                    Text(L10n.text("Trim canvas edges. Hidden strokes remain editable."))
                        .font(.caption2).foregroundStyle(.secondary)
                    Button(L10n.text("Apply")) {
                        controller.adjustCanvas(from: original, to: cropSize,
                                                resample: false, origin: cropOrigin)
                        dismiss()
                    }.disabled(cropPercent == 100)
                }
                page("Rotate", icon: "rotate.right") {
                    Image(systemName: "rectangle.portrait")
                        .font(.system(size: 42)).rotationEffect(.degrees(Double(turns * 90)))
                        .frame(height: 65)
                    Picker(L10n.text("Rotation"), selection: $turns) {
                        Text("90° ↻").tag(1)
                        Text("180°").tag(2)
                        Text("90° ↺").tag(3)
                    }.pickerStyle(.inline).frame(height: 100)
                    Button(L10n.text("Apply")) {
                        let size = turns == 2 ? original : CGSize(width: original.height, height: original.width)
                        controller.adjustCanvas(from: original, to: size, resample: false, quarterTurns: turns)
                        dismiss()
                    }
                }
            }
            .tabViewStyle(.page)
            .navigationTitle(L10n.text("Canvas size"))
            .task {
                preview = WatchBitmapRenderer.render(document: controller.document, size: original,
                    scale: min(1, 160 / max(original.width, original.height)))
            }
            .onAppear {
                width = (original.width * displayScale).rounded()
                height = (original.height * displayScale).rounded()
                resolution = controller.document.resolution
            }
        }
    }

    private var cropPreview: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / original.width, geometry.size.height / original.height)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(.gray.opacity(0.3))
                if let preview {
                    Image(decorative: preview, scale: 1).resizable()
                }
                Rectangle().stroke(.green, lineWidth: 2)
                    .frame(width: cropSize.width * scale, height: cropSize.height * scale)
                    .offset(x: cropOrigin.x * scale, y: cropOrigin.y * scale)
            }
            .frame(width: original.width * scale, height: original.height * scale)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(height: 65).accessibilityLabel(L10n.text("Crop area"))
    }

    private func setScale(_ factor: Double) {
        width = max(1, (original.width * displayScale * factor).rounded())
        height = max(1, (original.height * displayScale * factor).rounded())
    }

    private func dimension(_ title: String, value: Binding<Double>) -> some View {
        Stepper(value: value, in: 1...maximumPixels, step: 1) {
            Text("\(L10n.text(title)): \(Int(value.wrappedValue)) px")
                .monospacedDigit()
        }
    }

    private func page<Content: View>(_ title: String, icon: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(spacing: 10) {
                Label(L10n.text(title), systemImage: icon).font(.headline)
                content()
            }.padding(.horizontal, 8).padding(.bottom, 28)
        }
    }
}
