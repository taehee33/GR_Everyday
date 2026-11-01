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
                GRDrawing(model: camera.shortModel)
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

/// A front view of a GR drawn in code: grip on the left, lens right of centre, the top
/// plate's dial and shutter button. Black like the camera in either appearance.
struct GRDrawing: View {
    var model: String?

    var body: some View {
        Canvas { ctx, size in
            // Drawn on a 320 × 190 grid, scaled to fit.
            let s = min(size.width / 320, size.height / 190)
            ctx.translateBy(x: (size.width - 320 * s) / 2, y: (size.height - 190 * s) / 2)
            ctx.scaleBy(x: s, y: s)

            let ink = Color(white: 0.11), edge = Color(white: 0.32)

            // Top plate: mode dial (left), shutter and power (right).
            for r in [CGRect(x: 30, y: 26, width: 62, height: 12), CGRect(x: 196, y: 28, width: 36, height: 10),
                      CGRect(x: 244, y: 30, width: 22, height: 8)] {
                ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(Color(white: 0.2)))
            }

            // Body with a soft top light.
            let body = Path(roundedRect: CGRect(x: 8, y: 36, width: 304, height: 140), cornerRadius: 16)
            ctx.drawLayer { layer in
                layer.addFilter(.shadow(color: .black.opacity(0.35), radius: 10, y: 6))
                layer.fill(body, with: .color(ink))
            }
            ctx.fill(body, with: .linearGradient(Gradient(colors: [Color(white: 0.24), ink, Color(white: 0.06)]),
                                                 startPoint: CGPoint(x: 0, y: 36), endPoint: CGPoint(x: 0, y: 176)))
            ctx.stroke(body, with: .color(edge), lineWidth: 1)

            // Grip: textured rubber, slightly proud of the body.
            let grip = Path(roundedRect: CGRect(x: 14, y: 42, width: 84, height: 128), cornerRadius: 12)
            ctx.fill(grip, with: .color(Color(white: 0.08)))
            ctx.drawLayer { layer in
                layer.clip(to: grip)
                for y in stride(from: 46.0, to: 170, by: 5) {
                    for x in stride(from: 18.0 + (Int(y) % 10 == 6 ? 2.5 : 0), to: 98, by: 5) {
                        layer.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.6, height: 1.6)), with: .color(Color(white: 0.17)))
                    }
                }
            }
            ctx.stroke(grip, with: .color(Color(white: 0.22)), lineWidth: 1)

            // AF assist lamp and the small sensor window.
            ctx.fill(Path(ellipseIn: CGRect(x: 118, y: 54, width: 8, height: 8)), with: .color(Color(white: 0.3)))
            ctx.fill(Path(roundedRect: CGRect(x: 262, y: 52, width: 14, height: 6), cornerRadius: 2), with: .color(Color(white: 0.2)))

            // Lens: barrel rings, then glass with a reflection.
            let c = CGPoint(x: 194, y: 108)
            func circle(_ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)) }
            ctx.fill(circle(60), with: .linearGradient(Gradient(colors: [Color(white: 0.3), Color(white: 0.08)]),
                                                         startPoint: CGPoint(x: c.x, y: c.y - 60), endPoint: CGPoint(x: c.x, y: c.y + 60)))
            ctx.stroke(circle(60), with: .color(Color(white: 0.4)), lineWidth: 1)
            ctx.fill(circle(50), with: .color(Color(white: 0.05)))
            ctx.stroke(circle(44), with: .color(Color(white: 0.2)), lineWidth: 1.5)
            ctx.fill(circle(30), with: .radialGradient(Gradient(colors: [Color(red: 0.16, green: 0.2, blue: 0.3), .black]),
                                                         center: CGPoint(x: c.x - 6, y: c.y - 6), startRadius: 2, endRadius: 30))
            ctx.fill(circle(12), with: .color(Color(white: 0.02)))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 18, y: c.y - 20, width: 12, height: 7)),
                     with: .color(.white.opacity(0.35)))
            ctx.draw(Text("GR LENS f=18.3mm 1:2.8").font(.system(size: 5.5, weight: .medium)).foregroundColor(Color(white: 0.45)),
                     at: CGPoint(x: c.x, y: c.y + 39))

            // Badge.
            ctx.draw(Text("GR").font(.system(size: 20, weight: .semibold)).foregroundColor(Color(white: 0.5)),
                     at: CGPoint(x: 282, y: 156))
            if let model, model.uppercased().contains("HDF") {
                ctx.draw(Text("HDF").font(.system(size: 7, weight: .bold)).foregroundColor(Color(white: 0.45)),
                         at: CGPoint(x: 282, y: 142))
            }
        }
        .accessibilityLabel(Text("RICOH GR"))
    }
}
