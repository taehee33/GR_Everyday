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
    /// Which way the gallery wall runs: down the screen or across it.
    var wallDirection: WallDirection = .vertical
    /// Profile picture: R2 a/{id}/{version}.jpg; nil = none (initial shown instead).
    var avatarVersion: Int? = nil
    /// Instagram username without "@".
    var instagram: String? = nil
    /// One http(s) link.
    var website: String? = nil
    /// The cameras shown on the profile (up to 5); empty = not shown.
    var cameras: [String] = []

    static let bioLimit = 150
    static let camerasLimit = 5
    /// Cameras offered on the profile; anything else can be typed.
    static let cameraChoices = ["GR IV", "GR IV HDF", "GR IIIx", "GR IIIx HDF", "GR III", "GR III HDF", "GR II", "GR"]

    /// "@name", "instagram.com/name/" or a full link → "name"; nil when it is not a username.
    static func normalizeInstagram(_ text: String) -> String? {
        var name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = name.range(of: "instagram.com/", options: .caseInsensitive) {
            name = String(name[range.upperBound...])
        }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "@/"))
        if let end = name.firstIndex(where: { $0 == "/" || $0 == "?" }) { name = String(name[..<end]) }
        return name.range(of: "^[A-Za-z0-9._]{1,30}$", options: .regularExpression) != nil ? name : nil
    }

    /// "example.com" → "https://example.com"; nil when it is not a web link.
    static func normalizeWebsite(_ text: String) -> String? {
        var link = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if link.isEmpty || link.contains(where: \.isWhitespace) || link.count > 200 { return nil }
        if !link.lowercased().hasPrefix("http://") && !link.lowercased().hasPrefix("https://") {
            link = "https://" + link
        }
        guard let url = URL(string: link), let host = url.host, host.contains("."), url.user == nil else { return nil }
        return link
    }

    var instagramURL: URL? { instagram.flatMap { URL(string: "https://instagram.com/\($0)") } }
    var websiteURL: URL? { website.flatMap(URL.init(string:)) }

    /// grid = 그리드 (Instagram-style profile), free = 갤러리 (frames hung on a wall).
    enum WallStyle: String, Codable { case grid, free }
    enum WallDirection: String, Codable { case vertical, horizontal }

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
        // "@" is never part of a username; drop one typed out of habit.
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@")).lowercased()
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
    /// The owner's names, when the store read them with the photo (the feed does).
    var author: MomentAuthor? = nil

    enum Status: String, Codable { case uploading, published, hidden }

    var isShared: Bool { sharedAt != nil }
}

/// Who took a photo (or wrote a comment), as shown on the feed: display name, username and
/// profile picture.
struct MomentAuthor: Codable, Equatable {
    var handle: String?
    var displayName: String?
    var avatarVersion: Int? = nil

    /// The display name, or the username when there is none.
    var title: String {
        displayName ?? handle ?? "이름 없음"
    }
}

/// A comment under a photo.
struct MomentComment: Identifiable, Equatable {
    let id: Int
    let photoID: UUID
    let author: UUID
    var authorInfo: MomentAuthor?
    let body: String
    let createdAt: Date

    static let limit = 300
}

/// Why a photo is reported; the raw values are the database's reports.reason check.
enum MomentReportReason: String, CaseIterable, Identifiable {
    case nudity, violence, spam, copyright, notGR = "not_gr", other
    var id: String { rawValue }

    /// The reasons a comment can be reported for (comment_reports has no not_gr).
    static var forComments: [MomentReportReason] { allCases.filter { $0 != .notGR } }

    var title: String {
        switch self {
        case .nudity: return "선정적인 내용"
        case .violence: return "폭력적이거나 불쾌한 내용"
        case .spam: return "스팸·광고"
        case .copyright: return "다른 사람의 사진 (저작권)"
        case .notGR: return "GR로 찍지 않은 사진"
        case .other: return "기타"
        }
    }
}

/// A report I filed, and what became of it (reports.status).
struct MomentReport: Identifiable, Equatable {
    let id: Int
    /// nil once the photo has been deleted.
    let photoID: UUID?
    let reason: MomentReportReason
    let createdAt: Date
    let status: Status

