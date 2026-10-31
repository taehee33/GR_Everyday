import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers

/// One slider in the develop panel. Values are stored by raw value, so a newer build's
/// sliders don't break edits saved by an older one.
enum Param: String, CaseIterable, Identifiable {
    case temperature, tint
    case exposure, contrast, highlights, shadows, whites, blacks
    case vibrance, saturation
    case clarity, sharpness, vignette, grain
    case straighten

    var id: String { rawValue }

    var label: String {
        switch self {
        case .temperature: return "색온도"
        case .tint: return "색조"
        case .exposure: return "노출"
        case .contrast: return "대비"
        case .highlights: return "하이라이트"
        case .shadows: return "섀도"
        case .whites: return "흰색 계열"
        case .blacks: return "검정 계열"
        case .vibrance: return "생동감"
        case .saturation: return "채도"
        case .clarity: return "명료도"
        case .sharpness: return "선명도"
        case .vignette: return "비네팅"
        case .grain: return "그레인"
        case .straighten: return "수평 보정"
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .exposure: return -4...4
        case .sharpness, .grain: return 0...100
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
        case .exposure: return String(format: "%+.2f", value)
        case .straighten: return String(format: "%+.1f°", value)
        default: return value == 0 ? "0" : String(format: "%+.0f", value)
        }
    }

    enum Group: String, CaseIterable, Identifiable {
        case whiteBalance = "화이트 밸런스", tone = "톤", presence = "색", effects = "디테일·효과"
        var id: String { rawValue }
        var params: [Param] {
            switch self {
            case .whiteBalance: return [.temperature, .tint]
            case .tone: return [.exposure, .contrast, .highlights, .shadows, .whites, .blacks]
            case .presence: return [.vibrance, .saturation]
            case .effects: return [.clarity, .sharpness, .vignette, .grain]
            }
        }
    }
}

/// Looks modelled on the GR's image controls, applied on top of the saved file.
enum Look: String, CaseIterable, Identifiable, Codable {
    case standard, vivid, monochrome, softMonochrome, hardMonochrome, highContrastBW
    case positiveFilm, negativeFilm, bleachBypass, retro, hdrTone, crossProcess, cinemaYellow, cinemaGreen

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: return "스탠다드"
        case .vivid: return "비비드"
        case .monochrome: return "모노톤"
        case .softMonochrome: return "소프트 모노톤"
        case .hardMonochrome: return "하드 모노톤"
        case .highContrastBW: return "하이 콘트라스트 흑백"
        case .positiveFilm: return "포지티브 필름"
        case .negativeFilm: return "네거티브 필름"
        case .bleachBypass: return "블리치 바이패스"
        case .retro: return "레트로"
        case .hdrTone: return "HDR 톤"
        case .crossProcess: return "크로스 프로세스"
        case .cinemaYellow: return "시네마(옐로)"
        case .cinemaGreen: return "시네마(그린)"
        }
    }

    /// `scale` is the image's long edge / 2000, so radii look the same at any size.
    func apply(_ image: CIImage, scale: CGFloat) -> CIImage {
        switch self {
        case .standard:
            return image
        case .vivid:
            return image.vibrance(0.25).controls(saturation: 1.3, contrast: 1.06)
        case .monochrome:
            return image.applyingFilter("CIPhotoEffectMono")
        case .softMonochrome:
            return image.applyingFilter("CIPhotoEffectMono")
                .curve([0.06, 0.3, 0.53, 0.76, 0.95])
        case .hardMonochrome:
            return image.applyingFilter("CIPhotoEffectNoir")
                .curve([0, 0.18, 0.5, 0.82, 1])
        case .highContrastBW:
            return image.applyingFilter("CIPhotoEffectNoir")
                .curve([0, 0.08, 0.62, 0.95, 1])
        case .positiveFilm:
            return image.controls(saturation: 1.2)
                .curve([0, 0.22, 0.5, 0.79, 1])
                .matrix(r: 1.04, g: 1.0, b: 0.95)
        case .negativeFilm:
            return image.controls(saturation: 0.8)
                .curve([0.07, 0.29, 0.52, 0.74, 0.96])
                .matrix(r: 0.98, g: 1.0, b: 1.02, bias: (-0.005, 0.005, 0.015))
        case .bleachBypass:
            let color = image.controls(saturation: 0.55)
            return image.applyingFilter("CIPhotoEffectMono")
                .applyingFilter("CIOverlayBlendMode", parameters: [kCIInputBackgroundImageKey: color])
                .curve([0, 0.2, 0.5, 0.8, 1])
        case .retro:
            return image.applyingFilter("CIPhotoEffectTransfer")
                .applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.25])
                .curve([0.08, 0.3, 0.52, 0.74, 0.94])
        case .hdrTone:
            let f = CIFilter.highlightShadowAdjust()
            f.inputImage = image
            f.highlightAmount = 0.4
            f.shadowAmount = 0.8
            f.radius = Float(10 * scale)
            return (f.outputImage ?? image)
                .applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 30 * scale, kCIInputIntensityKey: 0.6])
                .controls(saturation: 1.15)
        case .crossProcess:
            return image.applyingFilter("CIPhotoEffectProcess")
        case .cinemaYellow:
            return image.matrix(r: 1.05, g: 1.02, b: 0.86, bias: (0.02, 0.01, -0.01))
                .controls(saturation: 0.85, contrast: 1.04)
                .curve([0.04, 0.26, 0.5, 0.76, 0.98])
        case .cinemaGreen:
            return image.matrix(r: 0.92, g: 1.04, b: 0.96, bias: (-0.01, 0.02, 0.015))
                .controls(saturation: 0.8, contrast: 1.04)
                .curve([0.04, 0.26, 0.5, 0.76, 0.98])
        }
    }
}

