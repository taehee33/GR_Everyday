import SwiftUI

/// Someone to open, by id (for `.sheet(item:)`).
struct MomentPersonRef: Identifiable, Hashable {
    let id: UUID
}

/// Someone's 갤러리, opened from 순간들 (their name or picture) or a comment: their profile on
/// top, then their photos the way they hung them (액자 or 그리드). Photos open with likes and
/// comments.
struct MomentPersonGallery: View {
    @ObservedObject var account: MomentAccount
    let owner: UUID
    @StateObject private var feed: MomentFeed
    @Environment(\.dismiss) private var dismiss
    @State private var opened: MomentPhoto?
    @State private var fullScreen = false

    init(account: MomentAccount, owner: UUID) {
        self.account = account
        self.owner = owner
        _feed = StateObject(wrappedValue: MomentFeed(store: account.store, source: .owner(owner)))
    }

    private var title: String {
        guard let profile = feed.profile else { return "갤러리" }
        return "\(profile.displayName ?? profile.handle ?? "이름 없음") 님의 갤러리"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let profile = feed.profile {
                        MomentProfileSummary(store: account.store, profile: profile,
                                             counts: "사진 \(feed.photos.count) · 공유 \(feed.photos.filter(\.isShared).count)")
                            .frame(maxWidth: 820)
                            .frame(maxWidth: .infinity)
                        wall(profile)
                    } else if let message = feed.errorMessage {
                        Text(message).font(.footnote).foregroundStyle(.red)
                            .frame(maxWidth: .infinity, minHeight: 200)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                    }
                    if let notice = feed.notice {
                        Label(notice, systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(20)
                .frame(maxWidth: 1200)
                .frame(maxWidth: .infinity)
            }
            .refreshable { await feed.reload() }
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
                if feed.profile?.wallStyle == .free, !feed.photos.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button { fullScreen = true } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                        }
                        .accessibilityLabel("전체화면으로 보기")
                        .help("전체화면으로 보기")
                    }
                }
            }
        }
        .task { await feed.reload() }
        .sheet(item: $opened) { photo in
            MomentFeedDetail(account: account, feed: feed, photoID: photo.id, linksAuthor: false, showsComments: true)
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $fullScreen) { fullScreenWall }
        #else
        .sheet(isPresented: $fullScreen) {
            fullScreenWall.frame(minWidth: 1000, idealWidth: 1280, minHeight: 700, idealHeight: 820)
        }
        .frame(minWidth: 620, idealWidth: 860, minHeight: 680, idealHeight: 820)
        #endif
    }

    @ViewBuilder private func wall(_ profile: MomentProfile) -> some View {
        if feed.photos.isEmpty {
            Text("아직 올린 사진이 없어요.")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 160)
        } else if profile.wallStyle == .grid {
            MomentProfileGrid(store: account.store, photos: feed.photos, items: feed.items) { opened = $0 }
        } else {
            MomentWallStatic(store: account.store, photos: feed.photos, items: feed.items,
                             direction: profile.wallDirection) { opened = $0 }
        }
    }

    private var fullScreenWall: some View {
        MomentWallFullScreen(store: account.store, photos: feed.photos, items: feed.items,
                             direction: feed.profile?.wallDirection ?? .vertical,
                             title: [feed.profile?.displayName, feed.profile?.handle].compactMap { $0 }.joined(separator: "  ")) { photo in
            MomentFeedDetail(account: account, feed: feed, photoID: photo.id, linksAuthor: false, showsComments: true)
        }
    }
}

