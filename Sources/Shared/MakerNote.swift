import Foundation
import ImageIO

/// Reads what the GR records about a shot in its maker note.
///
/// GR files carry a Pentax-format maker note behind a "RICOH\0II" header. Tag 0x004f
/// ("ImageTone" in ExifTool) holds the image control, tag 0x009e the HDF setting. Names
/// come from ExifTool's Pentax table plus codes confirmed on the user's GR IV; any other
/// code is shown as a number, never guessed. No tag records which custom slot (1–3) was
/// used, so a custom shot shows up as the image control it is based on.
enum MakerNote {
    struct ImageControl: Equatable {
        let code: Int
        let name: String?
    }

    struct Shot: Equatable {
        var imageControl: ImageControl?
        /// 0 off, 1 on, 2 red filter (GR IV Monochrome).
        var hdf: Int?
        /// Tag 0x0033 ("PictureMode"): P [0,0,1], Tv [4,0,1], Av [5,0,1], Sn [0,32,1] on the
        /// GR IV. Sn is ExposureProgram 2 in EXIF, the same as P; only this tells them apart.
        var pictureMode: [Int]?
        /// Tag 0x0247: the image control's settings, 35 little-endian Int16s, -32768 where
        /// that control has no such setting. See `toneSettings` for the known positions.
        var toneParams: [Int]?

        var hdfLabel: String? {
            switch hdf {
            case 0: return "꺼짐"
            case 1: return "켜짐"
            case 2: return "레드 필터"
            case let v?: return "알 수 없음 (코드 \(v))"
            case nil: return nil
            }
        }
    }

    static let imageToneNames: [Int: String] = [
        // GR III codes from ExifTool, names as on the GR IV's Korean menu.
        256: "스탠다드", 257: "비비드", 258: "모노톤", 259: "소프트 모노톤", 260: "하드 모노톤",
        261: "하이 콘트라스트 흑백", 262: "포지티브 필름", 263: "블리치 바이패스", 264: "복고풍",
        265: "HDR 톤", 266: "크로스 프로세스", 267: "네거티브 필름",
        // GR IV, confirmed by shooting with each setting.
        268: "시네마톤 (옐로)", 269: "시네마톤 (그린)",
        // GR IV Monochrome, ExifTool 13.60 (2026-10-28). 33024 is listed both as Standard
        // and as Custom 1–3 there, so it stays a number.
        33025: "솔리드", 33026: "소프트", 33027: "하이 콘트라스트", 33028: "그레이니", 33029: "HDR 톤",
    ]

