import Foundation

// Moment's data, as the app sees it. `SupabaseMomentStore` (next step, once the Supabase
// project exists) talks to the backend in supabase/migrations; `MockMomentStore` keeps
// everything in memory with the same limits, for screens, previews and tests.

struct MomentProfile: Codable, Equatable, Identifiable {
    let id: UUID
    var handle: String?
    var displayName: String?
    var bio: String?
    var wallStyle: WallStyle
    /// How many photos the wall may hold (15 free; a purchase raises it on the server).
    var wallLimit: Int
    /// When the handle was last changed (nil until the first change after setting it).
    var handleChangedAt: Date? = nil

    enum WallStyle: String, Codable { case grid, free }

    static let handleChangeInterval: TimeInterval = 30 * 24 * 3600
    static let handleHoldInterval: TimeInterval = 14 * 24 * 3600

    /// When the handle may change next; nil when it may change now.
    var nextHandleChange: Date? {
        guard handle != nil, let changed = handleChangedAt else { return nil }
        let next = changed.addingTimeInterval(Self.handleChangeInterval)
        return next > Date() ? next : nil
    }

    /// Same rule as profiles_display_name_check: 1–20 characters, any script.
    static func normalizeDisplayName(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .precomposedStringWithCanonicalMapping
    }

    static func displayNameProblem(_ name: String) -> String? {
        if name.isEmpty { return "1자 이상 입력해 주세요." }
        if name.count > 20 { return "20자 이하로 입력해 주세요." }
        if name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return "쓸 수 없는 문자가 있어요."
        }
        return nil
    }

    /// Same rule as the profiles.handle check in the database (2–20 of a–z, 0–9, "_", ".").
    static func isValidHandle(_ handle: String) -> Bool {
        handle.range(of: "^[a-z0-9_.]{2,20}$", options: .regularExpression) != nil
    }

    /// What the user typed, as it will be saved: trimmed and lowercased.
    static func normalizeHandle(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Why a (normalized) handle cannot be used, in words for the user; nil when it is fine.
    static func handleProblem(_ handle: String) -> String? {
        if handle.range(of: "^[a-z0-9_.]*$", options: .regularExpression) == nil {
            return "영문, 숫자, 밑줄(_), 마침표(.)만 쓸 수 있어요."
        }
        if handle.count < 2 { return "2자 이상 입력해 주세요." }
        if handle.count > 20 { return "20자 이하로 입력해 주세요." }
        return nil
    }
}

struct MomentPhoto: Codable, Equatable, Identifiable {
    let id: UUID
    let owner: UUID
    var status: Status
    var caption: String?
    let width: Int
    let height: Int
    let thumbWidth: Int
    let thumbHeight: Int
    var info: MomentShotInfo
    var likeCount: Int
    let createdAt: Date
    /// On the Moment feed since; nil = only on the owner's wall.
    var sharedAt: Date?

    enum Status: String, Codable { case uploading, published, hidden }

    var isShared: Bool { sharedAt != nil }
}

/// One photo's place on a Photowall. Both layouts are kept so switching style loses nothing.
struct WallItem: Codable, Equatable {
    let photoID: UUID
    // Free layout, in fractions of the wall's width.
    var x: Double = 0
    var y: Double = 0
    var width: Double = 0.3
    var z: Int = 0
    var rotation: Double = 0
    // Grid layout.
    var gridOrder: Int = 0
    var gridSpan: GridSpan = .one

    enum GridSpan: String, Codable, CaseIterable {
        case one = "1x1", wide = "2x1", tall = "1x2", big = "2x2"
    }
}

/// What the upload sheet hands to the store.
struct MomentUpload {
    let image: MomentImage.Rendered
    let info: MomentShotInfo
    var caption: String?
    /// Share to the feed right after it is on the wall (uses one of this month's shares).
    var shareNow: Bool
}

/// Counts shown as "벽 12/15 · 이번 달 공유 3/5".
struct MomentQuota: Equatable {
    var wallUsed: Int
    var wallLimit: Int
    var sharesLeft: Int
    var sharesPerMonth: Int

    var wallFull: Bool { wallUsed >= wallLimit }
}

enum MomentError: LocalizedError, Equatable {
    case signedOut
    case needsHandle
    case wallFull(limit: Int)
    case dailyUploadLimit(Int)
    case monthlyShareLimit(Int)
    case notShareable
    case notFound
    case handleTaken
    case handleChangeTooSoon(Date?)
    case displayNameTaken
    case invalidName(String)
    case uploadFailed
    case server(String)

