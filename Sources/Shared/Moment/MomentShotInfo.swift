import Foundation
import ImageIO

/// Which groups of shot info the owner shares with a Moment photo. Saved as the default in
/// 설정 → Moment and changed per photo in the upload sheet. Location is off unless turned on.
struct MomentShareOptions: Codable, Equatable {
    var camera = true
    var exposure = true
    var imageControl = true
    var takenAt = true
    var location: LocationShare = .off

    enum LocationShare: String, Codable, CaseIterable {
        /// Not shared.
        case off
        /// Shared as recorded. (The raw value is the old name, kept so saved defaults still load;
        /// until 2026-11-13 it was rounded to about 1 km.)
        case approximate
    }

    private static let key = "moment.shareOptions"

    static func load(_ defaults: UserDefaults = .standard) -> MomentShareOptions {
        guard let data = defaults.data(forKey: key),
              let options = try? JSONDecoder().decode(MomentShareOptions.self, from: data) else { return .init() }
        return options
    }

    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

/// The shot info stored with a Moment photo, one field per DB column (`photos.camera`,
/// `exposure`, `image_control`, `taken_at`, `lat`, `lon`). A nil field is not shared. The
/// uploaded image files never carry EXIF; this is the only place shot info goes.
struct MomentShotInfo: Codable, Equatable {
    var camera: String?
    /// Where `camera` came from (`photos.camera_source`); nil when no camera is shared.
    var cameraSource: CameraSource?
    var exposure: Exposure?
    var imageControl: ImageControl?
    var takenAt: Date?
    var lat: Double?
    var lon: Double?
    /// A place name the owner typed or picked on the map ("성수동"); not read from the file.
    var place: String?
    /// The film loaded in a film GR ("Kodak Portra 400"), picked or typed by the owner
    /// (`photos.film`). Shown where a digital GR shows its image control.
    var film: String?

    enum CameraSource: String, Codable {
        /// Read from a GR original (Ricoh maker note and a GR model name).
        case exif
        /// Picked by the owner for a photo without GR shot info (a film GR scan, a GR DIGITAL file).
        case declared
    }

    /// The cameras an owner may pick for a photo without GR shot info: the film GRs, and every
    /// digital GR in release order (a scan, an export or a phone copy can lose the shot info).
    /// Keep in sync with DECLARED_CAMERAS in supabase/functions/moment-upload.
    static let filmCameras = ["GR1", "GR10", "GR1s", "GR21", "GR1v"]
    static let digitalCameras = [
        "GR DIGITAL", "GR DIGITAL II", "GR DIGITAL III", "GR DIGITAL IV",
        "GR", "GR II", "GR III", "GR III HDF", "GR IIIx", "GR IIIx HDF", "GR IV", "GR IV HDF",
    ]
    static var declarableCameras: [String] { filmCameras + digitalCameras }
    /// Films offered for a film GR; anything else can be typed (up to `filmLimit` characters).
    static let filmChoices = [
        "Kodak Portra 160", "Kodak Portra 400", "Kodak Portra 800", "Kodak Ektar 100",
        "Kodak Gold 200", "Kodak UltraMax 400", "Kodak ColorPlus 200", "Kodak Tri-X 400",
        "Kodak T-Max 400", "Fujifilm Superia X-TRA 400", "Fujifilm C200", "Fujifilm Velvia 50",
        "Fujifilm Provia 100F", "Fujifilm Acros 100 II", "Ilford HP5 Plus 400", "Ilford FP4 Plus 125",
        "Ilford Delta 3200", "Ilford XP2 Super 400", "CineStill 800T", "CineStill 400D",
        "Lomography Color 400",
    ]
    static let filmLimit = 40

    /// True when the camera was picked by the owner rather than read from the file.
    var isCameraDeclared: Bool { camera != nil && cameraSource == .declared }

    struct Exposure: Codable, Equatable {
        /// "1/30", "2\"" — as the camera shows it.
        var shutter: String?
        /// 2.8
        var aperture: Double?
        var iso: Int?
        /// Exposure compensation in EV, e.g. -0.7.
        var ev: Double?
        var focal35: Int?
        /// "P", "Sn", "Av", "Tv", "M".
        var mode: String?
    }

    struct ImageControl: Codable, Equatable {
        var code: Int
        var name: String?
        var settings: [Setting]
        /// "꺼짐", "켜짐", "레드 필터".
        var hdf: String?

        struct Setting: Codable, Equatable {
            var name: String
            var value: String
        }
    }

