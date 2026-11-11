import Foundation

/// Self-contained parts of the guided tour. Each chapter starts on a cleared canvas
/// with the default brush, so it never depends on another chapter's result.
enum TutorialChapter: Int, CaseIterable, Identifiable {
    case firstDrawing, tools, composition

    struct Lesson: Equatable {
        let steps: [TutorialStep]
    }

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .firstDrawing: L10n.text("First drawing")
        case .tools: L10n.text("Drawing tools")
        case .composition: L10n.text("Composition")
        }
    }

    var systemImage: String {
        switch self {
        case .firstDrawing: "hand.draw"
        case .tools: "paintbrush.pointed"
        case .composition: "lasso"
        }
    }

    /// Every lesson begins on the canvas and ends there, so the next one can start fresh.
    var lessons: [Lesson] {
        switch self {
        case .firstDrawing: [
            Lesson(steps: [.firstStrokes, .history]),
            Lesson(steps: [.zoomCanvas, .panCanvas, .finishCamera]),
            Lesson(steps: [.openTools, .pickColor, .openWidth, .setWidth, .openOpacity, .setOpacity,
                           .openTool, .selectReed, .closeTools, .reedStrokes]),
            Lesson(steps: [.saveDrawing, .openMenu, .openGallery, .galleryFullscreen,
                           .deleteDrawing, .returnToCanvas, .clearCanvas])
        ]
        case .tools: [
            Lesson(steps: [.holdCircle]),
            Lesson(steps: [.openTools, .chooseFill, .closeTools, .fillCanvas]),
            Lesson(steps: [.openTools, .selectColor, .tapAddColor, .openPalettes, .findNewPalette,
                           .createPalette, .addPaletteColor, .adjustPaletteColor, .savePaletteColor,
                           .closeTools]),
            Lesson(steps: [.openTools, .openTool, .chooseReed, .openAngle, .setAngle, .closeTools,
                           .reedStrokes])
        ]
        case .composition: [
            // Draw first, so the layer lessons never rely on an earlier chapter's artwork.
            Lesson(steps: [.firstStrokes, .openLayers, .openLayerSettings, .lockTransparency,
                           .closeLayerSettings, .closeLayers]),
            Lesson(steps: [.openTools, .pickColor, .closeTools, .paintOverStroke]),
            // Moving the new layer under the first one shows which layer covers the other.
            Lesson(steps: [.openLayers, .addLayer, .moveLayerDown, .closeLayers, .drawBehindStroke]),
            Lesson(steps: [.openLasso, .selectLasso, .transformLasso, .finishLasso])
        ]
        }
    }

    private static let completionKey = "tutorial.completedChapters.v1"

    static func completed(in defaults: UserDefaults) -> Set<TutorialChapter> {
        let values = defaults.array(forKey: completionKey) as? [Int] ?? []
        return Set(values.compactMap(TutorialChapter.init(rawValue:)))
    }

    func markCompleted(in defaults: UserDefaults) {
        var chapters = Self.completed(in: defaults)
        guard chapters.insert(self).inserted else { return }
        defaults.set(chapters.map(\.rawValue).sorted(), forKey: Self.completionKey)
    }
}
