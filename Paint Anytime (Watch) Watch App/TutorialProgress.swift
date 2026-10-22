import Foundation

enum TutorialStep: Int, CaseIterable {
    case inactive = 0
    case firstStrokes, holdCircle, zoomCanvas, panCanvas, finishCamera, openTools
    case selectColor, tapAddColor, openPalettes, findNewPalette, createPalette
    case addPaletteColor, adjustPaletteColor, savePaletteColor
    case openWidth, setWidth, openOpacity, setOpacity, openTool
    case selectReed, openAngle, setAngle, closeTools, reedStrokes
    case history, saveDrawing, shareDrawing, openMenu, openGallery
    case galleryFullscreen, deleteDrawing, returnToCanvas, clearCanvas, finished

    // The completion screen is a result, not another lesson.
    // Angle exercises are no longer part of the guided sequence.
    static var lessonCount: Int { finished.rawValue - 3 }
    var completedLessonCount: Int {
        max(0, rawValue - 1 - (rawValue >= TutorialStep.closeTools.rawValue ? 2 : 0))
    }
}

/// Pure exercise rules; completed skills remain available for exploration.
struct TutorialProgress {
    private(set) var step: TutorialStep = .inactive
    private(set) var count = 0
    private(set) var hasPanned = false
    private var unlockedToolPages: Set<Int> = [1]

    enum Event {
        case heldCircle, stroke, openedTools, closedTools, openedInfo, closedInfo, browsedTools
        case panned, finishedCamera, history, saved, closedSave, openedMenu, openedGallery
        case galleryFullscreen, deleted, returnedToCanvas, cleared
        case reachedAddColor, returnedToColorSelection, openedColorList, browsedPalettes, foundNewPalette
        case createdPalette, openedColorEditor, adjustedColor, savedColor
    }
    enum Effect: Equatable {
        case none, advance, showResult, pauseReminders
        case resumeReminders(advance: Bool)
    }
    mutating func start() { self = TutorialProgress(); step = .firstStrokes }
    mutating func stop() { step = .inactive }
    mutating func advance() {
        guard step != .inactive, step != .finished,
              let next = TutorialStep(rawValue: step.rawValue + 1) else { return }
        count = 0
        step = step == .selectReed ? .closeTools : next
        switch step {
        case .openWidth: unlockedToolPages.insert(0)
        case .openOpacity: unlockedToolPages.insert(5)
        case .openTool: unlockedToolPages.formUnion([2, 3, 6])
        case .selectReed: unlockedToolPages = visibleToolPages
        case .openAngle: unlockedToolPages.insert(4)
        default: break
        }
    }
    mutating func record(_ event: Event) -> Effect {
        switch (step, event) {
        case (.selectReed, .browsedTools): return .advance
        case (.tapAddColor, .returnedToColorSelection):
            step = .selectColor
            count = 0
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
        case (.selectColor, .reachedAddColor), (.tapAddColor, .openedColorList),
             (.openPalettes, .browsedPalettes), (.findNewPalette, .foundNewPalette),
             (.createPalette, .createdPalette), (.addPaletteColor, .openedColorEditor),
             (.adjustPaletteColor, .adjustedColor), (.savePaletteColor, .savedColor): return .advance
        case (.clearCanvas, .cleared): return .showResult
        case (.openTools, .openedTools), (.closeTools, .closedTools), (.reedStrokes, .stroke),
             (.saveDrawing, .saved), (.shareDrawing, .closedSave), (.openMenu, .openedMenu),
             (.openGallery, .openedGallery), (.galleryFullscreen, .galleryFullscreen),
             (.deleteDrawing, .deleted), (.returnToCanvas, .returnedToCanvas): return .advance
        default: break
        }
        return .none
    }
    var visibleToolPages: Set<Int> { [0, 1, 2, 3, 4, 5, 6] }
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
        case .selectReed: return old.instrument != style.instrument
        case .setAngle: return page == 4 && style.instrument == .reed && old.reedAngle != style.reedAngle
        default: return false
        }
    }
}
