import Combine
import SwiftUI
#if os(macOS)
import AppKit
#endif
import Foundation

@MainActor
final class LibraryModel: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "전체", jpeg = "JPG", raw = "RAW", video = "영상", unsaved = "미저장"
        var id: String { rawValue }
    }

    /// The iPhone/iPad filter sheet: file type, saved or not, shooting days. Applied on top
    /// of `filter` (the Mac's picker), which the iPhone leaves at 전체.
    struct Refine: Equatable {
        enum Saved: String, CaseIterable { case all = "모두", unsaved = "미저장", saved = "저장됨" }
        var kind: Photo.Kind?
        var saved: Saved = .all
        /// Whole days, inclusive.
        var from: Date?
        var to: Date?
        /// Image control by maker-note code (MakerNote.imageToneNames).
        var tone: Int?
        var isActive: Bool { self != Refine() }
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

    @Published private(set) var photos: [Photo] = [] {
        didSet { indexRawPartners() }
    }
    /// DNGs by folder and name without extension, to find a JPEG's RAW partner.
    private var rawPartners: [String: Photo] = [:]
    /// Also called from init, where didSet doesn't run (the offline list is loaded there).
    private func indexRawPartners() {
        rawPartners = Dictionary(photos.filter { $0.kind == .raw }.map { (Self.pairKey($0), $0) },
                                 uniquingKeysWith: { first, _ in first })
    }
    private nonisolated static func pairKey(_ photo: Photo) -> String {
        "\(photo.dir)/\((photo.name as NSString).deletingPathExtension.uppercased())"
    }

    /// The grid thumbnail for a photo. The camera's thumb for a DNG is its embedded preview,
    /// much larger than the 160 px thumb it gives for a JPEG (seen on GR IV HDF fw 1.20), and
    /// RAW+JPEG pairs are the same shot, so a JPEG with a DNG partner shows the DNG's thumb.
    ///
    /// 설정 → 선명한 썸네일 (iPhone/iPad, off by default): a JPEG without a DNG uses the
    /// camera's 720 px preview instead, kept on disk (~55 KB each) so it stays sharp offline.
    /// Until that preview is on disk, an offline library falls back to the small thumb.
    /// JPEGs on the card without a DNG partner: the photos 선명한 썸네일 changes.
    var jpegOnlyCount: Int {
        photos.filter { $0.kind == .jpeg && rawPartners[Self.pairKey($0)] == nil }.count
    }

    func thumbURL(_ photo: Photo) -> URL {
        if photo.kind == .jpeg, let raw = rawPartners[Self.pairKey(photo)] {
            return CameraAPI.photoURL(raw, size: .thumb)
        }
        if photo.kind == .jpeg, ImageCache.sharpThumbnails {
            let preview = CameraAPI.photoURL(photo, size: .view)
            if CameraAPI.online || ImageCache.hasThumbnail(preview) { return preview }
        }
        return CameraAPI.photoURL(photo, size: .thumb)
    }
    /// When `photos` was last read from the camera; shown while offline.
    @Published private(set) var listSavedAt: Date?
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
    @Published var refine = Refine() {
        // Hidden photos leave the selection, so the count and 저장 match what is shown.
        didSet { selection.formIntersection(visible.map(\.id)) }
    }
    /// Saved files by name (the save folder and its date subfolders).
    @Published private(set) var localFiles: [String: URL] = [:]
    /// EXIF orientation of saved files, by file name.
    @Published private(set) var localOrientation: [String: Int] = [:]
    @Published var sort: Sort {
        didSet { UserDefaults.standard.set(sort.rawValue, forKey: "sort") }
    }
    @Published var groupByDate: Bool {
        didSet { UserDefaults.standard.set(groupByDate, forKey: "groupByDate") }
    }
    @Published var destination: URL {
        didSet {
            UserDefaults.standard.set(destination.path, forKey: "destination")
            FolderAccess.remember(destination)
            refreshSaved()
        }
    }

    /// Save into <folder>/yyyy-MM-dd by shooting day.
    @Published var dateSubfolders: Bool {
        didSet { UserDefaults.standard.set(dateSubfolders, forKey: "dateSubfolders") }
    }
    /// Leave a file alone when one with the same name is already in the save folder.
    /// iPhone/iPad always skip photos already saved (no setting there: saving one again
    /// would only add a duplicate to the Photos app). The Mac keeps its 설정 toggle.
    private var skipsSaved: Bool {
        #if os(iOS)
        true
        #else
        skipExisting
        #endif
    }
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

    /// ~/Pictures/GR in the user's real home; inside the sandbox homeDirectoryForCurrentUser
    /// is the app's container, and the Pictures entitlement covers the real folder.
    #if os(macOS)
    static let defaultDestination = FolderAccess.realHome.appendingPathComponent("Pictures/GR")
    #else
    static let defaultDestination = URL.documentsDirectory
    #endif

    private var transferTask: Task<Void, Never>?
    private var infoTask: Task<Void, Never>?
    private var storeWrite: Task<Void, Never>?

    init() {
        let stored = UserDefaults.standard.string(forKey: "destination")
        destination = FolderAccess.restore() ?? stored.map { URL(fileURLWithPath: $0) } ?? Self.defaultDestination
        sort = UserDefaults.standard.string(forKey: "sort").flatMap(Sort.init) ?? .newest
        groupByDate = UserDefaults.standard.object(forKey: "groupByDate") as? Bool ?? true
        dateSubfolders = UserDefaults.standard.bool(forKey: "dateSubfolders")
        skipExisting = UserDefaults.standard.object(forKey: "skipExisting") as? Bool ?? true
        revealAfterSave = UserDefaults.standard.bool(forKey: "revealAfterSave")
        filmstrip = UserDefaults.standard.object(forKey: "filmstrip") as? Bool ?? true
        // The grid redraws as photos are read while a 촬영 통계 filter is on.
        statsChanges = stats.objectWillChange.sink { [weak self] _ in
            if self?.shotFilter != nil || self?.refine.tone != nil { self?.objectWillChange.send() }
        }
        CardCache.migrate()
        infos = Self.readInfoCache()
        if let saved = CardCache.readList() {
            photos = saved.photos
            indexRawPartners()
            listSavedAt = saved.savedAt
            refreshSaved()
        }
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

    /// Turns photos a quarter at a time from the grid or loupe (⌘R / ⌥⌘R), without opening
    /// 편집. Kept with the edits; written into the file's orientation when a camera photo is
    /// saved (see download). Positive is clockwise.
    func rotate(_ photos: [Photo], by turns: Int) {
        for photo in photos where photo.kind != .video {
            var adj = adjustments(photo)
            adj.quarterTurns = ((adj.quarterTurns + turns) % 4 + 4) % 4
            adj.crop = nil
            setAdjustments(adj, for: photo)
        }
    }

    /// EXIF orientation to show the camera's thumbnails and previews with: the saved file's
    /// when there is one (it carries rotations made here or in other apps), else the camera's.
    func orientation(_ photo: Photo) -> Int {
        localOrientation[photo.name] ?? infos[photo.id]?.orientation ?? 1
    }

    /// Upright on screen taller than wide, counting a quarter turn made here.
    func isPortrait(_ photo: Photo) -> Bool {
        [5, 6, 7, 8].contains(orientation(photo)) != (adjustments(photo).quarterTurns % 2 != 0)
    }

    func rating(_ photo: Photo) -> Int { ratings[photo.id] ?? 0 }

    func setRating(_ value: Int, for photos: [Photo]) {
        for photo in photos { ratings[photo.id] = value == 0 ? nil : value }
    }

    func localURL(_ photo: Photo) -> URL? { localFiles[photo.name] }

    /// Plain click: only this photo. ⌘: add / remove. ⇧: range from the current photo.
    func click(_ photo: Photo, command: Bool = false, shift: Bool = false) {
        if shift, let anchor = current,
           let a = visible.firstIndex(of: anchor), let b = visible.firstIndex(of: photo) {
            let range = visible[min(a, b)...max(a, b)].map(\.id)
            if command { selection.formUnion(range) } else { selection = Set(range) }
            return
        }
        if command {
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

    func passes(_ photo: Photo, _ r: Refine) -> Bool {
        if let kind = r.kind, photo.kind != kind { return false }
        switch r.saved {
        case .all: break
        case .unsaved: if saved.contains(photo.name) { return false }
        case .saved: if !saved.contains(photo.name) { return false }
        }
        if r.from != nil || r.to != nil {
            guard let date = shootingDate(photo) else { return false }
            let calendar = Calendar.current
            if let from = r.from, date < calendar.startOfDay(for: from) { return false }
            if let to = r.to, let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: to)),
               date >= end { return false }
        }
        if let tone = r.tone, shotRecord(photo)?.imageTone != tone { return false }
        return true
    }

    /// Image controls on the card, by code: how many shots and the newest one, for the
    /// 이미지 컨트롤 view and the filter sheet. A RAW+JPEG pair counts once.
    struct ToneGroup: Identifiable {
        let code: Int
        let count: Int
        let latest: Photo
        var id: Int { code }
        var name: String { MakerNote.imageToneNames[code] ?? "알 수 없음 (\(code))" }
    }

    var toneGroups: [ToneGroup] {
        var counts: [Int: Int] = [:], latest: [Int: Photo] = [:]
        // The camera lists files in shooting order, so the last one seen is the newest.
        for photo in ShotStats.shots(photos) {
            guard let code = shotRecord(photo)?.imageTone else { continue }
            counts[code, default: 0] += 1
            latest[code] = photo
        }
        return counts.keys.sorted { counts[$0]! > counts[$1]! }
            .map { ToneGroup(code: $0, count: counts[$0]!, latest: latest[$0]!) }
    }

    /// What the filter sheet would show, before it is applied.
    func count(_ r: Refine) -> Int {
        photos.filter { matches($0, filter) && passesRating($0) && passesShot($0) && passes($0, r) }.count
    }

    func shootingDate(_ photo: Photo) -> Date? { infos[photo.id]?.date ?? shotRecord(photo)?.date }

    /// First and last shooting day on the card, for the date pickers.
    var dateRange: ClosedRange<Date>? {
        let dates = photos.compactMap { shootingDate($0) }
        guard let first = dates.min(), let last = dates.max() else { return nil }
        return first...last
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
        let filtered = photos.filter { matches($0, filter) && passesRating($0) && passesShot($0) && passes($0, refine) }
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
        // Connecting starts one and the library view another; the second would only repeat it.
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let list = try await CameraAPI.photos()
            if await cardChanged(list) { clearCaches() }
            photos = list
            listSavedAt = .now
            CardCache.writeList(list)
            CardCache.prune(keeping: list.compactMap { ImageCache.diskURL(thumbURL($0))?.lastPathComponent })
            let ids = Set(list.map(\.id))
            infos = infos.filter { ids.contains($0.key) }
            error = nil
            refreshSaved()
            loadInfos()
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
            // A pull-to-refresh that iOS called off; nothing went wrong with the camera.
        } catch {
            self.error = "사진 목록을 불러오지 못했어요: \(error.localizedDescription)"
        }
    }

    /// After a shot: the camera needs a moment to write the file before it is listed, and a
    /// reload already running would make this one a no-op, so wait for both.
    func reloadAfterShot() async {
        for _ in 0..<20 where isLoading { try? await Task.sleep(for: .milliseconds(250)) }
        try? await Task.sleep(for: .seconds(1.5))
        await reload()
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
            await self?.prefetchThumbnails()
        }
    }

    /// Every thumbnail, not only the ones scrolled to, so the whole card can be browsed
    /// later without the camera. A few KB each; ones already on disk are skipped.
    private func prefetchThumbnails() async {
        for photo in photos.reversed() where !ImageCache.hasThumbnail(thumbURL(photo)) {
            if Task.isCancelled || !CameraAPI.online { return }
            _ = await ImageCache.shared.image(for: thumbURL(photo))
        }
    }

    /// Reads 촬영 통계 for new photos and records the card in its history, so shots deleted
    /// later still count. Runs after the dates, which videos need.
    func refreshStats() {
        stats.scan(photos, dates: infos.compactMapValues(\.date))
    }

    private static var infoCacheURL: URL { ImageCache.folder.appendingPathComponent("photo-info.json") }

    private static func readInfoCache() -> [String: PhotoInfo] {
        guard let data = try? Data(contentsOf: infoCacheURL) else { return [:] }
        return (try? JSONDecoder().decode([String: PhotoInfo].self, from: data)) ?? [:]
    }

    private func writeInfoCache() {
        guard let data = try? JSONEncoder().encode(infos) else { return }
        try? FileManager.default.createDirectory(at: ImageCache.folder, withIntermediateDirectories: true)
        try? data.write(to: Self.infoCacheURL, options: .atomic)
    }

    /// The photo list, thumbnails, dates and downloaded movies kept in ~/Library/Caches/GR Mac.
    var cacheSize: Int64 {
        let files = FileManager.default.enumerator(at: ImageCache.folder, includingPropertiesForKeys: [.fileSizeKey])
        return (files?.allObjects as? [URL] ?? []).reduce(0) {
            $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// The caches (dates, thumbnails, 촬영 통계) are keyed by file name, and names come back
    /// after a card format, or for the next shot after deleting the last one. The newest file
    /// is the one a reused name would land on, so ask the camera for its shooting time and
    /// compare. Costs one small request per reload.
    private func cardChanged(_ list: [Photo]) async -> Bool {
        // The camera lists files in shooting order.
        guard let probe = list.last(where: { infos[$0.id]?.date != nil }),
              let cached = infos[probe.id]?.date,
              let fresh = try? await CameraAPI.info(probe).date,
              !Self.sameMoment(cached, fresh) else { return false }
        DebugLog.write("cache: \(probe.id) was shot \(cached), now \(fresh); file names were reused, clearing caches")
        return true
    }

    /// USB (macOS's Image Capture) and Wi-Fi (the camera) both feed one cache, and USB can
    /// report a shot a second later than its EXIF time (R0000550.DNG: 20:33:40 over USB,
    /// 20:33:39 in the file). A name reused after a format won't land within seconds.
    private static func sameMoment(_ a: Date, _ b: Date) -> Bool {
        abs(a.timeIntervalSince(b)) < 3
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
        Task {
            let read = await Task.detached(priority: .utility) {
                files.compactMapValues { url -> Int? in
                    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                          let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
                    return p[kCGImagePropertyOrientation] as? Int
                }
            }.value
            if read != localOrientation { localOrientation = read }
        }
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
        guard CameraAPI.online else {
            error = "카메라에 연결하면 저장할 수 있어요."
            return
        }
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
            #if os(macOS)
            if savedAny, revealAfterSave, !Task.isCancelled { NSWorkspace.shared.open(destination) }
            #endif
        }
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        #if os(iOS)
        var waiting: [String: (file: URL, index: Int, kind: Photo.Kind)] = [:]
        #endif
        for i in transfers.indices {
            if Task.isCancelled { break }
            let photo = transfers[i].photo
            if skipsSaved, saved.contains(photo.name) {
                transfers[i].status = .done
                selection.remove(photo.id)
                continue
            }
            savedAny = true
            transfers[i].status = .running(0)
            do {
                let file = try await download(photo) { [weak self] fraction in
                    self?.transfers[i].status = .running(fraction)
                }
                transfers[i].status = .done
                #if os(iOS)
                await addToPhotos(photo, file: file, index: i, later: transfers[(i + 1)...], waiting: &waiting)
                #else
                _ = file
                #endif
                refreshSaved()
                selection.remove(photo.id)
            } catch {
                transfers[i].status = .failed(Task.isCancelled ? "취소됨" : error.localizedDescription)
            }
        }
        #if os(iOS)
        await flushPhotos(waiting)
        #endif
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

    /// Returns the saved file.
    @discardableResult
    private func download(_ photo: Photo, progress: @escaping (Double) -> Void) async throws -> URL {
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
        // A rotation made in the library goes into the saved JPEG's orientation tag; the image
        // data is copied as is, so nothing is recompressed. The edit is then dropped, since
        // the file itself now shows the photo upright.
        let adj = adjustments(photo)
        let rotate = photo.kind == .jpeg && (adj.quarterTurns % 4 != 0 || adj.flipped)
        if rotate {
            let current = infos[photo.id]?.orientation ?? 1
            try Self.writeOrientation(Self.orientation(current, turns: adj.quarterTurns, flipped: adj.flipped), of: file)
        }
        try FileManager.default.moveItem(at: file, to: target)
        if rotate {
            var rest = adjustments(photo)
            rest.quarterTurns = 0
            rest.flipped = false
            setAdjustments(rest, for: photo)
        }
        progress(1)
        return target
    }

    #if os(iOS)
    /// Adds a downloaded file to the Photos app. With 설정 → RAW+JPEG 한 항목 on, a JPEG or DNG
    /// waits for its partner (same name, also in this batch) and the two go in as one item;
    /// a partner that never arrives (skipped, failed, cancelled) is added alone by flushPhotos.
    private func addToPhotos(_ photo: Photo, file: URL, index: Int, later: ArraySlice<Transfer>,
                             waiting: inout [String: (file: URL, index: Int, kind: Photo.Kind)]) async {
        let base = ((photo.name as NSString).deletingPathExtension).uppercased()
        let pairable = PhotosLibrary.pairRAW && (photo.kind == .jpeg || photo.kind == .raw)
        do {
            if pairable, let partner = waiting[base], partner.kind != photo.kind {
                waiting[base] = nil
                let (jpeg, raw) = photo.kind == .jpeg ? (file, partner.file) : (partner.file, file)
                do {
                    try await PhotosLibrary.addPair(jpeg: jpeg, raw: raw)
                } catch {
                    transfers[partner.index].status = .failed(error.localizedDescription)
                    throw error
                }
            } else if pairable, later.contains(where: { other in
                other.photo.kind != photo.kind && (other.photo.kind == .jpeg || other.photo.kind == .raw)
                    && ((other.photo.name as NSString).deletingPathExtension).uppercased() == base
            }) {
                waiting[base] = (file, index, photo.kind)
            } else {
                try await PhotosLibrary.add(file, isVideo: photo.kind == .video)
            }
        } catch {
            transfers[index].status = .failed(error.localizedDescription)
        }
    }

    private func flushPhotos(_ waiting: [String: (file: URL, index: Int, kind: Photo.Kind)]) async {
        for item in waiting.values {
            do {
                try await PhotosLibrary.add(item.file, isVideo: false)
            } catch {
                transfers[item.index].status = .failed(error.localizedDescription)
            }
        }
    }
    #endif

    /// EXIF orientation after turning an image `turns` quarters clockwise, then mirroring it
    /// left to right, as DevelopEngine.geometry does. Orientations as 2×2 maps from stored to
    /// shown pixels (y down).
    nonisolated static func orientation(_ exif: Int, turns: Int, flipped: Bool) -> Int {
        let maps: [Int: [Int]] = [1: [1, 0, 0, 1], 2: [-1, 0, 0, 1], 3: [-1, 0, 0, -1], 4: [1, 0, 0, -1],
                                  5: [0, 1, 1, 0], 6: [0, -1, 1, 0], 7: [0, -1, -1, 0], 8: [0, 1, -1, 0]]
        func times(_ a: [Int], _ b: [Int]) -> [Int] {
            [a[0] * b[0] + a[1] * b[2], a[0] * b[1] + a[1] * b[3], a[2] * b[0] + a[3] * b[2], a[2] * b[1] + a[3] * b[3]]
        }
        var m = maps[exif] ?? maps[1]!
        for _ in 0..<(((turns % 4) + 4) % 4) { m = times(maps[6]!, m) }
        if flipped { m = times(maps[2]!, m) }
        return maps.first { $0.value == m }?.key ?? 1
    }

    /// Changes only the orientation value: the two bytes of tag 0x0112 in the JPEG's EXIF are
    /// patched in place, so the image data, maker note and Ricoh's APP7 segment stay as the
    /// camera wrote them. (ImageIO's lossless copy drops APP7.) Falls back to that copy only
    /// when the file has no orientation tag.
    nonisolated static func writeOrientation(_ value: Int, of url: URL) throws {
        let failed = CameraAPI.APIError(message: "사진 방향을 저장하지 못했어요")
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let head = [UInt8](try handle.read(upToCount: 128 * 1024) ?? Data())
        if let offset = orientationOffset(head) {
            try handle.seek(toOffset: UInt64(offset.position))
            let v = UInt16(value)
            try handle.write(contentsOf: offset.littleEndian ? [UInt8(v & 0xFF), UInt8(v >> 8)] : [UInt8(v >> 8), UInt8(v & 0xFF)])
            return
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src) else { throw failed }
        let out = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil) else { throw failed }
        let options: [CFString: Any] = [kCGImageDestinationMergeMetadata: true, kCGImageDestinationOrientation: value]
        guard CGImageDestinationCopyImageSource(dest, src, options as CFDictionary, nil) else {
            try? FileManager.default.removeItem(at: out)
            throw failed
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: out)
    }

    /// Where IFD0's Orientation (0x0112, SHORT) value sits in a JPEG's Exif segment.
    nonisolated static func orientationOffset(_ b: [UInt8]) -> (position: Int, littleEndian: Bool)? {
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var i = 2
        while i + 10 < b.count, b[i] == 0xFF {
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            if b[i + 1] == 0xE1, b[(i + 4)..<(i + 10)].elementsEqual(Array("Exif\0\0".utf8)) {
                let t = i + 10
                guard t + 8 <= b.count else { return nil }
                let le = b[t] == 0x49
                func u16(_ p: Int) -> Int { le ? Int(b[p]) | Int(b[p + 1]) << 8 : Int(b[p]) << 8 | Int(b[p + 1]) }
                func u32(_ p: Int) -> Int { le ? u16(p) | u16(p + 2) << 16 : u16(p) << 16 | u16(p + 2) }
                let ifd = t + u32(t + 4)
                guard ifd + 2 <= b.count else { return nil }
                for k in 0..<u16(ifd) {
                    let e = ifd + 2 + k * 12
                    guard e + 12 <= b.count else { return nil }
                    if u16(e) == 0x0112, u16(e + 2) == 3 { return (e + 8, le) }
                }
                return nil
            }
            i += 2 + length
        }
        return nil
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
    /// Bounded by decoded size: 720 px thumbs (DNGs', or 선명한 썸네일) are ~1.4 MB each in
    /// memory, so a scrolled-through card would otherwise grow without limit.
    private let originals: NSCache<NSString, PlatformImage> = {
        let cache = NSCache<NSString, PlatformImage>()
        cache.totalCostLimit = 200 << 20
        return cache
    }()
    private let oriented: NSCache<NSString, PlatformImage> = {
        let cache = NSCache<NSString, PlatformImage>()
        cache.totalCostLimit = 200 << 20
        return cache
    }()
    private static func cost(_ image: PlatformImage) -> Int {
        image.cgImageValue.map { $0.bytesPerRow * $0.height } ?? 0
    }
    private var inFlight: [URL: Task<PlatformImage?, Never>] = [:]

    static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("GR Mac", isDirectory: true)
    }

    func image(for url: URL, orientation: Int = 1) async -> PlatformImage? {
        let key = "\(url.absoluteString)#\(orientation)" as NSString
        if let hit = oriented.object(forKey: key) { return hit }
        guard let image = await original(url) else { return nil }
        let result = image.upright(orientation)
        oriented.setObject(result, forKey: key, cost: Self.cost(result))
        return result
    }

    func clear() {
        originals.removeAllObjects()
        oriented.removeAllObjects()
    }

    private func original(_ url: URL) async -> PlatformImage? {
        let key = url.absoluteString as NSString
        if let hit = originals.object(forKey: key) { return hit }
        if let running = inFlight[url] { return await running.value }
        let task = Task { () -> PlatformImage? in
            let disk = Self.diskURL(url)
            if let disk, let data = try? Data(contentsOf: disk), let image = PlatformImage(data: data) { return image }
            guard CameraAPI.online else { return nil }
            guard let (data, response) = try? await CameraAPI.session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = PlatformImage(data: data) else { return nil }
            if let disk {
                try? FileManager.default.createDirectory(at: disk.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: disk, options: .atomic)
            }
            return image
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { originals.setObject(image, forKey: key, cost: Self.cost(image)) }
        return image
    }

    static func hasThumbnail(_ url: URL) -> Bool {
        diskURL(url).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    static let sharpThumbnailsKey = "sharpThumbnails"
    /// iPhone/iPad only: over USB the Mac would build each preview from the whole original.
    static var sharpThumbnails: Bool {
        #if os(iOS)
        UserDefaults.standard.bool(forKey: sharpThumbnailsKey)
        #else
        false
        #endif
    }

    /// Thumbnails go to disk (a few KB each, 55 KB for a DNG's); previews stay in memory,
    /// except a JPEG's 720 px preview while 선명한 썸네일 is on (it is then its thumbnail).
    static func diskURL(_ url: URL) -> URL? {
        let parts = url.pathComponents.suffix(2).joined(separator: "_")
        if url.query?.contains("size=thumb") == true {
            return CardCache.thumbs.appendingPathComponent("\(parts).jpg")
        }
        if sharpThumbnails, url.query?.contains("size=view") == true, url.pathExtension.uppercased() == "JPG" {
            return CardCache.thumbs.appendingPathComponent("\(parts).view.jpg")
        }
        return nil
    }
}

extension PlatformImage {
    /// Rotate by an EXIF orientation. A portrait orientation on an image that is already
    /// taller than wide is left alone, in case the decoder applied it.
    func upright(_ orientation: Int) -> PlatformImage {
        guard let cg = cgImageValue else { return self }
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
        return PlatformImage(cgImageValue: rotated)
    }
}

#if os(macOS)
/// Keeps the sandboxed app's access to a save folder the user picked, across launches,
/// with a security-scoped bookmark. ~/Pictures needs none (it has its own entitlement).
enum FolderAccess {
    static var realHome: URL {
        guard let home = getpwuid(getuid())?.pointee.pw_dir else { return FileManager.default.homeDirectoryForCurrentUser }
        return URL(fileURLWithPath: String(cString: home), isDirectory: true)
    }

    private static var accessed: URL?

    static func remember(_ folder: URL) {
        guard folder != accessed else { return }
        let data = try? folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: "destinationBookmark")
        start(folder)
    }

    static func restore() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: "destinationBookmark") else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale) else { return nil }
        start(url)
        if stale { remember(url) }
        return url
    }

    private static func start(_ folder: URL) {
        accessed?.stopAccessingSecurityScopedResource()
        accessed = folder.startAccessingSecurityScopedResource() ? folder : nil
    }
}
#else
/// iOS: photos go to the app's Documents folder (shown in the Files app) and the Photos app.
enum FolderAccess {
    static var realHome: URL { URL.documentsDirectory.deletingLastPathComponent() }
    static func remember(_ folder: URL) {}
    static func restore() -> URL? { nil }
}
#endif

