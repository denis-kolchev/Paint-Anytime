import Foundation
import simd

enum TutorialStep: Int, CaseIterable {
    case inactive = 0
    case firstStrokes, holdCircle, zoomCanvas, panCanvas, finishCamera, openTools
    case pickColor, openCurrentPalette, openPalettes, findNewPalette, createPalette
    case addPaletteColor, adjustPaletteColor, savePaletteColor
    case openWidth, setWidth, openOpacity, setOpacity, openTool
    case selectReed, chooseReed, openAngle, setAngle, closeTools, reedStrokes
    case chooseFill, fillCanvas
    case chooseBlur, blurCanvas
    case crossMarkerLine, openDrawingSettings, openColorBlending, chooseColorInversion, redrawMarkerLine
    case openLayers, openLayerSettings, lockTransparency, closeLayerSettings, closeLayers
    case paintOverStroke, addLayer, moveLayerDown, drawBehindStroke
    case openLasso, selectLasso, transformLasso, finishLasso
    case history, saveDrawing, openMenu, openGallery
    case galleryFullscreen, deleteDrawing, returnToCanvas, clearCanvas
    case openCanvasSettings, openPerspective, choosePerspective, leavePerspective, leaveMenu, perspectiveStroke
    case openCanvasSize, openCrop, applyCrop
    case startSelection, selectDrawings, favoriteSelection
    case openCanvasEditor, chooseEditorSlot, chooseEraserAction, saveCanvasLayout, toggleEraser, eraseStroke
    // Results, not lessons: they wait for Next (or Done after the last chapter).
    case chapterComplete, finished

    var isResult: Bool { self == .chapterComplete || self == .finished }
}

/// Pure exercise rules; completed skills remain available for exploration.
struct TutorialProgress {
    private(set) var step: TutorialStep = .inactive
    private(set) var count = 0
    private(set) var hasPanned = false
    private(set) var chapters: [TutorialChapter] = []
    private(set) var chapterIndex = 0
    private(set) var lessonIndex = 0
    private var stepIndex = 0
    private var unlockedToolPages: Set<Int> = [1]
    /// Changes when a lesson within a chapter starts on a fresh canvas.
    private(set) var freshLessonRevision = 0
    /// Whether the current lesson keeps the brush of the lesson before it.
    var lessonKeepsBrush: Bool {
        guard chapters.indices.contains(chapterIndex) else { return false }
        let lessons = chapters[chapterIndex].lessons
        return lessons.indices.contains(lessonIndex) && lessons[lessonIndex].keepsBrush
    }

    enum Event {
        case openedLasso, selectedLasso, failedLassoSelection, transformedLasso, finishedLasso
        case heldCircle, stroke, filled, openedTools, closedTools, openedInfo, closedInfo, browsedTools
        case panned, finishedCamera, history, saved, openedMenu, openedGallery
        case galleryFullscreen, deleted, returnedToCanvas, cleared
        case openedCurrentPalette, browsedPalettes, foundNewPalette
        case returnedToPalettes
        case openedLayers, openedLayerSettings, lockedTransparency, closedLayerSettings, closedLayers
        case paintedOver, addedLayer, movedLayerDown, drewBehind
        case createdPalette, openedColorEditor, adjustedColor, savedColor
        case openedCanvasSettings, openedPerspective, choseVanishingPoints, drewAlongGuide
        case leftPerspective, leftMenu
        case openedCanvasEditor, choseEditorSlot, choseEraserAction, savedCanvasLayout, toggledEraser, erased
        case openedCanvasSize, openedCrop, croppedCanvas
        case startedSelection, cancelledSelection, selectedDrawings, deselectedDrawings, favoritedSelection
        case crossedMarkerLine, openedDrawingSettings, openedColorBlending, choseColorInversion
    }
    enum Effect: Equatable {
        case none, advance, showResult, pauseReminders
        case resumeReminders(advance: Bool)
    }

    var chapter: TutorialChapter? {
        step == .inactive || !chapters.indices.contains(chapterIndex) ? nil : chapters[chapterIndex]
    }

    /// Reads the chapter list directly: `chapter` is nil until the first step begins.
    private var lessonSteps: [TutorialStep] {
        guard chapters.indices.contains(chapterIndex) else { return [] }
        let lessons = chapters[chapterIndex].lessons
        guard lessons.indices.contains(lessonIndex) else { return [] }
        return lessons[lessonIndex].steps
    }

