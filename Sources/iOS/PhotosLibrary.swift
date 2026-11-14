import Photos
import UIKit

/// Saving on iPhone and iPad: into the Photos app, the Files app's ‘GR Everyday’ folder,
/// or both (설정 → 사진 저장 → 저장 위치).
enum PhotosLibrary {
    /// Settings → 사진 저장: put a JPEG and its DNG (same file name) into one Photos item,
    /// shown as RAW+JPEG. Off by default: each file is its own item.
    static let pairRAWKey = "photosPairRAWJPEG"
    static var pairRAW: Bool { UserDefaults.standard.bool(forKey: pairRAWKey) }

    /// Where a saved photo goes. The Photos app only by default, so a photo isn't kept twice.
    enum Target: String, CaseIterable, Identifiable {
        case photos, both, files
        var id: String { rawValue }
        var title: String {
            switch self {
            case .photos: return "사진 앱"
            case .both: return "사진 앱 + 파일 앱"
            case .files: return "파일 앱만"
            }
        }
        var toPhotos: Bool { self != .files }
        var keepsFile: Bool { self != .photos }
    }
    static let targetKey = "saveTarget"
    static var target: Target {
        UserDefaults.standard.string(forKey: targetKey).flatMap(Target.init) ?? .photos
    }

    struct Denied: LocalizedError {
        var errorDescription: String? { "사진 앱에 저장할 권한이 없어요. 설정 → GR Everyday → 사진에서 허용해 주세요." }
    }

    /// Returns the new Photos item's identifier.
    @discardableResult
    static func add(_ file: URL, isVideo: Bool) async throws -> String? {
        try await authorize()
        let id = Box()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: isVideo ? .video : .photo, fileURL: file, options: nil)
            id.value = request.placeholderForCreatedAsset?.localIdentifier
        }
        return id.value
    }

    /// One item: the JPEG is what Photos shows and shares, the DNG rides along as its RAW.
    @discardableResult
    static func addPair(jpeg: URL, raw: URL) async throws -> String? {
        try await authorize()
        let id = Box()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: jpeg, options: nil)
            request.addResource(with: .alternatePhoto, fileURL: raw, options: nil)
            id.value = request.placeholderForCreatedAsset?.localIdentifier
        }
        return id.value
    }

    private final class Box: @unchecked Sendable { var value: String? }

    private static func authorize() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw Denied() }
    }

    // MARK: Seeing what's still there

    /// Reading the library is a separate permission from adding to it; only with it can the
    /// app tell that a saved photo was deleted in the Photos app.
    static var readStatus: PHAuthorizationStatus { PHPhotoLibrary.authorizationStatus(for: .readWrite) }
    static var canRead: Bool { readStatus == .authorized || readStatus == .limited }

    /// Asks once; afterwards only the Settings app can change it.
    static func requestRead() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    /// Which of these Photos items still exist. Nil without read access.
    static func existing(_ ids: [String]) -> Set<String>? {
        guard canRead, !ids.isEmpty else { return canRead ? [] : nil }
        let found = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var out = Set<String>()
        found.enumerateObjects { asset, _, _ in out.insert(asset.localIdentifier) }
        return out
    }

    /// A photo saved before the app kept Photos identifiers: the item made from this file,
    /// found by its shooting time and original file name. Needs full access.
    static func find(name: String, near date: Date, within seconds: TimeInterval) -> String? {
        guard readStatus == .authorized else { return nil }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate <= %@",
                                        date.addingTimeInterval(-seconds) as NSDate, date.addingTimeInterval(seconds) as NSDate)
        let assets = PHAsset.fetchAssets(with: options)
        var match: String?
        assets.enumerateObjects { asset, _, stop in
            let names = PHAssetResource.assetResources(for: asset).map(\.originalFilename)
            if names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                match = asset.localIdentifier
                stop.pointee = true
            }
        }
        return match
    }

    struct NotFound: LocalizedError {
        var errorDescription: String? { "사진 앱에서 이 사진을 찾지 못했어요. 지워졌을 수 있어요." }
    }

    /// The camera files this Photos item was made from, written byte for byte to a temporary
    /// folder: the JPEG and, for a RAW+JPG item, its DNG. Nothing is re-encoded, so the
    /// maker note that marks a GR original is still there. Needs read access.
    static func exportOriginals(_ id: String) async throws -> [URL] {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { throw NotFound() }
        let resources = PHAssetResource.assetResources(for: asset).filter { $0.type == .photo || $0.type == .alternatePhoto }
        guard !resources.isEmpty else { throw NotFound() }
        let dir = FileManager.default.temporaryDirectory.appending(path: "moment-upload/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true  // An original kept only in iCloud.
        var files: [URL] = []
        for resource in resources {
            let target = dir.appending(path: resource.originalFilename)
            try await PHAssetResourceManager.default().writeData(for: resource, toFile: target, options: options)
            files.append(target)
        }
        return files
    }

    /// A square thumbnail of a Photos item.
    static func thumbnail(_ id: String, side: CGFloat) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat  // One callback only.
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { done in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side, height: side),
                                                  contentMode: .aspectFill, options: options) { image, _ in
                done.resume(returning: image)
            }
        }
    }

    /// Opens the Photos app (it can't be sent to one item).
    @MainActor static func openApp() {
        if let url = URL(string: "photos-redirect://") { UIApplication.shared.open(url) }
    }

    /// Opens the Files app at a file in the app's folder.
    @MainActor static func showInFiles(_ file: URL) {
        let folder = file.deletingLastPathComponent()
        if let url = URL(string: "shareddocuments://" + folder.path) { UIApplication.shared.open(url) }
    }
}
