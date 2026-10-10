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
    @State private var turns = 0
    @State private var selectedPage = 0
    @FocusState private var focusedAdjustment: String?
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
            GeometryReader { geometry in
                TabView(selection: $selectedPage) {
                    page("Adjust size", mode: 0, height: geometry.size.height) { rowHeight in
                        adjustment("Width", value: Binding(get: { width }, set: {
                            width = $0
                            if proportional { height = ($0 / ratio).rounded() }
                        }), range: 1...maximumPixels, step: 1, suffix: "px")
                        adjustment("Height", value: Binding(get: { height }, set: {
                            height = $0
                            if proportional { width = ($0 * ratio).rounded() }
                        }), range: 1...maximumPixels, step: 1, suffix: "px")
                        adjustment("Resolution", value: Binding(get: { resolution }, set: { next in
                            if resample {
                                width = (width * next / resolution).rounded()
                                height = (height * next / resolution).rounded()
                            }
                            resolution = next
                        }), range: 18...300, step: 18, suffix: "DPI")
                        HStack(spacing: 4) {
                            option("Scale proportionally", value: $proportional)
                            option("Resample image", value: $resample)
                        }.frame(height: rowHeight)
                    }.tag(0)
                    page("Crop", mode: 1, height: geometry.size.height) { _ in
                        adjustment("Keep", value: $cropPercent, range: 10...100, step: 5, suffix: "%")
                        adjustment("Horizontal", value: $cropX, range: 0...100, step: 10, suffix: "%")
                        adjustment("Vertical", value: $cropY, range: 0...100, step: 10, suffix: "%")
                        Text(L10n.text("Trim canvas edges. Hidden strokes remain editable."))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .lineLimit(2).minimumScaleFactor(0.8)
                            .frame(maxHeight: .infinity)
                    }.tag(1)
                    page("Rotate", mode: 2, height: geometry.size.height) { _ in
                        ForEach(0...3, id: \.self) { turn in
                            compactButton(turn == 0 ? "0°" : turn == 1 ? "90° ↻" : turn == 2 ? "180°" : "90° ↺") {
                                turns = turn
                            }
                            .background(turns == turn ? Color.accentColor.opacity(0.35) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityAddTraits(turns == turn ? .isSelected : [])
                        }
                        Spacer(minLength: 0)
                    }.tag(2)
                }
                .tabViewStyle(.page)
            }
            .onChange(of: selectedPage) { _, page in
                focusedAdjustment = page == 0 ? "Width" : page == 1 ? "Keep" : nil
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: applyChanges) {
                        Image(systemName: "checkmark").foregroundStyle(.green)
                    }
                    .watchToolbarButtonStyle()
                    .disabled(selectedPage == 0 && !validSize)
                    .accessibilityLabel(L10n.text("Apply"))
                    .accessibilityHint(selectedPage == 0 && !validSize
                        ? L10n.text("Choose dimensions from 1 to 1024 pixels.") : "")
                }
                // The system toolbar owns hit testing in the clock/sheet chrome.
                // A content overlay in that area can be visible but untappable.
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .watchToolbarButtonStyle()
                        .accessibilityLabel(L10n.text("Close"))
                }
            }
            .ignoresSafeArea()
            .task {
                preview = WatchBitmapRenderer.render(document: controller.document, size: original,
                    scale: min(1, 160 / max(original.width, original.height)))
                width = (original.width * displayScale).rounded()
                height = (original.height * displayScale).rounded()
                resolution = controller.document.resolution
                focusedAdjustment = "Width"
            }
        }
    }

    private func canvasPreview(mode: Int) -> some View {
        GeometryReader { geometry in
            let target = mode == 0
                ? CGSize(width: width / displayScale, height: height / displayScale)
                : mode == 2 && turns % 2 != 0
                    ? CGSize(width: original.height, height: original.width) : original
            let scale = min(geometry.size.width / max(1, target.width),
                            geometry.size.height / max(1, target.height))
            ZStack {
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(.gray.opacity(0.3))
                    if let preview {
                        Image(decorative: preview, scale: 1).resizable()
                            .frame(width: (mode == 0 && resample ? target.width : original.width) * scale,
                                   height: (mode == 0 && resample ? target.height : original.height) * scale)
                            .rotationEffect(.degrees(mode == 2 ? Double(turns * 90) : 0))
                            .frame(width: target.width * scale, height: target.height * scale,
                                   alignment: mode == 0 ? .topLeading : .center)
                    }
                    if mode == 1 {
                        Rectangle().stroke(.green, lineWidth: 1.5)
                            .frame(width: cropSize.width * scale, height: cropSize.height * scale)
                            .offset(x: cropOrigin.x * scale, y: cropOrigin.y * scale)
                    }
                }
                .frame(width: target.width * scale, height: target.height * scale)
                .clipped()
                .overlay(Rectangle().stroke(.white.opacity(0.5), lineWidth: 0.5))
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityLabel(L10n.text(mode == 1 ? "Crop area" : "Canvas size"))
    }

    private func compactButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func option(_ title: String, value: Binding<Bool>) -> some View {
        Button { value.wrappedValue.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: value.wrappedValue ? "checkmark.circle.fill" : "circle")
                Text(L10n.text(title)).lineLimit(2).minimumScaleFactor(0.75)
            }.font(.system(size: 10))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(value.wrappedValue ? Color.accentColor : .secondary)
        .accessibilityLabel(L10n.text(title))
        .accessibilityValue(Text(value.wrappedValue ? "✓" : "−"))
        .accessibilityAddTraits(value.wrappedValue ? .isSelected : [])
    }

    private func adjustment(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                            step: Double, suffix: String) -> some View {
        HStack(spacing: 4) {
            Text(L10n.text(title)).lineLimit(1).minimumScaleFactor(0.65)
                .frame(maxWidth: .infinity, alignment: .leading)
            compactButton("−") {
                focusedAdjustment = title
                value.wrappedValue = max(range.lowerBound, value.wrappedValue - step)
            }
                .frame(width: 25).disabled(value.wrappedValue <= range.lowerBound)
                .accessibilityLabel("− " + L10n.text(title))
            Text("\(Int(value.wrappedValue)) \(suffix)")
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                .frame(width: 53)
                .foregroundStyle(range.contains(value.wrappedValue) ? Color.primary : .orange)
            compactButton("+") {
                focusedAdjustment = title
                value.wrappedValue = min(range.upperBound, value.wrappedValue + step)
            }
                .frame(width: 25).disabled(value.wrappedValue >= range.upperBound)
                .accessibilityLabel("+ " + L10n.text(title))
        }
        .frame(maxHeight: .infinity)
        .background(focusedAdjustment == title ? Color.accentColor.opacity(0.18) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { focusedAdjustment = title }
        .focusable(selectedPage == (title == "Width" || title == "Height" || title == "Resolution" ? 0 : 1))
        .focused($focusedAdjustment, equals: title)
        .modifier(SteppedCrownModifier(
            value: Binding(get: { (value.wrappedValue - range.lowerBound) / step }, set: { position in
                guard focusedAdjustment == title else { return }
                value.wrappedValue = min(range.upperBound, max(range.lowerBound,
                    range.lowerBound + position * step))
            }),
            range: 0...((range.upperBound - range.lowerBound) / step).rounded(.up),
            sensitivity: .low, crownUnitsPerStep: 1, context: selectedPage
        ))
        .accessibilityElement(children: .contain)
    }

    private func applyChanges() {
        switch selectedPage {
        case 0:
            guard validSize else { return }
            controller.adjustCanvas(from: original,
                to: CGSize(width: width / displayScale, height: height / displayScale),
                resample: resample, resolution: resolution)
        case 1:
            if cropPercent != 100 {
                controller.adjustCanvas(from: original, to: cropSize,
                                        resample: false, origin: cropOrigin)
            }
        default:
            if turns != 0 {
                let size = turns % 2 == 0 ? original : CGSize(width: original.height, height: original.width)
                controller.adjustCanvas(from: original, to: size, resample: false, quarterTurns: turns)
            }
        }
        dismiss()
    }

    private func page<Content: View>(_ title: String, mode: Int, height: CGFloat,
                                    @ViewBuilder content: (CGFloat) -> Content) -> some View {
        let rowHeight = max(20, min(28, (height - 125) / 5))
        return VStack(spacing: 3) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text(title)).font(.system(size: 12, weight: .semibold))
                        .lineLimit(2).minimumScaleFactor(0.8)
                    Text(mode == 0 ? "\(Int(width)) × \(Int(self.height)) px"
                         : mode == 1 ? "\(Int(cropSize.width * displayScale)) × \(Int(cropSize.height * displayScale)) px"
                         : "\(Int((turns % 2 == 0 ? original.width : original.height) * displayScale)) × \(Int((turns % 2 == 0 ? original.height : original.width) * displayScale)) px")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    if mode == 0 {
                        HStack(spacing: 4) {
                            compactButton("50%") { setScale(0.5) }
                            compactButton("100%") { setScale(1) }
                        }.frame(height: 18)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                canvasPreview(mode: mode).frame(width: 52, height: 44)
            }.frame(height: 52)
            content(rowHeight)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .padding(.top, 40)
        .padding(.bottom, 22)
        .frame(height: height)
    }

    private func setScale(_ factor: Double) {
        width = max(1, (original.width * displayScale * factor).rounded())
        height = max(1, (original.height * displayScale * factor).rounded())
    }

}
