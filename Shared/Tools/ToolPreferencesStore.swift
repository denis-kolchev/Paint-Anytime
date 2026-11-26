import Foundation

struct ToolPreferencesStore {
    let defaults: UserDefaults

    var styles: [Int: PencilStyle] {
        defaults.data(forKey: "drawing.styles.v1")
            .flatMap { try? JSONDecoder().decode([Int: PencilStyle].self, from: $0) } ?? [:]
    }

    var synchronization: ToolSynchronization {
        defaults.data(forKey: "drawing.synchronization.v1")
            .flatMap { try? JSONDecoder().decode(ToolSynchronization.self, from: $0) } ?? ToolSynchronization()
    }

    var instrument: DrawingInstrument {
        DrawingInstrument(rawValue: defaults.integer(forKey: "drawing.instrument.v1")) ?? .monoline
    }

    func save(styles: [Int: PencilStyle], synchronization: ToolSynchronization,
              instrument: DrawingInstrument) -> Bool {
        guard let stylesData = try? JSONEncoder().encode(styles),
              let synchronizationData = try? JSONEncoder().encode(synchronization) else { return false }
        defaults.set(stylesData, forKey: "drawing.styles.v1")
        defaults.set(synchronizationData, forKey: "drawing.synchronization.v1")
        defaults.set(instrument.rawValue, forKey: "drawing.instrument.v1")
        return true
    }
}
