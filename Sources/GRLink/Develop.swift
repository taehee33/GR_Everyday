import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// One slider in the edit panel. Each maps to one documented Apple Core Image filter
/// (named in `filter`), the same engine Photos and Preview use. None of them imitates the
/// camera's own processing.
enum Param: String, CaseIterable, Identifiable {
    case exposure, contrast, highlights, shadows
    case temperature, tint, vibrance, saturation
    case sharpness
    case straighten

    var id: String { rawValue }

    var label: String {
        switch self {
        case .exposure: return "노출"
        case .contrast: return "대비"
        case .highlights: return "하이라이트"
        case .shadows: return "섀도"
        case .temperature: return "색온도"
        case .tint: return "색조"
        case .vibrance: return "생동감"
        case .saturation: return "채도"
        case .sharpness: return "선명도"
        case .straighten: return "수평 보정"
        }
    }

    var filter: String {
        switch self {
        case .exposure: return "CIExposureAdjust (EV)"
        case .contrast, .saturation: return "CIColorControls"
        case .highlights, .shadows: return "CIHighlightShadowAdjust"
        case .temperature, .tint: return "CITemperatureAndTint"
        case .vibrance: return "CIVibrance"
        case .sharpness: return "CISharpenLuminance"
        case .straighten: return "회전 변환"
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .exposure: return -3...3
        case .highlights: return -100...0
        case .sharpness: return 0...100
        case .straighten: return -45...45
        default: return -100...100
        }
    }

    var step: Double {
        switch self {
        case .exposure: return 0.05
        case .straighten: return 0.1
        default: return 1
        }
    }

    func format(_ value: Double) -> String {
        switch self {
        case .exposure: return String(format: "%+.2f EV", value)
        case .straighten: return String(format: "%+.1f°", value)
        default: return value == 0 ? "0" : String(format: "%+.0f", value)
        }
    }

    enum Group: String, CaseIterable, Identifiable {
        case light = "빛", color = "색", detail = "디테일"
        var id: String { rawValue }
        var params: [Param] {
            switch self {
            case .light: return [.exposure, .contrast, .highlights, .shadows]
            case .color: return [.temperature, .tint, .vibrance, .saturation]
            case .detail: return [.sharpness]
            }
        }
    }
}

/// Edits kept per photo; the saved file itself is never changed.
struct Adjustments: Codable, Hashable {
    var values: [String: Double] = [:]
    /// Clockwise quarter turns.
    var quarterTurns = 0
    var flipped = false
    /// x, y, width, height as fractions of the rotated / straightened image, origin top-left.
    var crop: [Double]?

    init() {}

    subscript(param: Param) -> Double {
        get { values[param.rawValue] ?? 0 }
        set { values[param.rawValue] = abs(newValue) < 0.0001 ? nil : newValue }
    }

    var isDefault: Bool { self == Adjustments() }

    var cropRect: CGRect? {
        get { crop.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) } }
        set {
            guard let r = newValue, r.width < 0.999 || r.height < 0.999 else { crop = nil; return }
            crop = [r.minX, r.minY, r.width, r.height]
        }
    }

    /// Same edits without the crop, for showing the whole frame while cropping.
    var uncropped: Adjustments {
        var a = self
        a.crop = nil
        return a
    }

    private enum CodingKeys: String, CodingKey { case values, quarterTurns, flipped, crop }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Drop values of removed sliders saved by older builds.
        let known = Set(Param.allCases.map(\.rawValue))
        values = ((try? c.decode([String: Double].self, forKey: .values)) ?? [:]).filter { known.contains($0.key) }
        quarterTurns = (try? c.decode(Int.self, forKey: .quarterTurns)) ?? 0
        flipped = (try? c.decode(Bool.self, forKey: .flipped)) ?? false
        crop = (try? c.decode([Double].self, forKey: .crop)).flatMap { $0.count == 4 ? $0 : nil }
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

    static func apply(_ adj: Adjustments, to input: CIImage) -> CIImage {
        var image = geometry(adj, input)
        if let r = adj.cropRect {
            let e = image.extent
            let rect = CGRect(x: e.minX + r.minX * e.width, y: e.minY + (1 - r.maxY) * e.height,
                              width: r.width * e.width, height: r.height * e.height).integral
            image = image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        }
        let extent = image.extent
        if adj[.temperature] != 0 || adj[.tint] != 0 {
            // A higher target neutral renders cooler, so +색온도 lowers it (warmer).
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                // Same for tint: a negative target tint renders magenta, so +색조 = magenta.
                "inputTargetNeutral": CIVector(x: 6500 - adj[.temperature] * 30, y: -adj[.tint]),
            ])
        }
        if adj[.exposure] != 0 {
            image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: adj[.exposure]])
        }
        if adj[.highlights] != 0 || adj[.shadows] != 0 {
            image = image.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 1 + adj[.highlights] / 100,
                "inputShadowAmount": adj[.shadows] / 100,
            ])
        }
        if adj[.contrast] != 0 {
            // Pivot on perceptual mid-gray: in Core Image's linear space it would mostly darken.
            image = image.applyingFilter("CILinearToSRGBToneCurve")
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1 + adj[.contrast] / 200])
                .applyingFilter("CISRGBToneCurveToLinear")
        }
        if adj[.saturation] != 0 {
            image = image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1 + adj[.saturation] / 100])
        }
        if adj[.vibrance] != 0 {
            image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": adj[.vibrance] / 100])
        }
        if adj[.sharpness] > 0 {
            let scale = max(extent.width, extent.height) / 2000
            image = image.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: adj[.sharpness] / 100, kCIInputRadiusKey: max(1, 1.5 * scale),
            ])
        }
        return image.cropped(to: extent)
    }

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
        // Square-root scale, so one dark or bright peak doesn't flatten the rest.
        let scale: (Double) -> Double = { min(1, ($0 / peak).squareRoot()) }
        red = red.map(scale)
        green = green.map(scale)
        blue = blue.map(scale)
        luma = luma.map(scale)
    }
}
