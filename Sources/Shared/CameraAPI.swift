import Foundation

/// RICOH GR HTTP API, served by the camera on its own Wi-Fi access point.
/// Spec: github.com/CursedHardware/ricoh-wireless-protocol (openapi.yaml).
struct CameraAPI {
    /// GRLINK_CAMERA_URL points the app at a mock camera for development.
    static let wifiBase: URL = {
        let env = ProcessInfo.processInfo.environment["GRLINK_CAMERA_URL"]
        return URL(string: env ?? "http://192.168.0.1")!
    }()

    /// The camera over Wi-Fi, or USBCamera's local server while connected by USB.
    /// Set only on the main actor, before requests for the new connection start.
    nonisolated(unsafe) static var base: URL = wifiBase

    /// False while no camera is connected: the library then shows what was saved from the
    /// last connection and must not ask 192.168.0.1, which is often the home router.
    nonisolated(unsafe) static var online = false

    /// When a download from the camera last moved. A long save keeps the camera's small web
    /// server busy, so a ping can time out then; data still arriving says it's connected.
    nonisolated(unsafe) static var lastTraffic = Date.distantPast

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        // The camera's web server is small; flooding it with parallel requests stalls it.
        config.httpMaximumConnectionsPerHost = 2
        config.timeoutIntervalForRequest = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    enum ImageSize: String { case thumb, view, xs }

    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func url(_ path: String, query: [String: String] = [:]) -> URL {
        var components = URLComponents(url: base.appendingPathComponent("v1" + path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url!
    }

    static func photoURL(_ photo: Photo, size: ImageSize? = nil) -> URL {
        url("/photos/\(photo.dir)/\(photo.name)", query: size.map { ["size": $0.rawValue] } ?? [:])
    }

    static func liveViewURL() -> URL { url("/liveview") }

    @discardableResult
    /// `retry`: send once more when the camera dropped the connection (-1005). Its small
    /// server closes kept-alive connections now and then, mostly while the live view runs.
    /// On by default for reads; off for anything that must not happen twice (the shutter).
    static func request(_ method: String, _ path: String, form: [String: String]? = nil, timeout: TimeInterval = 15,
                        retry: Bool? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: url(path), timeoutInterval: timeout)
        req.httpMethod = method
        if let form {
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = form.map { "\(escape($0.key))=\(escape($0.value))" }.joined(separator: "&").data(using: .utf8)
        }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch let error as URLError where error.code == .networkConnectionLost && (retry ?? (method == "GET")) {
            (data, response) = try await session.data(for: req)
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let errCode = json["errCode"] as? Int ?? status
        guard (200..<300).contains(status), errCode == 200 else {
            throw APIError(message: json["errMsg"] as? String ?? "HTTP \(status)")
        }
        return json
    }

    /// The camera doesn't decode %2C: "pos=50%2C50" is a 400 while "pos=50,50" focuses
    /// (GR IV HDF, fw 1.20), so commas go through as they are.
    private static func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~,"))) ?? s
    }

    static func props() async throws -> [String: Any] {
        try await request("GET", "/props")
    }

    static func ping(timeout: TimeInterval = 3) async -> Bool {
        (try? await request("GET", "/ping", timeout: timeout)) != nil
    }

    static func photos() async throws -> [Photo] {
        let json = try await request("GET", "/photos", timeout: 30)
        let dirs = json["dirs"] as? [[String: Any]] ?? []
        return dirs.flatMap { dir -> [Photo] in
            let name = dir["name"] as? String ?? ""
            return (dir["files"] as? [String] ?? []).map { Photo(dir: name, name: $0) }
        }
    }

    /// Shooting time and EXIF orientation (1 normal, 3 180°, 6 90° CW, 8 90° CCW).
    /// The camera's thumbnails and previews are stored unrotated.
    static func info(_ photo: Photo) async throws -> PhotoInfo {
        let json = try await request("GET", "/photos/\(photo.dir)/\(photo.name)/info")
        // Field names vary by model; whatever is present is shown in the info panel.
        var extras: [String: String] = [:]
        for key in ["cameraModel", "tv", "av", "sv", "xv", "size", "aspectRatio", "focalLength"] {
            if let v = json[key] { extras[key] = "\(v)" }
        }
        return PhotoInfo(date: (json["datetime"] as? String).flatMap(PhotoInfo.parseDate),
                         orientation: json["orientation"] as? Int ?? 1, extras: extras)
    }

    /// The first `limit` bytes of the original file: enough for its EXIF and maker note.
    /// Asks for a byte range and stops reading at the limit either way, so it works whether
    /// or not the camera honours ranges.
    static func head(_ photo: Photo, limit: Int = 512 * 1024) async throws -> Data {
        var req = URLRequest(url: photoURL(photo), timeoutInterval: 15)
        req.setValue("bytes=0-\(limit - 1)", forHTTPHeaderField: "Range")
        let (bytes, response) = try await session.bytes(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 206 else { throw APIError(message: "HTTP \(status)") }
        var data = Data()
        data.reserveCapacity(limit)
        var buffer = [UInt8]()
        buffer.reserveCapacity(16 * 1024)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count == buffer.capacity {
                data.append(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                if data.count >= limit { break }
            }
        }
        data.append(contentsOf: buffer)
        return data.prefix(limit)
    }

    /// The focus method lives under /params/lens; everything else under /params/camera.
    static func setParams(_ params: [String: String]) async throws {
        var camera = params
        // The camera reports positive exposure compensation as "+0.7" but answers 400 to
        // that; "0.7" is what it takes (GR IV HDF fw 1.20, 2026-11-10).
        if let xv = camera["xv"], xv.hasPrefix("+") { camera["xv"] = String(xv.dropFirst()) }
        if let focus = camera.removeValue(forKey: "focusSetting") {
            try await request("PUT", "/params/lens", form: ["focusSetting": focus])
        }
        if !camera.isEmpty { try await request("PUT", "/params/camera", form: camera) }
    }

    static func shoot() async throws {
        try await request("POST", "/camera/shoot", timeout: 30)
    }

    /// x, y in percent of the live view frame.
    /// Focus at x, y. Returns the camera's verdict when its reply has one; nil when it only
    /// accepted the command. props.focused doesn't help: on the GR IV HDF (fw 1.20) it stayed
    /// 0 for 15 s after taps that visibly focused.
    static func focus(x: Int, y: Int) async throws -> Bool? {
        // Focusing twice is harmless.
        let reply = try await request("POST", "/lens/focus", form: ["pos": "\(x),\(y)"], retry: true)
        DebugLog.write("focus: reply \(reply)")
        return reply["focused"] as? Bool
    }

    static func finishWLAN() async {
        _ = try? await request("POST", "/device/wlan/finish", timeout: 5)
    }
}

struct Photo: Identifiable, Hashable, Codable {
    let dir: String
    let name: String
    var id: String { "\(dir)/\(name)" }

    enum Kind: String, CaseIterable { case jpeg = "JPG", raw = "RAW", video = "영상", other = "기타" }

    var kind: Kind {
        switch (name as NSString).pathExtension.uppercased() {
        case "JPG", "JPEG": return .jpeg
        case "DNG": return .raw
        case "MOV", "MP4": return .video
        default: return .other
        }
    }
}

struct PhotoInfo: Hashable, Codable {
    let date: Date?
    let orientation: Int
    var extras: [String: String] = [:]

    var isPortrait: Bool { [5, 6, 7, 8].contains(orientation) }

    /// "2026-10-31T12:30:05", with or without a zone (camera local time when absent).
    static func parseDate(_ text: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: text) { return date }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return local.date(from: String(text.prefix(19)))
    }
}
