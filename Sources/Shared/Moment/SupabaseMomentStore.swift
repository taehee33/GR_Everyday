import Foundation
import Supabase

/// Where 순간 (Moments) lives. The publishable key is meant to ship in apps: what it can do is
/// limited by the database's row level security (supabase/migrations).
enum MomentBackend {
    static let url = URL(string: "https://rqnwgvfirkfxfawnawzf.supabase.co")!
    static let publishableKey = "sb_publishable_cojeybLAeRjdBFHpVxQtRA_Rz3BYm8_"
    /// Used until app_config.image_base_url has been read.
    static let defaultImageBase = URL(string: "https://moment-img.moment-img.workers.dev")!
    /// Where Supabase sends the browser back after a web sign-in (Google). Listed in
    /// supabase/config.toml [auth] additional_redirect_urls.
    static let authRedirect = URL(string: "com.hantaehee.greveryday://login-callback")!

    /// One client for the whole app; it keeps the signed-in session in the Keychain and
    /// refreshes it on its own.
    static let client = SupabaseClient(supabaseURL: url, supabaseKey: publishableKey)
}

/// `MomentStore` backed by Supabase (database, auth, Edge Functions) and R2 (files, through
/// presigned URLs from moment-upload). See PLAN-moment.md sections 5–7.
final class SupabaseMomentStore: MomentStore, @unchecked Sendable {
    private let client: SupabaseClient
    private let session: URLSession
    private(set) var me: MomentProfile?
    private var imageBase = MomentBackend.defaultImageBase

    init(client: SupabaseClient = MomentBackend.client, session: URLSession = .shared) {
        self.client = client
        self.session = session
    }

    // MARK: Account

