import SwiftUI

/// The 순간들 feed: photos people shared, newest first, with likes, reports and blocks.
@MainActor
final class MomentFeed: ObservableObject {
    @Published private(set) var photos: [MomentPhoto] = []
    /// Photos I have liked, among those loaded.
    @Published private(set) var liked: Set<UUID> = []
    @Published private(set) var loading = false
    @Published private(set) var reachedEnd = false
    /// True once the first page has been asked for.
    @Published private(set) var loaded = false
    @Published var errorMessage: String?
    /// A short note after a report or block ("신고했어요" …).
    @Published var notice: String?

    let store: MomentStore
    static let pageSize = 30

    init(store: MomentStore) {
        self.store = store
    }

    /// First page again (pull to refresh, after sharing, after signing in).
    func reload() async {
        loading = true
        errorMessage = nil
        defer { loading = false; loaded = true }
        do {
            let page = try await store.feed(before: nil, limit: Self.pageSize)
            photos = page
            reachedEnd = page.count < Self.pageSize
            liked = (try? await store.likes(among: page.map(\.id))) ?? []
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The next page, when the last loaded photo scrolls into view.
    func loadMore() async {
        guard !loading, !reachedEnd, let last = photos.last?.sharedAt else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await store.feed(before: last, limit: Self.pageSize)
            let known = Set(photos.map(\.id))
            photos += page.filter { !known.contains($0.id) }
            reachedEnd = page.count < Self.pageSize
            liked.formUnion((try? await store.likes(among: page.map(\.id))) ?? [])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Re-reads which photos I liked (after signing in or out).
    func refreshLikes() async {
        liked = (try? await store.likes(among: photos.map(\.id))) ?? []
    }

    func photo(_ id: UUID) -> MomentPhoto? { photos.first { $0.id == id } }

    /// Likes or unlikes at once on screen, and puts it back if the server says no.
    func toggleLike(_ id: UUID) async {
        guard store.me != nil else { errorMessage = MomentError.signedOut.localizedDescription; return }
        let on = !liked.contains(id)
        apply(id, on)
        do {
            try await store.like(id, on)
        } catch {
            apply(id, !on)
            errorMessage = error.localizedDescription
        }
    }

    private func apply(_ id: UUID, _ on: Bool) {
        if on { liked.insert(id) } else { liked.remove(id) }
        if let i = photos.firstIndex(where: { $0.id == id }) {
            photos[i].likeCount = max(photos[i].likeCount + (on ? 1 : -1), 0)
        }
    }

    /// Reports the photo and takes it off my feed. False when it failed.
    func report(_ id: UUID, _ reason: MomentReportReason) async -> Bool {
        do {
            try await store.report(id, reason: reason.rawValue, note: nil)
            photos.removeAll { $0.id == id }
            notice = "신고했어요. 확인한 뒤 조치할게요."
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Blocks the owner and takes all their photos off my feed. False when it failed.
    func block(_ owner: UUID) async -> Bool {
        do {
            try await store.block(owner)
            photos.removeAll { $0.owner == owner }
            notice = "차단했어요. 이 사람의 사진은 더 이상 보이지 않아요."
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

/// The feed as a grid of thumbnails; a tap opens the photo.
struct MomentFeedView: View {
    @ObservedObject var account: MomentAccount
    @ObservedObject var feed: MomentFeed
    @State private var opened: MomentPhoto?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("공유된 순간들").font(.headline)
                Spacer()
                if feed.loading {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await feed.reload() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("새로고침")
                }
            }
            if let notice = feed.notice {
                Label(notice, systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.secondary)
            }
            if let message = feed.errorMessage {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
            if feed.loaded, feed.photos.isEmpty, !feed.loading {
                VStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.title2).foregroundStyle(.secondary)
                    Text("아직 공유된 순간이 없어요.").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.tileMin), spacing: 4)], spacing: 4) {
                    ForEach(feed.photos) { photo in
                        Button { opened = photo } label: {
                            FeedTile(store: feed.store, photo: photo, liked: feed.liked.contains(photo.id))
                        }
                        .buttonStyle(.plain)
                        .onAppear { if photo.id == feed.photos.last?.id { Task { await feed.loadMore() } } }
                    }
                }
            }
        }
        .task { if !feed.loaded { await feed.reload() } }
        .task(id: account.me?.id) { if feed.loaded { await feed.refreshLikes() } }
        .sheet(item: $opened) { photo in
            MomentFeedDetail(account: account, feed: feed, photoID: photo.id)
        }
    }

    #if os(macOS)
    static let tileMin: CGFloat = 150
    #else
    static let tileMin: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 180 : 110
    #endif
}

/// A square thumbnail with the author's name and likes along the bottom.
private struct FeedTile: View {
    let store: MomentStore
    let photo: MomentPhoto
    let liked: Bool

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                AsyncImage(url: store.thumbURL(photo)) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
            }
            .clipped()
            .overlay(alignment: .bottom) {
                HStack(spacing: 4) {
                    Text(photo.author?.title ?? "").lineLimit(1)
                    Spacer(minLength: 2)
                    if photo.likeCount > 0 || liked {
                        Image(systemName: liked ? "heart.fill" : "heart")
                        Text("\(photo.likeCount)")
                    }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
            }
            .contentShape(Rectangle())
            .accessibilityLabel("\(photo.author?.title ?? "") 님의 사진")
    }
}

