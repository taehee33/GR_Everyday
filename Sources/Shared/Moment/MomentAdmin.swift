import Foundation
import Supabase

/// 설정 › 계정 › 어드민: what the people in `admins` can change from the app. Every call goes to
/// an admin_* database function that checks is_admin() itself, so this is only the client side
/// (supabase/migrations/20261114060000_moment_admin.sql, PLAN-admin.md).
@MainActor
final class MomentAdmin: ObservableObject {
    static let shared = MomentAdmin()

    @Published private(set) var isAdmin = false

    private let client: SupabaseClient

    init(client: SupabaseClient = MomentBackend.client) {
        self.client = client
    }

    /// Asks the server whether I am an admin. Only the real server has admins (not -momentMock).
    func refresh(account: MomentAccount) async {
        guard account.store is SupabaseMomentStore, account.state == .ready else {
            isAdmin = false
            return
        }
        isAdmin = (try? await client.rpc("is_admin").execute().value as Bool) ?? false
    }

    // MARK: 어드민 명단

    struct Member: Decodable, Identifiable, Equatable {
        let userID: UUID
        let handle: String?
        let displayName: String?
        let createdAt: Date
        var id: UUID { userID }
        enum CodingKeys: String, CodingKey {
            case userID = "user_id", handle, displayName = "display_name", createdAt = "created_at"
        }
    }

    func members() async throws -> [Member] {
        try await call { try await self.client.rpc("admin_list").execute().value }
    }

    func addMember(handle: String) async throws {
        try await run { try await self.client.rpc("admin_add", params: ["p_handle": handle]).execute() }
    }

    func removeMember(_ id: UUID) async throws {
        try await run { try await self.client.rpc("admin_remove", params: ["p_user": id]).execute() }
    }

    // MARK: 사용자

    struct User: Decodable, Identifiable, Equatable {
        let id: UUID
        let handle: String?
        let displayName: String?
        let createdAt: Date
        var wallUsed: Int
        var wallLimit: Int
        /// Their own wall limit; false = it follows the default.
        var wallOwn: Bool
        var sharesUsed: Int
        var sharesLimit: Int
        /// This person's own monthly limit; nil = the default.
        var sharesOverride: Int?
        let isAdmin: Bool

        var name: String { displayName ?? handle ?? "이름 없음" }

        enum CodingKeys: String, CodingKey {
            case id, handle, displayName = "display_name", createdAt = "created_at",
                 wallUsed = "wall_used", wallLimit = "wall_limit", wallOwn = "wall_own", sharesUsed = "shares_used",
                 sharesLimit = "shares_limit", sharesOverride = "shares_override", isAdmin = "is_admin"
        }
    }

    func users(search: String) async throws -> [User] {
        struct Params: Encodable { let p_search: String; let p_limit: Int }
        return try await call {
            try await self.client.rpc("admin_users", params: Params(p_search: search, p_limit: 100)).execute().value
        }
    }

    /// nil = back to the default.
    func setWallLimit(_ user: UUID, _ limit: Int?) async throws {
        try await run {
            try await self.client.rpc("admin_set_wall_limit", params: UserLimit(p_user: user, p_limit: limit)).execute()
        }
    }

    /// nil = back to the default.
    func setShareLimit(_ user: UUID, _ limit: Int?) async throws {
        try await run {
            try await self.client.rpc("admin_set_share_limit", params: UserLimit(p_user: user, p_limit: limit)).execute()
        }
    }

