import Foundation

/// Release availability is based on the public version, not the build number.
struct AppReleaseFeatures {
    static let current = AppReleaseFeatures(
        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    )

    let includesVersion11Tools: Bool
    let showsPhotoTransferControls: Bool

    init(version: String) {
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        let majorVersion = components.first.flatMap { Int($0) } ?? 1
        let minorVersion = components.count > 1 ? Int(components[1]) ?? 0 : 0
        let isVersion11OrLater = majorVersion > 1 || (majorVersion == 1 && minorVersion >= 1)
        includesVersion11Tools = isVersion11OrLater
        showsPhotoTransferControls = isVersion11OrLater
    }

    func allows(_ instrument: DrawingInstrument) -> Bool {
        switch instrument {
        case .pencil, .crayon, .watercolor: includesVersion11Tools
        default: true
        }
    }

    /// Apply only to the active tool; existing drawing strokes retain their appearance.
    func availableStyle(_ style: PencilStyle) -> PencilStyle {
        var result = style
        if !allows(result.instrument) {
            result.instrument = .monoline
            result.width = min(result.instrument.maximumWidth, max(1, result.width))
        }
        return result
    }
}