/// Profile picture, names and links, then the introduction and the cameras in use. The top of
/// 내 갤러리 and of anyone's gallery.
struct MomentProfileSummary: View {
    let store: MomentStore
    let profile: MomentProfile
    /// A line under the names ("사진 7 · 공유 3"), for someone else's gallery.
    var counts: String? = nil
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                MomentAvatarView(store: store, profile: profile, size: 72)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName ?? profile.handle ?? "")
                        .font(.headline)
                    if profile.displayName != nil, let handle = profile.handle {
                        Text(handle).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let counts {
                        Text(counts).font(.caption).foregroundStyle(.secondary)
                    }
                    if profile.instagramURL != nil || profile.websiteURL != nil {
                        HStack(spacing: 12) { links }
                            .padding(.top, 4)
                    }
                }
                Spacer(minLength: 0)
            }
            if let bio = profile.bio {
                Text(bio).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if !profile.cameras.isEmpty {
                ChipFlow(spacing: 6) {
                    ForEach(profile.cameras, id: \.self) { camera in
                        Label(camera, systemImage: "camera")
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.quaternary.opacity(0.6), in: Capsule())
                    }
                }
            }
        }
    }

    /// Instagram and website, as small icons under the username.
    @ViewBuilder private var links: some View {
        if let url = profile.instagramURL {
            Button { openURL(url) } label: { InstagramGlyph(size: 17) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("인스타그램 열기")
                .help("Instagram \(profile.instagram ?? "")")
        }
        if let url = profile.websiteURL {
            Button { openURL(url) } label: {
                Image(systemName: "link").font(.system(size: 15, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("웹사이트 열기")
            .help(url.absoluteString)
        }
    }
}

/// A gallery wall to look at, not to arrange: the frames where their owner hung them.
struct MomentWallStatic: View {
    let store: MomentStore
    let photos: [MomentPhoto]
    let items: [UUID: WallItem]
    let direction: MomentProfile.WallDirection
    let onOpen: (MomentPhoto) -> Void
    @State private var width: CGFloat = 0

    private var geometry: WallGeometry {
        let unit: CGFloat
        if direction == .vertical {
            unit = max(min(width, 820), 200)
        } else {
            #if os(iOS)
            unit = UIDevice.current.userInterfaceIdiom == .phone ? 400 : 580
            #else
            unit = 580
            #endif
        }
        return WallGeometry(unit: unit, direction: direction)
    }

    private func photo(_ id: UUID) -> MomentPhoto? { photos.first { $0.id == id } }

    var body: some View {
        let geo = geometry
        let shown = geo.resolved(photos, items: items).sorted { $0.z < $1.z }
        let length = max(shown.compactMap { item in
            photo(item.photoID).map { item.y + geo.along(geo.size($0, width: item.width)) }
        }.max() ?? 0, 0.6) + 0.08
        let canvas = ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.04))
            ForEach(shown, id: \.photoID) { item in
                if let photo = photo(item.photoID) {
                    let origin = geo.origin(item)
                    WallFrame(store: store, photo: photo, size: geo.size(photo, width: item.width), selected: false)
                        .offset(x: origin.x, y: origin.y)
                        .onTapGesture { onOpen(photo) }
                }
            }
        }
        .frame(width: geo.direction == .vertical ? geo.unit : CGFloat(length) * geo.unit,
               height: geo.direction == .vertical ? CGFloat(length) * geo.unit : geo.unit,
               alignment: .topLeading)

        Group {
            if geo.direction == .vertical {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: CGFloat(length) * geo.unit)
                    .overlay(alignment: .top) { canvas }
            } else {
                ScrollView(.horizontal, showsIndicators: false) { canvas }
                    .frame(height: geo.unit)
                    .scrollClipDisabled()
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

// MARK: - Comments

@MainActor
final class MomentComments: ObservableObject {
    @Published private(set) var list: [MomentComment] = []
    @Published private(set) var loaded = false
    @Published private(set) var sending = false
    @Published var errorMessage: String?
    @Published var notice: String?

    let store: MomentStore
    let photoID: UUID

    init(store: MomentStore, photoID: UUID) {
        self.store = store
        self.photoID = photoID
    }

    func reload() async {
        do {
            list = try await store.comments(on: photoID)
            errorMessage = nil
        } catch {
            errorMessage = "댓글을 불러오지 못했어요."
        }
        loaded = true
    }

    /// True when it was posted (the box can be cleared).
    func send(_ text: String) async -> Bool {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return false }
        sending = true
        defer { sending = false }
        do {
            let comment = try await store.addComment(on: photoID, String(body.prefix(MomentComment.limit)))
            list.append(comment)
            errorMessage = nil
            return true
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
            return false
        }
    }

    func delete(_ comment: MomentComment) async {
        do {
            try await store.deleteComment(comment.id)
            list.removeAll { $0.id == comment.id }
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }

    func report(_ comment: MomentComment, _ reason: MomentReportReason) async {
        do {
            try await store.reportComment(comment.id, reason: reason.rawValue)
            list.removeAll { $0.id == comment.id }
            notice = "댓글을 신고했어요. 내 화면에서는 바로 사라져요."
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }

    func block(_ author: UUID) async {
        do {
            try await store.block(author)
            list.removeAll { $0.author == author }
            notice = "차단했어요. 이 사람의 사진과 댓글이 더 이상 보이지 않아요."
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }
}

/// The comments under a photo in a sheet that slides up, Instagram style: the list, and a box
/// pinned to the bottom to write one. Dragging the list or tapping anywhere off the box puts
/// the keyboard away. Long-press (right-click on the Mac) or ⋯ on a comment to delete it (mine,
/// or any under my photo), report it or block its writer. The detail screen owns `model`, so
/// its comment count follows what happens here.
struct MomentCommentsSheet: View {
    @ObservedObject var account: MomentAccount
    @ObservedObject var model: MomentComments
    let photo: MomentPhoto
    /// Opens a writer's gallery (the sheet closes first).
    var onOpenPerson: ((UUID) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var reporting: MomentComment?
    @FocusState private var focused: Bool

    private var myID: UUID? { account.me?.id }
    private var canWrite: Bool { account.state == .ready && photo.status == .published }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if !model.loaded {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    } else if model.list.isEmpty {
                        VStack(spacing: 6) {
                            Text("아직 댓글이 없어요").font(.headline)
                            Text(canWrite ? "첫 댓글을 남겨 보세요." : "").font(.subheadline).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    ForEach(model.list) { comment in
                        row(comment)
                    }
                    if let notice = model.notice {
                        Label(notice, systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.secondary)
                    }
                    if let message = model.errorMessage {
                        Text(message).font(.footnote).foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { focused = false })
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .navigationTitle("댓글")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #else
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
            }
            #endif
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #else
        .frame(minWidth: 460, minHeight: 520)
        #endif
        .task { await model.reload() }
        .confirmationDialog("댓글을 신고하는 이유를 골라 주세요",
                            isPresented: Binding(get: { reporting != nil }, set: { if !$0 { reporting = nil } }),
                            titleVisibility: .visible, presenting: reporting) { comment in
            ForEach(MomentReportReason.forComments) { reason in
                Button(reason.title, role: .destructive) { Task { await model.report(comment, reason) } }
            }
        }
    }

    @ViewBuilder private var bottomBar: some View {
        if canWrite {
            composer
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
        } else if account.me == nil {
            Text("댓글은 로그인한 뒤에 남길 수 있어요.")
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(.bar)
        }
    }

    private func openPerson(_ id: UUID) {
        guard let onOpenPerson else { return }
        dismiss()
        // Let this sheet finish closing before the next one opens.
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            onOpenPerson(id)
        }
    }

    private func row(_ comment: MomentComment) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button { openPerson(comment.author) } label: {
                MomentAvatarView(store: account.store, owner: comment.author, author: comment.authorInfo, size: 36)
            }
            .buttonStyle(.plain)
            .disabled(onOpenPerson == nil)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Button { openPerson(comment.author) } label: {
                        Text(comment.authorInfo?.title ?? "이름 없음").font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .disabled(onOpenPerson == nil)
                    if comment.author == photo.owner {
                        Text("작가").font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    Text(comment.createdAt, format: .relative(presentation: .named))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(comment.body).font(.subheadline).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if myID != nil {
                Menu {
                    menuItems(comment)
                } label: {
                    Image(systemName: "ellipsis").font(.footnote).foregroundStyle(.secondary)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                #if os(macOS)
                .menuIndicator(.hidden)
                .fixedSize()
                #endif
                .accessibilityLabel("댓글 더 보기")
            }
        }
        .contextMenu { if myID != nil { menuItems(comment) } }
    }

    @ViewBuilder private func menuItems(_ comment: MomentComment) -> some View {
        if comment.author == myID || photo.owner == myID {
            Button(role: .destructive) { Task { await model.delete(comment) } } label: {
                Label("삭제", systemImage: "trash")
            }
        }
        if comment.author != myID {
            Button(role: .destructive) { reporting = comment } label: {
                Label("신고", systemImage: "exclamationmark.bubble")
            }
            Button(role: .destructive) { Task { await model.block(comment.author) } } label: {
                Label("\(comment.authorInfo?.title ?? "작성자") 차단", systemImage: "hand.raised")
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .center, spacing: 10) {
            MomentAvatarView(store: account.store, profile: account.me, size: 36)
            HStack(alignment: .bottom, spacing: 8) {
                TextField("", text: $text,
                          prompt: Text(prompt).foregroundStyle(.tertiary),
                          axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($focused)
                    .onChange(of: text) { _, new in
                        if new.count > MomentComment.limit { text = String(new.prefix(MomentComment.limit)) }
                    }
                    .onSubmit(send)
                    .padding(.vertical, 9)
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.sending {
                    Button(action: send) {
                        if model.sending {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("게시").bold()
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.sending)
                    .padding(.bottom, 9)
                }
            }
            .padding(.horizontal, 14)
            .background(Capsule().strokeBorder(.quaternary))
        }
    }

    private var prompt: String {
        if photo.owner == myID { return "댓글 달기…" }
        return "\(photo.author?.title ?? "작가")님에게 댓글 달기…"
    }

    private func send() {
        let draft = text
        Task {
            if await model.send(draft) {
                text = ""
                focused = false
            }
        }
    }
}