    var errorDescription: String? {
        switch self {
        case .signedOut: return "로그인이 필요해요."
        case .needsHandle: return "먼저 사용할 이름(핸들)을 정해 주세요."
        case .wallFull(let limit): return "벽이 가득 찼어요 (\(limit)장). 사진을 내리면 새로 걸 수 있어요."
        case .dailyUploadLimit(let n): return "오늘은 더 올릴 수 없어요 (하루 \(n)장)."
        case .monthlyShareLimit(let n): return "이번 달 공유를 모두 썼어요 (한 달 \(n)장)."
        case .notShareable: return "공유할 수 없는 사진이에요."
        case .notFound: return "사진을 찾을 수 없어요."
        case .handleTaken: return "이미 쓰고 있는 사용자명이에요. 다른 사용자명을 골라 주세요."
        case .handleChangeTooSoon(let date?):
            return "사용자명은 30일에 한 번 바꿀 수 있어요. \(date.formatted(date: .long, time: .omitted))부터 바꿀 수 있어요."
        case .handleChangeTooSoon(nil): return "사용자명은 30일에 한 번 바꿀 수 있어요."
        case .displayNameTaken: return "이미 쓰고 있는 표시 이름이에요. 다른 이름을 골라 주세요."
        case .invalidName(let reason): return reason
        case .uploadFailed: return "사진을 올리지 못했어요. 다시 시도해 주세요."
        case .server(let message): return "서버 오류가 났어요. (\(message))"
        }
    }
}

protocol MomentStore: AnyObject {
    var me: MomentProfile? { get }

    /// Sign in with the identity token from Sign in with Apple and the raw nonce it was asked
    /// with. Loads `me` afterwards.
    func signInWithApple(idToken: String, nonce: String) async throws
    /// Google through Supabase's web sign-in, shown in the system's sign-in sheet.
    func signInWithGoogle() async throws
    func signOut() async throws
    /// Reloads `me` from the server (nil when signed out).
    func refreshMe() async throws
    /// 2–20 characters of a–z, 0–9, "_" and ".". Needed before the first upload; can be
    /// changed later.
    func setHandle(_ handle: String) async throws
    /// True when nobody else uses or holds `handle` (my own current or held handle counts as
    /// available).
    func isHandleAvailable(_ handle: String) async throws -> Bool
    /// Display name: any script, 1–20 characters, unique ignoring case; changes any time.
    func setDisplayName(_ name: String) async throws
    func isDisplayNameAvailable(_ name: String) async throws -> Bool
    /// Deletes the account and every photo in it (App Store 5.1.1(v)).
    func deleteAccount() async throws

    /// Photos shared to the feed, newest first. Pass the last photo's `sharedAt` to page.
    func feed(before: Date?, limit: Int) async throws -> [MomentPhoto]
    /// A wall: the owner's published photos and their layout.
    func wall(of owner: UUID) async throws -> (profile: MomentProfile, photos: [MomentPhoto], items: [WallItem])
    func quota() async throws -> MomentQuota

    func upload(_ upload: MomentUpload) async throws -> MomentPhoto
    func delete(_ photo: UUID) async throws
    func share(_ photo: UUID) async throws -> MomentPhoto
    /// Off the feed, still on the wall. The used share is not returned.
    func unshare(_ photo: UUID) async throws
    /// Turning shot info off (or back on from the original) without re-uploading.
    func updateInfo(_ photo: UUID, info: MomentShotInfo, caption: String?) async throws
    func saveWall(style: MomentProfile.WallStyle, items: [WallItem]) async throws

    func like(_ photo: UUID, _ on: Bool) async throws
    func report(_ photo: UUID, reason: String, note: String?) async throws
    func block(_ owner: UUID) async throws

    /// Where the app downloads a photo's files from (the Worker today, a domain later).
    func displayURL(_ photo: MomentPhoto) -> URL
    func thumbURL(_ photo: MomentPhoto) -> URL
}

/// In-memory store with the server's rules (wall limit, monthly shares, report hiding), for
/// building screens before the backend exists and for tests.
final class MockMomentStore: MomentStore {
    struct Limits {
        var wallFree = 15
        /// nil = no daily cap (the current setting on the server too).
        var uploadsPerDay: Int?
        var sharesPerMonth = 5
        var reportsToHide = 5
    }