    static func shot(_ url: URL) -> Shot? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 2_000_000) else { return nil }
        return shot(data)
    }

    static func shot(_ data: Data) -> Shot? {
        guard data.count > 16 else { return nil }
        let bytes = [UInt8](data)
        guard let tiff = tiffStart(bytes) else { return nil }
        guard let note = makerNote(bytes, tiff: tiff) else { return nil }
        // "RICOH\0" + byte order + IFD; offsets inside are relative to the note's start.
        guard note.count > 10, note.starts(with: Array("RICOH\0".utf8)) else { return nil }
        let le = note[6] == 0x49
        var shot = Shot()
        for i in 0..<read16(note, 8, le) {
            let e = 10 + i * 12
            guard e + 12 <= note.count else { break }
            let tag = read16(note, e, le), type = read16(note, e + 2, le)
            if tag == 0x004f, type == 3 {
                let code = read16(note, e + 8, le)
                shot.imageControl = ImageControl(code: code, name: imageToneNames[code])
            } else if tag == 0x009e, type == 1 {
                shot.hdf = Int(note[e + 8])
            } else if tag == 0x0033, type == 1 || type == 7, read32(note, e + 4, le) == 3 {
                shot.pictureMode = note[(e + 8)..<(e + 11)].map(Int.init)
            } else if tag == 0x0247, type == 7 {
                // Stored as bytes; the values inside are little-endian on the GR IV.
                let count = read32(note, e + 4, le), offset = read32(note, e + 8, le)
                if count >= 2, offset + count <= note.count {
                    shot.toneParams = stride(from: offset, to: offset + count - 1, by: 2).map {
                        Int(Int16(bitPattern: UInt16(note[$0]) | UInt16(note[$0 + 1]) << 8))
                    }
                }
            }
        }
        return shot.imageControl == nil && shot.hdf == nil && shot.pictureMode == nil && shot.toneParams == nil ? nil : shot
    }

    /// Positions in tag 0x0247 matched against the camera's own menu (GR IV HDF fw 1.20:
    /// Custom 1 on Standard, Positive Film, Cross Process, Retro, and Soft Monotone shots
    /// changing one setting at a time; every control's full menu photographed at its defaults). Index 7 stays unnamed (never
    /// set on any of the 14 image controls).
    /// Named positions, in the camera menu's order. Toning-like items sit after 샤프니스;
    /// each image control uses at most one of them (others hold -1 or -32768).
    static let toneSettingNames: [(index: Int, name: String)] = [
        (0, "채도"), (1, "색상"), (2, "키"), (3, "콘트라스트"), (4, "콘트라스트(하이라이트)"),
        (5, "콘트라스트(섀도)"), (6, "샤프니스"),
        (8, "조색"),      // 복고풍
        (13, "조색"),     // 흑백 계열: 0 끄기, 1–5 색
        (14, "조색"),     // 블리치 바이패스: 0 끄기
        (15, "조색"),     // HDR 톤: 0 끄기
        (24, "조색"),     // 시네마톤
        (21, "색조"),     // 크로스 프로세스: 1 = B
        (16, "HDR톤 효과"),
        (9, "음영"), (10, "명료도"),
    ]

    /// 흑백 조색 colours in the camera's order; 필터 효과 is a 4-byte preset at indexes 17–18
    /// (8, 0 on colour controls); 입자감 is index 19: 8 off, anything else on (0x0303 soft
    /// mono and Positive Film, 0x0301 Hi-Contrast B&W).
    static let toningNames = ["끄기", "주황", "빨강", "초록", "파랑", "보라"]
    static let filterPresets: [[Int]: String] = [
        [0, 0]: "끄기", [2561, 5190]: "1", [10241, 2610]: "2", [23105, 2580]: "3", [30817, 2570]: "4",
    ]

    /// The settings this shot's image control has, in the camera menu's order ("+1"). A
    /// position not matched to a menu item yet but holding a value shows as "? (N번)", so
    /// it can be compared with the camera's menu.
    static func toneSettings(_ params: [Int]?) -> [(name: String, value: String)] {
        guard let params else { return [] }
        func at(_ i: Int) -> Int? { i < params.count && params[i] != -32768 ? params[i] : nil }
        func signed(_ v: Int) -> String { v > 0 ? "+\(v)" : "\(v)" }
        var out: [(name: String, value: String)] = []
        let mono = (at(13) ?? -1) >= 0
        for item in toneSettingNames {
            guard let v = at(item.index) else { continue }
            // These slots hold -1 on image controls that don't have the item.
            if [13, 14, 15, 16, 21, 24].contains(item.index), v == -1 { continue }
            switch item.index {
            case 13: out.append((item.name, toningNames.indices.contains(v) ? toningNames[v] : "코드 \(v)"))
            case 14, 15: out.append((item.name, v == 0 ? "끄기" : "\(v)"))
            case 16, 24: out.append((item.name, "\(v)"))
            case 21: out.append((item.name, v == 1 ? "B" : "\(v)"))
            default: out.append((item.name, signed(v)))
            }
            if item.index == 16 || (item.index == 24) { continue }
            if item.index == 21 || item.index == 13 {
                // 필터 효과 follows 조색 on monochrome controls.
                if item.index == 13, params.count > 18, let f = filterPresets[[params[17], params[18]]] {
                    out.append(("필터 효과", f))
                }
            }
        }
        // 입자감 comes last in the menu. Shown for monochrome controls, and for colour ones
        // only when on (where it is "--" otherwise, or absent).
        if let g = at(19), mono || g != 8 { out.append(("입자감", g == 8 ? "끄기" : "켜기")) }
        let named = Set(toneSettingNames.map(\.index)).union([17, 18, 19, 20])
        for i in params.indices where !named.contains(i) {
            if let v = at(i), v != -1 { out.append(("? (\(i)번)", "\(v)")) }
        }
        return out
    }

    static func imageControl(_ url: URL) -> ImageControl? { shot(url)?.imageControl }

    /// The EXIF fields the shooting statistics need, read straight from the TIFF structure:
    /// ImageIO wants the JPEG frame header too, which the GR IV puts ~100 KB in (after a
    /// 59 KB APP7), while these sit in the first 40 KB.
    struct Exif {
        var program: Int?
        var focal35: Int?
        var width: Int?
        var height: Int?
        /// "2026:11:01 12:17:25", camera local time.
        var dateOriginal: String?
    }

    static func exif(_ data: Data) -> Exif? {
        guard data.count > 16 else { return nil }
        let b = [UInt8](data)
        guard let tiff = tiffStart(b), tiff + 8 <= b.count else { return nil }
        let le = b[tiff] == 0x49
        guard let exifIFD = ifd(b, tiff: tiff, at: read32(b, tiff + 4, le), le).first(where: { $0.tag == 0x8769 })
        else { return nil }
        var out = Exif()
        for e in ifd(b, tiff: tiff, at: exifIFD.value, le) {
            // SHORT values sit in the first two bytes of the value field.
            let number = e.type == 3 ? read16(b, e.offset + 8, le) : e.value
            switch e.tag {
            case 0x8822: out.program = number
            case 0xA405: out.focal35 = number
            case 0xA002: out.width = number
            case 0xA003: out.height = number
            case 0x9003 where e.type == 2 && e.count >= 19:
                let start = tiff + e.value
                if start + 19 <= b.count { out.dateOriginal = String(decoding: b[start..<(start + 19)], as: UTF8.self) }
            default: break
            }
        }
        return out
    }

    private static func ifd(_ b: [UInt8], tiff: Int, at ifd: Int, _ le: Bool)
        -> [(tag: Int, type: Int, count: Int, value: Int, offset: Int)] {
        let start = tiff + ifd
        guard ifd > 0, start + 2 <= b.count else { return [] }
        return (0..<read16(b, start, le)).compactMap { k in
            let e = start + 2 + k * 12
            guard e + 12 <= b.count else { return nil }
            return (read16(b, e, le), read16(b, e + 2, le), read32(b, e + 4, le), read32(b, e + 8, le), e)
        }
    }

    /// Offset of the TIFF header: inside the Exif APP1 segment of a JPEG, or 0 for DNG/TIFF.
    private static func tiffStart(_ b: [UInt8]) -> Int? {
        if b[0] == 0x49 || b[0] == 0x4D { return 0 }
        guard b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var i = 2
        while i + 4 < b.count, b[i] == 0xFF {
            let marker = b[i + 1]
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            if marker == 0xE1, i + 10 < b.count, b[(i + 4)..<(i + 10)].elementsEqual(Array("Exif\0\0".utf8)) {
                return i + 10
            }
            i += 2 + length
        }
        return nil
    }

    private static func makerNote(_ b: [UInt8], tiff: Int) -> [UInt8]? {
        guard tiff + 8 <= b.count else { return nil }
        let le = b[tiff] == 0x49
        func entries(_ ifd: Int) -> [(tag: Int, count: Int, value: Int)] {
            let start = tiff + ifd
            guard start + 2 <= b.count else { return [] }
            let n = read16(b, start, le)
            return (0..<n).compactMap { k in
                let e = start + 2 + k * 12
                guard e + 12 <= b.count else { return nil }
                return (read16(b, e, le), read32(b, e + 4, le), read32(b, e + 8, le))
            }
        }
        let ifd0 = entries(read32(b, tiff + 4, le))
        // JPEG: Exif IFD → MakerNote. DNG: the same "RICOH" note sits in IFD0's
        // DNGPrivateData (0xC634), 160 KB long, so only the part inside `b` is kept: the
        // tags read here (0x0247 among them) are near its start.
        let note = ifd0.first(where: { $0.tag == 0x8769 }).flatMap { exif in entries(exif.value).first { $0.tag == 0x927C } }
            ?? ifd0.first { $0.tag == 0xC634 }
        guard let note else { return nil }
        let start = tiff + note.value
        guard start >= 0, start < b.count else { return nil }
        return Array(b[start..<min(start + note.count, b.count)])
    }

    private static func read16(_ b: [UInt8], _ i: Int, _ le: Bool) -> Int {
        le ? Int(b[i]) | Int(b[i + 1]) << 8 : Int(b[i]) << 8 | Int(b[i + 1])
    }

    private static func read32(_ b: [UInt8], _ i: Int, _ le: Bool) -> Int {
        le ? Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24
           : Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
    }
}

