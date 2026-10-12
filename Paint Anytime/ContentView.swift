//
//  ContentView.swift
//  Paint Anytime
//
//  Created by Denis Kolchev on 18.09.2026.
//

import SwiftUI
import SwiftUI

struct ContentView: View {
    @StateObject private var controller = CanvasController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        CanvasView(controller: controller)
            .ignoresSafeArea()
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { controller.flushStylePreferences() }
            }
            .onDisappear { controller.flushStylePreferences() }
            .overlay(alignment: .bottom) {
                HStack(spacing: 12) {
                    Label(controller.pencilStyle.instrument.title, systemImage: "pencil")

                    Slider(
                        value: $controller.pencilStyle.width,
                        in: 1...24
                    )
                    .frame(width: 140)

                    Text(L10n.format("%d pt", Int(controller.pencilStyle.width)))
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(cornerRadius: 18)
                )
                .padding(.bottom, 20)
            }
    }
}

#Preview {
    ContentView()
}
