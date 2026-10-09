import Foundation

/// An identity per tap also handles repeated launches of the same complication.
struct WatchLaunchRequest: Identifiable {
    enum Destination: String { case newCanvas = "new-canvas", gallery, app }
    let id = UUID()
    let destination: Destination

    init?(url: URL) {
        guard url.scheme == "paintanytime", let host = url.host,
              let destination = Destination(rawValue: host),
              url.path.isEmpty || url.path == "/" else { return nil }
        self.destination = destination
    }
}
