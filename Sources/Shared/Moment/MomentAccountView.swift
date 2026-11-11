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
    @Published private(set) var quota: MomentQuota?
    @Published var errorMessage: String?
    @Published private(set) var busy = false
    @Published private(set) var handleCheck: NameCheck = .empty
    @Published private(set) var displayNameCheck: NameCheck = .empty
    /// My uploaded photos, newest first.
    @Published private(set) var myPhotos: [MomentPhoto] = []
    private var checkTasks: [NameKind: Task<Void, Never>] = [:]

    let store: MomentStore
    /// The raw nonce of the Sign in with Apple request in flight; Supabase checks its hash.
    private var nonce: String?

    init(store: MomentStore = SupabaseMomentStore()) {
        self.store = store
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
        guard let me = store.me else { myPhotos = []; return }
        if let wall = try? await store.wall(of: me.id) { myPhotos = wall.photos }
        quota = try? await store.quota()
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
            return true
        } catch {
            errorMessage = error.localizedDescription
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

    private func run(_ work: @escaping () async throws -> Void) async {
        busy = true
        errorMessage = nil
        do {
            try await work()
        } catch {
            errorMessage = error.localizedDescription
        }
        me = store.me
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

/// Sign in, pick names, and see the account: the part of the 순간들 tab that exists so far.
struct MomentAccountView: View {
    @ObservedObject var account: MomentAccount
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var confirmDelete = false
    @State private var editing: MomentAccount.NameKind?
    @State private var uploading = false

    var body: some View {
        VStack(spacing: 14) {
            switch account.state {
            case .loading:
                ProgressView()
            case .signedOut:
                Text("사진을 올리고 공유하려면 로그인해 주세요.")
                    .font(.callout).foregroundStyle(.secondary)
                SignInWithAppleButton(.signIn) { request in
                    account.prepare(request)
                } onCompletion: { result in
                    Task { await account.complete(result) }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(maxWidth: Self.buttonWidth, minHeight: Self.buttonHeight, maxHeight: Self.buttonHeight)
                .clipShape(RoundedRectangle(cornerRadius: Self.buttonRadius, style: .continuous))
                GoogleSignInButton(height: Self.buttonHeight, radius: Self.buttonRadius) {
                    Task { await account.signInWithGoogle() }
                }
                .frame(maxWidth: Self.buttonWidth)
            case .needsHandle:
                Text("사용자명과 표시 이름을 정해 주세요.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                SetupNamesForm(account: account)
                accountActions
            case .ready:
                profileHeader
                if let q = account.quota {
                    Text("벽 \(q.wallUsed)/\(q.wallLimit) · 이번 달 공유 \(q.sharesPerMonth - q.sharesLeft)/\(q.sharesPerMonth)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let kind = editing {
                    NameEditor(account: account, kind: kind, saveTitle: "저장",
                               initial: (kind == .handle ? account.me?.handle : account.me?.displayName) ?? "") {
                        editing = nil
                    }
                    if kind == .handle {
                        Text("사용자명은 30일에 한 번 바꿀 수 있고, 이전 사용자명은 14일 동안 다른 사람이 쓸 수 없어요.")
                            .font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).frame(maxWidth: 300)
                    }
                    Button("취소") { editing = nil }
                        .buttonStyle(.borderless).controlSize(.small)
                } else {
                    nameButtons
                }
                Button {
                    uploading = true
                } label: {
                    Label("사진 올리기", systemImage: "plus").frame(maxWidth: 240)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(account.quota?.wallFull == true)
                if account.quota?.wallFull == true {
                    Text("벽이 가득 찼어요. 사진을 내리면 새로 걸 수 있어요.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                MyMomentsGrid(account: account)
                accountActions
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
        .confirmationDialog("탈퇴할까요?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("탈퇴하고 모두 삭제", role: .destructive) { Task { await account.deleteAccount() } }
        } message: {
            Text("계정과 올린 사진, 벽, 공유 기록이 모두 지워지고 되돌릴 수 없어요.")
        }
    }

    /// 한태희 / @taehee, or just @taehee until a display name is set.
    @ViewBuilder private var profileHeader: some View {
        VStack(spacing: 2) {
            if let name = account.me?.displayName {
                Text(name).font(.title3.bold())
            }
            if let handle = account.me?.handle {
                Text("@\(handle)")
                    .font(account.me?.displayName == nil ? .headline : .subheadline)
                    .foregroundStyle(account.me?.displayName == nil ? .primary : .secondary)
            }
        }
    }

    private var nameButtons: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Button(account.me?.displayName == nil ? "표시 이름 정하기" : "표시 이름 변경") { editing = .displayName }
                Button("사용자명 변경") { editing = .handle }
                    .disabled(account.me?.nextHandleChange != nil)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            if let next = account.me?.nextHandleChange {
                Text("사용자명은 \(next.formatted(date: .long, time: .omitted))부터 바꿀 수 있어요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Log out and leave; shown on every signed-in step.
    private var accountActions: some View {
        HStack(spacing: 12) {
            Button("로그아웃") {
                editing = nil
                Task { await account.signOut() }
            }
            Button("탈퇴", role: .destructive) { confirmDelete = true }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.top, 4)
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

/// A name field that says right away whether the name can be used (green when the format is
/// right, red when not or when someone else has it); saving works only once the server says it
/// is free.
private struct NameEditor: View {
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
private struct SetupNamesForm: View {
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

/// One text box. Handles carry a fixed "@" inside the box; empty fields show a translucent
/// "@ID" / "username" hint.
private struct NameField: View {
    let kind: MomentAccount.NameKind
    @Binding var text: String
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 1) {
            if kind == .handle {
                Text("@").foregroundStyle(text.isEmpty ? .tertiary : .secondary)
            }
            TextField("", text: $text, prompt: Text(kind == .handle ? "ID" : "username").foregroundStyle(.tertiary))
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
