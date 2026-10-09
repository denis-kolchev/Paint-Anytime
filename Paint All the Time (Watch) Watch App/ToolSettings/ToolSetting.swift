import Foundation
import SwiftUI

enum ToolSetting: Int, CaseIterable {
    // Keep stored page identifiers stable; display order is defined by the view.
    case width, color, instrument, mode, direction, opacity, sensitivity
    var title: String {
        switch self {
        case .sensitivity: L10n.text("Sensitivity")
        case .opacity: L10n.text("Opacity")
        case .width: L10n.text("Width")
        case .color: L10n.text("Color")
        case .instrument: L10n.text("Tool")
        case .mode: L10n.text("Mode")
        case .direction: L10n.text("Angle")
        }
    }
}

/// Uses a fixed Crown step independent of rotation speed.
struct SteppedCrownModifier: ViewModifier {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var sensitivity: DigitalCrownRotationalSensitivity = .high
    var crownUnitsPerStep: Double = 4
    var context = 0
    @State private var crownPosition: Double?
    var onChange: (DigitalCrownEvent) -> Void = { _ in }

    // Preserve partial travel so four Crown units produce one setting unit.
    private var crownValue: Binding<Double> {
        Binding {
            crownPosition ?? value * crownUnitsPerStep
        } set: { proposed in
            let position = min(range.upperBound * crownUnitsPerStep,
                               max(range.lowerBound * crownUnitsPerStep, proposed))
            crownPosition = position
            value = settingValue(for: position)
        }
    }

    private func settingValue(for position: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, (position / crownUnitsPerStep).rounded()))
    }

    func body(content: Content) -> some View {
        content
            .digitalCrownRotation(
                detent: crownValue,
                from: range.lowerBound * crownUnitsPerStep,
                through: range.upperBound * crownUnitsPerStep, by: 1,
                sensitivity: sensitivity, isContinuous: false, isHapticFeedbackEnabled: true,
                onChange: onChange)
            .onChange(of: value) { _, newValue in
                // Buttons and other edits start the next turn at the updated value.
                if let crownPosition, settingValue(for: crownPosition) != newValue {
                    self.crownPosition = nil
                }
            }
            .onChange(of: context) { _, _ in crownPosition = nil }
            .onDisappear { crownPosition = nil }
    }
}
