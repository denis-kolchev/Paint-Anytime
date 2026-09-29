import Foundation

/// Raw values retain the lesson order used by localized lesson descriptions.
enum TutorialStep: Int, CaseIterable {
    case inactive = 0
    case firstStrokes = 1
    case openTools = 2
    case selectGreen = 3
    case openWidth = 4
    case setWidth = 5
    case selectReed = 6
    case readToolInfo = 7
    case setAngle = 8
    case reedStrokes = 9
    case zoomCanvas = 10
    case panCanvas = 11
    case history = 12
    case saveDrawing = 13
    case shareDrawing = 14
    case openGallery = 15
    case galleryFullscreen = 16
    case deleteDrawing = 17
    case returnToCanvas = 18
    case clearCanvas = 19
    case finished = 20
}

/// Pure exercise rules. Timing, observation, and presentation belong to TutorialSession.
struct TutorialProgress {
    private(set) var step: TutorialStep = .inactive
    private(set) var count = 0
    private(set) var hasPanned = false
    private var hasClosedTools = false
    private var hasOpenedInfo = false

    enum Event {
        case stroke, openedTools, closedTools, openedInfo, closedInfo
        case panned, finishedCamera, history, saved, closedSave, openedGallery
        case galleryFullscreen, deleted, returnedToCanvas, cleared
    }

    enum Effect: Equatable {
        case none, advance, showResult, pauseReminders
        case resumeReminders(advance: Bool)
    }

    mutating func start() {
        self = TutorialProgress()
        step = .firstStrokes
    }

    mutating func stop() { step = .inactive }

    mutating func advance() {
        guard step != .inactive, step != .finished,
              let next = TutorialStep(rawValue: step.rawValue + 1) else { return }
        count = 0
        step = next
    }

    mutating func record(_ event: Event) -> Effect {
        switch (step, event) {
        case (.firstStrokes, .stroke):
            count += 1
            return count >= 2 ? .advance : .none
        case (.openTools, .openedTools): return .showResult
        case (.readToolInfo, .openedInfo):
            hasOpenedInfo = true
            return .pauseReminders
        case (.readToolInfo, .closedInfo): return .resumeReminders(advance: hasOpenedInfo)
        case (.reedStrokes, .closedTools): hasClosedTools = true
        case (.reedStrokes, .stroke):
            if hasClosedTools { count += 1 }
            return count >= 2 ? .advance : .none
        case (.panCanvas, .panned): hasPanned = true
        case (.panCanvas, .finishedCamera): return hasPanned ? .advance : .none
        case (.history, .history):
            count += 1
            return count >= 2 ? .showResult : .none
        case (.openGallery, .openedGallery), (.returnToCanvas, .returnedToCanvas), (.clearCanvas, .cleared):
            return .showResult
        case (.saveDrawing, .saved), (.shareDrawing, .closedSave),
             (.galleryFullscreen, .galleryFullscreen), (.deleteDrawing, .deleted): return .advance
        default: break
        }
        return .none
    }

    var visibleToolPages: Set<Int> {
        switch step {
        case .selectGreen: [1]
        case .openWidth: [1, 0]
        case .setWidth: [0]
        case .selectReed: [0, 2]
        case .readToolInfo: [2]
        case .setAngle: [2, 4]
        case .reedStrokes: [4]
        default: [0, 1, 2, 3, 4]
        }
    }

    func allowsToolAdjustment(page: Int) -> Bool {
        switch step {
        case .selectGreen: page == 1
        case .setWidth: page == 0
        case .selectReed: page == 2
        case .setAngle: page == 4
        default: false
        }
    }

    func allowsToolPage(_ page: Int) -> Bool {
        switch step {
        case .openWidth: page == 0
        case .selectReed: page == 2
        case .setAngle: page == 4
        default: false
        }
    }

    func completesPageChange(_ page: Int) -> Bool { step == .openWidth && page == 0 }

    /// Nil means this lesson does not evaluate tool adjustments.
    func matchesStyle(_ style: PencilStyle) -> Bool? {
        switch step {
        case .selectGreen: style.color == SIMD4<Float>(0.2, 0.7, 0.35, 1)
        case .setWidth: style.width == 10
        case .selectReed: style.instrument == .reed
        case .setAngle: style.reedAngle == 20
        default: nil
        }
    }
}
