import SwiftUI

struct WatchAppSettingsView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @Environment(\.openURL) private var openURL
    private let supportEmail = "paintanytime.app@gmail.com"
    @ObservedObject var controller: CanvasController
    var onOpenDrawings: () -> Void
    var onStartTutorial: () -> Void
    @ObservedObject var tutorial = TutorialSession.inactive

    var body: some View {
        NavigationStack {
            List {
                Button(action: onOpenDrawings) {
                    Label(L10n.text("Gallery"), systemImage: "photo.on.rectangle")
                        .tutorialHint(tutorial, steps: [.openGallery])
                }
                if !tutorial.isActive {
                    NavigationLink {
                        AppLanguageSelectionView()
                    } label: {
                        Label(L10n.text("Language"), systemImage: "globe")
                    }
                    Button(action: onStartTutorial) {
                        Label(L10n.text("Tutorial"), systemImage: "graduationcap")
                    }
                    NavigationLink {
                        DrawingSettingsView(controller: controller)
                    } label: {
                        Label(L10n.text("Drawing"), systemImage: "paintbrush")
                    }
                    NavigationLink {
                        WatchLegalDocumentView(title: "Privacy Policy", paragraphs: WatchLegalText.privacy)
                    } label: {
                        Label(L10n.text("Privacy Policy"), systemImage: "hand.raised")
                    }
                    Button(action: reportBug) {
                        Label(L10n.text("Report a bug"), systemImage: "envelope")
                    }
                }
            }
            .labelStyle(CenteredMenuLabelStyle())
            .navigationTitle(L10n.text("More"))
            .toolbarTitleDisplayMode(.inline)
        }
    }

    private func reportBug() {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Paint Anytime — " + L10n.text("Report a bug"))
        ]
        guard let url = components.url else { return }
        // watchOS supports opening URLs, but not the completion-handler overload.
        openURL(url)
    }
}

private struct CenteredMenuLabelStyle: LabelStyle {
    @ScaledMetric(relativeTo: .body) private var iconWidth = 24.0

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 8) {
            configuration.icon
                .frame(width: iconWidth)
            configuration.title
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct DrawingSettingsView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @ObservedObject var controller: CanvasController

    var body: some View {
        List {
            NavigationLink {
                DrawingSpaceSettingsView()
            } label: {
                Label(L10n.text("More room to draw"), systemImage: "arrow.up.left.and.arrow.down.right")
            }
            NavigationLink {
                ToolSynchronizationView(controller: controller)
            } label: {
                Label(L10n.text("Tool synchronization"), systemImage: "arrow.triangle.2.circlepath")
            }
            NavigationLink {
                PaletteVisibilitySettingsView(controller: controller)
            } label: {
                Label(L10n.text("Visible palettes"), systemImage: "paintpalette")
            }
            NavigationLink {
                ColorBlendingSelectionView(controller: controller)
            } label: {
                Label(L10n.text("Color blending"), systemImage: "circle.lefthalf.filled")
            }
        }
        .labelStyle(CenteredMenuLabelStyle())
        .navigationTitle(L10n.text("Drawing"))
        .toolbarTitleDisplayMode(.inline)
    }
}

private struct PaletteVisibilitySettingsView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @AppStorage("watch.inkPalette.v1") private var paletteData = Data()
    @AppStorage("watch.inkPalettes.v2") private var palettesData = Data()
    @ObservedObject var controller: CanvasController

    private var library: InkPaletteLibrary {
        InkPaletteLibrary.decode(palettesData, legacy: paletteData)
    }

    var body: some View {
        List {
            if library.palettes.contains(where: { !$0.isBuiltIn }) {
                NavigationLink {
                    List { paletteRows(builtIn: true) }
                        .navigationTitle(L10n.text("Ready-made palettes"))
                } label: {
                    Label(L10n.text("Ready-made palettes"), systemImage: "paintpalette")
                }
                NavigationLink {
                    List { paletteRows(builtIn: false) }
                        .navigationTitle(L10n.text("My palettes"))
                } label: {
                    Label(L10n.text("My palettes"), systemImage: "person.crop.square")
                }
            } else {
                paletteRows(builtIn: true)
            }
        }
        .navigationTitle(L10n.text("Visible palettes"))
    }

    private func paletteRows(builtIn: Bool) -> some View {
        ForEach(library.palettes.filter { $0.isBuiltIn == builtIn }) { entry in
            Button {
                setVisible(!entry.isVisible, id: entry.id)
            } label: {
                HStack {
                    Text(entry.palette.displayTitle)
                    Spacer()
                    Image(systemName: entry.isVisible ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(entry.isVisible ? Color.green : Color.secondary)
                }
            }
            .disabled(entry.isVisible && library.visiblePalettes.count == 1)
            .accessibilityAddTraits(entry.isVisible ? .isSelected : [])
        }
    }

    private func setVisible(_ visible: Bool, id: String) {
        var updated = library
        let previousActiveID = updated.activeID
        guard let index = updated.palettes.firstIndex(where: { $0.id == id }) else { return }
        guard visible || !updated.palettes[index].isVisible || updated.visiblePalettes.count > 1 else { return }
        updated.palettes[index].isHidden = !visible
        // Keep an available palette selected when hiding the active one.
        if !visible && updated.activeID == id {
            guard let fallback = updated.visiblePalettes.first(where: { !$0.palette.selectedColors.isEmpty }) else { return }
            updated.activeID = fallback.id
        }
        guard let data = try? JSONEncoder().encode(updated) else { return }
        palettesData = data
        if updated.activeID != previousActiveID,
           !updated.activePalette.selectedColors.contains(where: { $0.rgba == controller.pencilStyle.color }),
           let first = updated.activePalette.selectedColors.first {
            controller.pencilStyle.color = first.rgba
        }
    }
}

