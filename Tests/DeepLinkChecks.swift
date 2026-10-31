import Foundation

@main
struct DeepLinkChecks {
    static func main() {
        for (host, destination) in [("canvas", PaintDeepLink.canvas), ("gallery", .gallery),
                                    ("new", .newCanvas), ("settings", .settings),
                                    ("new-canvas", .newCanvas), ("app", .app)] {
            let url = URL(string: "paintanytime://\(host)")!
            precondition(PaintDeepLink(url: url) == destination)
            precondition(WatchLaunchRequest(url: url)?.destination == destination)
            precondition(WatchLaunchRequest(url: url)?.id != WatchLaunchRequest(url: url)?.id)
        }
        for value in ["https://gallery", "paintanytime://unknown", "paintanytime://gallery/extra",
                      "paintanytime://user@gallery", "paintanytime://gallery:123", "file:///tmp/a.paintanytime"] {
            precondition(PaintDeepLink(url: URL(string: value)!) == nil)
        }
        precondition(PaintDeepLink(url: URL(string: "PAINTANYTIME://CANVAS/?campaign=event")!) == .canvas)
        let artwork = WatchLaunchRequest(url: URL(string: "paintanytime://gallery?artwork=sample.png")!)
        precondition(artwork?.artworkFilename == "sample.png")
        let invalid = WatchLaunchRequest(url: URL(string: "paintanytime://gallery?artwork=..%2Fsample.png")!)
        precondition(invalid?.artworkFilename == nil)
        print("Deep link checks passed")
    }
}
