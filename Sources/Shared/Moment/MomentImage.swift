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
        files.first { isJPEG($0) } ?? files.first { isDNG($0) }
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

    /// Builds both upload files from the shot's original files (JPG and/or DNG).
    static func render(_ files: [URL], thumbEncoder: ThumbEncoder = .default) throws -> Rendered {
        guard let source = pickSource(files) else { throw Failure.noSource }
        guard isGROriginal(source) else { throw Failure.notGROriginal }
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil) else { throw Failure.unreadable }

        let display = try upright(src, maxEdge: displayEdge, embeddedOnly: isDNG(source))
        let edge = max(display.width, display.height)
        guard edge >= minimumEdge else { throw Failure.tooSmall(edge) }
        guard let displaySRGB = toSRGB(display),
              let displayData = encode(displaySRGB, type: .jpeg, quality: displayQuality),
              let thumbImage = scaled(displaySRGB, maxEdge: thumbEdge),
              let thumb = thumbEncoder.encode(thumbImage)
        else { throw Failure.encodeFailed }

        return Rendered(display: displayData,
                        displaySize: CGSize(width: displaySRGB.width, height: displaySRGB.height),
                        thumb: thumb.data,
                        thumbSize: CGSize(width: thumbImage.width, height: thumbImage.height),
                        thumbType: thumb.mimeType,
                        source: source)
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
