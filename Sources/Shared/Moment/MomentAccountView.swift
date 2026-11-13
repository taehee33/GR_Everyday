import AuthenticationServices
import CryptoKit
import SwiftUI

/// The signed-in 순간들 (Moments) account, shared by the tab's screens.
@MainActor
final class MomentAccount: ObservableObject {
    enum State: Equatable {
        case loading
        case signedOut
        /// Signed in but no handle yet; needed before the first upload.
        case needsHandle
        case ready
    }

    /// The two names a person has: the unique @handle and the display name shown on photos.
    enum NameKind { case handle, displayName }

    /// Live verdict on a name being typed: format first, then "is it free?" from the server.
    enum NameCheck: Equatable {
        case empty
        case invalid(String)
        case checking
        case available
        case taken
        /// Same as the name I already have.
        case current

        var canSave: Bool { self == .available }
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var me: MomentProfile?
    /// "Google · name@example.com": which sign-in this is, so a wrong account is easy to spot.
    @Published private(set) var signInLabel: String?
    /// Reports I filed (설정 › 계정 › 신고 내역).
    @Published private(set) var reports: [MomentReport]?
    @Published private(set) var quota: MomentQuota?
    @Published var errorMessage: String?
    @Published private(set) var busy = false
    @Published private(set) var handleCheck: NameCheck = .empty
    @Published private(set) var displayNameCheck: NameCheck = .empty
    /// My uploaded photos, newest first.
    @Published private(set) var myPhotos: [MomentPhoto] = []
    /// Where each of my photos hangs on my wall (both layouts).
    @Published private(set) var wallItems: [UUID: WallItem] = [:]
    /// Which of my photos I liked myself (the heart on 내 사진).
    @Published private(set) var likedMine: Set<UUID> = []
    private var checkTasks: [NameKind: Task<Void, Never>] = [:]

    /// Reads whether I liked this photo of mine.
    func loadLike(_ id: UUID) async {
        guard store.me != nil, let on = try? await store.likes(among: [id]) else { return }
        if on.contains(id) { likedMine.insert(id) } else { likedMine.remove(id) }
    }

    /// Likes or unlikes one of my photos: shown at once, put back if the server says no.
    func toggleLike(_ id: UUID) async {
        guard store.me != nil else { errorMessage = MomentError.signedOut.localizedDescription; return }
        let on = !likedMine.contains(id)
        applyLike(id, on)
        do {
            try await store.like(id, on)
        } catch {
            applyLike(id, !on)
            show(error)
        }
    }

    private func applyLike(_ id: UUID, _ on: Bool) {
        if on { likedMine.insert(id) } else { likedMine.remove(id) }
        if let i = myPhotos.firstIndex(where: { $0.id == id }) {
            myPhotos[i].likeCount = max(myPhotos[i].likeCount + (on ? 1 : -1), 0)
        }
    }

    let store: MomentStore
    /// The shared photos everyone sees; kept here so the tab's screens use one copy.
    let feed: MomentFeed
    /// Photos I liked (설정 › 계정 › 좋아요한 사진).
    let likedFeed: MomentFeed

    /// One account for the whole app: the 순간들 tab and 설정 › 계정 show the same sign-in.
    static let shared: MomentAccount = {
        #if DEBUG
        // Launch with -momentMock to see the screens with a signed-in sample account and
        // photos, without touching the server.
        if ProcessInfo.processInfo.arguments.contains("-momentMock") {
            return MomentAccount(store: MockMomentStore.sample())
        }
        #endif
        return MomentAccount()
    }()
    /// The raw nonce of the Sign in with Apple request in flight; Supabase checks its hash.
    private var nonce: String?

    init(store: MomentStore = SupabaseMomentStore()) {
        self.store = store
        self.feed = MomentFeed(store: store)
        self.likedFeed = MomentFeed(store: store, source: .liked)
    }

    func load() async {
        await run { try await self.store.refreshMe() }
    }

    func prepare(_ request: ASAuthorizationAppleIDRequest) {
        let raw = Self.randomNonce()
        nonce = raw
        request.requestedScopes = []
        request.nonce = Self.sha256(raw)
    }

