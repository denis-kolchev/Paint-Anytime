import SwiftUI

struct InkPreset: Codable, Identifiable {
    var id: String { customID ?? nameKey }
    var customID: String? = nil
    let nameKey: String
    var name: String { L10n.text(resolvedNameKey) }

    // Legacy custom colors stored their HEX as the name. Built-in names stay intact.
    var resolvedNameKey: String {
        guard customID != nil else { return nameKey }
        return NamedInkColors.name(forHex: nameKey) ?? nameKey
    }

    var resolvingColorName: InkPreset {
        InkPreset(customID: customID, nameKey: resolvedNameKey, rgba: rgba)
    }
    let rgba: SIMD4<Float>

    var color: Color {
        Color(.sRGB, red: Double(rgba.x), green: Double(rgba.y),
              blue: Double(rgba.z), opacity: Double(rgba.w))
    }

    static let all: [InkPreset] = [
        .init(nameKey: "Black", rgba: SIMD4(0, 0, 0, 1)),
        .init(nameKey: "Gray", rgba: SIMD4(0.45, 0.45, 0.48, 1)),
        .init(nameKey: "Red", rgba: SIMD4(0.95, 0.18, 0.22, 1)),
        .init(nameKey: "Orange", rgba: SIMD4(1, 0.5, 0.1, 1)),
        .init(nameKey: "Yellow", rgba: SIMD4(1, 0.8, 0.1, 1)),
        .init(nameKey: "Green", rgba: SIMD4(0.2, 0.7, 0.35, 1)),
        .init(nameKey: "Light blue", rgba: SIMD4(0.15, 0.7, 0.9, 1)),
        .init(nameKey: "Blue", rgba: SIMD4(0.15, 0.35, 0.95, 1)),
        .init(nameKey: "Purple", rgba: SIMD4(0.6, 0.3, 0.85, 1)),
        .init(nameKey: "Pink", rgba: SIMD4(0.95, 0.35, 0.65, 1)),
        .init(nameKey: "Brown", rgba: SIMD4(0.55, 0.32, 0.18, 1)),
        .init(nameKey: "White", rgba: SIMD4(1, 1, 1, 1))
    ]

}
