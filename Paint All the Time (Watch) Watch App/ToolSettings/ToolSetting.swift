import Foundation

enum ToolSetting: Int, CaseIterable {
    case width, color, instrument, mode, direction
    var title: String {
        switch self {
        case .width: L10n.text("Width")
        case .color: L10n.text("Color")
        case .instrument: L10n.text("Tool")
        case .mode: L10n.text("Mode")
        case .direction: L10n.text("Angle")
        }
    }
}

