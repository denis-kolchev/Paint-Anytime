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
    var lessons: [Lesson] { lessons(features: .current) }

    /// Lessons for features of the given release; Canvas size arrives in 1.2.
    func lessons(features: AppReleaseFeatures) -> [Lesson] {
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
        case .composition:
            compositionLessons(includesCrop: features.showsCanvasSizeControls)
        }
    }

    private func compositionLessons(includesCrop: Bool) -> [Lesson] {
        var lessons = [
            // Draw first, so the layer lessons never rely on an earlier chapter's artwork.
            Lesson(steps: [.firstStrokes, .openLayers, .openLayerSettings, .lockTransparency,
                           .closeLayerSettings, .closeLayers]),
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