    var limits = Limits()
    private(set) var me: MomentProfile?
    private var profiles: [UUID: MomentProfile] = [:]
    private var photos: [UUID: MomentPhoto] = [:]
    private var items: [UUID: WallItem] = [:]
    /// Every share ever made (owner, time); kept after unshare/delete like the server.
    private var shares: [(owner: UUID, at: Date)] = []
    private var reports: [UUID: Set<UUID>] = [:]
    private var blocked: Set<UUID> = []
    private var liked: Set<UUID> = []
    var now: () -> Date = Date.init

    init(signedInAs handle: String? = "me") {
        let id = UUID()
        let profile = MomentProfile(id: id, handle: handle, wallStyle: .grid, wallLimit: limits.wallFree)
        profiles[id] = profile
        me = profile
    }

    private func requireMe() throws -> MomentProfile {
        guard let me else { throw MomentError.signedOut }
        return me
    }

    func signInWithApple(idToken: String, nonce: String) async throws {
        if me == nil {
            let profile = MomentProfile(id: UUID(), wallStyle: .grid, wallLimit: limits.wallFree)
            profiles[profile.id] = profile
            me = profile
        }
    }

    func signInWithGoogle() async throws {
        try await signInWithApple(idToken: "", nonce: "")
    }

    func signOut() async throws { me = nil }

    func refreshMe() async throws {}

    /// Old handles held for their previous owner (handle → owner, until).
    private var holds: [String: (owner: UUID, until: Date)] = [:]

    func setHandle(_ handle: String) async throws {
        var me = try requireMe()
        guard MomentProfile.isValidHandle(handle) else { throw MomentError.invalidName("invalid handle") }
        if me.handle == handle { return }
        if let next = me.nextHandleChange { throw MomentError.handleChangeTooSoon(next) }
        guard try await isHandleAvailable(handle) else { throw MomentError.handleTaken }
        holds[handle] = nil
        if let old = me.handle {
            holds[old] = (me.id, now().addingTimeInterval(MomentProfile.handleHoldInterval))
            me.handleChangedAt = now()
        }
        me.handle = handle
        self.me = me
        profiles[me.id] = me
    }

    func isHandleAvailable(_ handle: String) async throws -> Bool {
        if profiles.values.contains(where: { $0.handle == handle && $0.id != me?.id }) { return false }
        if let hold = holds[handle], hold.until > now(), hold.owner != me?.id { return false }
        return true
    }

    func setDisplayName(_ name: String) async throws {
        var me = try requireMe()
        if let problem = MomentProfile.displayNameProblem(name) { throw MomentError.invalidName(problem) }
        guard try await isDisplayNameAvailable(name) else { throw MomentError.displayNameTaken }
        me.displayName = name
        self.me = me
        profiles[me.id] = me
    }

    func isDisplayNameAvailable(_ name: String) async throws -> Bool {
        let key = name.precomposedStringWithCanonicalMapping.lowercased()
        return !profiles.values.contains {
            $0.id != me?.id && $0.displayName?.precomposedStringWithCanonicalMapping.lowercased() == key
        }
    }

    func deleteAccount() async throws {
        let me = try requireMe()
        photos = photos.filter { $0.value.owner != me.id }
        profiles[me.id] = nil
        self.me = nil
    }

