import Combine
import Foundation

final class ToolSettings: ObservableObject {
    @Published var pencilStyle: PencilStyle {
        didSet {
            let availableStyle = AppReleaseFeatures.current.availableStyle(pencilStyle)
            if pencilStyle != availableStyle { pencilStyle = availableStyle }
            guard pencilStyle != oldValue else { return }
            savedStyles[pencilStyle.instrument.rawValue] = pencilStyle
            propagateSynchronizedStyle()
            scheduleStylePersistence()
        }
    }
    @Published private(set) var synchronization = ToolSynchronization()

    @Published private(set) var blendingMode: ColorBlendingMode = .hybrid
    private static let blendingKey = "drawing.blending.v1"

    func setBlendingMode(_ mode: ColorBlendingMode) {
        guard mode != blendingMode else { return }
        blendingMode = mode
        pencilStyle.blendingMode = mode
        if persistsPreferences { preferences.defaults.set(mode.rawValue, forKey: Self.blendingKey) }
    }

    var maximumWidth: Float { pencilStyle.instrument.maximumWidth }

    func setSynchronizeWidth(_ enabled: Bool) {
        guard synchronization.width != enabled else { return }
        synchronization.width = enabled
        synchronizationChanged()
    }

    func setSynchronizeColor(_ enabled: Bool) {
        guard synchronization.color != enabled else { return }
        synchronization.color = enabled
        synchronizationChanged()
    }

    func setSynchronizeOpacity(_ enabled: Bool) {
        guard synchronization.opacity != enabled else { return }
        synchronization.opacity = enabled
        synchronizationChanged()
    }

    private func synchronizationChanged() {
        // Enabling synchronization uses the current tool as the starting value.
        propagateSynchronizedStyle()
        scheduleStylePersistence()
    }

    private func propagateSynchronizedStyle() {
        guard synchronization.width || synchronization.color || synchronization.opacity else { return }
        var updated = synchronization
        if updated.width { updated.sharedWidth = pencilStyle.width }
        if updated.color && pencilStyle.instrument != .eraser {
            updated.sharedColor = pencilStyle.color
        }
        if updated.opacity && pencilStyle.instrument != .eraser {
            updated.sharedOpacity = pencilStyle.effectiveOpacity
        }
        // Publish once, and only if shared values actually changed.
        if updated != synchronization { synchronization = updated }
        for instrument in DrawingInstrument.allCases {
            var style = savedStyles[instrument.rawValue] ?? .initial(for: instrument)
            if synchronization.width { style.width = synchronization.sharedWidth }
            if synchronization.color && instrument != .eraser { style.color = synchronization.sharedColor }
            if synchronization.opacity && instrument != .eraser { style.opacity = synchronization.sharedOpacity }
            savedStyles[instrument.rawValue] = style
        }
    }

    private var pendingStyleSave: Task<Void, Never>?
    private var stylePreferencesDirty = false

    private func scheduleStylePersistence() {
        guard persistsPreferences else { return }
        stylePreferencesDirty = true
        pendingStyleSave?.cancel()
        pendingStyleSave = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.flushStylePreferences()
        }
    }

    /// Flush when leaving settings or going inactive, even during a Crown gesture.
    func flushStylePreferences() {
        pendingStyleSave?.cancel()
        pendingStyleSave = nil
        guard stylePreferencesDirty,
              preferences.save(styles: savedStyles, synchronization: synchronization,
                               instrument: pencilStyle.instrument) else { return }
        stylePreferencesDirty = false
    }

    private let preferences: ToolPreferencesStore
    private let persistsPreferences: Bool
    private var savedStyles: [Int: PencilStyle]
    init(defaults: UserDefaults = .standard, persistsPreferences: Bool = true) {
        self.preferences = ToolPreferencesStore(defaults: defaults)
        self.persistsPreferences = persistsPreferences
        if !persistsPreferences {
            savedStyles = [:]
            pencilStyle = .initial(for: .monoline)
            return
        }
        let restoredBlendingMode = defaults.string(forKey: Self.blendingKey).flatMap(ColorBlendingMode.init(rawValue:)) ?? .hybrid
        blendingMode = restoredBlendingMode
        let decoded = preferences.styles
        savedStyles = decoded
        let restoredSynchronization = preferences.synchronization
        let savedInstrument = preferences.instrument
        let instrument = AppReleaseFeatures.current.allows(savedInstrument) ? savedInstrument : .monoline
        var restored = decoded[instrument.rawValue] ?? .initial(for: instrument)
        restored.blendingMode = restoredBlendingMode
        if !restored.width.isFinite { restored.width = instrument.defaultWidth }
        restored.width = min(instrument.maximumWidth, max(1, restored.width))
        if restoredSynchronization.width { restored.width = restoredSynchronization.sharedWidth }
        if restoredSynchronization.color && instrument != .eraser { restored.color = restoredSynchronization.sharedColor }
        if restoredSynchronization.opacity && instrument != .eraser { restored.opacity = restoredSynchronization.sharedOpacity }
        synchronization = restoredSynchronization
        pencilStyle = AppReleaseFeatures.current.availableStyle(restored)
    }

    func selectInstrument(_ instrument: DrawingInstrument) {
        guard AppReleaseFeatures.current.allows(instrument), instrument != pencilStyle.instrument else { return }
        var style = savedStyles[instrument.rawValue] ?? .initial(for: instrument)
        if synchronization.width { style.width = synchronization.sharedWidth }
        else { style.width = min(instrument.maximumWidth, max(1, style.width)) }
        if synchronization.color && instrument != .eraser { style.color = synchronization.sharedColor }
        if synchronization.opacity && instrument != .eraser { style.opacity = synchronization.sharedOpacity }
        style.blendingMode = blendingMode
        pencilStyle = AppReleaseFeatures.current.availableStyle(style)
    }

}

struct ToolSynchronization: Codable, Equatable {
    var width = true
    var color = true
    var opacity = true
    var sharedOpacity: Float = 1
    var sharedWidth: Float = 4
    var sharedColor = SIMD4<Float>(0, 0, 0, 1)

    init() {}

    private enum CodingKeys: String, CodingKey {
        case width, color, opacity, sharedWidth, sharedColor, sharedOpacity
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        width = try values.decodeIfPresent(Bool.self, forKey: .width) ?? true
        color = try values.decodeIfPresent(Bool.self, forKey: .color) ?? true
        opacity = try values.decodeIfPresent(Bool.self, forKey: .opacity) ?? true
        sharedWidth = try values.decodeIfPresent(Float.self, forKey: .sharedWidth) ?? 4
        sharedColor = try values.decodeIfPresent(SIMD4<Float>.self, forKey: .sharedColor) ?? SIMD4(0, 0, 0, 1)
        let decoded = try values.decodeIfPresent(Float.self, forKey: .sharedOpacity) ?? 1
        sharedOpacity = decoded.isFinite ? min(1, max(0, decoded)) : 1
    }
}