    func signInWithApple(idToken: String, nonce: String) async throws {
        do {
            _ = try await client.auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce))
        } catch {
            throw Self.map(error)
        }
        try await refreshMe()
    }

    func signInWithGoogle() async throws {
        do {
            let scheme = MomentBackend.authRedirect.scheme ?? "com.hantaehee.greveryday"
            _ = try await client.auth.signInWithOAuth(provider: .google, redirectTo: MomentBackend.authRedirect) { url in
                try await WebSignIn.run(url, callbackScheme: scheme)
            }
        } catch {
            throw Self.map(error)
        }
        try await refreshMe()
    }

    func signOut() async throws {
        try? await client.auth.signOut()
        me = nil
    }

    func refreshMe() async throws {
        await loadImageBase()
        guard let user = client.auth.currentUser else { me = nil; return }
        do {
            let row: ProfileRow = try await client.from("profiles").select()
                .eq("id", value: user.id).single().execute().value
            me = row.profile
        } catch {
            throw Self.map(error)
        }
    }

    /// Goes through set_handle(), which enforces the 30-day limit and the 14-day hold.
    func setHandle(_ handle: String) async throws {
        _ = try requireMe()
        guard MomentProfile.isValidHandle(handle) else {
            throw MomentError.invalidName(MomentProfile.handleProblem(handle) ?? "사용할 수 없는 사용자명이에요.")
        }
        do {
            try await client.rpc("set_handle", params: ["p_handle": handle]).execute()
        } catch let error as PostgrestError where error.code == "23505" {
            throw MomentError.handleTaken
        } catch {
            throw Self.map(error)
        }
        try await refreshMe()
    }

    func isHandleAvailable(_ handle: String) async throws -> Bool {
        do {
            return try await client.rpc("handle_available", params: ["p_handle": handle]).execute().value
        } catch {
            throw Self.map(error)
        }
    }

    func setDisplayName(_ name: String) async throws {
        let me = try requireMe()
        if let problem = MomentProfile.displayNameProblem(name) { throw MomentError.invalidName(problem) }
        do {
            try await client.from("profiles").update(["display_name": name], returning: .minimal)
                .eq("id", value: me.id).execute()
        } catch let error as PostgrestError where error.code == "23505" {
            throw MomentError.displayNameTaken
        } catch let error as PostgrestError where error.code == "23514" {
            throw MomentError.invalidName("쓸 수 없는 표시 이름이에요.")
        } catch {
            throw Self.map(error)
        }
        try await refreshMe()
    }

    func isDisplayNameAvailable(_ name: String) async throws -> Bool {
        do {
            return try await client.rpc("display_name_available", params: ["p_name": name]).execute().value
        } catch {
            throw Self.map(error)
        }
    }

    func deleteAccount() async throws {
        _ = try requireMe()
        let _: Empty = try await invoke("account-delete", body: Empty())
        try? await client.auth.signOut()
        me = nil
    }

    // MARK: Reading

    func feed(before: Date?, limit: Int) async throws -> [MomentPhoto] {
        do {
            var query = client.from("photos").select(PhotoRow.columns)
                .eq("status", value: "published")
                .not("shared_at", operator: .`is`, value: "null")
            if let before { query = query.lt("shared_at", value: before) }
            let rows: [PhotoRow] = try await query.order("shared_at", ascending: false)
                .limit(limit).execute().value
            return rows.map(\.photo)
        } catch {
            throw Self.map(error)
        }
    }

    func wall(of owner: UUID) async throws -> (profile: MomentProfile, photos: [MomentPhoto], items: [WallItem]) {
        do {
            async let profile: ProfileRow = client.from("profiles").select()
                .eq("id", value: owner).single().execute().value
            async let photos: [PhotoRow] = client.from("photos").select(PhotoRow.columns)
                .eq("owner", value: owner).order("created_at", ascending: false).execute().value
            async let items: [WallItemRow] = client.from("wall_items").select()
                .eq("owner", value: owner).execute().value
            return try await (profile.profile, photos.map(\.photo), items.map(\.item))
        } catch {
            throw Self.map(error)
        }
    }

    func quota() async throws -> MomentQuota {
        let me = try requireMe()
        do {
            async let used = client.from("photos").select("id", head: true, count: .exact)
                .eq("owner", value: me.id).execute().count
            async let left: Int = client.rpc("shares_left").execute().value
            let limits: Limits = try await client.from("app_config").select("value")
                .eq("key", value: "limits").single().execute().value
            return try await MomentQuota(wallUsed: used ?? 0, wallLimit: me.wallLimit,
                                         sharesLeft: left, sharesPerMonth: limits.value.sharesPerMonth)
        } catch {
            throw Self.map(error)
        }
    }

    // MARK: Uploading

    func upload(_ upload: MomentUpload) async throws -> MomentPhoto {
        _ = try requireMe()
        let image = upload.image
        let started: UploadStart = try await invoke("moment-upload", body: UploadRequest(
            width: Int(image.displaySize.width), height: Int(image.displaySize.height),
            thumbWidth: Int(image.thumbSize.width), thumbHeight: Int(image.thumbSize.height),
            displayBytes: image.display.count, thumbBytes: image.thumb.count,
            thumbType: image.thumbType, caption: upload.caption, info: upload.info))

        try await put(image.display, to: started.display)
        try await put(image.thumb, to: started.thumb)

        let published: PublishResult = try await invoke(
            "moment-publish", body: PublishRequest(id: started.id, shareNow: upload.shareNow))
        return published.photo.photo
    }

    private func put(_ data: Data, to target: PresignedPut) async throws {
        var request = URLRequest(url: target.url)
        request.httpMethod = "PUT"
        for (name, value) in target.headers { request.setValue(value, forHTTPHeaderField: name) }
        let (_, response) = try await session.upload(for: request, from: data)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MomentError.uploadFailed }
    }

    func delete(_ photo: UUID) async throws {
        let _: Empty = try await invoke("moment-delete", body: ["id": photo])
    }

    // MARK: Sharing and editing

    func share(_ photo: UUID) async throws -> MomentPhoto {
        do {
            try await client.rpc("share_photo", params: ["p_photo": photo]).execute()
            let row: PhotoRow = try await client.from("photos").select(PhotoRow.columns)
                .eq("id", value: photo).single().execute().value
            return row.photo
        } catch {
            throw Self.map(error)
        }
    }

    func unshare(_ photo: UUID) async throws {
        do {
            try await client.rpc("unshare_photo", params: ["p_photo": photo]).execute()
        } catch {
            throw Self.map(error)
        }
    }

    func updateInfo(_ photo: UUID, info: MomentShotInfo, caption: String?) async throws {
        do {
            try await client.from("photos").update(InfoUpdate(info: info, caption: caption), returning: .minimal)
                .eq("id", value: photo).execute()
        } catch {
            throw Self.map(error)
        }
    }

    func saveWall(style: MomentProfile.WallStyle, items: [WallItem]) async throws {
        let me = try requireMe()
        do {
            try await client.from("profiles").update(["wall_style": style.rawValue], returning: .minimal)
                .eq("id", value: me.id).execute()
            if !items.isEmpty {
                try await client.from("wall_items")
                    .upsert(items.map { WallItemRow(item: $0, owner: me.id) }, onConflict: "photo_id",
                            returning: .minimal)
                    .execute()
            }
        } catch {
            throw Self.map(error)
        }
        try await refreshMe()
    }

    func like(_ photo: UUID, _ on: Bool) async throws {
        let me = try requireMe()
        do {
            if on {
                try await client.from("likes").upsert(["user_id": me.id, "photo_id": photo],
                                                      onConflict: "user_id,photo_id",
                                                      returning: .minimal, ignoreDuplicates: true).execute()
            } else {
                try await client.from("likes").delete(returning: .minimal)
                    .eq("user_id", value: me.id).eq("photo_id", value: photo).execute()
            }
        } catch {
            throw Self.map(error)
        }
    }

    func report(_ photo: UUID, reason: String, note: String?) async throws {
        let me = try requireMe()
        do {
            try await client.from("reports")
                .insert(ReportRow(reporter: me.id, photoID: photo, reason: reason, note: note), returning: .minimal)
                .execute()
        } catch let error as PostgrestError where error.code == "23505" {
            return  // already reported by me
        } catch {
            throw Self.map(error)
        }
    }

    func block(_ owner: UUID) async throws {
        let me = try requireMe()
        do {
            try await client.from("blocks").upsert(["blocker": me.id, "blocked": owner],
                                                   onConflict: "blocker,blocked",
                                                   returning: .minimal, ignoreDuplicates: true).execute()
        } catch {
            throw Self.map(error)
        }
    }

    // MARK: Files

    func displayURL(_ photo: MomentPhoto) -> URL {
        imageBase.appending(path: "p/\(photo.id.uuidString.lowercased())/display.jpg")
    }

    func thumbURL(_ photo: MomentPhoto) -> URL {
        imageBase.appending(path: "p/\(photo.id.uuidString.lowercased())/thumb")
    }

    private func loadImageBase() async {
        struct Row: Decodable { let value: String }
        if let row: Row = try? await client.from("app_config").select("value")
            .eq("key", value: "image_base_url").single().execute().value,
           let url = URL(string: row.value) {
            imageBase = url
        }
    }

    // MARK: Helpers

    private func requireMe() throws -> MomentProfile {
        guard let me else { throw MomentError.signedOut }
        return me
    }

    /// Calls an Edge Function and maps its `{ error, detail }` replies to `MomentError`.
    private func invoke<Body: Encodable, Response: Decodable>(_ name: String, body: Body) async throws -> Response {
        do {
            return try await client.functions.invoke(
                name, options: FunctionInvokeOptions(body: body, encoder: Self.encoder), decoder: Self.decoder)
        } catch FunctionsError.httpError(let code, let data) {
            let reply = try? JSONDecoder().decode(FunctionErrorReply.self, from: data)
            throw Self.momentError(code: reply?.error, detail: reply?.detail) ?? MomentError.server("\(name) \(code)")
        } catch {
            throw Self.map(error)
        }
    }

    private static func momentError(code: String?, detail: String?) -> MomentError? {
        let n = detail.flatMap(Int.init) ?? 0
        switch code {
        case "signed_out": return .signedOut
        case "needs_handle": return .needsHandle
        case "wall_full": return .wallFull(limit: n)
        case "daily_upload_limit": return .dailyUploadLimit(n)
        case "monthly_share_limit": return .monthlyShareLimit(n)
        case "not_shareable": return .notShareable
        case "not_found": return .notFound
        case "upload_mismatch": return .uploadFailed
        case "handle_taken": return .handleTaken
        case "invalid_handle": return .invalidName("사용할 수 없는 사용자명이에요.")
        case "handle_change_too_soon": return .handleChangeTooSoon(detail.flatMap(parseTimestamp))
        default: return nil
        }
    }

    /// Database functions raise their code in the message (see 20261110000000_moment_upload.sql).
    private static func map(_ error: Error) -> Error {
        if error is MomentError { return error }
        if let pg = error as? PostgrestError {
            return momentError(code: pg.message, detail: pg.details) ?? MomentError.server(pg.message)
        }
        return error
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    /// Edge Function replies carry Postgres timestamps ("2026-11-10T12:00:00.123456+00:00").
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = parseTimestamp(text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Bad date \(text)"))
        }
        return d
    }()

    static func parseTimestamp(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? plain.date(from: text)
    }
}