    /// Fraction of the current chapter's exercises; the ring fills once per chapter.
    var chapterProgress: Double {
        guard let chapter else { return 0 }
        if step == .chapterComplete || step == .finished { return 1 }
        let lessons = chapter.lessons
        let total = lessons.reduce(0) { $0 + $1.steps.count }
        let previous = lessons.prefix(lessonIndex).reduce(0) { $0 + $1.steps.count }
        return Double(previous + stepIndex) / Double(max(1, total))
    }

    var completedLessonCount: Int {
        switch step {
        case .inactive: 0
        case .chapterComplete, .finished: chapter?.lessons.count ?? 0
        default: lessonIndex
        }
    }

    mutating func start(chapters: [TutorialChapter] = TutorialChapter.allCases) {
        self = TutorialProgress()
        self.chapters = chapters.isEmpty ? TutorialChapter.allCases : chapters
        beginLesson()
    }
    mutating func stop() { step = .inactive }

    /// Completes the current exercise; lessons within a chapter follow each other directly.
    mutating func advance() {
        guard step != .inactive, !step.isResult else { return }
        if stepIndex + 1 < lessonSteps.count { enter(stepIndex + 1) } else { finishLesson() }
    }

    /// Next on a chapter result. Returns true when the following chapter begins.
    @discardableResult
    mutating func continueToNext() -> Bool {
        guard step == .chapterComplete else { return false }
        chapterIndex += 1
        lessonIndex = 0
        beginLesson()
        return true
    }

    private mutating func finishLesson() {
        count = 0
        if lessonIndex + 1 < (chapter?.lessons.count ?? 0) {
            lessonIndex += 1
            if chapters[chapterIndex].lessons[lessonIndex].startsFresh { freshLessonRevision &+= 1 }
            beginLesson()
        } else if chapterIndex + 1 < chapters.count { step = .chapterComplete }
        else { step = .finished }
    }

    private mutating func beginLesson() {
        hasPanned = false
        unlockedToolPages = [1]
        enter(0)
    }

    private mutating func enter(_ index: Int) {
        guard lessonSteps.indices.contains(index) else { return }
        stepIndex = index
        count = 0
        step = lessonSteps[index]
        // Pages between Color and the target stay reachable for the swipe.
        switch step {
        case .openWidth: unlockedToolPages.insert(0)
        case .openOpacity: unlockedToolPages.formUnion([0, 5])
        case .openTool: unlockedToolPages.formUnion([0, 2, 3, 5, 6])
        case .selectReed: unlockedToolPages = visibleToolPages
        case .openAngle: unlockedToolPages.insert(4)
        // The fill and blur lessons open on Tool and keep the carousel there.
        case .chooseFill, .chooseBlur: unlockedToolPages = [2]
        default: break
        }
    }

    /// Steps back within the lesson when the user undoes a completed action.
    private mutating func returnTo(_ target: TutorialStep) {
        guard let index = lessonSteps.firstIndex(of: target) else { return }
        enter(index)
    }

