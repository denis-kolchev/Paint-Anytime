import SwiftUI

/// How the canvas is shown on screen, without changing the drawing or its saved file.
/// App-wide options; more display aids belong here as they appear. Each mode shows its
/// idea as an icon; what they do is explained behind the info button.
struct DisplaySettingsView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @AppStorage(CanvasPixelView.storageKey) private var pixelMode = CanvasPixelView.Mode.smooth

    var body: some View {
        List {
            Section {
                ForEach(CanvasPixelView.Mode.allCases, id: \.rawValue) { mode in
                    Button {
                        pixelMode = mode
                    } label: {
                        HStack {
                            PixelModeIcon(mode: mode)
                            Text(mode.title)
                            Spacer()
                            if pixelMode == mode {
                                Image(systemName: "checkmark").foregroundStyle(.green)
                            }
                        }
                    }
                    .accessibilityAddTraits(pixelMode == mode ? .isSelected : [])
                }
            } header: {
                Text(L10n.text("When zoomed in"))
            }
        }
        .navigationTitle(L10n.text("Display"))
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    DisplayModesInformationView()
                } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel(L10n.text("About display modes"))
            }
        }
    }
}

/// What each mode does, opened from the Display info button.
private struct DisplayModesInformationView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(CanvasPixelView.Mode.allCases, id: \.rawValue) { mode in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            PixelModeIcon(mode: mode)
                            Text(mode.title).font(.headline)
                        }
                        Text(mode.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
        .navigationTitle(L10n.text("Display"))
    }
}

/// The mode's idea on one stroke of the plain round brush, in the style of the colour
/// blending and palette icons (a small square of paper): drawn smooth, as the squares
/// of its pixels, or (Auto) smooth on the left turning into pixels on the right. The
/// pixels carry their partial coverage, as zoomed-in pixels of a real stroke do.
struct PixelModeIcon: View {
    let mode: CanvasPixelView.Mode
    @ScaledMetric(relativeTo: .body) private var side = 28.0
    /// Pixels per side of the pixelated stroke.
    private static let cells = 8
    /// Samples per pixel side for its coverage.
    private static let samples = 4
    private static let paper = Color(white: 0.96)
    private static let ink = Color(red: 0.16, green: 0.33, blue: 0.86)

    /// An S-shaped stroke across the square, with round caps like the round brush.
    private static func stroke(in size: CGSize) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: size.width * 0.18, y: size.height * 0.74))
        path.addCurve(to: CGPoint(x: size.width * 0.82, y: size.height * 0.26),
                      control1: CGPoint(x: size.width * 0.48, y: size.height * 1.06),
                      control2: CGPoint(x: size.width * 0.52, y: size.height * -0.06))
        return path.strokedPath(StrokeStyle(lineWidth: size.width * 0.2, lineCap: .round, lineJoin: .round))
    }

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Self.paper))
            let stroke = Self.stroke(in: size)
            let half = CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
            if mode != .pixels {
                var smooth = context
                if mode == .auto { smooth.clip(to: Path(CGRect(x: 0, y: 0, width: size.width / 2, height: size.height))) }
                smooth.fill(stroke, with: .color(Self.ink))
            }
            guard mode != .smooth else { return }
            let cell = size.width / CGFloat(Self.cells)
            let step = cell / CGFloat(Self.samples)
            for row in 0..<Self.cells {
                for column in 0..<Self.cells {
                    let square = CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)
                    if mode == .auto && !half.contains(CGPoint(x: square.midX, y: square.midY)) { continue }
                    var covered = 0
                    for sy in 0..<Self.samples {
                        for sx in 0..<Self.samples {
                            let point = CGPoint(x: square.minX + (CGFloat(sx) + 0.5) * step,
                                                y: square.minY + (CGFloat(sy) + 0.5) * step)
                            if stroke.contains(point) { covered += 1 }
                        }
                    }
                    guard covered > 0 else { continue }
                    let coverage = Double(covered) / Double(Self.samples * Self.samples)
                    // A hair of overlap hides seams between neighbouring pixels.
                    context.fill(Path(square.insetBy(dx: -0.125, dy: -0.125)),
                                 with: .color(Self.ink.opacity(coverage)))
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.2, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: side * 0.2, style: .continuous)
                .strokeBorder(.white.opacity(0.25), lineWidth: 1)
        }
        // Decorative: the mode's title already names it.
        .accessibilityHidden(true)
    }
}