// MARK: - Wire types

private struct Empty: Codable {}

private struct FunctionErrorReply: Decodable {
    let error: String?
    let detail: String?
}

private struct PresignedPut: Decodable {
    let url: URL
    let headers: [String: String]
}

private struct UploadRequest: Encodable {
    let width, height, thumbWidth, thumbHeight, displayBytes, thumbBytes: Int
    let thumbType: String
    let caption: String?
    let info: MomentShotInfo

    enum CodingKeys: String, CodingKey {
        case width, height, caption, info
        case thumbWidth = "thumb_width", thumbHeight = "thumb_height"
        case displayBytes = "display_bytes", thumbBytes = "thumb_bytes", thumbType = "thumb_type"
    }
}

private struct UploadStart: Decodable {
    let id: UUID
    let display: PresignedPut
    let thumb: PresignedPut
}

private struct PublishRequest: Encodable {
    let id: UUID
    let shareNow: Bool
    enum CodingKeys: String, CodingKey { case id, shareNow = "share_now" }
}

private struct PublishResult: Decodable {
    let photo: PhotoRow
    let shareError: String?
    enum CodingKeys: String, CodingKey { case photo, shareError = "share_error" }
}

private struct Limits: Decodable {
    let value: Value
    struct Value: Decodable {
        let sharesPerMonth: Int
        enum CodingKeys: String, CodingKey { case sharesPerMonth = "shares_per_month" }
    }
}

