import SwiftUI

struct WatchAppSettingsView: View {
    @ObservedObject var controller: CanvasController
    var onOpenDrawings: () -> Void

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    ToolSynchronizationView(controller: controller)
                } label: {
                    Text("Синхронизация инструментов")
                }
                Button("Галерея") { onOpenDrawings() }
            }
            .navigationTitle("Дополнительно")
        }
    }
}

private struct ToolSynchronizationView: View {
    @ObservedObject var controller: CanvasController

    var body: some View {
        List {
            Section {
                Toggle("Общая толщина", isOn: Binding(
                    get: { controller.synchronization.width },
                    set: { controller.setSynchronizeWidth($0) }
                ))
                Toggle("Общий цвет", isOn: Binding(
                    get: { controller.synchronization.color },
                    set: { controller.setSynchronizeColor($0) }
                ))
            } footer: {
                Text("Выбранные параметры общие для инструментов. Цвет не применяется к ластику.")
            }
        }
        .navigationTitle("Синхронизация")
    }
}
