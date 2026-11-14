import Foundation
import ImageIO
import Photos

/// Every save, kept in Application Support: what was saved, when, into which Photos item
/// and/or file, and what was skipped or failed. With read access to the Photos library it
/// also knows which saved photos were deleted there since, so they are offered again
/// instead of being skipped as already saved.
@MainActor
final class SaveHistory: NSObject, ObservableObject {
    static let shared = SaveHistory()

    struct Record: Codable, Identifiable, Hashable {
        enum Outcome: String, Codable {
            case saved
            /// Was gone from the Photos app; put back from the copy in the Files app.
            case resaved
            /// Already there, so left alone.
            case skipped
            case failed
        }
        var id = UUID()
        /// One save (one tap of 저장, or one auto-save).
        var session: UUID
        var date: Date
        var photo: Photo
        var outcome: Outcome
        var message: String?
        var bytes: Int64?
        /// The Photos item made from it.
        var assetID: String?
        /// The copy in the Files app, relative to Documents.
        var file: String?
        /// The library could be read when it was saved, so the item is known to be visible
        /// to the app: not finding it later means it was deleted.
        var checkable = false
        /// When the photo was taken, as the camera said. A file name alone can belong to
        /// another photo after the memory card changes.
        var shotAt: Date?

        var name: String { photo.name }
        var isSave: Bool { outcome == .saved || outcome == .resaved }
        var fileURL: URL? { file.map { URL.documentsDirectory.appendingPathComponent($0) } }
    }

    /// Where a saved photo stands in the Photos app.
    enum PhotosState: Equatable {
        case inPhotos
        /// Saved there once, not there now.
        case deleted
        /// Saved there, but the app can't look (no read access).
        case unknown
        /// Never saved there, as far as the app knows.
        case none
    }

    @Published private(set) var records: [Record] = []
    /// Photos items that still exist; nil when the library can't be read.
    @Published private(set) var present: Set<String>?
    @Published private(set) var readStatus = PhotosLibrary.readStatus
    /// Files saved before the app kept records, looked up in Photos once by time and name:
    /// the item found, or "" for none. Only filled with full access.
    private var legacy: [String: String] = [:]
    /// Photos saved before records were kept, taken off the 다운로드 기록 list by the user.
    @Published private(set) var hidden = Set<String>()
    /// The newest save of each file name.
    private var latestSave: [String: Record] = [:]
    private var checkingLegacy = false
    /// Looked up this run without a result, so not tried again until the next launch.
    private var tried = Set<String>()
    private var observing = false
    /// Called when what's saved may have changed (a deletion in Photos, a lookup finished).
    var onChange: (() -> Void)?

    private struct Store: Codable {
        var records: [Record] = []
        var legacy: [String: String] = [:]
        var hidden: Set<String>? = nil
    }

    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GR Mac/save-history.json")
    }

    override private init() {
        super.init()
        if let data = try? Data(contentsOf: Self.url),
           let store = try? JSONDecoder().decode(Store.self, from: data) {
            records = store.records
            legacy = store.legacy
            hidden = store.hidden ?? []
        }
        reindex()
        startObserving()
        refreshPresence()
    }

    // MARK: Writing

    func add(_ record: Record) {
        records.append(record)
        if record.isSave { latestSave[record.name] = record }
        persist()
    }

    func remove(_ ids: Set<UUID>) {
        records.removeAll { ids.contains($0.id) }
        reindex()
        persist()
        onChange?()
    }

    /// Takes older saves (no record) off the list; the photos themselves stay.
    func hide(_ names: Set<String>) {
        guard !names.isEmpty else { return }
        hidden.formUnion(names)
        persist()
    }

    func clear() {
        records = []
        reindex()
        persist()
        onChange?()
    }

    private func reindex() {
        latestSave = [:]
        for r in records where r.isSave { latestSave[r.name] = r }
    }

    private func persist() {
        let store = Store(records: records, legacy: legacy, hidden: hidden)
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.url, options: .atomic)
    }

    // MARK: Reading

    /// Names with a save on record.
    var savedNames: Set<String> { Set(latestSave.keys) }

    func latest(_ name: String) -> Record? { latestSave[name] }

    func photosState(_ name: String) -> PhotosState {
        if let r = latestSave[name] {
            if let id = r.assetID { return state(of: id, checkable: r.checkable) }
            // Saved to the Files app only: not a deletion when Photos doesn't have it.
            if r.outcome == .saved { return .none }
        }
        if let id = legacy[name] {
            return id.isEmpty ? .deleted : state(of: id, checkable: true)
        }
        return .none
    }

    /// Where this one save's Photos item stands.
    func photosState(of record: Record) -> PhotosState {
        guard record.isSave, let id = record.assetID else { return .none }
        return state(of: id, checkable: record.checkable)
    }

    private func state(of id: String, checkable: Bool) -> PhotosState {
        guard let present else { return .unknown }
        if present.contains(id) { return .inPhotos }
        // With limited access an item the user didn't pick is hidden, not deleted.
        return checkable || readStatus == .authorized ? .deleted : .unknown
    }

    // MARK: The Photos library

    func requestRead() async {
        let status = await PhotosLibrary.requestRead()
        readStatus = status
        startObserving()
        refreshPresence()
        onChange?()
    }

    private func startObserving() {
        readStatus = PhotosLibrary.readStatus
        guard !observing, PhotosLibrary.canRead else { return }
        observing = true
        PHPhotoLibrary.shared().register(self)
    }

    func refreshPresence() {
        readStatus = PhotosLibrary.readStatus
        let ids = Array(Set(records.compactMap(\.assetID) + legacy.values.filter { !$0.isEmpty }))
        present = PhotosLibrary.existing(ids)
    }

    /// Looks up files in the save folder that were saved before records were kept, so a
    /// photo deleted in Photos since is known as such. Full access only; once per name.
    func checkLegacy(_ files: [String: URL]) {
        guard readStatus == .authorized, !checkingLegacy else { return }
        let todo = files.filter { latestSave[$0.key] == nil && legacy[$0.key] == nil && !tried.contains($0.key) }
        guard !todo.isEmpty else { return }
        checkingLegacy = true
        tried.formUnion(todo.keys)
        Task {
            let found = await Task.detached(priority: .utility) { () -> [String: String] in
                var out: [String: String] = [:]
                for (name, url) in todo {
                    // Photos dates an item by its shooting time; without one (a movie, say)
                    // by when it was added, a moment after the file was written here.
                    if let date = Self.shootingDate(url) {
                        out[name] = PhotosLibrary.find(name: name, near: date, within: 2) ?? ""
                    } else if let written = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate {
                        // Not found this way is no proof it's gone: leave those unknown.
                        if let id = PhotosLibrary.find(name: name, near: written, within: 600) { out[name] = id }
                    }
                }
                return out
            }.value
            checkingLegacy = false
            DebugLog.write("save history: looked up \(todo.count) older saves: \(found.values.filter { !$0.isEmpty }.count) in Photos, \(found.values.filter(\.isEmpty).count) not")
            guard !found.isEmpty else { return }
            legacy.merge(found) { _, new in new }
            persist()
            refreshPresence()
            onChange?()
        }
    }

    /// EXIF DateTimeOriginal, as Photos reads it (local time unless an offset is given).
    nonisolated static func shootingDate(_ url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String {
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ssZZZZZ"
            if let date = formatter.date(from: text + offset) { return date }
        }
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = .current
        return formatter.date(from: text)
    }
}

extension SaveHistory: PHPhotoLibraryChangeObserver {
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            let before = self.present
            self.refreshPresence()
            if self.present != before { self.onChange?() }
        }
    }
}
