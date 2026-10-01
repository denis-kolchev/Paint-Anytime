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

    private func synchronizationChanged() {
        // Enabling synchronization uses the current tool as the starting value.
        propagateSynchronizedStyle()
        scheduleStylePersistence()
    }

    private func propagateSynchronizedStyle() {
        guard synchronization.width || synchronization.color else { return }
        var updated = synchronization
        if updated.width { updated.sharedWidth = pencilStyle.width }
        if updated.color && pencilStyle.instrument != .eraser {
            updated.sharedColor = pencilStyle.color
        }
        // Publish once, and only if shared values actually changed.
        if updated != synchronization { synchronization = updated }
        for instrument in DrawingInstrument.allCases {
            var style = savedStyles[instrument.rawValue] ?? .initial(for: instrument)
            if synchronization.width { style.width = synchronization.sharedWidth }
            if synchronization.color && instrument != .eraser { style.color = synchronization.sharedColor }
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
        let decoded = preferences.styles
        savedStyles = decoded
        let restoredSynchronization = preferences.synchronization
        let savedInstrument = preferences.instrument
        let instrument = AppReleaseFeatures.current.allows(savedInstrument) ? savedInstrument : .monoline
        var restored = decoded[instrument.rawValue] ?? .initial(for: instrument)
        if !restored.width.isFinite { restored.width = instrument.defaultWidth }
        restored.width = min(instrument.maximumWidth, max(1, restored.width))
        if restoredSynchronization.width { restored.width = restoredSynchronization.sharedWidth }
        if restoredSynchronization.color && instrument != .eraser { restored.color = restoredSynchronization.sharedColor }
        synchronization = restoredSynchronization
        pencilStyle = AppReleaseFeatures.current.availableStyle(restored)
    }

    func selectInstrument(_ instrument: DrawingInstrument) {
        guard AppReleaseFeatures.current.allows(instrument), instrument != pencilStyle.instrument else { return }
        var style = savedStyles[instrument.rawValue] ?? .initial(for: instrument)
        if synchronization.width { style.width = synchronization.sharedWidth }
        else { style.width = min(instrument.maximumWidth, max(1, style.width)) }
        if synchronization.color && instrument != .eraser { style.color = synchronization.sharedColor }
        pencilStyle = AppReleaseFeatures.current.availableStyle(style)
    }

}

struct ToolSynchronization: Codable, Equatable {
    var width = true
    var color = true
    var sharedWidth: Float = 4
    var sharedColor = SIMD4<Float>(0, 0, 0, 1)
}
