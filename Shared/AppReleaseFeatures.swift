import Foundation

/// Release availability is based on the public version, not the build number.
struct AppReleaseFeatures {
    static let current = AppReleaseFeatures(
        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    )

    let includesSecondReleaseTools: Bool
    let showsPhotoTransferControls: Bool

    init(version: String) {
        let majorVersion = Int(version.split(separator: ".").first ?? "") ?? 1
        includesSecondReleaseTools = majorVersion >= 2
        showsPhotoTransferControls = majorVersion >= 2
    }

    func allows(_ instrument: DrawingInstrument) -> Bool {
        switch instrument {
        case .pencil, .crayon, .watercolor: includesSecondReleaseTools
        default: true
        }
    }

    func allowsColor(_ color: SIMD4<Float>) -> Bool {
        includesSecondReleaseTools || !(color.x == 1 && color.y == 1 && color.z == 1)
    }

    func availableColor(_ color: SIMD4<Float>) -> SIMD4<Float> {
        allowsColor(color) ? color : SIMD4(0, 0, 0, color.w)
    }

    /// Apply only to the active tool; existing drawing strokes retain their appearance.
    func availableStyle(_ style: PencilStyle) -> PencilStyle {
        var result = style
        if !allows(result.instrument) {
            result.instrument = .monoline
            result.width = min(result.instrument.maximumWidth, max(1, result.width))
        }
        result.color = availableColor(result.color)
        return result
    }
}
