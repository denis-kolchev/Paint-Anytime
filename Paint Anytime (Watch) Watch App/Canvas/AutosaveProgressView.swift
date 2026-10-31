import SwiftUI

struct AutosaveProgressView: View {
    let completed: Bool

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
                .overlay(Color.gray.opacity(0.25))
            VStack(spacing: 10) {
                ZStack {
                    if completed {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(.green)
                    } else {
                        ProgressView()
                            .controlSize(.large)
                    }
                }
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)
                Text(L10n.text(completed ? "Autosaved" : "Autosaving…"))
                    .font(.headline)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
