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
    var exposure: Exposure?
    var imageControl: ImageControl?
    var takenAt: Date?
    var lat: Double?
    var lon: Double?
    /// A place name the owner typed or picked on the map ("성수동"); not read from the file.
    var place: String?

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
        case camera, exposure, lat, lon, place
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
        if options.camera { out.camera = camera }
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
