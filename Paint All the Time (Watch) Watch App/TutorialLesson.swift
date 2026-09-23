import Foundation

/// Stable source keys let each lesson use the same localization path as the editor.
enum TutorialLesson {
    private static let descriptions: [String] = [
        "Welcome to Paint Anytime! Draw two separate strokes in the center of the canvas. Your own drawings are safe during this tutorial.",
        "Let's try another brush. Tap the tool button in the upper-right corner.",
        "Turn the Digital Crown or tap a neighboring color to select green.",
        "Swipe left or tap Width at the bottom to open the width setting.",
        "Turn the Digital Crown to set the width to 10 pt.",
        "Open the Tool page and select Reed pen using the Digital Crown or the tool list.",
        "Tap the information button at the top left. Read about the tool, then close the page with the cross.",
        "Open the Angle page and set the nib angle to 20 degrees. Use the Digital Crown or the arrow buttons.",
        "Tap the green checkmark to return to the canvas, then draw two strokes with your new brush.",
        "Turn the Digital Crown to zoom the canvas in or out, then stop turning.",
        "You are in camera mode. Drag to move the canvas, then tap the green checkmark.",
        "Try Undo and Redo at the bottom. Use these buttons twice in total.",
        "Save your drawing with the button in the lower-right corner. It goes into the temporary tutorial gallery.",
        "Share offers the options available on your watch. You can try sharing, then close this page with the cross to continue.",
        "Tap the three dots at the top left, then choose Gallery.",
        "These are practice pictures. Turn the Digital Crown or tap a picture twice to open it at full size.",
        "In the regular gallery, you can also edit and share drawings. Swipe to browse the pictures. Choose one, tap the trash button and confirm deletion. Only a tutorial copy is deleted.",
        "Use the back button at the top left until you return to the canvas.",
        "Tap the broom in the lower-left corner and confirm to clear the practice canvas.",
        "Well done! Your own canvas and gallery will return. To repeat the tour, tap the three dots and choose Tutorial."
    ]

    static func description(for step: Int) -> String {
        guard descriptions.indices.contains(step - 1) else { return "" }
        return L10n.text(descriptions[step - 1])
    }
}