    func complete(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code != .canceled {
                errorMessage = "Apple 로그인에 실패했어요. (\(error.localizedDescription))"
            }
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let data = credential.identityToken, let token = String(data: data, encoding: .utf8),
                  let nonce else {
                errorMessage = "Apple 로그인 정보를 읽지 못했어요."
                return
            }
            await run { try await self.store.signInWithApple(idToken: token, nonce: nonce) }
        }
    }

    func signInWithGoogle() async {
        await run {
            do {
                try await self.store.signInWithGoogle()
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                return
            }
        }
    }

    // MARK: Names

    func check(_ kind: NameKind) -> NameCheck {
        kind == .handle ? handleCheck : displayNameCheck
    }

    private func setCheck(_ kind: NameKind, _ value: NameCheck) {
        if kind == .handle { handleCheck = value } else { displayNameCheck = value }
    }

    static func normalize(_ text: String, _ kind: NameKind) -> String {
        kind == .handle ? MomentProfile.normalizeHandle(text) : MomentProfile.normalizeDisplayName(text)
    }

    /// Called as the user types: checks the format at once, then asks the server whether the
    /// name is free (after a short pause, so not on every keystroke).
    func checkName(_ text: String, _ kind: NameKind) {
        checkTasks[kind]?.cancel()
        let name = Self.normalize(text, kind)
        let current = kind == .handle ? me?.handle : me?.displayName
        if name.isEmpty { setCheck(kind, .empty); return }
        let problem = kind == .handle ? MomentProfile.handleProblem(name) : MomentProfile.displayNameProblem(name)
        if let problem { setCheck(kind, .invalid(problem)); return }
        if let current, Self.normalize(current, kind).lowercased() == name.lowercased(), name == current {
            setCheck(kind, .current); return
        }
        setCheck(kind, .checking)
        checkTasks[kind] = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let free = try? await (kind == .handle ? store.isHandleAvailable(name) : store.isDisplayNameAvailable(name))
            guard !Task.isCancelled else { return }
            switch free {
            case true?: setCheck(kind, .available)
            case false?: setCheck(kind, .taken)
            case nil: setCheck(kind, .invalid("확인하지 못했어요. 인터넷 연결을 확인해 주세요."))
            }
        }
    }

    /// Saves a name (first time or a change). Returns true when it was saved.
    @discardableResult
    func saveName(_ text: String, _ kind: NameKind) async -> Bool {
        let name = Self.normalize(text, kind)
        guard check(kind).canSave else { return false }
        await run {
            if kind == .handle { try await self.store.setHandle(name) } else { try await self.store.setDisplayName(name) }
        }
        let saved = (kind == .handle ? me?.handle : me?.displayName) == name
        if saved { setCheck(kind, .current) }
        if errorMessage == MomentError.handleTaken.errorDescription
            || errorMessage == MomentError.displayNameTaken.errorDescription { setCheck(kind, .taken) }
        return saved
    }

    /// First-time setup: handle, then display name. Returns true when both were saved.
    @discardableResult
    func saveNames(handle: String, displayName: String) async -> Bool {
        guard handleCheck.canSave, displayNameCheck.canSave else { return false }
        guard await saveName(handle, .handle) else { return false }
        return await saveName(displayName, .displayName)
    }

    /// Reloads my photos and the wall/share counts (after an upload, for example).
    func reloadPhotos() async {
        guard let me = store.me else { myPhotos = []; wallItems = [:]; return }
        if let wall = try? await store.wall(of: me.id) {
            myPhotos = wall.photos
            wallItems = Dictionary(wall.items.map { ($0.photoID, $0) }, uniquingKeysWith: { a, _ in a })
        }
        quota = try? await store.quota()
    }

    /// Saves 프로필 편집: the texts, then the picture (`avatar`: nil = unchanged, .some(nil) =
    /// remove). False when something failed; errorMessage says what.
    func saveProfile(_ edit: MomentProfileEdit, avatar: Data??) async -> Bool {
        errorMessage = nil
        do {
            try await store.updateProfile(edit)
            if let avatar { try await store.setAvatar(avatar) }
            me = store.me
            return true
        } catch {
            me = store.me
            show(error)
            return false
        }
    }

    /// Saves how my wall looks: the view (갤러리/그리드), the gallery's direction, and any moved
    /// frames. Shows the change at once and puts it back if the server says no.
    @discardableResult
    func saveWall(style: MomentProfile.WallStyle, direction: MomentProfile.WallDirection,
                  items: [WallItem]) async -> Bool {
        let before = (me, wallItems)
        me?.wallStyle = style
        me?.wallDirection = direction
        for item in items { wallItems[item.photoID] = item }
        do {
            try await store.saveWall(style: style, direction: direction, items: items)
            if let saved = store.me {
                // The server may not keep the direction yet (column not there); keep what was chosen.
                me = saved
                me?.wallDirection = direction
            }
            return true
        } catch {
            (me, wallItems) = before
            show(error)
            return false
        }
    }

    func reloadReports() async {
        do {
            reports = try await store.myReports()
        } catch {
            show(error)
        }
    }

    // MARK: My photos

    func share(_ photo: MomentPhoto) async {
        await act { _ = try await self.store.share(photo.id) }
    }

    func unshare(_ photo: MomentPhoto) async {
        await act { try await self.store.unshare(photo.id) }
    }

    @discardableResult
    func delete(_ photo: MomentPhoto) async -> Bool {
        await act { try await self.store.delete(photo.id) }
    }

    /// Runs one photo action, then reloads my photos and counts. False when it failed.
    @discardableResult
    private func act(_ work: @escaping () async throws -> Void) async -> Bool {
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            try await work()
            await reloadPhotos()
            // Sharing, unsharing and deleting change what the feed shows.
            if feed.loaded { await feed.reload() }
            return true
        } catch {
            show(error)
            return false
        }
    }

    // MARK: Account

    func signOut() async {
        await run { try await self.store.signOut() }
        handleCheck = .empty
        displayNameCheck = .empty
    }

    func deleteAccount() async {
        await run { try await self.store.deleteAccount() }
        handleCheck = .empty
        displayNameCheck = .empty
    }

    /// Puts an error on screen, except a cancelled request: closing a sheet or leaving a screen
    /// cancels its loading, and that is not something the person needs to hear about.
    private func show(_ error: Error) {
        if error.isCancellation || Task.isCancelled { return }
        errorMessage = error.localizedDescription
    }

    private func run(_ work: @escaping () async throws -> Void) async {
        busy = true
        errorMessage = nil
        do {
            try await work()
        } catch {
            show(error)
        }
        let previous = me?.id
        me = store.me
        signInLabel = store.signInLabel
        if previous != me?.id {
            // Another account (or none): nothing of the last one may stay on screen.
            myPhotos = []
            reports = nil
            likedFeed.clear()
        }
        quota = me?.handle != nil ? try? await store.quota() : nil
        state = me == nil ? .signedOut : (me?.handle == nil ? .needsHandle : .ready)
        if state == .ready, myPhotos.isEmpty { await reloadPhotos() }
        if state != .ready { myPhotos = [] }
        busy = false
    }

    static func randomNonce(length: Int = 32) -> String {
        let chars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in chars.randomElement(using: &generator)! })
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// 내 갤러리: sign in, pick names the first time, then upload and see my photos. Changing
/// names, logging out and leaving live in 설정 › 계정 (MomentAccountSection).
struct MomentAccountView: View {
    @ObservedObject var account: MomentAccount
    @EnvironmentObject private var library: LibraryModel
    @State private var uploading = false

