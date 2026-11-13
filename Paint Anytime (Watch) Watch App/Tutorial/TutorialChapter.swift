import Foundation

/// Self-contained parts of the guided tour. Each chapter starts on a cleared canvas
/// with the default brush, so it never depends on another chapter's result.
enum TutorialChapter: Int, CaseIterable, Identifiable {
    case basic, advanced

    struct Lesson: Equatable {
        let steps: [TutorialStep]
        /// Clears the canvas and restores the default brush, as a new chapter does.
        var startsFresh = false
    }

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .basic: L10n.text("Basic course")
        case .advanced: L10n.text("Advanced course")
        }
    }

    var systemImage: String {
        switch self {
        case .basic: "hand.draw"
        case .advanced: "paintbrush.pointed"
        }
    }

    /// Every lesson begins on the canvas and ends there, so the next one can start fresh.
    var lessons: [Lesson] { lessons(features: .current) }

    /// Lessons for features of the given release; Canvas size arrives in 1.2.
    func lessons(features: AppReleaseFeatures) -> [Lesson] {
        switch self {
        case .basic: [
            Lesson(steps: [.firstStrokes, .history]),
            Lesson(steps: [.zoomCanvas, .panCanvas, .finishCamera]),
            Lesson(steps: [.openTools, .pickColor, .openWidth, .setWidth, .openOpacity, .setOpacity,
                           .openTool, .selectReed, .closeTools, .reedStrokes]),
            Lesson(steps: [.saveDrawing, .openMenu, .openGallery, .galleryFullscreen,
                           .deleteDrawing, .returnToCanvas, .clearCanvas])
        ]
        case .advanced:
            toolLessons + compositionLessons(includesCrop: features.showsCanvasSizeControls)
        }
    }

    private var toolLessons: [Lesson] {
        [
            Lesson(steps: [.holdCircle]),
            // Guides straighten a stroke, like the held shape before them.
            // Choosing the guides returns to the canvas by itself: a toolbar ✕ would push
            // the tutorial menu's rows under its navigation bar.
            Lesson(steps: [.openMenu, .openCanvasSettings, .openPerspective, .choosePerspective,
                           .perspectiveStroke]),
            Lesson(steps: [.openTools, .chooseFill, .closeTools, .fillCanvas]),
            // Blur softens the filled edges, so it follows the fill.
            Lesson(steps: [.openTools, .chooseBlur, .closeTools, .blurCanvas]),
            // The lesson clears the canvas and draws a yellow marker line itself; the user's
            // light blue marker mixes with it, then Color inversion changes the overlap.
            Lesson(steps: [.crossMarkerLine, .openMenu, .openDrawingSettings, .openColorBlending,
                           .chooseColorInversion, .redrawMarkerLine]),
            // The corner button opens the palette in use, as in the editor.
            Lesson(steps: [.openTools, .openCurrentPalette, .openPalettes, .findNewPalette,
                           .createPalette, .addPaletteColor, .adjustPaletteColor, .savePaletteColor,
                           .closeTools])
        ]
    }

    private func compositionLessons(includesCrop: Bool) -> [Lesson] {
        var lessons = [
            // Draw first on a fresh canvas, so the layer lessons never rely on the
            // tool lessons' artwork, brush or blending mode.
            Lesson(steps: [.firstStrokes, .openLayers, .openLayerSettings, .lockTransparency,
                           .closeLayerSettings, .closeLayers], startsFresh: true),
            Lesson(steps: [.openTools, .pickColor, .closeTools, .paintOverStroke]),
            // Moving the new layer under the first one shows which layer covers the other;
            // a third color keeps the strokes behind distinct from both earlier ones.
            Lesson(steps: [.openLayers, .addLayer, .moveLayerDown, .closeLayers,
                           .openTools, .pickColor, .closeTools, .drawBehindStroke]),
            Lesson(steps: [.openLasso, .selectLasso, .transformLasso, .finishLasso])
        ]
        // The lasso changes part of the picture; cropping frames all of it, and undo restores the edges.
        if includesCrop {
            lessons.append(Lesson(steps: [.openMenu, .openCanvasSettings, .openCanvasSize, .openCrop,
                                          .applyCrop, .history]))
        }
        // The tutorial gallery starts with practice pictures, so selection needs no saved drawing.
        lessons.append(Lesson(steps: [.openMenu, .openGallery, .startSelection, .selectDrawings,
                                      .favoriteSelection, .returnToCanvas]))
        return lessons
    }

    private static let completionKey = "tutorial.completedChapters.v2"
    /// Three chapters: 0 First drawing, 1 Drawing tools, 2 Composition.
    private static let legacyCompletionKey = "tutorial.completedChapters.v1"

    static func completed(in defaults: UserDefaults) -> Set<TutorialChapter> {
        if let values = defaults.array(forKey: completionKey) as? [Int] {
            return Set(values.compactMap(TutorialChapter.init(rawValue:)))
        }
        // The advanced course joins the old second and third chapters; it counts as
        // completed only when both were.
        let legacy = Set(defaults.array(forKey: legacyCompletionKey) as? [Int] ?? [])
        var chapters: Set<TutorialChapter> = []
        if legacy.contains(0) { chapters.insert(.basic) }
        if legacy.isSuperset(of: [1, 2]) { chapters.insert(.advanced) }
        return chapters
    }

    func markCompleted(in defaults: UserDefaults) {
        var chapters = Self.completed(in: defaults)
        guard chapters.insert(self).inserted else { return }
        defaults.set(chapters.map(\.rawValue).sorted(), forKey: Self.completionKey)
    }
}