/// What the library keeps of the last card so it can be browsed without the camera: the
/// photo list, plus the thumbnails, dates and 촬영 통계 kept next to it. One set, shared by
/// Wi-Fi and USB (it used to be one per camera address).
@MainActor
enum CardCache {
    private static var listURL: URL { ImageCache.folder.appendingPathComponent("photo-list.json") }
    static var thumbs: URL { ImageCache.folder.appendingPathComponent("thumbs", isDirectory: true) }

    private struct SavedList: Codable {
        let savedAt: Date
        let photos: [Photo]
    }

    static func readList() -> (savedAt: Date, photos: [Photo])? {
        guard let data = try? Data(contentsOf: listURL),
              let list = try? JSONDecoder().decode(SavedList.self, from: data) else { return nil }
        return (list.savedAt, list.photos)
    }

    static func writeList(_ photos: [Photo]) {
        guard let data = try? JSONEncoder().encode(SavedList(savedAt: .now, photos: photos)) else { return }
        try? FileManager.default.createDirectory(at: ImageCache.folder, withIntermediateDirectories: true)
        try? data.write(to: listURL, options: .atomic)
    }

    /// Thumbnails of photos no longer on the card.
    /// Also drops a JPEG's own thumb once it uses its DNG's, and previews kept for 선명한
    /// 썸네일 after that setting is turned off.
    static func prune(keeping names: [String]) {
        let keep = Set(names)
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: thumbs.path)) ?? [] where !keep.contains(name) {
            try? fm.removeItem(at: thumbs.appendingPathComponent(name))
        }
    }

    /// Earlier builds kept these per camera address (192.168.0.1 for Wi-Fi, 127.0.0.1 for
    /// USB). Merge them into the shared set, Wi-Fi's first, once.
    static func migrate() {
        let fm = FileManager.default
        let folder = ImageCache.folder
        let hosts = ["192.168.0.1", "127.0.0.1"]
        for name in ["photo-info", "shot-stats"] {
            let target = folder.appendingPathComponent("\(name).json")
            for host in hosts {
                let old = folder.appendingPathComponent("\(name)-\(host).json")
                guard fm.fileExists(atPath: old.path) else { continue }
                if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: old) } else { try? fm.moveItem(at: old, to: target) }
            }
        }
        for host in hosts {
            let old = thumbs.appendingPathComponent(host, isDirectory: true)
            guard let names = try? fm.contentsOfDirectory(atPath: old.path) else { continue }
            for name in names where !fm.fileExists(atPath: thumbs.appendingPathComponent(name).path) {
                try? fm.moveItem(at: old.appendingPathComponent(name), to: thumbs.appendingPathComponent(name))
            }
            try? fm.removeItem(at: old)
        }
    }
}
