import Foundation

/// Shared URL vocabulary; legacy complication URLs remain supported.
enum PaintDeepLink: String {
    case canvas, gallery, settings, app
    case newCanvas = "new"

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "paintanytime",
              components.user == nil, components.password == nil, components.port == nil,
              components.path.isEmpty || components.path == "/",
              let host = components.host?.lowercased() else { return nil }
        if host == "new-canvas" { self = .newCanvas }
        else if let destination = Self(rawValue: host) { self = destination }
        else { return nil }
    }
}