private struct ToolSynchronizationView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @ObservedObject var controller: CanvasController

    var body: some View {
        List {
            Section {
                Toggle(L10n.text("Shared width"), isOn: Binding(
                    get: { controller.synchronization.width },
                    set: { controller.setSynchronizeWidth($0) }
                ))
                Toggle(L10n.text("Shared opacity"), isOn: Binding(
                    get: { controller.synchronization.opacity },
                    set: { controller.setSynchronizeOpacity($0) }
                ))
                Toggle(L10n.text("Shared color"), isOn: Binding(
                    get: { controller.synchronization.color },
                    set: { controller.setSynchronizeColor($0) }
                ))
            } footer: {
                Text(L10n.text("Share width, opacity, and color across tools. Color and opacity do not apply to the eraser."))
            }
        }
        .navigationTitle(L10n.text("Synchronization"))
    }
}

struct AppLanguageSelectionView: View {
    var onSelection: (() -> Void)? = nil
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @State private var pendingLanguageCode: String?

    var body: some View {
        ScrollViewReader { proxy in
            List(AppLanguage.displayOrder) { language in
                Button {
                    guard pendingLanguageCode == nil else { return }
                    if language.id == AppLanguage.currentCode {
                        onSelection?()
                        return
                    }
                    pendingLanguageCode = language.id
                } label: {
                    HStack {
                        Text(verbatim: language.nativeName)
                        Spacer()
                        if AppLanguage.currentCode == language.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.green)
                        }
                    }
                }
                .id(language.id)
                .accessibilityAddTraits(AppLanguage.currentCode == language.id ? .isSelected : [])
            }
            .onAppear {
                proxy.scrollTo(AppLanguage.currentCode, anchor: .center)
            }
        }
        .disabled(pendingLanguageCode != nil)
        .accessibilityHidden(pendingLanguageCode != nil)
        .overlay {
            if pendingLanguageCode != nil {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text(L10n.text("Changing language…"))
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.9))
                .accessibilityElement(children: .combine)
            }
        }
        .navigationBarBackButtonHidden(pendingLanguageCode != nil)
        .interactiveDismissDisabled(pendingLanguageCode != nil)
        .navigationTitle(L10n.text("Language"))
        .task(id: pendingLanguageCode) {
            guard let code = pendingLanguageCode else { return }
            defer { pendingLanguageCode = nil }
            do {
                // Let the indicator render before invalidating all localized views.
                try await Task.sleep(for: .milliseconds(100))
                try Task.checkCancellation()
                languageCode = code
                // Keep the overlay through the first layout of the updated interface.
                try await Task.sleep(for: .milliseconds(150))
                try Task.checkCancellation()
                onSelection?()
            } catch {
                // SwiftUI cancels this task if the selection screen disappears.
            }
        }
    }
}

private struct WatchLegalDocumentView: View {
    let title: String
    let paragraphs: [String]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(paragraphs.indices, id: \.self) { index in
                    Text(verbatim: paragraphs[index])
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .navigationTitle(L10n.text(title))
    }
}

private struct ColorBlendingSelectionView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @ObservedObject var controller: CanvasController

    var body: some View {
        List {
            Section {
                ForEach(ColorBlendingMode.allCases, id: \.rawValue) { mode in
                    Button {
                        controller.setBlendingMode(mode)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(mode.effectTitle)
                                Text(mode.referenceLabel)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            if controller.blendingMode == mode {
                                Image(systemName: "checkmark").foregroundStyle(.green)
                            }
                        }
                    }
                    .accessibilityAddTraits(controller.blendingMode == mode ? .isSelected : [])
                }
            } footer: {
                Text(L10n.text("Applies to new marker and watercolor strokes. Hybrid is the default."))
            }
        }
        .navigationTitle(L10n.text("Color blending"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    ColorBlendingInformationView(mode: controller.blendingMode)
                } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel(L10n.text("About color blending"))
            }
        }
    }
}

