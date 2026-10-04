import Foundation

enum ToolSetting: Int, CaseIterable {
    // Keep stored page identifiers stable; display order is defined by the view.
    case width, color, instrument, mode, direction, opacity
    var title: String {
        switch self {
        case .opacity: L10n.text("Opacity")
        case .width: L10n.text("Width")
        case .color: L10n.text("Color")
        case .instrument: L10n.text("Tool")
        case .mode: L10n.text("Mode")
        case .direction: L10n.text("Angle")
        }
    }
}