    var body: some View {
        VStack(spacing: 14) {
            switch account.state {
            case .loading:
                ProgressView()
            case .signedOut:
                Text("사진을 업로드하고 순간들에 공유하려면 로그인해 주세요.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                MomentSignInButtons(account: account)
            case .needsHandle:
                MomentNamesSetup(account: account)
            case .ready:
                MomentProfileHeader(account: account) { uploading = true }
                MomentWallView(account: account) { uploading = true }
            }
            if let message = account.errorMessage {
                Text(message).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
        .disabled(account.busy)
        .task { if account.state == .loading { await account.load() } }
        .sheet(isPresented: $uploading) {
            MomentUploadView(account: account, saveFolder: library.destination)
        }
    }

    // The Apple and Google buttons share one size and shape so they read as a pair.
    // On the Mac, Apple's button keeps its own ~30 pt height and 13 pt semibold label whatever
    // frame it gets, so the pair follows that there.
    #if os(macOS)
    static let buttonWidth: CGFloat = 280
    static let buttonHeight: CGFloat = 30
    static let buttonRadius: CGFloat = 6
    #else
    static let buttonWidth: CGFloat = 280
    static let buttonHeight: CGFloat = 44
    static let buttonRadius: CGFloat = 8
    #endif
}

/// Sign in with Apple and Google, as a pair.
struct MomentSignInButtons: View {
    @ObservedObject var account: MomentAccount
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 10) {
            SignInWithAppleButton(.signIn) { request in
                account.prepare(request)
            } onCompletion: { result in
                Task { await account.complete(result) }
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(maxWidth: MomentAccountView.buttonWidth, minHeight: MomentAccountView.buttonHeight,
                   maxHeight: MomentAccountView.buttonHeight)
            .clipShape(RoundedRectangle(cornerRadius: MomentAccountView.buttonRadius, style: .continuous))
            GoogleSignInButton(height: MomentAccountView.buttonHeight, radius: MomentAccountView.buttonRadius) {
                Task { await account.signInWithGoogle() }
            }
            .frame(maxWidth: MomentAccountView.buttonWidth)
            Text("Apple과 Google은 서로 다른 계정이에요. 전에 쓰던 방법으로 로그인해 주세요.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 300)
        }
    }
}

/// A new account's first step: both names, and which sign-in this is, with a way out when it
/// is not the account the person meant to use.
struct MomentNamesSetup: View {
    @ObservedObject var account: MomentAccount
    @State private var confirmSignOut = false
    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text("처음 로그인한 계정이에요").font(.headline)
                if let label = account.signInLabel {
                    Text(label).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text("사용자명과 표시 이름을 정하면 시작할 수 있어요. 전에 쓰던 계정이 따로 있다면 로그아웃한 뒤 그때 쓴 방법(Apple 또는 Google, 같은 메일)으로 로그인해 주세요.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 320)
            }
            SetupNamesForm(account: account)
            HStack(spacing: 12) {
                Button("로그아웃") { confirmSignOut = true }
                Button("탈퇴", role: .destructive) { confirmDelete = true }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .momentSignOutAlert(account: account, isPresented: $confirmSignOut)
        .momentDeleteAlert(account: account, isPresented: $confirmDelete)
    }
}

/// A name field that says right away whether the name can be used (green when the format is
/// right, red when not or when someone else has it); saving works only once the server says it
/// is free.
struct NameEditor: View {
    @ObservedObject var account: MomentAccount
    let kind: MomentAccount.NameKind
    let saveTitle: String
    var initial = ""
    var onSaved: () -> Void = {}
    @State private var text = ""

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                NameField(kind: kind, text: $text, onSubmit: save)
                Button(saveTitle, action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(!account.check(kind).canSave || account.busy)
            }
            .frame(maxWidth: 300)
            NameStatus(kind: kind, check: account.check(kind))
                .frame(maxWidth: 300, alignment: .leading)
        }
        .onAppear {
            text = initial
            account.checkName(initial, kind)
        }
        .onChange(of: text) { _, new in account.checkName(new, kind) }
    }

    private func save() {
        Task { if await account.saveName(text, kind) { onSaved() } }
    }
}

/// First sign-in: @handle and display name on one screen, saved together.
struct SetupNamesForm: View {
    @ObservedObject var account: MomentAccount
    @State private var handle = ""
    @State private var displayName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("사용자명").font(.subheadline.weight(.semibold))
                NameField(kind: .handle, text: $handle, onSubmit: save)
                NameStatus(kind: .handle, check: account.handleCheck)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("표시 이름").font(.subheadline.weight(.semibold))
                NameField(kind: .displayName, text: $displayName, onSubmit: save)
                NameStatus(kind: .displayName, check: account.displayNameCheck)
            }
            Button(action: save) {
                Text("시작하기").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!account.handleCheck.canSave || !account.displayNameCheck.canSave || account.busy)
        }
        .frame(maxWidth: 300)
        .onChange(of: handle) { _, new in account.checkName(new, .handle) }
        .onChange(of: displayName) { _, new in account.checkName(new, .displayName) }
    }

    private func save() {
        Task { await account.saveNames(handle: handle, displayName: displayName) }
    }
}

