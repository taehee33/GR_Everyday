import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns a camera original into the two files Moment uploads: a 3072 px JPEG for the full
/// view and a small thumbnail for grids. Both are sRGB and carry no metadata at all; the shot
/// info the owner chooses to share travels separately (`MomentShotInfo`). See PLAN-moment.md.
///
/// Only GR originals are accepted. A DNG is not developed here: GR DNGs embed the camera's
/// own full-size JPEG (image control applied, verified on a GR IV HDF to match the camera
/// JPG), and that JPEG is what gets used.
///
/// A photo without GR shot info (a film GR scan, a GR DIGITAL file) is accepted only once the
/// owner has picked its camera (`declared`); then any image ImageIO reads will do, and nothing
/// is read from its metadata (a scan's EXIF is the scanner's or the phone's, GPS included).
enum MomentImage {
    static let displayEdge = 3072
    static let thumbEdge = 600
    /// Below this the source is too small to be worth showing (or is a DNG's 160 px preview).
    static let minimumEdge = 1080
    static let displayQuality = 0.9

    struct Rendered {
        let display: Data
        let displaySize: CGSize
        let thumb: Data
        let thumbSize: CGSize
        /// MIME type of `thumb` ("image/webp" once the WebP encoder is in, see `ThumbEncoder`).
        let thumbType: String
        /// The file the pixels came from (the JPG when both a JPG and a DNG exist).
        let source: URL
    }

    enum Failure: LocalizedError, Equatable {
        case noSource
        case notGROriginal
        case unreadable
        case noEmbeddedJPEG
        case tooSmall(Int)
        case encodeFailed

        var errorDescription: String? {
            switch self {
            case .noSource: return "올릴 사진 파일이 없어요."
            case .notGROriginal: return "GR로 찍은 원본만 Moment에 올릴 수 있어요."
            case .unreadable: return "사진 파일을 읽을 수 없어요."
            case .noEmbeddedJPEG: return "이 DNG에는 카메라가 만든 JPEG가 들어 있지 않아요."
            case .tooSmall(let edge): return "사진이 너무 작아요 (긴 변 \(edge)px)."
            case .encodeFailed: return "업로드용 이미지를 만들지 못했어요."
            }
        }
    }

    /// The camera original to read for one shot: the JPG when there is one (same pixels as the
    /// DNG's embedded JPEG, and faster), otherwise the DNG.
    static func pickSource(_ files: [URL]) -> URL? {
        files.first { isJPEG($0) } ?? files.first { isDNG($0) } ?? files.first { isImage($0) }
    }

    /// Any image file by extension (HEIC, PNG, TIFF, …), for photos whose camera is picked.
    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    static func isDNG(_ url: URL) -> Bool { url.pathExtension.uppercased() == "DNG" }
    static func isJPEG(_ url: URL) -> Bool { ["JPG", "JPEG"].contains(url.pathExtension.uppercased()) }

    /// True when the file was written by a GR camera: it has the Ricoh maker note and a GR
    /// model name. Edits made in the app live in edits.json, never in the file, so a file that
    /// passes is the untouched original.
    static func isGROriginal(_ url: URL) -> Bool {
        guard MakerNote.shot(url) != nil,
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
              let model = tiff[kCGImagePropertyTIFFModel] as? String
        else { return false }
        return model.uppercased().contains("GR")
    }

    /// Loaded at up to this size so a crop still fills the 3072 px full view.
    static let workingEdge = 4608

    /// The original, upright and in sRGB, kept while the owner frames it.
    struct Loaded {
        let image: CGImage
        let source: URL
    }

