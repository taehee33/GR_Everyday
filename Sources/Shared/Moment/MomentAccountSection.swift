import SwiftUI

/// 설정 › 계정: the 순간들 account in the settings form of both apps. Sign in, change names,
/// see the photos I liked and what became of my reports, log out, leave.
struct MomentAccountSection: View {
    @ObservedObject var account = MomentAccount.shared
    @State private var sheet: Sheet?
    @State private var confirmSignOut = false
    @State private var confirmDelete = false

    enum Sheet: String, Identifiable {
        case signIn, displayName, handle, profile, liked, reports
        var id: String { rawValue }
    }

    var body: some View {
        Section {
            switch account.state {
            case .loading:
                HStack { Text("계정 확인 중…").foregroundStyle(.secondary); Spacer(); ProgressView().controlSize(.small) }
            case .signedOut:
                Button("로그인") { sheet = .signIn }
            case .needsHandle:
                identity
                Button("사용자명과 표시 이름 정하기") { sheet = .signIn }
                signOutRows
            case .ready:
                identity
                row("표시 이름 변경", value: account.me?.displayName) { sheet = .displayName }
                row("사용자명 변경", value: account.me?.handle) { sheet = .handle }
                    .disabled(account.me?.nextHandleChange != nil)
                if let next = account.me?.nextHandleChange {
                    Text("사용자명은 \(next.formatted(date: .long, time: .omitted))부터 바꿀 수 있어요.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                row("프로필 편집", icon: "person.crop.circle") { sheet = .profile }
                row("좋아요한 사진", icon: "heart") { sheet = .liked }
                row("신고 내역", icon: "exclamationmark.bubble") { sheet = .reports }
                signOutRows
            }
            if let message = account.errorMessage {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("계정")
                .task { if account.state == .loading { await account.load() } }
                .sheet(item: $sheet) { sheet in sheetContent(sheet) }
        }
        .disabled(account.busy)
    }

    /// 순간 / soongone / Google · name@example.com
    private var identity: some View {
        HStack(spacing: 12) {
            MomentAvatarView(store: account.store, profile: account.me, size: 44)
            identityText
        }
    }

    private var identityText: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let name = account.me?.displayName {
                Text(name).font(.headline)
            }
            if let handle = account.me?.handle {
                Text(handle).font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("사용자명을 아직 정하지 않았어요").font(.subheadline)
            }
            if let label = account.signInLabel {
                Text(label).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var signOutRows: some View {
        // Each alert hangs on its own row: in a settings list, one attached to the footer
        // never shows.
        Button("로그아웃") { confirmSignOut = true }
            .momentSignOutAlert(account: account, isPresented: $confirmSignOut)
        Button("탈퇴", role: .destructive) { confirmDelete = true }
            .momentDeleteAlert(account: account, isPresented: $confirmDelete)
    }

    private func row(_ title: String, value: String? = nil, icon: String? = nil,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                if let icon { Image(systemName: icon).frame(width: 22).foregroundStyle(.secondary) }
                Text(title).foregroundStyle(.primary)
                Spacer()
                if let value { Text(value).foregroundStyle(.secondary).lineLimit(1) }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func sheetContent(_ sheet: Sheet) -> some View {
        switch sheet {
        case .signIn:
            SheetFrame(title: "순간들 계정", onClose: close) {
                VStack(spacing: 16) {
                    switch account.state {
                    case .loading: ProgressView()
                    case .signedOut: MomentSignInButtons(account: account)
                    case .needsHandle: MomentNamesSetup(account: account)
                    case .ready:
                        Label("로그인했어요", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            .task { close() }
                    }
                    if let message = account.errorMessage {
                        Text(message).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                    }
                }
                .disabled(account.busy)
            }
        case .displayName, .handle:
            let kind: MomentAccount.NameKind = sheet == .handle ? .handle : .displayName
            SheetFrame(title: kind == .handle ? "사용자명 변경" : "표시 이름 변경", onClose: close) {
                VStack(spacing: 12) {
                    NameEditor(account: account, kind: kind, saveTitle: "저장",
                               initial: (kind == .handle ? account.me?.handle : account.me?.displayName) ?? "",
                               onSaved: close)
                    Text(kind == .handle
                         ? "사용자명은 30일에 한 번 바꿀 수 있고, 이전 사용자명은 14일 동안 다른 사람이 쓸 수 없어요."
                         : "표시 이름은 사진 아래에 보이는 이름이에요. 언제든 바꿀 수 있어요.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 300)
                    if let message = account.errorMessage {
                        Text(message).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
        case .profile:
            MomentProfileEditView(account: account)
        case .liked:
            SheetFrame(title: "좋아요한 사진", wide: true, onClose: close) {
                MomentPhotoList(account: account, feed: account.likedFeed,
                                emptyText: "아직 좋아요한 사진이 없어요.")
                    .task { await account.likedFeed.reload() }
            }
        case .reports:
            SheetFrame(title: "신고 내역", onClose: close) {
                MomentReportList(account: account)
            }
        }
    }

    private func close() { sheet = nil }
}

/// 로그아웃 asks once more before signing out.
private struct MomentSignOutAlert: ViewModifier {
    @ObservedObject var account: MomentAccount
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.alert("로그아웃할까요?", isPresented: $isPresented) {
            Button("취소", role: .cancel) {}
            Button("로그아웃", role: .destructive) { Task { await account.signOut() } }
        } message: {
            Text("올린 사진은 그대로 남아 있고, 다시 로그인하면 볼 수 있어요.")
        }
    }
}

/// 탈퇴 goes through only after the person types their own 사용자명 (or "탈퇴" when no
/// 사용자명 has been set yet).
private struct MomentDeleteAlert: ViewModifier {
    @ObservedObject var account: MomentAccount
    @Binding var isPresented: Bool
    @State private var typed = ""

    private var expected: String { account.me?.handle ?? "탈퇴" }

    private var matches: Bool {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if account.me?.handle != nil, text.hasPrefix("@") { text.removeFirst() }
        return text.caseInsensitiveCompare(expected) == .orderedSame
    }

    func body(content: Content) -> some View {
        content.alert("탈퇴할까요?", isPresented: $isPresented) {
            TextField(expected, text: $typed)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            Button("취소", role: .cancel) { typed = "" }
            Button("탈퇴하고 모두 삭제", role: .destructive) {
                typed = ""
                Task { await account.deleteAccount() }
            }
            .disabled(!matches)
        } message: {
            Text(account.me?.handle != nil
                 ? "계정과 올린 사진, 벽, 공유 기록이 모두 지워지고 되돌릴 수 없어요. 계속하려면 사용자명 ‘\(expected)’을 입력해 주세요."
                 : "계정과 올린 사진, 벽, 공유 기록이 모두 지워지고 되돌릴 수 없어요. 계속하려면 ‘탈퇴’를 입력해 주세요.")
        }
    }
}

extension View {
    func momentSignOutAlert(account: MomentAccount, isPresented: Binding<Bool>) -> some View {
        modifier(MomentSignOutAlert(account: account, isPresented: isPresented))
    }

    func momentDeleteAlert(account: MomentAccount, isPresented: Binding<Bool>) -> some View {
        modifier(MomentDeleteAlert(account: account, isPresented: isPresented))
    }
}

/// A sheet with a title and a close button, scrolling when the content is long.
private struct SheetFrame<Content: View>: View {
    let title: String
    var wide = false
    let onClose: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        NavigationStack {
            ScrollView {
                content.padding(20).frame(maxWidth: .infinity)
            }
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기", action: onClose) }
            }
        }
        #if os(macOS)
        .frame(minWidth: wide ? 640 : 440, minHeight: wide ? 640 : 380)
        #endif
    }
}

/// Reports I filed, each with the photo (while it exists), the reason, and what became of it.
private struct MomentReportList: View {
    @ObservedObject var account: MomentAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let reports = account.reports {
                if reports.isEmpty {
                    Text("신고한 사진이 없어요.").font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    Text("신고한 사진은 내 순간들에서 바로 빠져요. 확인이 끝나면 여기에서 결과를 알려 드려요.")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(reports) { report in
                        HStack(alignment: .top, spacing: 12) {
                            thumb(report)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(report.reason.title).font(.subheadline.weight(.semibold))
                                Label(report.status.title, systemImage: report.status.icon)
                                    .font(.footnote)
                                    .foregroundStyle(report.status == .received ? .secondary : .primary)
                                Text("\(report.createdAt.formatted(date: .long, time: .shortened)) 신고")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        Divider()
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 160)
            }
        }
        .task { await account.reloadReports() }
    }

    @ViewBuilder private func thumb(_ report: MomentReport) -> some View {
        RoundedRectangle(cornerRadius: 4).fill(.quaternary)
            .frame(width: 56, height: 56)
            .overlay {
                if let id = report.photoID, report.status != .removed {
                    AsyncImage(url: account.store.thumbURL(id)) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.clear
                    }
                } else {
                    Image(systemName: "photo").foregroundStyle(.tertiary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
