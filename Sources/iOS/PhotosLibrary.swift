import Photos

/// Saving on iPhone and iPad: the file stays in the app's Documents folder (Files app) and
/// is added to the Photos app.
enum PhotosLibrary {
    struct Denied: LocalizedError {
        var errorDescription: String? { "사진 앱에 저장할 권한이 없습니다. 설정 → GR Connect → 사진에서 허용하세요." }
    }

    static func add(_ file: URL, isVideo: Bool) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw Denied() }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: isVideo ? .video : .photo, fileURL: file, options: nil)
        }
    }
}
