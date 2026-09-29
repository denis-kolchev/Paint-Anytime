import Foundation
import Photos

@MainActor
protocol PhotoLibraryWriting {
    var canSave: Bool { get }
    var permissionRequiresSettings: Bool { get }
    func requestPermission() async
    func save(_ image: URL) async throws
}

@MainActor
struct PhotoLibraryWriter: PhotoLibraryWriting {
    var canSave: Bool { PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized }
    var permissionRequiresSettings: Bool {
        [.denied, .restricted].contains(PHPhotoLibrary.authorizationStatus(for: .addOnly))
    }

    func requestPermission() async {
        _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    }

    func save(_ image: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: image)
        }
    }
}