/// What the info panel shows about a photo, read from the saved file or, for photos still
/// on the camera, from the first part of the original (where JPEG/DNG keep their EXIF).
struct PhotoMetadata {
    var camera: String?
    var shot: MakerNote.Shot?
    var shutter: String?
    var aperture: String?
    var iso: String?
    /// Exposure compensation, only when not zero.
    var compensation: String?
    var focalLength: String?
    var pixelSize: String?
    var fileSize: String?

    static func read(_ url: URL) -> PhotoMetadata? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        return build(src, shot: MakerNote.shot(url), fileSize: fileSize)
    }

    static func read(head: Data, fileSize: Int64?) -> PhotoMetadata? {
        guard let src = CGImageSourceCreateWithData(head as CFData, nil) else { return nil }
        return build(src, shot: MakerNote.shot(head), fileSize: fileSize)
    }

    private static func build(_ src: CGImageSource, shot: MakerNote.Shot?, fileSize: Int64?) -> PhotoMetadata? {
        guard let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        var m = PhotoMetadata(shot: shot)
        m.camera = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let t = exif[kCGImagePropertyExifExposureTime] as? Double, t > 0 {
            m.shutter = t >= 1 ? String(format: "%.1fs", t) : "1/\(Int((1 / t).rounded()))s"
        }
        if let f = exif[kCGImagePropertyExifFNumber] as? Double { m.aperture = String(format: "f/%.1f", f) }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { m.iso = "ISO \(iso)" }
        if let xv = exif[kCGImagePropertyExifExposureBiasValue] as? Double, abs(xv) >= 0.05 {
            m.compensation = String(format: "%+.1f EV", xv)
        }
        if let fl = exif[kCGImagePropertyExifFocalLength] as? Double { m.focalLength = String(format: "%.1fmm", fl) }
        let w = p[kCGImagePropertyPixelWidth] as? Int ?? exif[kCGImagePropertyExifPixelXDimension] as? Int
        let h = p[kCGImagePropertyPixelHeight] as? Int ?? exif[kCGImagePropertyExifPixelYDimension] as? Int
        if let w, let h {
            m.pixelSize = "\(w) × \(h) (\(String(format: "%.1f", Double(w * h) / 1_000_000))MP)"
        }
        if let fileSize { m.fileSize = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file) }
        return m
    }
}

/// Metadata already read this session, so stepping back and forth doesn't refetch.
@MainActor
enum MetadataCache {
    static var entries: [String: PhotoMetadata] = [:]
}
