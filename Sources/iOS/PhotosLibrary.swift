import Photos

/// Saving on iPhone and iPad: the file stays in the app's Documents folder (Files app) and
/// is added to the Photos app.
enum PhotosLibrary {
    /// Settings → 사진 저장: put a JPEG and its DNG (same file name) into one Photos item,
    /// shown as RAW+JPEG. Off by default: each file is its own item.
    static let pairRAWKey = "photosPairRAWJPEG"
    static var pairRAW: Bool { UserDefaults.standard.bool(forKey: pairRAWKey) }

    struct Denied: LocalizedError {
        var errorDescription: String? { "사진 앱에 저장할 권한이 없습니다. 설정 → GR Connect → 사진에서 허용하세요." }
    }

    static func add(_ file: URL, isVideo: Bool) async throws {
        try await authorize()
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: isVideo ? .video : .photo, fileURL: file, options: nil)
        }
    }

    /// One item: the JPEG is what Photos shows and shares, the DNG rides along as its RAW.
    static func addPair(jpeg: URL, raw: URL) async throws {
        try await authorize()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: jpeg, options: nil)
            request.addResource(with: .alternatePhoto, fileURL: raw, options: nil)
        }
    }

    private static func authorize() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw Denied() }
    }
}