/// One text box; empty fields show a translucent hint. Usernames have no "@": it is not
/// part of the name anywhere (database, links), and it read like an Instagram handle.
private struct NameField: View {
    let kind: MomentAccount.NameKind
    @Binding var text: String
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 1) {
            TextField("", text: $text, prompt: Text(kind == .handle ? "사용자명 (영문)" : "표시 이름").foregroundStyle(.tertiary))
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(kind == .handle ? .asciiCapable : .default)
                #endif
                .onSubmit(onSubmit)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.separator))
    }
}

/// Green when the format is right (and the name is free), red when it is not.
private struct NameStatus: View {
    let kind: MomentAccount.NameKind
    let check: MomentAccount.NameCheck

    var body: some View {
        content.font(.footnote)
    }

    @ViewBuilder private var content: some View {
        switch check {
        case .empty:
            Text(kind == .handle ? "영문, 숫자, _ . 로 2–20자" : "한글, 영문, 이모지 모두 가능 · 1–20자")
                .foregroundStyle(.secondary)
        case .invalid(let reason):
            Label(reason, systemImage: "xmark.circle.fill").foregroundStyle(.red)
        case .checking:
            Label("형식이 맞아요 · 중복 확인 중…", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .available:
            Label("사용할 수 있어요", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .taken:
            Label(kind == .handle ? "이미 쓰고 있거나 보호 중인 사용자명이에요" : "이미 쓰고 있는 표시 이름이에요",
                  systemImage: "xmark.circle.fill").foregroundStyle(.red)
        case .current:
            Label("지금 쓰고 있는 이름이에요", systemImage: "checkmark.circle").foregroundStyle(.green)
        }
    }
}

/// "Sign in with Google" drawn to sit next to Apple's button: same size, corners and type,
/// with Google's own colours (branding guidelines: light theme #FFFFFF / #1F1F1F with a
/// #747775 border, dark theme #131314 / #E3E3E3 with a #8E918F border) and the official "G".
/// Like the Apple button it is light on a dark screen and dark on a light one.
struct GoogleSignInButton: View {
    var height: CGFloat = 44
    var radius: CGFloat = 8
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    /// Matches the wording the Apple button uses on each platform.
    static var title: String {
        #if os(macOS)
        "Sign in with Google"
        #else
        "Google로 로그인"
        #endif
    }

    // Sized to Apple's button on each platform (see MomentAccountView.buttonHeight).
    #if os(macOS)
    // Measured from Apple's button on macOS 27: ~11 pt semibold label, ~10 pt logo, 4 pt gap.
    static let fontSize: CGFloat = 11
    static let fontWeight: Font.Weight = .semibold
    static let logoSize: CGFloat = 10
    static let spacing: CGFloat = 4
    #else
    static let fontSize: CGFloat = 17.5
    static let fontWeight: Font.Weight = .medium
    static let logoSize: CGFloat = 17.5
    static let spacing: CGFloat = 10
    #endif

    var body: some View {
        let light = colorScheme == .dark
        Button(action: action) {
            HStack(spacing: Self.spacing) {
                Image("GoogleG")
                    .resizable()
                    .frame(width: Self.logoSize, height: Self.logoSize)
                Text(Self.title)
                    .font(.system(size: Self.fontSize, weight: Self.fontWeight))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(light ? Color(red: 0x1F / 255, green: 0x1F / 255, blue: 0x1F / 255)
                                   : Color(red: 0xE3 / 255, green: 0xE3 / 255, blue: 0xE3 / 255))
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .background(light ? Color.white : Color(red: 0x13 / 255, green: 0x13 / 255, blue: 0x14 / 255),
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(light ? Color(red: 0x74 / 255, green: 0x77 / 255, blue: 0x75 / 255)
                                        : Color(red: 0x8E / 255, green: 0x91 / 255, blue: 0x8F / 255),
                                  lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.title)
    }
}

extension Error {
    /// A request that was called off (sheet closed, screen left), not one that failed.
    var isCancellation: Bool {
        if self is CancellationError { return true }
        let ns = self as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }
}
