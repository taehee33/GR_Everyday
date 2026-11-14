import SwiftUI
import ImageIO

/// Loads Moment's server images (display.jpg, thumb, profile pictures) with a memory and disk
/// cache. The files never change, so a URL is cached forever. AsyncImage was not enough: the
/// 3072 px full view is 2–3 MB, more than URLCache keeps, so every open downloaded it again
/// while the detail screen showed only the blurred thumbnail.
@MainActor
final class MomentImageLoader {
    static let shared = MomentImageLoader()

    private let memory: NSCache<NSURL, PlatformImage> = {
        let cache = NSCache<NSURL, PlatformImage>()
        cache.totalCostLimit = 200 << 20
        return cache
    }()
    private var inFlight: [URL: Task<PlatformImage?, Never>] = [:]

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()

    nonisolated static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Moment", isDirectory: true)
    }

    /// Already decoded, no waiting (lets a view show it on its first frame).
    func cached(_ url: URL) -> PlatformImage? { memory.object(forKey: url as NSURL) }

    func image(_ url: URL) async -> PlatformImage? {
        if let hit = cached(url) { return hit }
        if let running = inFlight[url] { return await running.value }
        let disk = Self.diskURL(url)
        let session = session
        let task = Task.detached(priority: .userInitiated) { () -> PlatformImage? in
            if url.isFileURL { return Self.decode((try? Data(contentsOf: url)) ?? Data()) }
            if let data = try? Data(contentsOf: disk), let image = Self.decode(data) { return image }
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = Self.decode(data) else { return nil }
            try? FileManager.default.createDirectory(at: disk.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: disk, options: .atomic)
            return image
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image {
            let cost = image.cgImageValue.map { $0.bytesPerRow * $0.height } ?? 0
            memory.setObject(image, forKey: url as NSURL, cost: cost)
        }
        return image
    }

    /// Decoded here, off the main thread, so SwiftUI does not decode a 3072 px JPEG while drawing.
    nonisolated private static func decode(_ data: Data) -> PlatformImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        return PlatformImage(cgImageValue: cg)
    }

    nonisolated private static func diskURL(_ url: URL) -> URL {
        // /p/{id}/display.jpg → p_{id}_display.jpg
        let name = url.pathComponents.filter { $0 != "/" }.joined(separator: "_")
        return folder.appendingPathComponent(name.isEmpty ? url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "x" : name)
    }
}

/// A Moment photo: the full view when `url` is the display file, with the (sharp) thumbnail
/// and a small spinner while it downloads.
struct MomentRemoteImage: View {
    let url: URL
    /// Shown while `url` loads, usually the thumbnail. nil = the placeholder colour only.
    var preview: URL?
    var contentMode: ContentMode = .fit
    var showsProgress = true

    @State private var image: PlatformImage?
    @State private var previewImage: PlatformImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image = image ?? MomentImageLoader.shared.cached(url) {
                Image(platformImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else if let preview = previewImage ?? preview.flatMap(MomentImageLoader.shared.cached) {
                Image(platformImage: preview).resizable().aspectRatio(contentMode: contentMode)
                    .overlay(alignment: .bottomTrailing) {
                        if showsProgress && !failed {
                            ProgressView()
                                .controlSize(.small)
                                .padding(6)
                                .background(.ultraThinMaterial, in: Circle())
                                .padding(8)
                        }
                    }
            } else {
                Color.gray.opacity(0.2)
            }
        }
        .task(id: url) {
            image = nil
            failed = false
            if MomentImageLoader.shared.cached(url) != nil { return }
            if let preview {
                Task { previewImage = await MomentImageLoader.shared.image(preview) }
            }
            image = await MomentImageLoader.shared.image(url)
            failed = image == nil
        }
    }
}
