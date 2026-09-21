//
//  ContentView.swift
//  Paint All the Time
//
//  Created by Denis Kolchev on 18.09.2026.
//

import SwiftUI
import SwiftUI

struct ContentView: View {
    @StateObject private var controller = CanvasController()

    var body: some View {
        CanvasView(controller: controller)
            .ignoresSafeArea()
            .overlay(alignment: .bottom) {
                HStack(spacing: 12) {
                    Label("Карандаш", systemImage: "pencil")

                    Slider(
                        value: $controller.pencilStyle.width,
                        in: 1...24
                    )
                    .frame(width: 140)

                    Text("\(Int(controller.pencilStyle.width)) pt")
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
