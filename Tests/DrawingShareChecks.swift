import CoreTransferable
import Foundation
import UniformTypeIdentifiers

@main
struct DrawingShareChecks {
    static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Drawing.png")
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII=")!
        try png.write(to: url)
        let item = DrawingShareItem(url: url)
        // ShareLink can prepare the item and preview concurrently before a tap.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    let provider = NSItemProvider()
                    provider.register(item)
                    precondition(provider.hasItemConformingToTypeIdentifier(UTType.png.identifier))
                    let data: Data = try await withCheckedThrowingContinuation { continuation in
                        _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.png.identifier) { data, error in
                            if let error { continuation.resume(throwing: error) }
                            else if let data { continuation.resume(returning: data) }
                            else { continuation.resume(throwing: CocoaError(.fileReadUnknown)) }
                        }
                    }
                    precondition(data == png, "Sharing must deliver the PNG file contents")
                }
            }
            try await group.waitForAll()
        }
        let original = try Data(contentsOf: url)
        precondition(original == png, "Sharing must preserve the saved drawing")
        print("PASS: concurrent drawing/preview registration and PNG transfer; original preserved")
    }
}