    private func monthStart(_ date: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: cal.dateComponents([.year, .month], from: date))!
    }

    private func sharesUsed(_ owner: UUID) -> Int {
        let start = monthStart(now())
        return shares.filter { $0.owner == owner && $0.at >= start }.count
    }

    private func wallCount(_ owner: UUID) -> Int {
        photos.values.filter { $0.owner == owner }.count
    }

    func feed(before: Date?, limit: Int) async throws -> [MomentPhoto] {
        photos.values
            .filter { $0.status == .published && $0.sharedAt != nil && !blocked.contains($0.owner) }
            .filter { before == nil || $0.sharedAt! < before! }
            .sorted { $0.sharedAt! > $1.sharedAt! }
            .prefix(limit).map { $0 }
    }

    func wall(of owner: UUID) async throws -> (profile: MomentProfile, photos: [MomentPhoto], items: [WallItem]) {
        guard let profile = profiles[owner] else { throw MomentError.notFound }
        let mine = owner == me?.id
        let list = photos.values
            .filter { $0.owner == owner && (mine || $0.status == .published) }
            .sorted { $0.createdAt > $1.createdAt }
        return (profile, list, list.compactMap { items[$0.id] })
    }

    func quota() async throws -> MomentQuota {
        let me = try requireMe()
        return MomentQuota(wallUsed: wallCount(me.id), wallLimit: me.wallLimit,
                           sharesLeft: max(limits.sharesPerMonth - sharesUsed(me.id), 0),
                           sharesPerMonth: limits.sharesPerMonth)
    }

    func upload(_ upload: MomentUpload) async throws -> MomentPhoto {
        let me = try requireMe()
        guard me.handle != nil else { throw MomentError.needsHandle }
        guard wallCount(me.id) < me.wallLimit else { throw MomentError.wallFull(limit: me.wallLimit) }
        if let perDay = limits.uploadsPerDay {
            let today = Calendar.current.startOfDay(for: now())
            if photos.values.filter({ $0.owner == me.id && $0.createdAt >= today }).count >= perDay {
                throw MomentError.dailyUploadLimit(perDay)
            }
        }
        if upload.shareNow, sharesUsed(me.id) >= limits.sharesPerMonth {
            throw MomentError.monthlyShareLimit(limits.sharesPerMonth)
        }
        var photo = MomentPhoto(
            id: UUID(), owner: me.id, status: .published, caption: upload.caption,
            width: Int(upload.image.displaySize.width), height: Int(upload.image.displaySize.height),
            thumbWidth: Int(upload.image.thumbSize.width), thumbHeight: Int(upload.image.thumbSize.height),
            info: upload.info, likeCount: 0, createdAt: now(), sharedAt: nil)
        photos[photo.id] = photo
        let first = (items.values.filter { photos[$0.photoID]?.owner == me.id }.map(\.gridOrder).min() ?? 1) - 1
        items[photo.id] = WallItem(photoID: photo.id, gridOrder: first)
        if upload.shareNow { photo = try await share(photo.id) }
        return photo
    }

    func delete(_ photo: UUID) async throws {
        guard photos[photo]?.owner == me?.id else { throw MomentError.notFound }
        photos[photo] = nil
        items[photo] = nil
    }

    func share(_ id: UUID) async throws -> MomentPhoto {
        let me = try requireMe()
        guard var photo = photos[id], photo.owner == me.id, photo.status == .published, photo.sharedAt == nil
        else { throw MomentError.notShareable }
        guard sharesUsed(me.id) < limits.sharesPerMonth else {
            throw MomentError.monthlyShareLimit(limits.sharesPerMonth)
        }
        let at = now()
        shares.append((me.id, at))
        photo.sharedAt = at
        photos[id] = photo
        return photo
    }

    func unshare(_ id: UUID) async throws {
        guard photos[id]?.owner == me?.id else { throw MomentError.notFound }
        photos[id]?.sharedAt = nil
    }

    func updateInfo(_ id: UUID, info: MomentShotInfo, caption: String?) async throws {
        guard photos[id]?.owner == me?.id else { throw MomentError.notFound }
        photos[id]?.info = info
        photos[id]?.caption = caption
    }

    func saveWall(style: MomentProfile.WallStyle, items newItems: [WallItem]) async throws {
        var me = try requireMe()
        me.wallStyle = style
        self.me = me
        profiles[me.id] = me
        for item in newItems where photos[item.photoID]?.owner == me.id { items[item.photoID] = item }
    }

    func like(_ id: UUID, _ on: Bool) async throws {
        _ = try requireMe()
        guard photos[id] != nil else { throw MomentError.notFound }
        if on, liked.insert(id).inserted { photos[id]?.likeCount += 1 }
        if !on, liked.remove(id) != nil { photos[id]?.likeCount -= 1 }
    }

    func report(_ id: UUID, reason: String, note: String?) async throws {
        let me = try requireMe()
        guard photos[id] != nil else { throw MomentError.notFound }
        reports[id, default: []].insert(me.id)
        if (reports[id]?.count ?? 0) >= limits.reportsToHide, photos[id]?.status == .published {
            photos[id]?.status = .hidden
        }
    }

    func block(_ owner: UUID) async throws {
        _ = try requireMe()
        blocked.insert(owner)
    }

    let imageBase = URL(string: "https://moment-img.example.workers.dev")!
    func displayURL(_ photo: MomentPhoto) -> URL { imageBase.appending(path: "p/\(photo.id.uuidString.lowercased())/display.jpg") }
    func thumbURL(_ photo: MomentPhoto) -> URL { imageBase.appending(path: "p/\(photo.id.uuidString.lowercased())/thumb") }
}