/// One shared photo: full view, who took it, caption and shot info; like, report, block.
struct MomentFeedDetail: View {
    @ObservedObject var account: MomentAccount
    @ObservedObject var feed: MomentFeed
    let photoID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var reporting = false
    @State private var confirmBlock = false

    private var photo: MomentPhoto? { feed.photo(photoID) }
    private var isMine: Bool { photo?.owner == account.me?.id }
    private var signedIn: Bool { account.me != nil }

    var body: some View {
        NavigationStack {
            Group {
                if let photo {
                    content(photo)
                } else {
                    Text("사진을 찾을 수 없어요.").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("순간")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
                if let photo, !isMine, signedIn {
                    ToolbarItem(placement: .primaryAction) { moreMenu(photo) }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 640)
        #endif
    }

    private func content(_ photo: MomentPhoto) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                MomentFullImage(store: feed.store, photo: photo)

                HStack(alignment: .center) {
                    authorLine(photo)
                    Spacer()
                    likeButton(photo)
                }

                if let caption = photo.caption {
                    Text(caption).font(.body).textSelection(.enabled)
                }
                if let shared = photo.sharedAt {
                    Text(shared.formatted(date: .long, time: .omitted))
                        .font(.caption).foregroundStyle(.secondary)
                }

                MomentInfoSection(info: photo.info)

                if !signedIn {
                    Text("좋아요·신고·차단은 로그인한 뒤에 할 수 있어요.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let message = feed.errorMessage {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
            }
            .padding(16)
        }
        .confirmationDialog("신고하는 이유를 골라 주세요", isPresented: $reporting, titleVisibility: .visible) {
            ForEach(MomentReportReason.allCases) { reason in
                Button(reason.title, role: .destructive) {
                    Task { if await feed.report(photo.id, reason) { dismiss() } }
                }
            }
        } message: {
            Text("신고한 사진은 내 피드에서 바로 사라지고, 신고가 쌓이면 모두에게서 숨겨져요.")
        }
        .confirmationDialog("\(photo.author?.title ?? "이 사람") 님을 차단할까요?", isPresented: $confirmBlock,
                            titleVisibility: .visible) {
            Button("차단", role: .destructive) {
                Task { if await feed.block(photo.owner) { dismiss() } }
            }
        } message: {
            Text("이 사람이 올린 사진이 피드와 벽에서 더 이상 보이지 않아요.")
        }
    }

    /// 한태희 @taehee (or just @taehee), with "나" on my own photos.
    private func authorLine(_ photo: MomentPhoto) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(photo.author?.displayName ?? photo.author?.handle.map { "@\($0)" } ?? "이름 없음")
                    .font(.headline)
                if isMine {
                    Text("나").font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }
            if photo.author?.displayName != nil, let handle = photo.author?.handle {
                Text("@\(handle)").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func likeButton(_ photo: MomentPhoto) -> some View {
        let liked = feed.liked.contains(photo.id)
        return Button {
            Task { await feed.toggleLike(photo.id) }
        } label: {
            Label("\(photo.likeCount)", systemImage: liked ? "heart.fill" : "heart")
                .foregroundStyle(liked ? Color.red : Color.primary)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.bordered)
        .disabled(!signedIn)
        .accessibilityLabel(liked ? "좋아요 취소" : "좋아요")
    }

    private func moreMenu(_ photo: MomentPhoto) -> some View {
        Menu {
            Button(role: .destructive) { reporting = true } label: {
                Label("신고", systemImage: "exclamationmark.bubble")
            }
            Button(role: .destructive) { confirmBlock = true } label: {
                Label("\(photo.author?.title ?? "작성자") 차단", systemImage: "hand.raised")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("더 보기")
    }
}
