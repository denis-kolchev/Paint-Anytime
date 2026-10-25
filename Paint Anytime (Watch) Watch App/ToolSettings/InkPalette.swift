import Foundation

struct InkPalette: Codable {
    var baseColors: [InkPreset]?
    var title: String?
    var generatedNameID: PaletteNameID?

    var displayTitle: String {
        if allColors.isEmpty { return L10n.text("New palette") }
        if let generatedNameID {
            return PaletteNameGenerator().displayName(generatedNameID)
        }
        return L10n.text(title ?? "Basic colors")
    }
    var customColors: [InkPreset] = []
    var selectedIDs: [String] = InkPreset.all.map(\.id)

    // Optional fields keep palettes saved before editing was introduced readable.
    var orderedIDs: [String]?
    var deletedIDs: [String]?

    init(baseColors: [InkPreset]? = nil, title: String? = nil,
         generatedNameID: PaletteNameID? = nil, customColors: [InkPreset] = [],
         selectedIDs: [String] = InkPreset.all.map(\.id),
         orderedIDs: [String]? = nil, deletedIDs: [String]? = nil) {
        self.baseColors = baseColors
        self.title = title
        self.generatedNameID = generatedNameID
        self.customColors = customColors
        self.selectedIDs = selectedIDs
        self.orderedIDs = orderedIDs
        self.deletedIDs = deletedIDs
    }

    var allColors: [InkPreset] {
        let available = ((baseColors ?? InkPaletteLibrary.basicColors) + customColors).filter { !(deletedIDs ?? []).contains($0.id) }
        let ordered = (orderedIDs ?? []).compactMap { id in available.first { $0.id == id } }
        return ordered + available.filter { !(orderedIDs ?? []).contains($0.id) }
    }

    mutating func delete(_ id: String) {
        guard !allColors.isEmpty else { return }
        deletedIDs = (deletedIDs ?? []) + [id]
        customColors.removeAll { $0.id == id }
        orderedIDs?.removeAll { $0 == id }
        selectedIDs.removeAll { $0 == id }
        if selectedIDs.isEmpty, let first = allColors.first { selectedIDs = [first.id] }
    }

    mutating func move(_ id: String, to target: String) {
        var ids = allColors.map(\.id)
        guard let from = ids.firstIndex(of: id), let to = ids.firstIndex(of: target), from != to else { return }
        ids.remove(at: from)
        ids.insert(id, at: to)
        orderedIDs = ids
    }
    var selectedColors: [InkPreset] {
        let selected = allColors.filter { selectedIDs.contains($0.id) }
        return selected.isEmpty ? Array(allColors.prefix(1)) : selected
    }

    static func decode(_ data: Data) -> InkPalette {
        guard var palette = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        var knownIDs = Set((palette.baseColors ?? InkPaletteLibrary.basicColors).map(\.id))
        palette.customColors = palette.customColors.filter { preset in
            let values = [preset.rgba.x, preset.rgba.y, preset.rgba.z, preset.rgba.w]
            return values.allSatisfy { $0.isFinite && (0...1).contains($0) }
                && knownIDs.insert(preset.id).inserted
        }
        palette.customColors = palette.customColors.map(\.resolvingColorName)
        palette.selectedIDs = palette.selectedColors.map(\.id)
        return palette
    }
}
