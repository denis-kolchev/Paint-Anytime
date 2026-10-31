import SwiftUI

struct PhoneDrawingActions: ToolbarContent {
    let url: URL
    let projectURL: URL
    let hasProject: Bool
    let isSaving: Bool
    let saveToPhotos: () -> Void
    let exportImage: () -> Void
    let exportProject: () -> Void
    let synchronize: () -> Void
    let sendToWatch: () -> Void
    let delete: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            Menu {
                ShareLink(item: url) {
                    Label("Image (.png)", systemImage: "photo")
                }
                ShareLink(item: projectURL) {
                    Label("Project (.paintanytime)", systemImage: "doc")
                }
                .disabled(!hasProject)
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
                    .frame(minWidth: 24, minHeight: 24)
            }

        }
        if #available(iOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .bottomBar)
        }
        ToolbarItem(placement: .bottomBar) {
            Menu {
                Button(action: saveToPhotos) {
                    Label("Photos", systemImage: "photo.badge.plus")
                }
                .disabled(isSaving)
                Button(action: exportImage) {
                    Label("Image (.png)", systemImage: "folder")
                }
                Button(action: exportProject) {
                    Label("Save Project to Files", systemImage: "doc")
                }
                .disabled(!hasProject)
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
                    .frame(minWidth: 24, minHeight: 24)
            }

        }
        if #available(iOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .bottomBar)
        }
        ToolbarItem(placement: .bottomBar) {
            Menu {
                if hasProject {
                    Button(action: sendToWatch) {
                        Label("Send to Apple Watch", systemImage: "applewatch")
                    }
                } else {
                    Button(action: synchronize) {
                        Label("Sync project from Apple Watch", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                Divider()
                Button(role: .destructive, action: delete) {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(isSaving)
            } label: {
                Label("More", systemImage: "ellipsis")
                    .frame(minWidth: 24, minHeight: 24)
            }
        }
    }
}