    enum Status: String {
        /// Filed; nothing decided yet.
        case received
        /// Enough reports came in: hidden from everyone until reviewed.
        case hidden
        /// The photo is gone (taken down after review, or deleted by its owner).
        case removed
        /// Reviewed and found to be fine.
        case dismissed

        var title: String {
            switch self {
            case .received: return "접수됨 · 확인하고 있어요"
            case .hidden: return "신고가 쌓여 모두에게서 숨겨졌어요"
            case .removed: return "사진이 삭제되었어요"
            case .dismissed: return "확인 결과 문제가 없다고 판단했어요"
            }
        }

        var icon: String {
            switch self {
            case .received: return "clock"
            case .hidden: return "eye.slash"
            case .removed: return "trash"
            case .dismissed: return "checkmark.circle"
            }
        }
    }
}

/// One photo's place on a Photowall. Both layouts are kept so switching style loses nothing.
struct WallItem: Codable, Equatable {
    let photoID: UUID
    // Free layout (갤러리), in units of the wall's short side (its width when the wall runs
    // down, its height when it runs across): x is across the wall, y along it, width is the
    // frame's width. The same numbers draw either direction, turned a quarter.
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

/// What 프로필 편집 saves (the picture goes separately, through setAvatar).
struct MomentProfileEdit: Equatable {
    var bio: String?
    var instagram: String?
    var website: String?
    /// Empty = none shown.
    var cameras: [String]
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

extension MomentStore {
    /// Where a profile picture is downloaded from; nil when there is none.
    func avatarURL(_ profile: MomentProfile) -> URL? {
        profile.avatarVersion.map { avatarURL(owner: profile.id, version: $0) }
    }

    func avatarURL(owner: UUID, author: MomentAuthor?) -> URL? {
        author?.avatarVersion.map { avatarURL(owner: owner, version: $0) }
    }
}

protocol MomentStore: AnyObject {
    var me: MomentProfile? { get }
    /// How I signed in, for the account screen: "Google · name@example.com".
    var signInLabel: String? { get }

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
    /// Bio, links and camera. Reloads `me`.
    func updateProfile(_ edit: MomentProfileEdit) async throws
    /// A square JPEG (MomentAvatar.render) as the profile picture, or nil to remove it.
    func setAvatar(_ jpeg: Data?) async throws
    /// Where a profile picture is downloaded from.
    func avatarURL(owner: UUID, version: Int) -> URL

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
    func saveWall(style: MomentProfile.WallStyle, direction: MomentProfile.WallDirection,
                  items: [WallItem]) async throws

    func like(_ photo: UUID, _ on: Bool) async throws
    /// Which of `photos` I have liked (empty when signed out).
    func likes(among photos: [UUID]) async throws -> Set<UUID>
    /// Photos I liked that can still be seen, most recently liked first.
    func likedPhotos(limit: Int) async throws -> [MomentPhoto]
    /// Reports I filed, newest first.
    func myReports() async throws -> [MomentReport]
    func report(_ photo: UUID, reason: String, note: String?) async throws
    func block(_ owner: UUID) async throws

    /// A photo's comments, oldest first (hidden ones and those of people I blocked left out).
    func comments(on photo: UUID) async throws -> [MomentComment]
    func addComment(on photo: UUID, _ text: String) async throws -> MomentComment
    /// Mine, or anyone's under my photo.
    func deleteComment(_ id: Int) async throws
    func reportComment(_ id: Int, reason: String) async throws

    /// Where the app downloads a photo's files from (the Worker today, a domain later).
    func displayURL(_ photo: MomentPhoto) -> URL
    func thumbURL(_ photo: MomentPhoto) -> URL
    /// The thumbnail of a photo known only by id (a report's).
    func thumbURL(_ id: UUID) -> URL
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
    fileprivate(set) var me: MomentProfile?
    var signInLabel: String? { me == nil ? nil : "Mock" }
    fileprivate var profiles: [UUID: MomentProfile] = [:]
    fileprivate var photos: [UUID: MomentPhoto] = [:]
    fileprivate var items: [UUID: WallItem] = [:]
    /// Every share ever made (owner, time); kept after unshare/delete like the server.
    private var shares: [(owner: UUID, at: Date)] = []
    private var reports: [UUID: Set<UUID>] = [:]
    private var filed: [MomentReport] = []
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