    mutating func record(_ event: Event) -> Effect {
        switch (step, event) {
        case (.selectReed, .browsedTools): return .advance
        case (.createPalette, .returnedToPalettes):
            returnTo(.findNewPalette)
            return .none
        case (.firstStrokes, .stroke), (.history, .history):
            count += 1
            return count >= 2 ? .advance : .none
        case (.panCanvas, .panned):
            hasPanned = true
            return .advance
        case (.finishCamera, .finishedCamera): return hasPanned ? .advance : .none
        // Information remains optional and never completes a lesson.
        case (_, .openedInfo): return .pauseReminders
        case (_, .closedInfo): return .resumeReminders(advance: false)
        case (.holdCircle, .heldCircle): return .advance
        case (.openCurrentPalette, .openedCurrentPalette),
             (.openPalettes, .browsedPalettes), (.findNewPalette, .foundNewPalette),
             (.createPalette, .createdPalette), (.addPaletteColor, .openedColorEditor),
             (.adjustPaletteColor, .adjustedColor), (.savePaletteColor, .savedColor): return .advance
        case (.selectLasso, .failedLassoSelection), (.transformLasso, .failedLassoSelection):
            count += 1
            // Repeated misses end the lesson instead of blocking the tour.
            if count >= 3 { finishLesson() }
            return .none
        // A stroke that misses the guides three times still ends the lesson.
        case (.perspectiveStroke, .stroke):
            count += 1
            return count >= 3 ? .advance : .none
        // Leaving selection mode, or keeping fewer than two pictures, restores that exercise.
        case (.selectDrawings, .cancelledSelection), (.favoriteSelection, .cancelledSelection):
            returnTo(.startSelection)
            return .none
        case (.favoriteSelection, .deselectedDrawings):
            returnTo(.selectDrawings)
            return .none
        // The chosen guides stay visible briefly; Back then leads to the menu and the canvas.
        case (.choosePerspective, .choseVanishingPoints): return .showResult
        case (.leavePerspective, .leftPerspective), (.leaveMenu, .leftMenu): return .advance
        // The chosen action stays visible briefly; the next step then closes the action list.
        case (.chooseEraserAction, .choseEraserAction): return .showResult
        case (.openCanvasEditor, .openedCanvasEditor), (.chooseEditorSlot, .choseEditorSlot),
             (.saveCanvasLayout, .savedCanvasLayout), (.toggleEraser, .toggledEraser),
             (.eraseStroke, .erased): return .advance
        // The applied crop stays visible briefly; the next step then returns to the canvas.
        case (.applyCrop, .croppedCanvas): return .showResult
        // The mixed and the inverted overlap each stay visible before the lesson moves on.
        case (.crossMarkerLine, .crossedMarkerLine), (.chooseColorInversion, .choseColorInversion),
             (.redrawMarkerLine, .crossedMarkerLine): return .showResult
        case (.openDrawingSettings, .openedDrawingSettings), (.openColorBlending, .openedColorBlending):
            return .advance
        case (.openCanvasSettings, .openedCanvasSettings), (.openPerspective, .openedPerspective),
             (.perspectiveStroke, .drewAlongGuide), (.openCanvasSize, .openedCanvasSize),
             (.openCrop, .openedCrop),
             (.startSelection, .startedSelection), (.selectDrawings, .selectedDrawings),
             (.favoriteSelection, .favoritedSelection): return .advance
        case (.openLasso, .openedLasso), (.selectLasso, .selectedLasso),
             (.transformLasso, .transformedLasso), (.finishLasso, .finishedLasso): return .advance
        case (.clearCanvas, .cleared): return .showResult
        case (.openTools, .openedTools), (.closeTools, .closedTools), (.reedStrokes, .stroke), (.reedStrokes, .filled),
             (.saveDrawing, .saved), (.openMenu, .openedMenu),
             (.openGallery, .openedGallery), (.galleryFullscreen, .galleryFullscreen),
             (.deleteDrawing, .deleted), (.returnToCanvas, .returnedToCanvas),
             (.fillCanvas, .filled), (.blurCanvas, .stroke), (.openLayers, .openedLayers),
             (.openLayerSettings, .openedLayerSettings), (.lockTransparency, .lockedTransparency),
             (.closeLayerSettings, .closedLayerSettings), (.closeLayers, .closedLayers),
             (.paintOverStroke, .paintedOver), (.addLayer, .addedLayer),
             (.moveLayerDown, .movedLayerDown), (.drawBehindStroke, .drewBehind): return .advance
        default: break
        }
        return .none
    }
    var visibleToolPages: Set<Int> { [0, 1, 2, 3, 4, 5, 6] }
    /// Lesson-wide, so menu rows stay installed while their pages are pushed.
    var teachesPerspective: Bool { step != .inactive && lessonSteps.contains(.openPerspective) }
    var teachesCrop: Bool { step != .inactive && lessonSteps.contains(.openCrop) }
    var teachesGallerySelection: Bool { step != .inactive && lessonSteps.contains(.startSelection) }
    var teachesBlending: Bool { step != .inactive && lessonSteps.contains(.openColorBlending) }
    var teachesCanvasEditor: Bool { step != .inactive && lessonSteps.contains(.openCanvasEditor) }
    /// The fill and blur lessons offer only the lesson's brush and their tool until the settings close.
    var lessonInstrument: DrawingInstrument? {
        guard step == .chooseFill || step == .chooseBlur || step == .closeTools else { return nil }
        if lessonSteps.contains(.chooseFill) { return .fill }
        if lessonSteps.contains(.chooseBlur) { return .blur }
        return nil
    }
    /// The repaint and layer-order lessons need a visible change, so colors already
    /// on the canvas cannot be chosen again.
    var locksLessonColor: Bool {
        (step == .pickColor || step == .closeTools)
            && (lessonSteps.contains(.paintOverStroke) || lessonSteps.contains(.drawBehindStroke))
    }
    /// Tool settings open on Color (1), or on Tool (2) when the lesson starts there.
    var initialToolPage: Int { step == .chooseFill || step == .chooseBlur ? 2 : 1 }
    func allowsToolAdjustment(page: Int) -> Bool { visibleToolPages.contains(page) }
    func allowsToolPage(_ page: Int) -> Bool {
        step == .inactive ? visibleToolPages.contains(page) : unlockedToolPages.contains(page)
    }
    func completesPageChange(_ page: Int) -> Bool {
        (step == .openWidth && page == 0) || (step == .openTool && page == 2)
            || (step == .openAngle && page == 4) || (step == .openOpacity && page == 5)
    }
    mutating func changedStyle(from old: PencilStyle, to style: PencilStyle, page: Int) -> Bool {
        switch step {
        case .setOpacity: return page == 5 && style.instrument != .eraser && old.opacity != style.opacity
        case .setWidth: return page == 0 && old.width != style.width
        case .pickColor: return page == 1 && old.color != style.color
        case .selectReed: return old.instrument != style.instrument
        case .chooseReed: return style.instrument == .reed
        case .chooseFill: return style.instrument == .fill
        case .chooseBlur: return style.instrument == .blur
        case .closeTools where lessonInstrument != nil:
            // Scrolling past the lesson's tool before closing restores the selection exercise.
            if let tool = lessonInstrument, style.instrument != tool {
                returnTo(tool == .fill ? .chooseFill : .chooseBlur)
            }
            return false
        case .openAngle, .setAngle:
            // Angle exists only for Reed; leaving it restores the selection exercise.
            guard style.instrument == .reed else {
                returnTo(.chooseReed)
                return false
            }
            return step == .setAngle && page == 4 && old.reedAngle != style.reedAngle
        default: return false
        }
    }
}

