import Foundation
import simd

enum TutorialStep: Int, CaseIterable {
    case inactive = 0
    case firstStrokes, holdCircle, zoomCanvas, panCanvas, finishCamera, openTools
    case pickColor, selectColor, tapAddColor, openPalettes, findNewPalette, createPalette
    case addPaletteColor, adjustPaletteColor, savePaletteColor
    case openWidth, setWidth, openOpacity, setOpacity, openTool
    case selectReed, chooseReed, openAngle, setAngle, closeTools, reedStrokes
    case chooseFill, fillCanvas
    case openLayers, openLayerSettings, lockTransparency, closeLayerSettings, closeLayers
    case paintOverStroke, addLayer, drawOnLayer
    case openLasso, selectLasso, transformLasso, finishLasso
    case history, saveDrawing, shareDrawing, openMenu, openGallery
    case galleryFullscreen, deleteDrawing, returnToCanvas, clearCanvas
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

    enum Event {
        case openedLasso, selectedLasso, failedLassoSelection, transformedLasso, finishedLasso
        case heldCircle, stroke, filled, openedTools, closedTools, openedInfo, closedInfo, browsedTools
        case panned, finishedCamera, history, saved, closedSave, openedMenu, openedGallery
        case galleryFullscreen, deleted, returnedToCanvas, cleared
        case reachedAddColor, returnedToColorSelection, openedColorList, browsedPalettes, foundNewPalette
        case returnedToPalettes
        case openedLayers, openedLayerSettings, lockedTransparency, closedLayerSettings, closedLayers
        case paintedOver, addedLayer
        case createdPalette, openedColorEditor, adjustedColor, savedColor
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
        // The fill lesson opens on Tool and keeps the carousel there.
        case .chooseFill: unlockedToolPages = [2]
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
        case (.tapAddColor, .returnedToColorSelection):
            returnTo(.selectColor)
            return .none
        case (.createPalette, .returnedToPalettes):
            returnTo(.findNewPalette)
            return .none
        case (.firstStrokes, .stroke), (.history, .history), (.drawOnLayer, .stroke):
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
        case (.selectColor, .reachedAddColor), (.tapAddColor, .openedColorList),
             (.openPalettes, .browsedPalettes), (.findNewPalette, .foundNewPalette),
             (.createPalette, .createdPalette), (.addPaletteColor, .openedColorEditor),
             (.adjustPaletteColor, .adjustedColor), (.savePaletteColor, .savedColor): return .advance
        case (.selectLasso, .failedLassoSelection), (.transformLasso, .failedLassoSelection):
            count += 1
            // Repeated misses end the lesson instead of blocking the tour.
            if count >= 3 { finishLesson() }
            return .none
        case (.openLasso, .openedLasso), (.selectLasso, .selectedLasso),
             (.transformLasso, .transformedLasso), (.finishLasso, .finishedLasso): return .advance
        case (.clearCanvas, .cleared): return .showResult
        case (.openTools, .openedTools), (.closeTools, .closedTools), (.reedStrokes, .stroke), (.reedStrokes, .filled),
             (.saveDrawing, .saved), (.shareDrawing, .closedSave), (.openMenu, .openedMenu),
             (.openGallery, .openedGallery), (.galleryFullscreen, .galleryFullscreen),
             (.deleteDrawing, .deleted), (.returnToCanvas, .returnedToCanvas),
             (.fillCanvas, .filled), (.openLayers, .openedLayers),
             (.openLayerSettings, .openedLayerSettings), (.lockTransparency, .lockedTransparency),
             (.closeLayerSettings, .closedLayerSettings), (.closeLayers, .closedLayers),
             (.paintOverStroke, .paintedOver), (.addLayer, .addedLayer): return .advance
        default: break
        }
        return .none
    }
    var visibleToolPages: Set<Int> { [0, 1, 2, 3, 4, 5, 6] }
    /// The fill lesson offers only the lesson's brush and Fill until the settings close.
    var limitsToolsToFill: Bool {
        (step == .chooseFill || step == .closeTools) && lessonSteps.contains(.chooseFill)
    }
    /// The repaint lesson needs a visible change, so the strokes' color cannot be chosen again.
    var locksLessonColor: Bool {
        (step == .pickColor || step == .closeTools) && lessonSteps.contains(.paintOverStroke)
    }
    /// Tool settings open on Color (1), or on Tool (2) when the lesson starts there.
    var initialToolPage: Int { step == .chooseFill ? 2 : 1 }
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
        case .closeTools where lessonSteps.contains(.chooseFill):
            // Scrolling past Fill before closing restores the selection exercise.
            if style.instrument != .fill { returnTo(.chooseFill) }
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