    func updateProfile(_ edit: MomentProfileEdit) async throws {
        var me = try requireMe()
        me.bio = edit.bio
        me.instagram = edit.instagram
        me.website = edit.website
        me.cameras = edit.cameras
        self.me = me
        profiles[me.id] = me
    }

    /// Pictures live in a temporary folder so AsyncImage can load them like the real ones.
    func setAvatar(_ jpeg: Data?) async throws {
        var me = try requireMe()
        if let jpeg {
            let version = (me.avatarVersion ?? 0) + 1
            try jpeg.write(to: avatarFile(me.id, version))
            me.avatarVersion = version
        } else {
            me.avatarVersion = nil
        }
        self.me = me
        profiles[me.id] = me
    }

    func avatarURL(owner: UUID, version: Int) -> URL { avatarFile(owner, version) }

    private func avatarFile(_ id: UUID, _ version: Int) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "mock-avatar-\(id.uuidString)-\(version).jpg")
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
            .prefix(limit).map { photo in
                var photo = photo
                let owner = profiles[photo.owner]
                photo.author = author(photo.owner)
                return photo
            }
    }

    private func author(_ id: UUID) -> MomentAuthor? {
        profiles[id].map { MomentAuthor(handle: $0.handle, displayName: $0.displayName, avatarVersion: $0.avatarVersion) }
    }

    func wall(of owner: UUID) async throws -> (profile: MomentProfile, photos: [MomentPhoto], items: [WallItem]) {
        guard let profile = profiles[owner] else { throw MomentError.notFound }
        let mine = owner == me?.id
        let list = photos.values
            .filter { $0.owner == owner && (mine || $0.status == .published) }
            .sorted { $0.createdAt > $1.createdAt }
            .map { photo in
                var photo = photo
                photo.author = author(owner)
                return photo
            }
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
        guard let old = photos[id], old.owner == me?.id else { throw MomentError.notFound }
        // Like the photos_camera_source trigger: a changed camera counts as picked by the owner.
        var info = info
        info.cameraSource = info.camera == nil ? nil
            : info.camera == old.info.camera ? old.info.cameraSource : .declared
        photos[id]?.info = info
        photos[id]?.caption = caption
    }