private struct ColorBlendingInformationView: View {
    let mode: ColorBlendingMode
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(mode.effectTitle)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(mode.referenceLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(description)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                if !mode.usesMultiplyFastPath {
                    Text(L10n.text("The first stroke colors empty canvas. Blending changes how later strokes overlap existing paint. The white canvas backing is not white paint."))
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ColorBlendingIllustration(mode: mode)
                    .aspectRatio(1, contentMode: .fit)
                    .accessibilityLabel(L10n.text("Blend chart: yellow passes increase to the right; blue passes increase downward."))
                Text(L10n.text("Yellow → · Blue ↓\n0–10 passes, 80% opacity. Yellow first, then blue. Watercolor example; marker builds up more gently."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.text("Applies to new marker and watercolor strokes. Hybrid is the default."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
        .navigationTitle(mode.title)

    }

    private var description: String {
        switch mode {
        case .hybrid: L10n.text("Build up color for painterly shading. Like Multiply, repeated strokes deepen shadows, but retain more of the brush color instead of quickly turning black. The default for marker and watercolor.")
        case .multiply: L10n.text("Paint colored shadows, deepen folds, or tint a sketch while keeping dark lines visible. Each pass darkens the underlying colors. White has no effect; many passes can make shadows muddy.")
        case .normal: L10n.text("Block in flat colors, paint over mistakes, and add crisp details. Opaque strokes replace the color below. Lower opacity lets you build transitions gradually without extra darkening.")
        case .screen: L10n.text("Build soft highlights, haze, and reflected light over darker paint. Repeated passes brighten the image. Black has no effect, and Screen cannot add visible color over white.")
        case .overlay: L10n.text("Tint existing shading while boosting contrast: shadows deepen and light areas brighten. Useful for color accents on a modeled form. Pure black and white stay unchanged; start over midtones.")
        case .softLight: L10n.text("Gently warm or cool existing paint and adjust its lighting. Softer than Overlay, useful for subtle shading and atmosphere. Neutral 50% gray has no effect; work over midtones.")
        case .hardLight: L10n.text("Paint dramatic light and strong colored shadows. Light brush colors brighten; dark brush colors deepen the image. Useful for bold lighting accents; lower opacity for more control.")
        case .darken: L10n.text("Add darker accents without lightening existing dark details. Each RGB channel keeps the darker value. Useful for reinforcing linework or shading; repeated identical opaque passes stop changing the result.")
        case .lighten: L10n.text("Add light accents while protecting brighter details. Each RGB channel keeps the lighter value. Useful for highlights on dark paint; it cannot leave a visible mark over white.")
        case .colorDodge: L10n.text("Create intense glow, hot highlights, and luminous edges over existing color. Bright brush colors quickly push highlights toward white. Use low opacity; the effect is invisible over white.")
        case .colorBurn: L10n.text("Deepen rich colored shadows and add gritty contrast. Dark brush colors can quickly crush detail to black. Use low opacity over existing paint; pure white stays white.")
        case .add: L10n.text("Add light for sparks, neon, and bright glow. RGB values add together and clip at white, so highlights can lose detail quickly. Best over dark paint with low opacity.")
        case .difference: L10n.text("Explore inverted colors and graphic effects. Similar colors turn dark; white inverts the underlying color, while black leaves it unchanged. Useful for experimental palettes rather than natural shading.")
        case .exclusion: L10n.text("Create softer inverted colors and muted graphic effects. Similar to Difference with gentler contrast. Black has no effect; white inverts the image. Try it for stylized color shifts.")
        }
    }
}

/// Repeated applications of the actual renderer's blend formula, not an approximation.
private struct ColorBlendingIllustration: View {
    let mode: ColorBlendingMode

    var body: some View {
        Canvas { context, size in
            let margin: CGFloat = 16
            let cell = (min(size.width, size.height) - margin) / 11
            for row in 0...10 {
                for column in 0...10 {
                    let result = mode.referenceSwatch(yellowPasses: column, bluePasses: row)
                    let rect = CGRect(x: margin + CGFloat(column) * cell,
                                      y: margin + CGFloat(row) * cell, width: cell + 0.25, height: cell + 0.25)
                    context.fill(Path(rect), with: .color(Color(.sRGB, red: Double(result.x),
                                                               green: Double(result.y), blue: Double(result.z), opacity: 1)))
                }
            }
            for index in [0, 5, 10] {
                let label = Text(verbatim: String(index)).font(.system(size: 9)).foregroundColor(.secondary)
                let position = margin + (CGFloat(index) + 0.5) * cell
                context.draw(label, at: CGPoint(x: position, y: 6))
                context.draw(label, at: CGPoint(x: 6, y: position))
            }
        }
        .accessibilityElement(children: .ignore)
    }
}

private struct DrawingSpaceSettingsView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @AppStorage("experimental.morphToolbar") private var usesMorphToolbar = false

    var body: some View {
        List {
            Section {
                Toggle(L10n.text("Keep buttons in a menu"), isOn: $usesMorphToolbar)
            } footer: {
                Text(L10n.text("Keep drawing controls in one menu for fewer buttons on the canvas and more room to draw."))
            }
        }
        .navigationTitle(L10n.text("More room to draw"))
    }
}
