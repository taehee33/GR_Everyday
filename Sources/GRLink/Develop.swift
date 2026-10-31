import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// The only slider left: straightening. Color and tone sliders were removed because the
/// camera's own processing can't be reproduced on the Mac.
enum Param: String, CaseIterable, Identifiable {
    case straighten

    var id: String { rawValue }
    var label: String { "수평 보정" }
    var range: ClosedRange<Double> { -45...45 }
    var step: Double { 0.1 }
    func format(_ value: Double) -> String { String(format: "%+.1f°", value) }
}

/// Geometry-only edits: rotation, mirror and straighten. No color or tone changes.
struct Adjustments: Codable, Hashable {
    var values: [String: Double] = [:]
    /// Clockwise quarter turns.
    var quarterTurns = 0
    var flipped = false

    init() {}

    subscript(param: Param) -> Double {
        get { values[param.rawValue] ?? 0 }
        set { values[param.rawValue] = abs(newValue) < 0.0001 ? nil : newValue }
    }

    var isDefault: Bool { self == Adjustments() }

    private enum CodingKeys: String, CodingKey { case values, quarterTurns, flipped }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Drop values of removed sliders saved by older builds.
        let known = Set(Param.allCases.map(\.rawValue))
        values = ((try? c.decode([String: Double].self, forKey: .values)) ?? [:]).filter { known.contains($0.key) }
        quarterTurns = (try? c.decode(Int.self, forKey: .quarterTurns)) ?? 0
        flipped = (try? c.decode(Bool.self, forKey: .flipped)) ?? false
    }
}

enum ExportFormat: String, CaseIterable, Identifiable {
    case jpeg = "JPEG", heic = "HEIC", tiff = "TIFF", png = "PNG"
    var id: String { rawValue }
    var type: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .heic: return .heic
        case .tiff: return .tiff
        case .png: return .png
        }
    }
    var fileExtension: String { type.preferredFilenameExtension ?? rawValue.lowercased() }
    var isLossy: Bool { self == .jpeg || self == .heic }
}

/// Core Image pipeline shared by the preview and the export.
enum DevelopEngine {
    static let context = CIContext(options: [.cacheIntermediates: false])
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The upright image in `url`, optionally shrunk so its long edge is at most `maxEdge`.
    static func load(_ url: URL, maxEdge: CGFloat? = nil) -> CIImage? {
        if ["DNG", "RAW"].contains(url.pathExtension.uppercased()), let raw = CIRAWFilter(imageURL: url) {
            if let maxEdge {
                let size = raw.nativeSize
                raw.scaleFactor = Float(min(1, maxEdge / max(size.width, size.height, 1)))
            }
            if let out = raw.outputImage { return out }
        }
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
        guard let maxEdge else { return image }
        let s = min(1, maxEdge / max(image.extent.width, image.extent.height, 1))
        guard s < 1 else { return image }
        return image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1])
    }

    static func cgImage(_ image: CIImage) -> CGImage? {
        context.createCGImage(image, from: image.extent.integral, format: .RGBA8, colorSpace: sRGB)
    }

    static func apply(_ adj: Adjustments, to input: CIImage) -> CIImage { geometry(adj, input) }

    /// Rotation, mirror and straighten (zoomed in just enough to keep the corners filled).
    static func geometry(_ adj: Adjustments, _ input: CIImage) -> CIImage {
        var image = input
        switch ((adj.quarterTurns % 4) + 4) % 4 {
        case 1: image = image.oriented(.right)
        case 2: image = image.oriented(.down)
        case 3: image = image.oriented(.left)
        default: break
        }
        if adj.flipped { image = image.oriented(.upMirrored) }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let angle = adj[.straighten] * .pi / 180
        guard angle != 0 else { return image }
        let w = image.extent.width, h = image.extent.height
        let cosA = abs(cos(angle)), sinA = abs(sin(angle))
        let s = max((w * cosA + h * sinA) / w, (w * sinA + h * cosA) / h)
        let t = CGAffineTransform(translationX: w / 2, y: h / 2)
            .rotated(by: -angle)
            .scaledBy(x: s, y: s)
            .translatedBy(x: -w / 2, y: -h / 2)
        return image.clampedToExtent().transformed(by: t).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }

    /// Full-resolution render of `source` with `adj`, keeping its metadata.
    static func export(source: URL, adj: Adjustments, to target: URL, format: ExportFormat, quality: Double) throws {
        guard let image = load(source) else { throw Failure(message: "원본 파일을 읽을 수 없습니다") }
        guard let cg = cgImage(apply(adj, to: image)) else { throw Failure(message: "이미지를 만들 수 없습니다") }
        var props: [CFString: Any] = [:]
        if let src = CGImageSourceCreateWithURL(source as CFURL, nil),
           let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            props = p
        }
        // Pixels are already upright and resized; drop what would contradict them.
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDNGDictionary,
                    kCGImagePropertyRawDictionary, kCGImagePropertyProfileName, kCGImagePropertyColorModel] {
            props.removeValue(forKey: key)
        }
        props[kCGImagePropertyOrientation] = 1
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = cg.width
            exif[kCGImagePropertyExifPixelYDimension] = cg.height
            props[kCGImagePropertyExifDictionary] = exif
        }
        if format.isLossy { props[kCGImageDestinationLossyCompressionQuality] = quality }
        guard let dest = CGImageDestinationCreateWithURL(target as CFURL, format.type.identifier as CFString, 1, nil) else {
            throw Failure(message: "\(format.rawValue) 파일을 만들 수 없습니다")
        }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Failure(message: "파일을 쓰지 못했습니다") }
    }
}

/// Red, green, blue and luminance counts, each scaled to 0…1.
struct Histogram: Equatable {
    var red = [Double](repeating: 0, count: 64)
    var green = [Double](repeating: 0, count: 64)
    var blue = [Double](repeating: 0, count: 64)
    var luma = [Double](repeating: 0, count: 64)

    init() {}

    init?(_ image: CGImage) {
        let w = 160, h = max(1, Int(Double(image.height) / Double(image.width) * 160))
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: DevelopEngine.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            red[r >> 2] += 1
            green[g >> 2] += 1
            blue[b >> 2] += 1
            luma[min(63, (r * 54 + g * 183 + b * 19) >> 10)] += 1
        }
        // Ignore the clipped end bins when scaling, so a blown sky doesn't flatten the rest.
        let peak = max(1, [red, green, blue, luma].flatMap { $0[1..<63] }.max() ?? 1)
        red = red.map { min(1, $0 / peak) }
        green = green.map { min(1, $0 / peak) }
        blue = blue.map { min(1, $0 / peak) }
        luma = luma.map { min(1, $0 / peak) }
    }
}
