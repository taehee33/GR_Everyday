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

    /// This shot's value for a 촬영 통계 table, as the table keys it.
    func key(_ field: ShotFilter.Field) -> String? {
        switch field {
        case .mode: return mode
        case .tone: return imageTone.map(String.init)
        case .aspect: return aspect
        case .crop: return focal35.map { $0 <= 28 ? "꺼짐" : "\($0)mm" }
        case .hdf: return hdf.map { ["꺼짐", "켜짐", "레드 필터"].indices.contains($0) ? ["꺼짐", "켜짐", "레드 필터"][$0] : "코드 \($0)" }
        }
    }

    static func aspect(_ ratio: Double) -> String {
        let known: [(String, Double)] = [("3:2", 1.5), ("4:3", 4.0 / 3), ("1:1", 1), ("16:9", 16.0 / 9)]
        let best = known.min { abs($0.1 - ratio) < abs($1.1 - ratio) }!
        return abs(best.1 - ratio) < 0.03 ? best.0 : String(format: "%.2f:1", ratio)
    }
}

/// Shooting statistics like GR WORLD's GR 로그: the files on the card, plus shots seen on it
/// before and deleted since. Each photo is read once and kept on disk next to the other caches.
@MainActor
final class ShotStats: ObservableObject {
    @Published private(set) var records: [String: ShotRecord] = [:]
    @Published private(set) var scanning = false
    @Published private(set) var pending = 0
    private var task: Task<Void, Never>?
    /// USB and Wi-Fi reach the camera at different hosts, each with its own cache file.
    private var loadedFrom: URL?

    /// Every shot seen on a card, kept after it is deleted so the totals add up like GR 로그.
    /// Lives in Application Support: clearing the cache leaves it.
    @Published private(set) var history: [String: HistoryEntry] = ShotStats.readHistory()

    struct HistoryEntry: Codable {
        let id: String
        let date: Date
        let video: Bool
        var record: ShotRecord?
    }

    /// The shots a card's file list stands for: a RAW+JPEG pair is one shot, its JPEG.
    static func shots(_ photos: [Photo]) -> [Photo] {
        let jpegs = Set(photos.filter { $0.kind == .jpeg }.map { ($0.name as NSString).deletingPathExtension })
        return photos.filter { photo in
            switch photo.kind {
            case .jpeg, .video: return true
            case .raw: return !jpegs.contains((photo.name as NSString).deletingPathExtension)
            case .other: return false
            }
        }
    }

    /// Reads every photo not seen before, newest first, then adds the card to `history`.
    /// `dates` are the camera's shooting times (videos have no EXIF to read).
    func scan(_ photos: [Photo], dates: [String: Date]) {
        task?.cancel()
        if loadedFrom != Self.url {
            records = Self.read()
            loadedFrom = Self.url
        }
        let todo = Self.shots(photos).reversed().filter { $0.kind != .video && records[$0.id] == nil }
        pending = todo.count
        scanning = !todo.isEmpty
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
            if !todo.isEmpty { self?.write() }
            self?.scanning = false
            self?.remember(photos, dates: dates)
        }
    }

    /// History key: file and shooting time, since file names come back after a format.
    /// Photos use their EXIF time, videos the camera's, so each shot always gets the same key.
    private func key(_ photo: Photo, dates: [String: Date]) -> String? {
        let date = photo.kind == .video ? dates[photo.id] : records[photo.id]?.date
        return date.map { "\(photo.id)@\(Int($0.timeIntervalSince1970))" }
    }

    private func remember(_ photos: [Photo], dates: [String: Date]) {
        var changed = false
        for photo in Self.shots(photos) {
            guard let key = key(photo, dates: dates) else { continue }
            let record = records[photo.id]
            if history[key] == nil {
                let date = photo.kind == .video ? dates[photo.id]! : record!.date!
                history[key] = HistoryEntry(id: photo.id, date: date, video: photo.kind == .video, record: record)
                changed = true
            }
        }
        if changed { writeHistory() }
    }

    /// Shots in `history` that are no longer on the card. A file whose time isn't known yet
    /// is assumed to still be there.
    func deleted(from photos: [Photo], dates: [String: Date]) -> [HistoryEntry] {
        var onCard = Set<String>(), undated = Set<String>()
        for photo in Self.shots(photos) {
            if let key = key(photo, dates: dates) { onCard.insert(key) } else { undated.insert(photo.id) }
        }
        return history.filter { !onCard.contains($0.key) && !undated.contains($0.value.id) }.map(\.value)
    }

    func clearHistory() {
        history = [:]
        try? FileManager.default.removeItem(at: Self.historyURL)
    }

    private static var historyURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GR Mac/shot-history.json")
    }

    private static func readHistory() -> [String: HistoryEntry] {
        guard let data = try? Data(contentsOf: historyURL) else { return [:] }
        return (try? JSONDecoder().decode([String: HistoryEntry].self, from: data)) ?? [:]
    }

    private func writeHistory() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        try? FileManager.default.createDirectory(at: Self.historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.historyURL, options: .atomic)
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

/// Narrows the library to what a 촬영 통계 row or day counted: one value of one field,
/// one shooting day, or both.
struct ShotFilter: Equatable {
    enum Field: String, CaseIterable, Identifiable {
        case mode = "노출 모드", tone = "이미지 컨트롤", aspect = "화상비율", crop = "크롭", hdf = "HDF"
        var id: String { rawValue }

        /// How a key reads on screen: image controls are stored by maker-note code.
        func label(_ key: String) -> String {
            guard self == .tone, let code = Int(key) else { return key }
            return MakerNote.imageToneNames[code] ?? "알 수 없음 (코드 \(code))"
        }
    }

    var field: Field?
    var value: String?
    var day: Date?

    var label: String {
        var parts: [String] = []
        if let field, let value { parts.append(field.label(value)) }
        if let day { parts.append(day.formatted(.dateTime.month().day())) }
        return parts.joined(separator: " · ")
    }
}
