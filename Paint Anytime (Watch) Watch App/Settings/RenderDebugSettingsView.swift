import SwiftUI
import Combine

/// Where the speed HUD sits, so it can be moved away from the toolbar buttons.
enum RenderHUDPosition: CaseIterable {
    case top, middle, bottom

    var title: String {
        switch self {
        case .top: "Top"
        case .middle: "Middle"
        case .bottom: "Bottom"
        }
    }

    var alignment: Alignment {
        switch self {
        case .top: .top
        case .middle: .center
        case .bottom: .bottom
        }
    }

    /// Clearance for the round toolbar buttons in the corners.
    var insets: EdgeInsets {
        switch self {
        case .top: EdgeInsets(top: 56, leading: 0, bottom: 0, trailing: 0)
        case .middle: EdgeInsets()
        case .bottom: EdgeInsets(top: 0, leading: 0, bottom: 56, trailing: 0)
        }
    }
}

/// Main-actor mirror of the render debug switches for SwiftUI. The renderer reads
/// `RenderStageSwitches` directly. Nothing persists: every launch starts from the defaults.
final class RenderDebugSettings: ObservableObject {
    static let shared = RenderDebugSettings()

    @Published var showsHUD = RenderDebug.isEnabled
    @Published var hudPosition = RenderHUDPosition.top
    /// Predicted tip lookahead in 60 Hz display frames; the shipping value is 2 (~33 ms).
    @Published var predictionFrames = 2
    @Published private(set) var disabledStages = RenderStageSwitches.shared.disabledStages

    func isOn(_ stage: RenderStage) -> Bool {
        guard RenderDebug.isEnabled else { return stage.isDefaultOn }
        return !disabledStages.contains(stage)
    }

    var isAtDefaults: Bool {
        RenderStage.allCases.allSatisfy { isOn($0) == $0.isDefaultOn }
    }

    func set(_ stage: RenderStage, isOn: Bool) {
        guard RenderDebug.isEnabled else { return }
        RenderStageSwitches.shared.set(stage, isOn: isOn)
        if isOn { disabledStages.remove(stage) } else { disabledStages.insert(stage) }
    }

    func resetToDefaults() {
        for stage in RenderStage.allCases { set(stage, isOn: stage.isDefaultOn) }
    }
}

/// ⋯ menu → Render debug: HUD, prediction lookahead and the three latency optimizations.
/// Changes apply from the next rendered frame; draw on the canvas to compare.
struct RenderDebugSettingsView: View {
    @ObservedObject private var settings = RenderDebugSettings.shared

    var body: some View {
        List {
            Section {
                Toggle(isOn: $settings.showsHUD) {
                    Text(verbatim: "Speed HUD")
                }
                Picker(selection: $settings.hudPosition) {
                    ForEach(RenderHUDPosition.allCases, id: \.self) { position in
                        Text(verbatim: position.title).tag(position)
                    }
                } label: {
                    Text(verbatim: "HUD position")
                }
                Picker(selection: $settings.predictionFrames) {
                    ForEach(1...4, id: \.self) { frames in
                        Text(verbatim: "\(frames) frame\(frames == 1 ? "" : "s") · \(frames * 17) ms").tag(frames)
                    }
                } label: {
                    Text(verbatim: "Prediction")
                }
            } footer: {
                Text(verbatim: "FPS: published frames/s. drop: frames replaced before rendering. ev: touch event → handler. disp: handler → frame queued. pub: queued → published. e2e: touch event → published; the screen shows it 1–2 vsyncs later. Stage times are averages in ms. main lag: wait of a main-queue probe every 50 ms. body: view re-evaluations/s. heat, LPM, mem, WC: thermal state, Low Power Mode, footprint, pending iPhone transfers.")
            }
            Section {
                ForEach(RenderStage.allCases, id: \.self) { stage in
                    Toggle(isOn: Binding(get: { settings.isOn(stage) },
                                         set: { settings.set(stage, isOn: $0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: stage.title)
                            Text(verbatim: stage.detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text(verbatim: "Latency optimizations")
            }
            if !settings.isAtDefaults {
                Button {
                    settings.resetToDefaults()
                } label: {
                    Text(verbatim: "Reset to defaults")
                }
            }
        }
        .navigationTitle(Text(verbatim: "Render debug"))
    }
}
