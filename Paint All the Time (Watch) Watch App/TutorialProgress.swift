import Foundation

enum TutorialStep: Int, CaseIterable {
    case inactive = 0
    case firstStrokes, zoomCanvas, panCanvas, finishCamera, openTools
    case selectColor, openWidth, setWidth, openTool, readToolInfo
    case selectReed, openAngle, setAngle, closeTools, reedStrokes
    case history, saveDrawing, shareDrawing, openMenu, openGallery
    case galleryFullscreen, deleteDrawing, returnToCanvas, clearCanvas, finished

    // The completion screen is a result, not another lesson.
    static var lessonCount: Int { finished.rawValue - 1 }
}

/// Pure exercise rules; completed skills remain available for exploration.
struct TutorialProgress {
    private(set) var step: TutorialStep = .inactive
    private(set) var count = 0
    private(set) var hasPanned = false
    private var hasOpenedInfo = false

    enum Event {
        case stroke, openedTools, closedTools, openedInfo, closedInfo
        case panned, finishedCamera, history, saved, closedSave, openedMenu, openedGallery
        case galleryFullscreen, deleted, returnedToCanvas, cleared
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
        step = next
    }
    mutating func record(_ event: Event) -> Effect {
        switch (step, event) {
        case (.firstStrokes, .stroke), (.history, .history):
            count += 1
            return count >= 2 ? .advance : .none
        case (.panCanvas, .panned):
            hasPanned = true
            return .advance
        case (.finishCamera, .finishedCamera): return hasPanned ? .advance : .none
        case (.readToolInfo, .openedInfo):
            hasOpenedInfo = true
            return .pauseReminders
        case (.readToolInfo, .closedInfo): return .resumeReminders(advance: hasOpenedInfo)
        case (.clearCanvas, .cleared): return .showResult
        case (.openTools, .openedTools), (.closeTools, .closedTools), (.reedStrokes, .stroke),
             (.saveDrawing, .saved), (.shareDrawing, .closedSave), (.openMenu, .openedMenu),
             (.openGallery, .openedGallery), (.galleryFullscreen, .galleryFullscreen),
             (.deleteDrawing, .deleted), (.returnToCanvas, .returnedToCanvas): return .advance
        default: break
        }
        return .none
    }
    var visibleToolPages: Set<Int> { [0, 1, 2, 3, 4] }
    func allowsToolAdjustment(page: Int) -> Bool { visibleToolPages.contains(page) }
    func allowsToolPage(_ page: Int) -> Bool { visibleToolPages.contains(page) }
    func completesPageChange(_ page: Int) -> Bool {
        (step == .openWidth && page == 0) || (step == .openTool && page == 2)
            || (step == .openAngle && page == 4)
    }
    mutating func changedStyle(from old: PencilStyle, to style: PencilStyle, page: Int) -> Bool {
        if [.openAngle, .setAngle, .closeTools].contains(step), style.instrument != .reed {
            step = .selectReed
            return false
        }
        switch step {
        case .selectColor: return page == 1 && old.color != style.color
        case .setWidth: return page == 0 && old.width != style.width
        case .selectReed: return style.instrument == .reed
        case .setAngle: return page == 4 && style.instrument == .reed && old.reedAngle != style.reedAngle
        default: return false
        }
    }
}
