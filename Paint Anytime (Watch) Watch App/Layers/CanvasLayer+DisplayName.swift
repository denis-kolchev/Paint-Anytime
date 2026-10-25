import Foundation

extension CanvasLayer {
    var displayName: String {
        if name.hasPrefix("Layer "), let number = Int(name.dropFirst(6)) {
            return L10n.format("Layer %d", number)
        }
        return name
    }
}
