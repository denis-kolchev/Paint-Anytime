import Foundation

enum TutorialLesson {
    static func compactInstruction(for step: TutorialStep) -> String {
        switch step {
        case .inactive: return ""
        case .firstStrokes: return L10n.text("Touch to draw.")
        case .zoomCanvas: return L10n.text("Turn the Digital Crown to zoom.")
        case .panCanvas: return L10n.text("Drag your finger to move around.")
        case .finishCamera: return L10n.text("Tap ✓ when ready.")
        case .openTools: return L10n.text("Tap the brush settings button.")
        case .selectColor: return L10n.text("Turn the Crown to choose a color.")
        case .openWidth: return L10n.text("Swipe left to Width.")
        case .setWidth: return L10n.text("Turn the Crown to change width.")
        case .openTool: return L10n.text("Swipe left to Tool.")
        case .readToolInfo: return L10n.text("Tap ⓘ to learn about any tool.")
        case .selectReed: return L10n.text("Choose Reed pen to set the angle.")
        case .openAngle: return L10n.text("Swipe left to Angle.")
        case .setAngle: return L10n.text("Turn the Crown to change the nib angle.")
        case .closeTools: return L10n.text("Tap ✓ to start drawing.")
        case .reedStrokes: return L10n.text("Try your new brush.")
        case .history: return L10n.text("Use the arrows to undo and redo.")
        case .saveDrawing: return L10n.text("Tap the button to save your drawing.")
        case .shareDrawing: return L10n.text("Scroll down to share your drawing, or tap × to close.")
        case .openMenu: return L10n.text("Tap ••• to visit the gallery.")
        case .openGallery: return L10n.text("Tap Gallery to see your saved drawings.")
        case .galleryFullscreen: return L10n.text("Turn the Crown or double-tap a picture.")
        case .deleteDrawing: return L10n.text("Tap the trash to delete a picture.")
        case .returnToCanvas: return L10n.text("Tap Back to leave the gallery.")
        case .clearCanvas: return L10n.text("Tap the broom to clear the canvas.")
        case .finished: return L10n.text("Well done! Tutorial complete.")
        }
    }
    static func description(for step: TutorialStep) -> String { compactInstruction(for: step) }
}
