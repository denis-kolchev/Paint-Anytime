import Foundation

struct SavedInkPalette: Codable, Identifiable {
    var id: String
    var palette: InkPalette
    var isHidden: Bool?

    var isVisible: Bool { isHidden != true }
    var isBuiltIn: Bool { InkPaletteLibrary.builtInIDs.contains(id) }
}

struct InkPaletteLibrary: Codable {
    var palettes: [SavedInkPalette]
    var activeID: String

    static let builtInIDs = Set(initial.palettes.map(\.id))

    var visiblePalettes: [SavedInkPalette] { palettes.filter(\.isVisible) }

    var activePalette: InkPalette {
        visiblePalettes.first { $0.id == activeID }?.palette
            ?? visiblePalettes.first?.palette ?? InkPalette()
    }

    /// Merge the browser's visible draft without deleting hidden palettes.
    func mergingVisiblePalettes(_ draft: Self) -> Self {
        var remaining = draft.palettes.makeIterator()
        var merged: [SavedInkPalette] = []
        for entry in palettes {
            if !entry.isVisible { merged.append(entry) }
            else if let next = remaining.next() { merged.append(next) }
        }
        while let next = remaining.next() { merged.append(next) }
        return Self(palettes: merged, activeID: draft.activeID)
    }

    static var tutorial: Self {
        return Self(palettes: [SavedInkPalette(id: "tutorial", palette:
            initial.activePalette)],
            activeID: "tutorial")
    }

    static let basicColors = InkPreset.all + colors("basic", "78CBB0 CDB4DB E9CBA7")

    private static func colors(_ id: String, _ hexes: String) -> [InkPreset] {
        hexes.split(separator: " ").enumerated().map { index, hex in
            let value = UInt32(hex, radix: 16)!
            return InkPreset(customID: "\(id)-\(index)", nameKey: "#\(hex)",
                rgba: SIMD4(Float((value >> 16) & 255) / 255,
                            Float((value >> 8) & 255) / 255, Float(value & 255) / 255, 1))
        }
    }

    static var initial: Self {
        let families: [(String, String, String)] = [
            ("reds", "Reds", "541D32 84243D B63246 E0444D F16C65 F6A08C F8C9B5 C94F70 E88FA9 F2C3CF 8C4138 B56B50 D69A72 777B62 F4E6D5"),
            ("oranges", "Oranges", "713C2B A54E2E D66A30 ED893B F7AC59 F6CA88 F8E2B5 C55A46 E98470 F2B3A0 B7844D D4AE64 858E68 4F7275 F4EBDD"),
            ("yellows", "Yellows", "73602C A68B32 D3B23B F2CE46 F9E373 FBF0AF F5E9CE D9993D EEB46A C3BF69 8E9D62 577B70 A67B6B D2AAA0 F8F4E5"),
            ("greens", "Greens", "183F38 28634B 41865B 66A56D 96C58A C8DDA9 E6EBD0 607748 92934F C3B66C 3F8980 79B6A6 B7D9C5 A66E56 E3BA95"),
            ("sky", "Light blues", "244E65 347C98 55A8C4 81CAE0 B8E4EE E0F2F1 327C80 67B4AE A2D6C6 658BAE 9AB8D9 CCD7EB B09CBF E6C2B3 F5E7CF"),
            ("blues", "Blues", "172944 244671 3266A3 4E8ACA 85B2E0 C0D7ED 284C62 397E91 7FB8BE 424879 7378A9 B4B6D3 987C86 D3AAA0 ECE4D7"),
            ("purples", "Purples", "382743 593B70 80559B A47BBB C8A8D7 E7D2E9 443E73 716BA6 ABA5D1 814766 B67794 DDA8BB 7A8A80 B8C7AB F0E3D0"),
            ("mono", "Black & white", "000000 191919 303030 484848 606060 787878 909090 A8A8A8 C0C0C0 D8D8D8 E8E8E8 F4F4F4 FFFFFF 827D77 A4ADB2"),
            ("browns", "Browns", "382B25 594034 7C5140 A16C4F C28C66 DDB491 EED8B8 713F3B A56455 CB9180 626346 8D9065 B8B58A 6E7770 C7C8B6")
        ]
        var entries = [SavedInkPalette(id: "basic", palette: InkPalette(title: "Basic colors"))]
        entries += families.map { id, title, hexes in
            let swatches = colors(id, hexes)
            return SavedInkPalette(id: id, palette: InkPalette(baseColors: swatches, title: title,
                                                               selectedIDs: swatches.map(\.id)), isHidden: true)
        }
        return Self(palettes: entries, activeID: "basic")
    }

    static func decode(_ data: Data, legacy: Data) -> Self {
        if let saved = try? JSONDecoder().decode(Self.self, from: data),
           Set(saved.palettes.map(\.id)).count == saved.palettes.count,
           saved.palettes.contains(where: { $0.id == saved.activeID && !$0.palette.selectedColors.isEmpty }) {
            return saved
        }
        var result = initial
        if !legacy.isEmpty {
            result.palettes[0].palette = InkPalette.decode(legacy)
            result.palettes[0].palette.title = "Basic colors"
        }
        return result
    }
}