    /// Sends a null limit as null rather than leaving it out.
    private struct UserLimit: Encodable {
        let p_user: UUID
        let p_limit: Int?
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(p_user, forKey: .p_user)
            try c.encode(p_limit, forKey: .p_limit)
        }
        enum CodingKeys: CodingKey { case p_user, p_limit }
    }

    // MARK: 기본값

    struct Defaults: Codable, Equatable {
        var sharesPerMonth: Int
        var wallPhotosFree: Int
        enum CodingKeys: String, CodingKey {
            case sharesPerMonth = "shares_per_month", wallPhotosFree = "wall_photos_free"
        }
    }

    func defaults() async throws -> Defaults {
        let rows: [Defaults] = try await call { try await self.client.rpc("admin_defaults").execute().value }
        return rows.first ?? Defaults(sharesPerMonth: 3, wallPhotosFree: 15)
    }

    func setDefaults(_ value: Defaults) async throws {
        struct Params: Encodable { let p_shares_per_month: Int; let p_wall_photos_free: Int }
        try await run {
            try await self.client.rpc("admin_set_defaults", params: Params(
                p_shares_per_month: value.sharesPerMonth, p_wall_photos_free: value.wallPhotosFree)).execute()
        }
    }

    // MARK: 당선작

    struct Contest: Decodable, Identifiable, Equatable {
        /// "2026-11-01"
        let month: String
        var title: String
        var theme: String?
        var intro: String?
        var winner: UUID?
        var announcedAt: Date?
        var id: String { month }

        /// "2026년 11월"
        var monthTitle: String {
            MomentContest(month: month, title: title).longMonthTitle
        }

        enum CodingKeys: String, CodingKey {
            case month, title, theme, intro, winner, announcedAt = "announced_at"
        }
    }

    struct Candidate: Decodable, Identifiable, Equatable {
        let rank: Int
        let photoID: UUID
        let likes: Int
        let likesNow: Int
        let author: String?
        let caption: String?
        let sharedAt: Date?
        let thumbURL: String?
        var id: UUID { photoID }
        enum CodingKeys: String, CodingKey {
            case rank, photoID = "photo_id", likes, likesNow = "likes_now", author, caption,
                 sharedAt = "shared_at", thumbURL = "thumb_url"
        }
    }

    func contests() async throws -> [Contest] {
        try await call {
            try await self.client.from("contests").select("month,title,theme,intro,winner,announced_at")
                .order("month", ascending: false).execute().value
        }
    }

    func saveContest(month: String, title: String, theme: String, intro: String) async throws {
        try await run {
            try await self.client.rpc("admin_save_contest", params: [
                "p_month": month, "p_title": title, "p_theme": theme, "p_intro": intro,
            ]).execute()
        }
    }

    func deleteContest(month: String) async throws {
        try await run { try await self.client.rpc("admin_delete_contest", params: ["p_month": month]).execute() }
    }

    /// nil takes the winner back out (and the month shows as not announced again).
    func setWinner(month: String, photo: UUID?) async throws {
        struct Params: Encodable {
            let p_month: String; let p_photo: UUID?
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(p_month, forKey: .p_month)
                try c.encode(p_photo, forKey: .p_photo)
            }
            enum CodingKeys: CodingKey { case p_month, p_photo }
        }
        try await run {
            try await self.client.rpc("admin_set_winner", params: Params(p_month: month, p_photo: photo)).execute()
        }
    }

    func ranking(month: String) async throws -> [Candidate] {
        struct Params: Encodable { let p_month: String; let p_limit: Int }
        return try await call {
            try await self.client.rpc("admin_contest_ranking", params: Params(p_month: month, p_limit: 50))
                .execute().value
        }
    }

    // MARK: Errors

    enum Failure: LocalizedError {
        case notAdmin, notFound, lastAdmin, invalidValue, other(String)
        var errorDescription: String? {
            switch self {
            case .notAdmin: "어드민만 할 수 있어요."
            case .notFound: "찾을 수 없어요."
            case .lastAdmin: "마지막 어드민은 뺄 수 없어요."
            case .invalidValue: "값을 확인해 주세요."
            case .other(let message): message
            }
        }
    }

    private func call<T>(_ body: @escaping () async throws -> T) async throws -> T {
        do { return try await body() } catch { throw Self.map(error) }
    }

    private func run(_ body: @escaping () async throws -> some Any) async throws {
        do { _ = try await body() } catch { throw Self.map(error) }
    }

    private static func map(_ error: Error) -> Error {
        guard let pg = error as? PostgrestError else { return error }
        switch pg.message {
        case "not_admin": return Failure.notAdmin
        case "not_found": return Failure.notFound
        case "last_admin": return Failure.lastAdmin
        case "invalid_value": return Failure.invalidValue
        default: return Failure.other(pg.message)
        }
    }
}