struct Adjustments: Codable, Hashable {
    var look: Look = .standard
    var lookAmount: Double = 100
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

    private enum CodingKeys: String, CodingKey { case look, lookAmount, values, quarterTurns, flipped }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        look = (try? c.decode(Look.self, forKey: .look)) ?? .standard
        lookAmount = (try? c.decode(Double.self, forKey: .lookAmount)) ?? 100
        values = (try? c.decode([String: Double].self, forKey: .values)) ?? [:]
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

    static func apply(_ adj: Adjustments, to input: CIImage) -> CIImage {
        var image = geometry(adj, input)
        let extent = image.extent
        let scale = max(extent.width, extent.height) / 2000

        if adj[.temperature] != 0 || adj[.tint] != 0 {
            let f = CIFilter.temperatureAndTint()
            f.inputImage = image
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: 6500 - adj[.temperature] * 30, y: adj[.tint])
            image = f.outputImage ?? image
        }
        if adj[.exposure] != 0 {
            image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: adj[.exposure]])
        }
        if adj.look != .standard, adj.lookAmount > 0 {
            let looked = adj.look.apply(image, scale: scale)
            image = adj.lookAmount >= 100 ? looked : image.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: looked, kCIInputTimeKey: adj.lookAmount / 100,
            ])
        }
        if adj[.highlights] < 0 || adj[.shadows] != 0 {
            let f = CIFilter.highlightShadowAdjust()
            f.inputImage = image
            f.highlightAmount = Float(1 + min(0, adj[.highlights]) / 100)
            f.shadowAmount = Float(adj[.shadows] / 100)
            image = f.outputImage ?? image
        }
        let c = adj[.contrast] / 100, h = max(0, adj[.highlights]) / 100, w = adj[.whites] / 100, b = adj[.blacks] / 100
        if c != 0 || h != 0 || w != 0 || b != 0 {
            let p0 = b >= 0 ? CGPoint(x: 0, y: b * 0.15) : CGPoint(x: -b * 0.1, y: 0)
            let p4 = w >= 0 ? CGPoint(x: 1 - w * 0.12, y: 1) : CGPoint(x: 1, y: 1 + w * 0.15)
            image = image.curve(points: [p0, CGPoint(x: 0.25, y: 0.25 - c * 0.07), CGPoint(x: 0.5, y: 0.5),
                                         CGPoint(x: 0.75, y: 0.75 + c * 0.07 + h * 0.06), p4])
        }
        let clarity = adj[.clarity] / 100
        if clarity > 0 {
            image = image.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 25 * scale, kCIInputIntensityKey: clarity * 0.8])
        } else if clarity < 0 {
            let soft = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 12 * scale]).cropped(to: extent)
            image = image.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: soft, kCIInputTimeKey: -clarity * 0.5])
        }
        if adj[.vibrance] != 0 { image = image.vibrance(adj[.vibrance] / 100) }
        if adj[.saturation] != 0 { image = image.controls(saturation: 1 + adj[.saturation] / 100) }
        if adj[.sharpness] > 0 {
            image = image.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: adj[.sharpness] / 100 * 1.2, kCIInputRadiusKey: max(1, 1.5 * scale),
            ])
        }
        if adj[.vignette] != 0 {
            let f = CIFilter.vignetteEffect()
            f.inputImage = image
            f.center = CGPoint(x: extent.midX, y: extent.midY)
            f.radius = Float(hypot(extent.width, extent.height) * 0.42)
            f.intensity = Float(-adj[.vignette] / 100)
            f.falloff = 0.6
            image = f.outputImage ?? image
        }
        if adj[.grain] > 0 {
            let a = adj[.grain] / 100 * 0.5
            let noise = CIFilter.randomGenerator().outputImage!
                .transformed(by: CGAffineTransform(scaleX: max(1, scale), y: max(1, scale)))
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: a, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: a, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: a, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                    "inputBiasVector": CIVector(x: 0.5 - a / 2, y: 0.5 - a / 2, z: 0.5 - a / 2, w: 0),
                ])
                .cropped(to: extent)
            image = noise.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: image])
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
        red = red.map { min(1, $0 / peak) }
        green = green.map { min(1, $0 / peak) }
        blue = blue.map { min(1, $0 / peak) }
        luma = luma.map { min(1, $0 / peak) }
    }
}

private extension CIImage {
    func controls(saturation: Double = 1, brightness: Double = 0, contrast: Double = 1) -> CIImage {
        applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: saturation, kCIInputBrightnessKey: brightness, kCIInputContrastKey: contrast,
        ])
    }

    func vibrance(_ amount: Double) -> CIImage {
        applyingFilter("CIVibrance", parameters: ["inputAmount": amount])
    }

    /// Tone curve through y values at x = 0, 0.25, 0.5, 0.75, 1.
    func curve(_ ys: [Double]) -> CIImage {
        curve(points: ys.enumerated().map { CGPoint(x: Double($0.offset) * 0.25, y: $0.element) })
    }

    func curve(points: [CGPoint]) -> CIImage {
        applyingFilter("CIToneCurve", parameters: [
            "inputPoint0": CIVector(cgPoint: points[0]), "inputPoint1": CIVector(cgPoint: points[1]),
            "inputPoint2": CIVector(cgPoint: points[2]), "inputPoint3": CIVector(cgPoint: points[3]),
            "inputPoint4": CIVector(cgPoint: points[4]),
        ])
    }

    func matrix(r: Double, g: Double, b: Double, bias: (Double, Double, Double) = (0, 0, 0)) -> CIImage {
        applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
            "inputBiasVector": CIVector(x: bias.0, y: bias.1, z: bias.2, w: 0),
        ])
    }
}
