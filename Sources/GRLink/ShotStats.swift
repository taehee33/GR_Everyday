import Foundation

/// What a shot was taken with, read once from the first 64 KB of the original (EXIF and the
/// maker note sit in the Exif segment, about 40 KB on the GR IV).
struct ShotRecord: Codable, Equatable {
    var date: Date?
    var mode: String?
    var imageTone: Int?
    var aspect: String?
    /// 35 mm-equivalent focal length: 28 uncropped on GR III/IV, 35 or 50 with crop.
    var focal35: Int?
    var hdf: Int?

    static let headLimit = 64 * 1024

    init(head: Data) {
        let shot = MakerNote.shot(head)
        imageTone = shot?.imageControl?.code
        hdf = shot?.hdf
        guard let exif = MakerNote.exif(head) else { return }
        mode = Self.mode(program: exif.program, pictureMode: shot?.pictureMode)
        focal35 = exif.focal35
        if let w = exif.width, let h = exif.height, w > 0, h > 0 {
            aspect = Self.aspect(Double(max(w, h)) / Double(min(w, h)))
        }
        if let text = exif.dateOriginal {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            date = f.date(from: text)
        }
    }

    /// Verified on the GR IV: P 2, Av 3, Tv 4 in EXIF; Sn is also 2 and differs only in the
    /// maker note (0x0033 = [0, 32, 1]). M is EXIF's "manual" (1); B, T and BT are not
    /// sampled yet, so any other code is shown as a number.
    static func mode(program: Int?, pictureMode: [Int]?) -> String? {
        switch program {
        case 2?: return pictureMode?.count == 3 && pictureMode?[1] == 32 ? "Sn" : "P"
        case 3?: return "Av"
        case 4?: return "Tv"
        case 1?: return "M"
        case let code?: return "기타 (\(code))"
        case nil: return nil
        }
    }

    static func aspect(_ ratio: Double) -> String {
        let known: [(String, Double)] = [("3:2", 1.5), ("4:3", 4.0 / 3), ("1:1", 1), ("16:9", 16.0 / 9)]
        let best = known.min { abs($0.1 - ratio) < abs($1.1 - ratio) }!
        return abs(best.1 - ratio) < 0.03 ? best.0 : String(format: "%.2f:1", ratio)
    }
}

/// Shooting statistics like GR WORLD's GR 로그, counted from the files still on the card.
/// Each photo is read once and kept on disk next to the other caches.
@MainActor
final class ShotStats: ObservableObject {
    @Published private(set) var records: [String: ShotRecord] = [:]
    @Published private(set) var scanning = false
    @Published private(set) var pending = 0
    private var task: Task<Void, Never>?
    /// USB and Wi-Fi reach the camera at different hosts, each with its own cache file.
    private var loadedFrom: URL?

    /// Reads every photo not seen before, newest first. One JPEG of a RAW+JPEG pair is enough.
    func scan(_ photos: [Photo]) {
        task?.cancel()
        if loadedFrom != Self.url {
            records = Self.read()
            loadedFrom = Self.url
        }
        let jpegs = Set(photos.filter { $0.kind == .jpeg }.map { ($0.name as NSString).deletingPathExtension })
        let todo = photos.reversed().filter { photo in
            guard records[photo.id] == nil else { return false }
            switch photo.kind {
            case .jpeg: return true
            case .raw: return !jpegs.contains((photo.name as NSString).deletingPathExtension)
            case .video, .other: return false
            }
        }
        pending = todo.count
        guard !todo.isEmpty else { return }
        scanning = true
        task = Task { [weak self] in
            var sinceWrite = 0
            for photo in todo {
                if Task.isCancelled { break }
                if let head = try? await CameraAPI.head(photo, limit: ShotRecord.headLimit) {
                    let record = await Task.detached { ShotRecord(head: head) }.value
                    self?.records[photo.id] = record
                    sinceWrite += 1
                    if sinceWrite >= 20 { self?.write(); sinceWrite = 0 }
                }
                self?.pending -= 1
            }
            self?.write()
            self?.scanning = false
        }
    }

    func cancel() {
        task?.cancel()
        scanning = false
    }

    func clear() {
        cancel()
        records = [:]
        pending = 0
        try? FileManager.default.removeItem(at: Self.url)
    }

    private static var url: URL {
        ImageCache.folder.appendingPathComponent("shot-stats-\(CameraAPI.base.host ?? "camera").json")
    }

    private static func read() -> [String: ShotRecord] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: ShotRecord].self, from: data)) ?? [:]
    }

    private func write() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? FileManager.default.createDirectory(at: ImageCache.folder, withIntermediateDirectories: true)
        try? data.write(to: Self.url, options: .atomic)
    }
}