    func saveWall(style: MomentProfile.WallStyle, direction: MomentProfile.WallDirection,
                  items newItems: [WallItem]) async throws {
        var me = try requireMe()
        me.wallStyle = style
        me.wallDirection = direction
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

    func likes(among ids: [UUID]) async throws -> Set<UUID> {
        me == nil ? [] : liked.intersection(ids)
    }

    func report(_ id: UUID, reason: String, note: String?) async throws {
        let me = try requireMe()
        guard photos[id] != nil else { throw MomentError.notFound }
        if reports[id, default: []].insert(me.id).inserted {
            filed.insert(MomentReport(id: filed.count + 1, photoID: id,
                                      reason: MomentReportReason(rawValue: reason) ?? .other,
                                      createdAt: now(), status: .received), at: 0)
        }
        if (reports[id]?.count ?? 0) >= limits.reportsToHide, photos[id]?.status == .published {
            photos[id]?.status = .hidden
        }
    }

    func likedPhotos(limit: Int) async throws -> [MomentPhoto] {
        photos.values.filter { liked.contains($0.id) && $0.status == .published }.prefix(limit).map { $0 }
    }

    func myReports() async throws -> [MomentReport] { filed }

    func block(_ owner: UUID) async throws {
        _ = try requireMe()
        blocked.insert(owner)
    }

    fileprivate var commentList: [MomentComment] = []

    func comments(on photo: UUID) async throws -> [MomentComment] {
        commentList.filter { $0.photoID == photo && !blocked.contains($0.author) }
            .map { var c = $0; c.authorInfo = author($0.author); return c }
    }

    func addComment(on photo: UUID, _ text: String) async throws -> MomentComment {
        let me = try requireMe()
        guard photos[photo]?.status == .published else { throw MomentError.notFound }
        let comment = MomentComment(id: (commentList.map(\.id).max() ?? 0) + 1, photoID: photo, author: me.id,
                                    authorInfo: author(me.id), body: text, createdAt: now())
        commentList.append(comment)
        return comment
    }

    func deleteComment(_ id: Int) async throws {
        let me = try requireMe()
        guard let comment = commentList.first(where: { $0.id == id }),
              comment.author == me.id || photos[comment.photoID]?.owner == me.id else { throw MomentError.notFound }
        commentList.removeAll { $0.id == id }
    }

    func reportComment(_ id: Int, reason: String) async throws {
        _ = try requireMe()
    }

    let imageBase = URL(string: "https://moment-img.example.workers.dev")!
    func displayURL(_ photo: MomentPhoto) -> URL { imageBase.appending(path: "p/\(photo.id.uuidString.lowercased())/display.jpg") }
    func thumbURL(_ photo: MomentPhoto) -> URL { thumbURL(photo.id) }
    func thumbURL(_ id: UUID) -> URL { imageBase.appending(path: "p/\(id.uuidString.lowercased())/thumb") }
}

#if DEBUG
extension MockMomentStore {
    /// A signed-in sample account with photos of different shapes, hung where the server
    /// puts new uploads (so the gallery lays them out itself).
    static func sample() -> MockMomentStore {
        let store = MockMomentStore(signedInAs: "sample")
        guard var me = store.me else { return store }
        me.displayName = "샘플"
        me.wallStyle = .free
        me.bio = "흘러가는 일상 속 특별한 순간을 모아요."
        me.instagram = "sample.gr"
        me.cameras = ["GR IV HDF", "GR IIIx"]
        store.me = me
        store.profiles[me.id] = me
        let shapes: [(Int, Int, String?)] = [
            (3072, 2048, "비 온 뒤 골목"), (2048, 3072, "창가"), (3072, 2048, nil), (2048, 2048, "퇴근길"),
            (2048, 3072, nil), (3072, 2048, "성수동 오후"), (3072, 1728, nil),
        ]
        for (n, shape) in shapes.enumerated() {
            let photo = MomentPhoto(
                id: UUID(), owner: me.id, status: .published, caption: shape.2,
                width: shape.0, height: shape.1, thumbWidth: 600, thumbHeight: 600 * shape.1 / shape.0,
                info: MomentShotInfo(camera: "GR IV", cameraSource: .exif), likeCount: n,
                createdAt: Date().addingTimeInterval(Double(-n) * 3600), sharedAt: n % 3 == 0 ? Date() : nil)
            store.photos[photo.id] = photo
            store.items[photo.id] = WallItem(photoID: photo.id, x: Double(n % 3) * 0.34,
                                             y: Double(n / 3) * 0.3, width: 0.3, gridOrder: -n)
        }
        // Someone else, so 순간들 has a stranger's photo to open.
        let other = MomentProfile(id: UUID(), handle: "neighbor", displayName: "이웃", bio: "골목을 걷는 사람.",
                                  wallStyle: .grid, wallLimit: 15, cameras: ["GR IIIx"])
        store.profiles[other.id] = other
        for n in 0..<4 {
            let photo = MomentPhoto(
                id: UUID(), owner: other.id, status: .published, caption: n == 0 ? "아침 산책" : nil,
                width: 3072, height: n % 2 == 0 ? 2048 : 3072, thumbWidth: 600, thumbHeight: n % 2 == 0 ? 400 : 600,
                info: MomentShotInfo(camera: "GR1v", cameraSource: .declared, film: "Kodak Portra 400"), likeCount: 2,
                createdAt: Date().addingTimeInterval(Double(-n) * 7200), sharedAt: n < 2 ? Date().addingTimeInterval(-60) : nil)
            store.photos[photo.id] = photo
            if n == 0 {
                store.commentList.append(MomentComment(id: 1, photoID: photo.id, author: me.id, authorInfo: nil,
                                                       body: "빛이 정말 좋네요!", createdAt: Date()))
            }
        }
        return store
    }
}
#endif