    /// Reads the shot's original (JPG, or the DNG's embedded camera JPEG) for framing.
    /// `declared`: the owner picked the camera, so the file need not be a GR original, and a
    /// DNG is developed by ImageIO (a scan's DNG has no camera JPEG inside).
    static func load(_ files: [URL], declared: Bool = false) throws -> Loaded {
        guard let source = pickSource(files) else { throw Failure.noSource }
        guard declared || isGROriginal(source) else { throw Failure.notGROriginal }
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil) else { throw Failure.unreadable }
        let image = try upright(src, maxEdge: workingEdge, embeddedOnly: isDNG(source) && !declared)
        let edge = max(image.width, image.height)
        guard edge >= minimumEdge else { throw Failure.tooSmall(edge) }
        guard let srgb = toSRGB(image) else { throw Failure.encodeFailed }
        return Loaded(image: srgb, source: source)
    }

    /// Builds both upload files from the shot's original files (JPG and/or DNG), uncropped.
    static func render(_ files: [URL], thumbEncoder: ThumbEncoder = .default) throws -> Rendered {
        try render(load(files), edit: MomentCropEdit(), thumbEncoder: thumbEncoder)
    }

    /// Both upload files from a loaded original, turned and cropped as framed.
    static func render(_ loaded: Loaded, edit: MomentCropEdit,
                       thumbEncoder: ThumbEncoder = .default) throws -> Rendered {
        guard let turned = rotated(loaded.image, quarterTurns: edit.quarterTurns) else { throw Failure.encodeFailed }
        let w = CGFloat(turned.width), h = CGFloat(turned.height)
        let crop = CGRect(x: edit.crop.minX * w, y: edit.crop.minY * h,
                          width: edit.crop.width * w, height: edit.crop.height * h)
            .integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard let cropped = edit.isCropped ? turned.cropping(to: crop) : turned else { throw Failure.encodeFailed }
        let edge = max(cropped.width, cropped.height)
        guard edge >= minimumEdge else { throw Failure.tooSmall(edge) }
        guard let display = scaled(cropped, maxEdge: displayEdge),
              let displayData = encode(display, type: .jpeg, quality: displayQuality),
              let thumbImage = scaled(display, maxEdge: thumbEdge),
              let thumb = thumbEncoder.encode(thumbImage)
        else { throw Failure.encodeFailed }

        return Rendered(display: displayData,
                        displaySize: CGSize(width: display.width, height: display.height),
                        thumb: thumb.data,
                        thumbSize: CGSize(width: thumbImage.width, height: thumbImage.height),
                        thumbType: thumb.mimeType,
                        source: loaded.source)
    }

    /// The image turned clockwise by `quarterTurns` × 90°.
    static func rotated(_ image: CGImage, quarterTurns: Int) -> CGImage? {
        let turns = ((quarterTurns % 4) + 4) % 4
        if turns == 0 { return image }
        let w = image.width, h = image.height
        let (outW, outH) = turns % 2 == 0 ? (w, h) : (h, w)
        guard let ctx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        // Core Graphics has y up, so a clockwise turn on screen is a negative angle here.
        ctx.translateBy(x: CGFloat(outW) / 2, y: CGFloat(outH) / 2)
        ctx.rotate(by: -CGFloat(turns) * .pi / 2)
        ctx.draw(image, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage()
    }

    /// The image upright and no larger than `maxEdge`. For a DNG, only the embedded camera
    /// JPEG is used (`embeddedOnly`); ImageIO picks the largest embedded image and scales it.
    private static func upright(_ src: CGImageSource, maxEdge: Int, embeddedOnly: Bool) throws -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: !embeddedOnly,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: !embeddedOnly,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            throw embeddedOnly ? Failure.noEmbeddedJPEG : Failure.unreadable
        }
        return image
    }

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Redraws into sRGB so an Adobe RGB original keeps its colours on every screen, and so
    /// the thumbnail and the full view always match.
    static func toSRGB(_ image: CGImage) -> CGImage? {
        draw(image, width: image.width, height: image.height)
    }

    static func scaled(_ image: CGImage, maxEdge: Int) -> CGImage? {
        let s = min(1, Double(maxEdge) / Double(max(image.width, image.height)))
        return draw(image, width: Int((Double(image.width) * s).rounded()),
                    height: Int((Double(image.height) * s).rounded()))
    }

    private static func draw(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// Encodes with no metadata dictionary, so no EXIF, GPS or maker note is written.
    static func encode(_ image: CGImage, type: UTType, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

/// How the owner framed a photo before uploading: turned in quarter turns, then cropped.
/// Only framing; colour and tone stay the camera's.
struct MomentCropEdit: Equatable {
    /// Clockwise quarter turns (0–3).
    var quarterTurns = 0
    /// The part kept, as fractions of the turned image (0–1, origin top left).
    var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// The shape picked on the crop screen, to open it the same way again.
    var aspect: MomentCropAspect = .original
    var portrait: Bool? = nil

    var isCropped: Bool {
        abs(crop.minX) > 0.0005 || abs(crop.minY) > 0.0005 || abs(crop.width - 1) > 0.0005 || abs(crop.height - 1) > 0.0005
    }
    var isEdited: Bool { quarterTurns % 4 != 0 || isCropped }
}

enum MomentCropAspect: String, CaseIterable, Identifiable {
    case original, free, square, fourFive, threeTwo, sixteenNine
    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "원본"
        case .free: return "자유"
        case .square: return "1:1"
        case .fourFive: return "4:5"
        case .threeTwo: return "3:2"
        case .sixteenNine: return "16:9"
        }
    }

    /// Long side over short side; nil = the photo's own (원본) or any (자유).
    var ratio: CGFloat? {
        switch self {
        case .original, .free: return nil
        case .square: return 1
        case .fourFive: return 5.0 / 4.0
        case .threeTwo: return 1.5
        case .sixteenNine: return 16.0 / 9.0
        }
    }
}

/// How the grid thumbnail is encoded. The plan is WebP (about 80 quality), but ImageIO can
/// only read WebP, not write it, so that needs libwebp (SPM, e.g. SDWebImage/libwebp-Xcode).
/// Until the package is added the thumbnail is a JPEG; the server stores whatever type it is
/// told, so switching later needs no other change.
struct ThumbEncoder {
    let mimeType: String
    let encoder: (CGImage) -> Data?

    func encode(_ image: CGImage) -> (data: Data, mimeType: String)? {
        encoder(image).map { ($0, mimeType) }
    }

    static let jpeg = ThumbEncoder(mimeType: "image/jpeg") { MomentImage.encode($0, type: .jpeg, quality: 0.8) }
    static var `default`: ThumbEncoder { jpeg }
}
