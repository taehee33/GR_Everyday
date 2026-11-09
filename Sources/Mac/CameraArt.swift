import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// The picture on a camera's page: the user's own photo of it if one was set, otherwise a
/// drawn GR. Ricoh's product shots are not bundled (they aren't ours to ship). Drop an
/// image on it or use the context menu to change it.
struct CameraPicture: View {
    let camera: SavedCamera
    @ObservedObject private var store = CameraPictures.shared
    @State private var dropTargeted = false

    var body: some View {
        Group {
            if let image = store.image(for: camera.id) {
                Image(nsImage: image)
                    .resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                GRCameraPicture()
            }
        }
        .frame(width: 256, height: 152)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            return store.set(url, for: camera.id)
        } isTargeted: { dropTargeted = $0 }
        .contextMenu { CameraPictureMenu(camera: camera) }
        .help("이미지를 끌어다 놓으면 카메라 사진이 바뀝니다")
    }
}

/// "사진 바꾸기…" / "기본 그림으로" items, shared by the picture's context menu and 관리.
struct CameraPictureMenu: View {
    let camera: SavedCamera
    @ObservedObject private var store = CameraPictures.shared

    var body: some View {
        Button("카메라 사진 바꾸기…") { store.choose(for: camera.id) }
        if store.image(for: camera.id) != nil {
            Button("기본 그림으로 되돌리기") { store.remove(camera.id) }
        }
    }
}

/// Per-camera pictures, downscaled copies in Application Support/GR Mac/Cameras/<id>.png.
@MainActor
final class CameraPictures: ObservableObject {
    static let shared = CameraPictures()

    /// Loaded pictures; `nil` caches "none set" so the disk isn't checked on every redraw.
    @Published private var images: [UUID: NSImage?] = [:]

    private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GR Mac/Cameras", isDirectory: true)
    }

    private static func file(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).png") }

    func image(for id: UUID) -> NSImage? {
        if let cached = images[id] { return cached }
        let image = NSImage(contentsOf: Self.file(id))
        // Filled in after this render pass; publishing during a view update is not allowed.
        DispatchQueue.main.async { self.images[id] = .some(image) }
        return image
    }

    func choose(for id: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.prompt = "선택"
        panel.message = "카메라 페이지에 보여 줄 이미지를 고르세요. 배경을 지운 PNG가 가장 잘 어울립니다."
        if panel.runModal() == .OK, let url = panel.url { set(url, for: id) }
    }

    /// Copies `url` scaled to at most 1200 px (EXIF rotation applied). False if it isn't an image.
    @discardableResult
    func set(_ url: URL, for id: UUID) -> Bool {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1200,
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return false }
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(Self.file(id) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return false }
        images[id] = .some(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
        return true
    }

    func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: Self.file(id))
        images[id] = .some(nil)
    }
}
