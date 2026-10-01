import Foundation

enum TutorialLesson {
    static func compactInstruction(for step: TutorialStep) -> String {
        switch step {
        case .inactive: return ""
        case .firstStrokes: return "Touch to draw."
        case .zoomCanvas: return "Turn the Digital Crown to zoom."
        case .panCanvas: return "Drag your finger to move around."
        case .finishCamera: return "Tap ✓ when ready."
        case .openTools: return "Tap the brush settings button."
        case .selectColor: return "Turn the Crown to choose a color."
        case .openWidth: return "Swipe left to Width."
        case .setWidth: return "Turn the Crown to change width."
        case .openTool: return "Swipe left to Tool."
        case .readToolInfo: return "Tap ⓘ to learn about any tool."
        case .selectReed: return "Choose Reed pen to set the angle."
        case .openAngle: return "Swipe left to Angle."
        case .setAngle: return "Turn the Crown to change the nib angle."
        case .closeTools: return "Tap ✓ to start drawing."
        case .reedStrokes: return "Try your new brush."
        case .history: return "Use the arrows to undo and redo."
        case .saveDrawing: return "Tap the button to save your drawing."
        case .shareDrawing: return "Scroll down to share your drawing, or tap × to close."
        case .openMenu: return "Tap ••• to visit the gallery."
        case .openGallery: return "Tap Gallery to see your saved drawings."
        case .galleryFullscreen: return "Turn the Crown or double-tap a picture."
        case .deleteDrawing: return "Tap the trash to delete a picture."
        case .returnToCanvas: return "Tap Back to leave the gallery."
        case .clearCanvas: return "Tap the broom to clear the canvas."
        case .finished: return "Well done! Tutorial complete."
        }
    }
    static func description(for step: TutorialStep) -> String { L10n.text(compactInstruction(for: step)) }
}