/// Whether a new stroke touches the painted shape of earlier strokes on the same layer.
enum TutorialStrokeOverlap {
    static func paintsOver(_ stroke: Stroke, earlier: [Stroke]) -> Bool {
        let path = segments(stroke)
        return earlier.contains { old in
            let reach = (stroke.style.width + old.style.width) / 2
            let oldPath = segments(old)
            return path.contains { segment in
                oldPath.contains { distance(segment, $0) <= reach }
            }
        }
    }

    /// Whether a stroke on `layerID` crosses a visible stroke on a layer above it.
    /// Without visible painted strokes above, any stroke counts, so the lesson cannot stall.
    static func passesBehind(_ stroke: Stroke, on layerID: UUID, in document: CanvasDocument) -> Bool {
        guard paints(stroke), let index = document.layers.firstIndex(where: { $0.id == layerID }),
              index + 1 < document.layers.count else { return false }
        let covering = document.layers[(index + 1)...]
            .filter { $0.isVisible && $0.opacity > 0 }
            .flatMap(\.strokes).filter { paints($0) }
        // Locked strokes only show inside unlocked ones, whose geometry is the visible shape.
        let shapes = covering.filter { !$0.locksTransparency }
        let candidates = shapes.isEmpty ? covering : shapes
        return candidates.isEmpty || paintsOver(stroke, earlier: candidates)
    }

    /// Erasers, fill and blur leave no stroke-shaped paint to compare.
    private static func paints(_ stroke: Stroke) -> Bool {
        ![.eraser, .fill, .blur].contains(stroke.style.instrument)
    }

    private typealias Segment = (start: SIMD2<Float>, end: SIMD2<Float>)

    // Fast strokes sample sparsely, so compare segments rather than samples.
    private static func segments(_ stroke: Stroke) -> [Segment] {
        let points = stroke.points.map(\.position)
        guard let first = points.first else { return [] }
        guard points.count > 1 else { return [(first, first)] }
        return zip(points, points.dropFirst()).map { ($0, $1) }
    }

    private static func distance(_ a: Segment, _ b: Segment) -> Float {
        if intersect(a, b) { return 0 }
        return min(distance(a.start, b), distance(a.end, b), distance(b.start, a), distance(b.end, a))
    }

    private static func distance(_ point: SIMD2<Float>, _ segment: Segment) -> Float {
        let direction = segment.end - segment.start
        let length = simd_length_squared(direction)
        let t = length > 0 ? min(1, max(0, simd_dot(point - segment.start, direction) / length)) : 0
        return simd_distance(point, segment.start + direction * t)
    }

    private static func intersect(_ a: Segment, _ b: Segment) -> Bool {
        func cross(_ u: SIMD2<Float>, _ v: SIMD2<Float>) -> Float { u.x * v.y - u.y * v.x }
        let d1 = cross(b.end - b.start, a.start - b.start), d2 = cross(b.end - b.start, a.end - b.start)
        let d3 = cross(a.end - a.start, b.start - a.start), d4 = cross(a.end - a.start, b.end - a.start)
        // Collinear and touching cases are covered by the endpoint distances.
        return (d1 > 0) != (d2 > 0) && (d3 > 0) != (d4 > 0) && d1 != 0 && d2 != 0 && d3 != 0 && d4 != 0
    }
}
