import Foundation

/// An identity per tap also handles repeated launches of the same complication.
struct WatchLaunchRequest: Identifiable {
    enum Destination: String { case newCanvas = "new-canvas", gallery, app }
    let id = UUID()
    let destination: Destination
    let artworkFilename: String?

    init?(url: URL) {
        guard url.scheme == "paintanytime", let host = url.host,
              let destination = Destination(rawValue: host),
              url.path.isEmpty || url.path == "/" else { return nil }
        self.destination = destination
        let filename = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "artwork" })?.value
        if destination == .gallery, let filename,
           !filename.contains("/"), !filename.contains("\\"),
           filename.lowercased().hasSuffix(".png") {
            artworkFilename = filename
        } else {
            artworkFilename = nil
        }
    }
}
