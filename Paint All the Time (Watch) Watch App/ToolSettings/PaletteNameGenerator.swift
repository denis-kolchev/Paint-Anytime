import Foundation

/// Local, deterministic palette naming. Add this file to the watchOS target (watchOS 10+).
/// Add PaletteNames500.json as a bundled resource for that target.
/// Stores stable IDs, NOT localized display strings.
nonisolated struct PaletteNameID: Codable, Hashable, Sendable {
    let theme: Int      // 0..<20
    let mood: Int       // 0..<25
    let suffix: Int     // 1 for the base name; 2+ only when all 500 names are taken

    var key: String { "palette.\(theme).\(mood).\(suffix)" }
}

nonisolated struct PaletteNameGenerator {
    static let capacity = 500

    /// Semantic anchors; ordering must match the translated JSON themes.
    private static let anchors: [String] = [
        "#1976B4", "#22B8A9", "#77BEFA", "#B6E6F1", "#313C82",
        "#6B57B2", "#B578BA", "#DC739B", "#BD3C53", "#D65028",
        "#F6D24E", "#D1A36E", "#BA6842", "#D99836", "#2F764B",
        "#91B64D", "#727B37", "#69775C", "#8C8D8E", "#E1DBCE"
    ]

    /// Each atmosphere occupies a distinct region in perceptual-features space.
    /// Feature coordinates are lightness, chroma, contrast and warmth (all 0...1).
    /// The weights and anchors are starting points: tune against real user palettes.
    private static let moods: [(Double, Double, Double, Double)] = [
        (0.78,0.48,0.30,0.55), (0.43,0.62,0.59,0.80), (0.18,0.38,0.55,0.20),
        (0.88,0.54,0.50,0.61), (0.48,0.48,0.32,0.32), (0.72,0.20,0.19,0.39),
        (0.67,0.31,0.19,0.64), (0.70,0.76,0.48,0.72), (0.76,0.67,0.43,0.54),
        (0.57,0.28,0.17,0.40), (0.67,0.39,0.27,0.51), (0.48,0.16,0.12,0.39),
        (0.40,0.43,0.61,0.46), (0.80,0.69,0.41,0.61), (0.35,0.46,0.29,0.59),
        (0.84,0.34,0.54,0.22), (0.77,0.25,0.13,0.59), (0.58,0.64,0.44,0.30),
        (0.29,0.36,0.68,0.18), (0.55,0.89,0.63,0.69), (0.60,0.41,0.14,0.50),
        (0.81,0.40,0.22,0.35), (0.58,0.32,0.32,0.37), (0.86,0.17,0.43,0.19),
        (0.66,0.75,0.63,0.47)
    ]

    /// `usedByOtherPalettes` MUST exclude the palette currently being renamed.
    /// It should contain the names already assigned to every other palette.
    /// For best stability pass the palette's prior ID in `previous`.
    func generate(hexColors: [String],
                  usedByOtherPalettes: Set<PaletteNameID> = [],
                  previous: PaletteNameID? = nil) -> PaletteNameID {
        let labs = hexColors.compactMap { Self.parseHex($0) }.map(Self.toOKLab)
        guard !labs.isEmpty else {
            return firstAvailable(used: usedByOtherPalettes, preferred: PaletteNameID(theme: 19, mood: 11, suffix: 1))
        }
        let meanL = labs.map(\.l).reduce(0,+) / Double(labs.count)
        let chromas = labs.map { hypot($0.a, $0.b) }
        let meanC = chromas.reduce(0,+) / Double(chromas.count)
        let lightRange = (labs.map(\.l).max() ?? 0) - (labs.map(\.l).min() ?? 0)
        let warmth = labs.map { lab -> Double in
            let hue = atan2(lab.b, lab.a) * 180 / .pi
            let adjusted = hue < 0 ? hue + 360 : hue
            let distance = abs(adjusted - 52)
            return 1 - min(distance, 360-distance) / 180
        }.reduce(0,+) / Double(labs.count)
        let profile = (meanL, min(meanC / 0.24, 1), min(lightRange / 0.7, 1), warmth)

        let anchors = Self.anchors.compactMap(Self.parseHex).map(Self.toOKLab)
        var candidates: [(id: PaletteNameID, score: Double)] = []
        for t in 0..<anchors.count {
            let a = anchors[t]
            // Make chromatic colors carry more signal than neutral white/grey/black.
            // Neutral palettes naturally prefer stone and pearl.
            let themeDist = labs.map { c -> Double in
                let dL = (c.l - a.l) * 0.38
                let da = c.a - a.a
                let db = c.b - a.b
                let weight = 0.4 + min(1, hypot(c.a,c.b) / 0.12)
                return sqrt(dL*dL + da*da + db*db) * weight
            }.reduce(0,+) / Double(labs.count)
            for m in 0..<25 {
                let x = Self.moods[m]
                let moodDist = abs(profile.0-x.0)*0.33
                             + abs(profile.1-x.1)*0.31
                             + abs(profile.2-x.2)*0.23
                             + abs(profile.3-x.3)*0.13
                let score = themeDist*1.85 + moodDist*0.42
                candidates.append((PaletteNameID(theme:t,mood:m,suffix:1),score))
            }
        }
        candidates.sort {
            if abs($0.score - $1.score) > 0.0000001 { return $0.score < $1.score }
            return $0.id.key < $1.id.key
        }
        // Stability: don't rename just because a new combination is marginally better.
        if let previous, previous.suffix == 1,
           !usedByOtherPalettes.contains(previous),
           let old = candidates.first(where: { $0.id == previous }),
           let best = candidates.first, old.score <= best.score + 0.018 {
            return previous
        }
        if let available = candidates.first(where: { !usedByOtherPalettes.contains($0.id) }) {
            return available.id
        }
        // More than 500 palettes: preserve uniqueness with a numbered suffix.
        return firstAvailable(used: usedByOtherPalettes, preferred: candidates[0].id)
    }

    private func firstAvailable(used: Set<PaletteNameID>, preferred: PaletteNameID) -> PaletteNameID {
        if !used.contains(preferred) { return preferred }
        for t in 0..<20 { for m in 0..<25 {
            let id = PaletteNameID(theme:t,mood:m,suffix:1)
            if !used.contains(id) { return id }
        }}
        var n = 2
        while used.contains(PaletteNameID(theme:preferred.theme,mood:preferred.mood,suffix:n)) { n += 1 }
        return PaletteNameID(theme:preferred.theme,mood:preferred.mood,suffix:n)
    }

    /// Names are complete locale-specific phrases, not assembled at runtime.
    /// Language is the current user-selected AppLanguage; all 28 are bundled.
    @MainActor
    func displayName(_ id: PaletteNameID, language: String? = nil) -> String {
        let language = language ?? AppLanguage.currentCode
        guard (0..<20).contains(id.theme), (0..<25).contains(id.mood) else { return L10n.text("Palette") }
        let names = Self.translations[language] ?? Self.translations["en"]
        guard let names, names.indices.contains(id.theme), names[id.theme].indices.contains(id.mood)
        else { return L10n.text("Palette") }
        let name = names[id.theme][id.mood]
        return id.suffix == 1 ? name : name + " (\(id.suffix))"
    }

    private static let translations: [String: [[String]]] = {
        guard let url = Bundle.main.url(forResource: "PaletteNames500", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let translations = try? JSONDecoder().decode([String: [[String]]].self, from: data)
        else { return [:] }
        return translations
    }()

    nonisolated private struct Lab { let l: Double; let a: Double; let b: Double }
    private static func parseHex(_ raw: String) -> (Double,Double,Double)? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.first == "#" { s.removeFirst() }
        guard s.count == 6, let n = UInt32(s, radix: 16) else { return nil }
        return (Double((n >> 16) & 255)/255, Double((n >> 8) & 255)/255, Double(n & 255)/255)
    }
    private static func toOKLab(_ rgb: (Double,Double,Double)) -> Lab {
        func linear(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x+0.055)/1.055, 2.4) }
        let r=linear(rgb.0), g=linear(rgb.1), b=linear(rgb.2)
        let l=cbrt(0.4122214708*r + 0.5363325363*g + 0.0514459929*b)
        let m=cbrt(0.2119034982*r + 0.6806995451*g + 0.1073969566*b)
        let s=cbrt(0.0883024619*r + 0.2817188376*g + 0.6299787005*b)
        return Lab(l:0.2104542553*l+0.7936177850*m-0.0040720468*s,
                   a:1.9779984951*l-2.4285922050*m+0.4505937099*s,
                   b:0.0259040371*l+0.7827717662*m-0.8086757660*s)
    }
}
