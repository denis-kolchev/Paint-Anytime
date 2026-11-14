import Foundation

/// Self-contained parts of the guided tour. Each chapter starts on a cleared canvas
/// with the default brush, so it never depends on another chapter's result.
enum TutorialChapter: Int, CaseIterable, Identifiable {
    case basic, advanced

    struct Lesson: Equatable {
        let steps: [TutorialStep]
        /// Clears the canvas and restores the default brush, as a new chapter does.
        var startsFresh = false
        /// With `startsFresh`, clears only the canvas and keeps the brush in use.
        var keepsBrush = false
    }

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .basic: L10n.text("Basic course")
        case .advanced: L10n.text("Advanced")
        }
    }

    var systemImage: String {
        switch self {
        case .basic: "hand.draw"
        case .advanced: "paintbrush.pointed"
        }
    }

    /// A rough time to complete the course, shown before it starts.
    var estimatedMinutes: Int {
        switch self {
        case .basic: 3
        case .advanced: 10
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
            // Autosave comes first in the menu; Back from it leaves the menu open, now with
            // Canvas. Guides then straighten a stroke, like the held shape before them. Back
            // leads from the guides to the menu, and from the menu to the canvas.
            Lesson(steps: [.openMenu, .openAutosave, .enableAutosave, .leaveAutosave,
                           .openCanvasSettings, .openPerspective, .choosePerspective,
                           .setRayCount, .leavePerspective, .leaveMenu, .perspectiveStroke]),
            // The corner button opens the palette in use, as in the editor.
            Lesson(steps: [.openTools, .openCurrentPalette, .openPalettes, .findNewPalette,
                           .createPalette, .addPaletteColor, .adjustPaletteColor, .savePaletteColor,
                           .closeTools, .autosaveDrawing, .clearCanvas])
        ]
    }

    private func compositionLessons(includesCrop: Bool) -> [Lesson] {
        var lessons = [
            // Draw first on a fresh canvas, so the layer lessons never rely on the earlier
            // artwork. The brush stays: the first strokes use the color made in the palette.
            Lesson(steps: [.firstStrokes, .openLayers, .openLayerSettings, .lockTransparency,
                           .closeLayerSettings, .closeLayers], startsFresh: true, keepsBrush: true),
            Lesson(steps: [.openTools, .pickColor, .closeTools, .paintOverStroke]),
            // Moving the new layer under the first one shows which layer covers the other;
            // a third color keeps the strokes behind distinct from both earlier ones.
            Lesson(steps: [.openLayers, .addLayer, .moveLayerDown, .closeLayers,
                           .openTools, .pickColor, .closeTools, .drawBehindStroke]),
            Lesson(steps: [.openLasso, .selectLasso, .transformLasso, .finishLasso]),
            // The tour's autosave keeps the lasso result first; it opens this lesson rather
            // than ending the lasso one, which repeated misses end early. The user then clears
            // the canvas before the demonstrated line.
            // The lesson clears the canvas and draws a yellow marker line itself; the user's
            // light blue marker mixes with it, then Color inversion changes the overlap. Back
            // leads out of the pages; the user undoes the crossing line and draws it again.
            Lesson(steps: [.autosaveDrawing, .clearCanvas, .crossMarkerLine, .openMenu, .openDrawingSettings, .openColorBlending,
                           .chooseColorInversion, .leaveColorBlending, .leaveDrawingSettings, .leaveMenu,
                           .undoMarkerLine, .redrawMarkerLine]),
            // The tutorial's editor starts from the original menus and never changes the
            // user's layout. Reset empties both top circles; one becomes a group of the
            // eyedropper and the eraser toggle. Back leaves the icon picker, ✕ the action
            // list. On the tutorial canvas a line comes first, then the group erases it.
            Lesson(steps: [.openMenu, .openCanvasSettings, .openCanvasEditor, .resetEditorLayout,
                           .chooseEditorSlot, .groupEditorActions, .chooseEditorActions,
                           .chooseGroupIcon, .leaveIconPicker, .closeActionList, .saveCanvasLayout,
                           .drawPracticeLine, .openPracticeGroup, .toggleEraser, .eraseStroke])
        ]
        // Cropping frames the whole picture: the Crown sets how much stays, a drag places it.
        if includesCrop {
            lessons.append(Lesson(steps: [.openMenu, .openCanvasSettings, .openCanvasSize, .openCrop,
                                          .trimCrop, .moveCrop, .applyCrop]))
        }
        // A last autosave, then the gallery shows the saved pictures; the tutorial gallery
        // also starts with practice pictures, so selection never lacks two. The liked ones
        // then appear in a watch-face widget, as the favorites widget would show them.
        lessons.append(Lesson(steps: [.autosaveDrawing, .openMenu, .openGallery, .startSelection,
                                      .selectDrawings, .favoriteSelection, .showFavoritesWidget,
                                      .returnToCanvas]))
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
