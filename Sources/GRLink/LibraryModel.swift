import AppKit
import Combine
import Foundation

@MainActor
final class LibraryModel: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "전체", jpeg = "JPG", raw = "RAW", video = "영상", unsaved = "미저장"
        var id: String { rawValue }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case newest = "최신순", oldest = "오래된순", name = "파일명순"
        var id: String { rawValue }
    }

    struct DaySection: Identifiable {
        let id: String
        let title: String
        let photos: [Photo]
    }

    /// Lightroom-style views: grid, one photo with filmstrip, and editing.
    enum Mode: String { case grid, loupe, develop }

    enum Compare: String { case off, sideBySide, split }

    struct Transfer: Identifiable {
        enum Status { case waiting, running(Double), done, failed(String) }
        let photo: Photo
        var status: Status = .waiting
        var id: String { photo.id }
    }

    @Published private(set) var photos: [Photo] = []
    /// Shooting statistics (촬영 통계 pane), counted from the photos above.
    let stats = ShotStats()
    /// Set from 촬영 통계: only shots with this image control, mode, … and/or day.
    @Published var shotFilter: ShotFilter?
    private var statsChanges: AnyCancellable?
    @Published var selection: Set<String> = []
    @Published var filter: Filter = .all
    @Published private(set) var saved: Set<String> = []
    @Published private(set) var isLoading = false
    @Published var error: String?
    @Published private(set) var transfers: [Transfer] = []
    @Published private(set) var isTransferring = false
    /// Shooting time and orientation per photo id, filled in after the list loads.
    @Published private(set) var infos: [String: PhotoInfo] = [:]
    @Published var mode: Mode = .grid
    /// The photo shown in loupe / develop, and the anchor for ⇧-click ranges.
    @Published var current: Photo?
    /// Tab: side panels (app sidebar, info / develop panel).
    @Published var panels = true
    /// ⇧Tab / F: everything but the photo.
    @Published var immersive = false
    @Published var filmstrip: Bool {
        didSet { UserDefaults.standard.set(filmstrip, forKey: "filmstrip") }
    }
    @Published var zoom = ZoomState()
    @Published var compare: Compare = .off
    @Published var showOriginal = false
    /// Edits and star ratings by photo id, kept in Application Support.
    @Published var edits: [String: Adjustments] = [:] { didSet { scheduleStoreWrite() } }
    @Published var ratings: [String: Int] = [:] { didSet { scheduleStoreWrite() } }
    @Published var minRating = 0
    /// Saved files by name (the save folder and its date subfolders).
    @Published private(set) var localFiles: [String: URL] = [:]
    @Published var sort: Sort {
        didSet { UserDefaults.standard.set(sort.rawValue, forKey: "sort") }
    }
    @Published var groupByDate: Bool {
        didSet { UserDefaults.standard.set(groupByDate, forKey: "groupByDate") }
    }
    @Published var destination: URL {
        didSet {
            UserDefaults.standard.set(destination.path, forKey: "destination")
            refreshSaved()
        }
    }

    /// Save into <folder>/yyyy-MM-dd by shooting day.
    @Published var dateSubfolders: Bool {
        didSet { UserDefaults.standard.set(dateSubfolders, forKey: "dateSubfolders") }
    }
    /// Leave a file alone when one with the same name is already in the save folder.
    @Published var skipExisting: Bool {
        didSet { UserDefaults.standard.set(skipExisting, forKey: "skipExisting") }
    }
    @Published var revealAfterSave: Bool {
        didSet { UserDefaults.standard.set(revealAfterSave, forKey: "revealAfterSave") }
    }

    /// Settings → 사진 저장 → 자동 저장. All off/limited by default; see autoSaveIfWanted().
    enum AutoSave {
        static let enabled = "autoSave", jpeg = "autoSaveJPEG", raw = "autoSaveRAW", video = "autoSaveVideo"
        static let usb = "autoSaveUSB", wifi = "autoSaveWiFi"
        static let defaults: [String: Bool] = [enabled: false, jpeg: true, raw: true, video: false, usb: true, wifi: true]
        static func value(_ key: String) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? defaults[key]! }
    }

    /// Set on connecting: save new photos once their dates are known (for date folders).
    private var autoSaveOnLoad = false

    /// Called when a camera connects, before its library loads.
    func prepareAutoSave(viaUSB: Bool) {
        autoSaveOnLoad = AutoSave.value(AutoSave.enabled) && AutoSave.value(viaUSB ? AutoSave.usb : AutoSave.wifi)
    }

    /// Saves the photos not yet in the save folder, of the kinds chosen in Settings.
    /// Copies only; nothing on the camera changes.
    private func autoSaveIfWanted() {
        guard autoSaveOnLoad else { return }
        autoSaveOnLoad = false
        let kinds: Set<Photo.Kind> = Set([(Photo.Kind.jpeg, AutoSave.jpeg), (.raw, AutoSave.raw), (.video, AutoSave.video)]
            .filter { AutoSave.value($0.1) }.map(\.0))
        let queue = photos.filter { kinds.contains($0.kind) && !saved.contains($0.name) }
        DebugLog.write("auto-save: \(queue.count) new of \(photos.count)")
        save(queue)
    }

    static let defaultDestination = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/GR")

    private var transferTask: Task<Void, Never>?
    private var infoTask: Task<Void, Never>?
    private var storeWrite: Task<Void, Never>?

    init() {
        let stored = UserDefaults.standard.string(forKey: "destination")
        destination = stored.map { URL(fileURLWithPath: $0) } ?? Self.defaultDestination
        sort = UserDefaults.standard.string(forKey: "sort").flatMap(Sort.init) ?? .newest
        groupByDate = UserDefaults.standard.object(forKey: "groupByDate") as? Bool ?? true
        dateSubfolders = UserDefaults.standard.bool(forKey: "dateSubfolders")
        skipExisting = UserDefaults.standard.object(forKey: "skipExisting") as? Bool ?? true
        revealAfterSave = UserDefaults.standard.bool(forKey: "revealAfterSave")
        filmstrip = UserDefaults.standard.object(forKey: "filmstrip") as? Bool ?? true
        // The grid redraws as photos are read while a 촬영 통계 filter is on.
        statsChanges = stats.objectWillChange.sink { [weak self] _ in
            if self?.shotFilter != nil { self?.objectWillChange.send() }
        }
        infos = Self.readInfoCache()
        loadStore()
    }

    private struct Store: Codable {
        var edits: [String: Adjustments] = [:]
        var ratings: [String: Int] = [:]
    }

    static var storeURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GR Mac/library.json")
    }

    private func loadStore() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let store = try? JSONDecoder().decode(Store.self, from: data) else { return }
        edits = store.edits
        ratings = store.ratings
        storeWrite?.cancel()
    }

    /// Written half a second after the last change, so dragging a slider doesn't write on every step.
    private func scheduleStoreWrite() {
        storeWrite?.cancel()
        let store = Store(edits: edits, ratings: ratings)
        storeWrite = Task {
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
            try? FileManager.default.createDirectory(at: Self.storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(store).write(to: Self.storeURL, options: .atomic)
        }
    }

    func adjustments(_ photo: Photo) -> Adjustments { edits[photo.id] ?? Adjustments() }

    func setAdjustments(_ adj: Adjustments, for photo: Photo) {
        edits[photo.id] = adj.isDefault ? nil : adj
    }

    func rating(_ photo: Photo) -> Int { ratings[photo.id] ?? 0 }

    func setRating(_ value: Int, for photos: [Photo]) {
        for photo in photos { ratings[photo.id] = value == 0 ? nil : value }
    }

    func localURL(_ photo: Photo) -> URL? { localFiles[photo.name] }

    /// Plain click: only this photo. ⌘: add / remove. ⇧: range from the current photo.
    func click(_ photo: Photo, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.shift), let anchor = current,
           let a = visible.firstIndex(of: anchor), let b = visible.firstIndex(of: photo) {
            let range = visible[min(a, b)...max(a, b)].map(\.id)
            if modifiers.contains(.command) { selection.formUnion(range) } else { selection = Set(range) }
            return
        }
        if modifiers.contains(.command) {
            toggle(photo)
        } else {
            selection = [photo.id]
        }
        current = photo
    }

    func toggle(_ photo: Photo) {
        if selection.contains(photo.id) { selection.remove(photo.id) } else { selection.insert(photo.id) }
    }

    /// Moves `current` within the visible photos; returns false at either end.
    @discardableResult
    func step(_ delta: Int) -> Bool {
        let list = visible
        guard !list.isEmpty else { return false }
        guard let cur = current, let i = list.firstIndex(of: cur) else {
            current = list.first
            return true
        }
        let next = i + delta
        guard list.indices.contains(next) else { return false }
        current = list[next]
        zoom.reset()
        showOriginal = false
        return true
    }

    func open(_ photo: Photo, in mode: Mode) {
        current = photo
        zoom.reset()
        self.mode = mode
    }

    /// False until the user has confirmed or picked a save folder once.
    var hasChosenDestination: Bool { UserDefaults.standard.string(forKey: "destination") != nil }

    func count(_ filter: Filter) -> Int { photos.filter { matches($0, filter) }.count }

    private func matches(_ photo: Photo, _ filter: Filter) -> Bool {
        switch filter {
        case .all: return true
        case .jpeg: return photo.kind == .jpeg
        case .raw: return photo.kind == .raw
        case .video: return photo.kind == .video
        case .unsaved: return !saved.contains(photo.name)
        }
    }

    private func passesRating(_ photo: Photo) -> Bool { minRating == 0 || rating(photo) >= minRating }

    /// A RAW shot with a JPEG twin is counted by the JPEG, so it is looked up there.
    func shotRecord(_ photo: Photo) -> ShotRecord? {
        if let record = stats.records[photo.id] { return record }
        guard photo.kind == .raw else { return nil }
        let base = (photo.name as NSString).deletingPathExtension
        return ["JPG", "jpg"].lazy.compactMap { self.stats.records["\(photo.dir)/\(base).\($0)"] }.first
    }

    private func passesShot(_ photo: Photo) -> Bool {
        guard let f = shotFilter else { return true }
        let record = shotRecord(photo)
        if let field = f.field, record?.key(field) != f.value { return false }
        if let day = f.day {
            guard let date = record?.date ?? infos[photo.id]?.date,
                  Calendar.current.isDate(date, inSameDayAs: day) else { return false }
        }
        return true
    }

    var visible: [Photo] {
        // The camera lists files in shooting order.
        let filtered = photos.filter { matches($0, filter) && passesRating($0) && passesShot($0) }
        switch sort {
        case .newest: return filtered.reversed()
        case .oldest: return filtered
        case .name: return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    /// `visible` split by shooting day, in display order. Days not read yet go last.
    var sections: [DaySection] {
        let photos = visible
        guard groupByDate else { return [DaySection(id: "all", title: "", photos: photos)] }
        let calendar = Calendar.current
        var order: [String] = []
        var groups: [String: [Photo]] = [:]
        var titles: [String: String] = [:]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "yyyy년 M월 d일 (E)"
        for photo in photos {
            let key: String
            if let date = infos[photo.id]?.date {
                let day = calendar.startOfDay(for: date)
                key = "\(day.timeIntervalSince1970)"
                titles[key] = formatter.string(from: day)
            } else {
                key = "unknown"
                titles[key] = "날짜 확인 중"
            }
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(photo)
        }
        if let i = order.firstIndex(of: "unknown") { order.append(order.remove(at: i)) }
        return order.map { DaySection(id: $0, title: titles[$0] ?? "", photos: groups[$0] ?? []) }
    }

    var infoProgress: (done: Int, total: Int) {
        (photos.filter { infos[$0.id] != nil }.count, photos.count)
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            photos = try await CameraAPI.photos()
            error = nil
            refreshSaved()
            loadInfos()
        } catch {
            self.error = "사진 목록을 불러오지 못했습니다: \(error.localizedDescription)"
        }
    }

    /// One small request per photo, newest first, so the top of the grid fills in first.
    /// Shooting time and orientation don't change once a photo exists, so they're kept on
    /// disk; only photos not seen before are asked for, one small request each, newest first.
    private func loadInfos() {
        infoTask?.cancel()
        let pending = photos.reversed().filter { infos[$0.id] == nil }
        infoTask = Task { [weak self] in
            var sinceWrite = 0
            for photo in pending {
                if Task.isCancelled { break }
                guard let info = try? await CameraAPI.info(photo) else { continue }
                self?.infos[photo.id] = info
                sinceWrite += 1
                if sinceWrite >= 20 { self?.writeInfoCache(); sinceWrite = 0 }
            }
            self?.writeInfoCache()
            self?.autoSaveIfWanted()
            self?.refreshStats()
        }
    }

    /// Reads 촬영 통계 for new photos and records the card in its history, so shots deleted
    /// later still count. Runs after the dates, which videos need.
    func refreshStats() {
        stats.scan(photos, dates: infos.compactMapValues(\.date))
    }

    private static var infoCacheURL: URL {
        ImageCache.folder.appendingPathComponent("photo-info-\(CameraAPI.base.host ?? "camera").json")
    }

    private static func readInfoCache() -> [String: PhotoInfo] {
        guard let data = try? Data(contentsOf: infoCacheURL) else { return [:] }
        return (try? JSONDecoder().decode([String: PhotoInfo].self, from: data)) ?? [:]
    }

    private func writeInfoCache() {
        guard let data = try? JSONEncoder().encode(infos) else { return }
        try? FileManager.default.createDirectory(at: ImageCache.folder, withIntermediateDirectories: true)
        try? data.write(to: Self.infoCacheURL, options: .atomic)
    }

    /// Thumbnails, dates and downloaded movies kept in ~/Library/Caches/GR Mac.
    var cacheSize: Int64 {
        let files = FileManager.default.enumerator(at: ImageCache.folder, includingPropertiesForKeys: [.fileSizeKey])
        return (files?.allObjects as? [URL] ?? []).reduce(0) {
            $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    func clearCaches() {
        infoTask?.cancel()
        try? FileManager.default.removeItem(at: ImageCache.folder)
        ImageCache.shared.clear()
        MetadataCache.entries = [:]
        stats.clear()
        infos = [:]
        if !photos.isEmpty { loadInfos() }
    }

    /// File names in the save folder and its date subfolders (one level down).
    func refreshSaved() {
        let fm = FileManager.default
        var files: [String: URL] = [:]
        for name in (try? fm.contentsOfDirectory(atPath: destination.path)) ?? [] {
            let sub = destination.appendingPathComponent(name)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: sub.path, isDirectory: &isDir), isDir.boolValue {
                for inner in (try? fm.contentsOfDirectory(atPath: sub.path)) ?? [] where files[inner] == nil {
                    files[inner] = sub.appendingPathComponent(inner)
                }
            } else {
                files[name] = sub
            }
        }
        localFiles = files
        saved = Set(files.keys)
    }

    func selectAll() { selection = Set(visible.map(\.id)) }
    var allVisibleSelected: Bool { !visible.isEmpty && visible.allSatisfy { selection.contains($0.id) } }
    func toggleSection(_ photos: [Photo]) {
        let ids = Set(photos.map(\.id))
        if ids.isSubset(of: selection) { selection.subtract(ids) } else { selection.formUnion(ids) }
    }
    func selectUnsaved() { selection = Set(visible.filter { !saved.contains($0.name) }.map(\.id)) }
    func clearSelection() { selection = [] }

    func saveSelected() { requestSave(visible.filter { selection.contains($0.id) }) }

    /// Photos waiting for the first-time "where to save" question.
    @Published var pendingSave: [Photo]?

    func requestSave(_ photos: [Photo]) {
        if hasChosenDestination { save(photos) } else { pendingSave = photos }
    }

    func save(_ queue: [Photo]) {
        guard !queue.isEmpty, !isTransferring else { return }
        transfers = queue.map { Transfer(photo: $0) }
        isTransferring = true
        transferTask = Task { [weak self] in
            await self?.runTransfers()
        }
    }

    func cancelTransfers() {
        transferTask?.cancel()
    }

    func dismissTransfers() {
        guard !isTransferring else { return }
        transfers = []
    }

    private func runTransfers() async {
        var savedAny = false
        defer {
            isTransferring = false
            refreshSaved()
            if savedAny, revealAfterSave, !Task.isCancelled { NSWorkspace.shared.open(destination) }
        }
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for i in transfers.indices {
            if Task.isCancelled { break }
            let photo = transfers[i].photo
            if skipExisting, saved.contains(photo.name) {
                transfers[i].status = .done
                selection.remove(photo.id)
                continue
            }
            savedAny = true
            transfers[i].status = .running(0)
            do {
                try await download(photo) { [weak self] fraction in
                    self?.transfers[i].status = .running(fraction)
                }
                transfers[i].status = .done
                refreshSaved()
                selection.remove(photo.id)
            } catch {
                transfers[i].status = .failed(Task.isCancelled ? "취소됨" : error.localizedDescription)
            }
        }
    }

    private func folder(for photo: Photo) async -> URL {
        guard dateSubfolders else { return destination }
        var info = infos[photo.id]
        if info == nil { info = try? await CameraAPI.info(photo) }
        guard let date = info?.date else { return destination.appendingPathComponent("날짜 미상") }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return destination.appendingPathComponent(formatter.string(from: date))
    }

    private func download(_ photo: Photo, progress: @escaping (Double) -> Void) async throws {
        let folder = await folder(for: photo)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(photo.name)
        let (file, response) = try await Downloader.fetch(CameraAPI.photoURL(photo)) { fraction in
            Task { @MainActor in progress(fraction) }
        }
        defer { try? FileManager.default.removeItem(at: file) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw CameraAPI.APIError(message: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
        if response.expectedContentLength > 0, size != response.expectedContentLength {
            throw CameraAPI.APIError(message: "크기 불일치 (\(size)/\(response.expectedContentLength))")
        }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: file, to: target)
        progress(1)
    }
}

/// URLSession download task with progress and cancellation, off the main thread.
enum Downloader {
    private final class Box: @unchecked Sendable {
        var task: URLSessionDownloadTask?
        var observation: NSKeyValueObservation?
    }

    static func fetch(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> (URL, URLResponse) {
        let box = Box()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = CameraAPI.session.downloadTask(with: url) { tmp, response, error in
                    box.observation = nil
                    guard let tmp, let response else {
                        continuation.resume(throwing: error ?? URLError(.unknown))
                        return
                    }
                    // The system deletes tmp when this handler returns.
                    let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    do {
                        try FileManager.default.moveItem(at: tmp, to: kept)
                        continuation.resume(returning: (kept, response))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                box.observation = task.progress.observe(\.fractionCompleted) { p, _ in progress(p.fractionCompleted) }
                box.task = task
                task.resume()
            }
        } onCancel: {
            box.task?.cancel()
        }
    }
}

/// Thumbnail / preview cache. The camera serves 160×120 thumbs and 720×480 / 1920×1280 previews.
/// Each image is downloaded once and rotated locally for each orientation; thumbnails are
/// also kept on disk, so reopening the library doesn't ask the camera for them again.
@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private let originals = NSCache<NSString, NSImage>()
    private let oriented = NSCache<NSString, NSImage>()
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]

    static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("GR Mac", isDirectory: true)
    }

    func image(for url: URL, orientation: Int = 1) async -> NSImage? {
        let key = "\(url.absoluteString)#\(orientation)" as NSString
        if let hit = oriented.object(forKey: key) { return hit }
        guard let image = await original(url) else { return nil }
        let result = image.upright(orientation)
        oriented.setObject(result, forKey: key)
        return result
    }

    func clear() {
        originals.removeAllObjects()
        oriented.removeAllObjects()
    }

    private func original(_ url: URL) async -> NSImage? {
        let key = url.absoluteString as NSString
        if let hit = originals.object(forKey: key) { return hit }
        if let running = inFlight[url] { return await running.value }
        let task = Task { () -> NSImage? in
            let disk = Self.diskURL(url)
            if let disk, let data = try? Data(contentsOf: disk), let image = NSImage(data: data) { return image }
            guard let (data, response) = try? await CameraAPI.session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = NSImage(data: data) else { return nil }
            if let disk {
                try? FileManager.default.createDirectory(at: disk.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: disk, options: .atomic)
            }
            return image
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { originals.setObject(image, forKey: key) }
        return image
    }

    /// Only thumbnails go to disk (a few KB each); previews stay in memory.
    private static func diskURL(_ url: URL) -> URL? {
        guard url.query?.contains("size=thumb") == true else { return nil }
        let parts = url.pathComponents.suffix(2).joined(separator: "_")
        return folder.appendingPathComponent("thumbs/\(url.host ?? "camera")/\(parts).jpg")
    }
}

extension NSImage {
    /// Rotate by an EXIF orientation. A portrait orientation on an image that is already
    /// taller than wide is left alone, in case the decoder applied it.
    func upright(_ orientation: Int) -> NSImage {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return self }
        let degrees: CGFloat
        switch orientation {
        case 3: degrees = 180
        case 6: degrees = -90
        case 8: degrees = 90
        default: return self
        }
        if degrees != 180, cg.height > cg.width { return self }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let size = degrees == 180 ? CGSize(width: w, height: h) : CGSize(width: h, height: w)
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return self }
        ctx.translateBy(x: size.width / 2, y: size.height / 2)
        ctx.rotate(by: degrees * .pi / 180)
        ctx.draw(cg, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        guard let rotated = ctx.makeImage() else { return self }
        return NSImage(cgImage: rotated, size: size)
    }
}