private struct ProfileRow: Decodable {
    let id: UUID
    let handle: String?
    let displayName: String?
    let bio: String?
    let wallStyle: String
    let wallLimit: Int
    let handleChangedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, handle, bio
        case displayName = "display_name", wallStyle = "wall_style", wallLimit = "wall_limit"
        case handleChangedAt = "handle_changed_at"
    }

    var profile: MomentProfile {
        MomentProfile(id: id, handle: handle, displayName: displayName, bio: bio,
                      wallStyle: MomentProfile.WallStyle(rawValue: wallStyle) ?? .grid, wallLimit: wallLimit,
                      handleChangedAt: handleChangedAt)
    }
}

private struct PhotoRow: Decodable {
    static let columns = "id,owner,status,caption,width,height,thumb_width,thumb_height,camera,exposure,image_control,taken_at,lat,lon,place,like_count,created_at,shared_at"

    let id: UUID
    let owner: UUID
    let status: MomentPhoto.Status
    let caption: String?
    let width, height, thumbWidth, thumbHeight, likeCount: Int
    let camera: String?
    let exposure: MomentShotInfo.Exposure?
    let imageControl: MomentShotInfo.ImageControl?
    let takenAt: Date?
    let lat, lon: Double?
    let place: String?
    let createdAt: Date
    let sharedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, owner, status, caption, width, height, camera, exposure, lat, lon, place
        case thumbWidth = "thumb_width", thumbHeight = "thumb_height", likeCount = "like_count"
        case imageControl = "image_control", takenAt = "taken_at"
        case createdAt = "created_at", sharedAt = "shared_at"
    }

    var photo: MomentPhoto {
        MomentPhoto(id: id, owner: owner, status: status, caption: caption, width: width, height: height,
                    thumbWidth: thumbWidth, thumbHeight: thumbHeight,
                    info: MomentShotInfo(camera: camera, exposure: exposure, imageControl: imageControl,
                                         takenAt: takenAt, lat: lat, lon: lon, place: place),
                    likeCount: likeCount, createdAt: createdAt, sharedAt: sharedAt)
    }
}

private struct WallItemRow: Codable {
    let photoID: UUID
    let owner: UUID
    let x, y, width, rotation: Double
    let z, gridOrder: Int
    let gridSpan: String

    enum CodingKeys: String, CodingKey {
        case owner, x, y, width, z, rotation
        case photoID = "photo_id", gridOrder = "grid_order", gridSpan = "grid_span"
    }

    init(item: WallItem, owner: UUID) {
        photoID = item.photoID
        self.owner = owner
        x = item.x; y = item.y; width = item.width; rotation = item.rotation
        z = item.z; gridOrder = item.gridOrder; gridSpan = item.gridSpan.rawValue
    }

    var item: WallItem {
        WallItem(photoID: photoID, x: x, y: y, width: width, z: z, rotation: rotation,
                 gridOrder: gridOrder, gridSpan: WallItem.GridSpan(rawValue: gridSpan) ?? .one)
    }
}

private struct ReportRow: Encodable {
    let reporter: UUID
    let photoID: UUID
    let reason: String
    let note: String?
    enum CodingKeys: String, CodingKey { case reporter, reason, note, photoID = "photo_id" }
}

/// Writes every shot-info column, including nulls, so turning a group off clears it.
private struct InfoUpdate: Encodable {
    let info: MomentShotInfo
    let caption: String?

    enum CodingKeys: String, CodingKey {
        case caption, camera, exposure, lat, lon, place
        case imageControl = "image_control", takenAt = "taken_at"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(caption, forKey: .caption)
        try c.encode(info.camera, forKey: .camera)
        try c.encode(info.exposure, forKey: .exposure)
        try c.encode(info.imageControl, forKey: .imageControl)
        try c.encode(info.takenAt, forKey: .takenAt)
        try c.encode(info.lat, forKey: .lat)
        try c.encode(info.lon, forKey: .lon)
        try c.encode(info.place, forKey: .place)
    }
}