    enum CodingKeys: String, CodingKey {
        case camera, exposure, lat, lon, place, film
        case cameraSource = "camera_source"
        case imageControl = "image_control"
        case takenAt = "taken_at"
    }

    /// "P · 1/30 · F2.8 · ISO 200 · 28mm"
    var exposureSummary: String? {
        guard let e = exposure else { return nil }
        var parts: [String] = []
        if let mode = e.mode { parts.append(mode) }
        if let s = e.shutter { parts.append(s) }
        if let a = e.aperture { parts.append(String(format: "F%.1f", a)) }
        if let iso = e.iso { parts.append("ISO \(iso)") }
        if let ev = e.ev, ev != 0 { parts.append(String(format: "%+.1f EV", ev)) }
        if let f = e.focal35 { parts.append("\(f)mm") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "포지티브 필름 · 키 -1, 콘트라스트 +3" (only settings moved off their defaults).
    func imageControlSummary(maxSettings: Int = 3) -> String? {
        guard let c = imageControl else { return nil }
        let name = c.name ?? "코드 \(c.code)"
        let changed = c.settings.filter { $0.value != "0" && $0.value != "끄기" }
        let details = changed.prefix(maxSettings).map { "\($0.name) \($0.value)" }.joined(separator: ", ")
        return details.isEmpty ? name : "\(name) · \(details)"
    }

    var isEmpty: Bool { self == MomentShotInfo() }

    /// Everything the file records, before the owner's choices are applied. Works the same
    /// for a GR JPG and a GR DNG (both carry the EXIF and the Ricoh maker note).
    static func read(_ url: URL) -> MomentShotInfo {
        var info = MomentShotInfo()
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return info }
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        let shot = MakerNote.shot(url)

        info.camera = (tiff[kCGImagePropertyTIFFModel] as? String)?
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "RICOH ", with: "")
        if info.camera != nil { info.cameraSource = .exif }

        var exposure = Exposure()
        exposure.shutter = (exif[kCGImagePropertyExifExposureTime] as? Double).map(shutterText)
        exposure.aperture = exif[kCGImagePropertyExifFNumber] as? Double
        exposure.iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first
        exposure.ev = (exif[kCGImagePropertyExifExposureBiasValue] as? Double).map { ($0 * 10).rounded() / 10 }
        exposure.focal35 = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int
        exposure.mode = ShotRecord.mode(program: exif[kCGImagePropertyExifExposureProgram] as? Int,
                                        pictureMode: shot?.pictureMode)
        if exposure != Exposure() { info.exposure = exposure }

        if let control = shot?.imageControl {
            info.imageControl = ImageControl(
                code: control.code, name: control.name,
                settings: MakerNote.toneSettings(shot?.toneParams).map { .init(name: $0.name, value: $0.value) },
                hdf: shot?.hdfLabel)
        }

        if let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            info.takenAt = date(text, offset: exif[kCGImagePropertyExifOffsetTimeOriginal] as? String)
        }

        if let gps, var lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           var lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            if (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" { lat = -lat }
            if (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" { lon = -lon }
            info.lat = lat
            info.lon = lon
        }
        return info
    }

    /// Keeps only what the owner chose to share.
    func shared(_ options: MomentShareOptions) -> MomentShotInfo {
        var out = MomentShotInfo()
        if options.camera, let camera {
            out.camera = camera
            out.cameraSource = cameraSource ?? .exif
            out.film = film
        }
        if options.exposure { out.exposure = exposure }
        if options.imageControl { out.imageControl = imageControl }
        if options.takenAt { out.takenAt = takenAt }
        out.place = place
        if options.location == .approximate, let lat, let lon {
            out.lat = lat
            out.lon = lon
        }
        return out
    }

    /// Same style as the photo info sheet: "1/N" for 1/N second, otherwise seconds ("0.3\"",
    /// "2\"").
    static func shutterText(_ seconds: Double) -> String {
        guard seconds > 0 else { return "0" }
        let inverse = 1 / seconds
        if seconds < 1, abs(inverse - inverse.rounded()) < 0.01 { return "1/\(Int(inverse.rounded()))" }
        return seconds >= 1 && seconds == seconds.rounded() ? "\(Int(seconds))\"" : String(format: "%.1f\"", seconds)
    }

    /// EXIF times are the camera's local clock. Uses the recorded offset when the camera
    /// wrote one, otherwise this device's time zone.
    static func date(_ text: String, offset: String?) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        if let offset, offset.count == 6 {
            f.dateFormat = "yyyy:MM:dd HH:mm:ssxxx"
            return f.date(from: text + offset)
        }
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.timeZone = .current
        return f.date(from: text)
    }
}
