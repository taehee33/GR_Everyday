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

    /// The person whose gallery this is (source .owner), and how they hung it.
    @Published private(set) var profile: MomentProfile?
    @Published private(set) var items: [UUID: WallItem] = [:]

    /// 탐색 only: the order and filters, and what the filters can offer.
    @Published var query = MomentExploreQuery()
    @Published private(set) var facets = MomentExploreFacets()
    /// 탐색 only: where the photos are, for the region map (about 1 km cells).
    @Published private(set) var mapCells: [MomentMapCell] = []
    /// 탐색 only: rows the server has given so far (some may be kept off screen), for the next offset.
    private var served = 0

    /// What the list holds: everyone's shared photos, 탐색 (sorted and filtered), the ones I
    /// liked, or one person's gallery.
    enum Source: Equatable { case shared, explore, liked, owner(UUID), winners }

    /// .winners only: 이달의 사진관, newest month first (the photos are the announced winners).
    @Published private(set) var contests: [MomentContest] = []

    let store: MomentStore
    let source: Source
    /// Where this list's hearts count: 순간들 (and the likes I gave there), or a gallery.
    var place: MomentLikePlace {
        if case .owner = source { return .gallery }
        return .moment
    }

    /// Where this photo's heart counts. 탐색 also shows gallery photos that are not on 순간들:
    /// their hearts are gallery likes (a 순간들 like needs the photo on 순간들).
    func place(of photo: MomentPhoto) -> MomentLikePlace {
        source == .explore && photo.sharedAt == nil ? .gallery : place
    }

    func place(of id: UUID) -> MomentLikePlace {
        photo(id).map { place(of: $0) } ?? place
    }

    /// Which of these I liked, each in its own place.
    private func likes(among photos: [MomentPhoto]) async -> Set<UUID> {
        let byPlace = Dictionary(grouping: photos) { place(of: $0) }
        var liked = Set<UUID>()
        for (place, photos) in byPlace {
            liked.formUnion((try? await store.likes(among: photos.map(\.id), in: place)) ?? [])
        }
        return liked
    }
    static let pageSize = 30
    /// Photos I reported; kept off my feed even after a reload.
    private var reported: Set<UUID> = []

    init(store: MomentStore, source: Source = .shared) {
        self.store = store
        self.source = source
    }

    /// Forgets everything (after signing out).
    func clear() {
        photos = []
        liked = []
        reported = []
        served = 0
        loaded = false
        reachedEnd = false
        notice = nil
        errorMessage = nil
    }

    /// First page again (pull to refresh, after sharing, after signing in).
    func reload() async {
        loading = true
        errorMessage = nil
        defer { loading = false; loaded = true }
        do {
            switch source {
            case .shared:
                let page = try await store.feed(before: nil, limit: Self.pageSize)
                if store.me != nil, let mine = try? await store.myReports() {
                    reported = Set(mine.compactMap(\.photoID))
                }
                photos = page.filter { !reported.contains($0.id) }
                reachedEnd = page.count < Self.pageSize
                liked = (try? await store.likes(among: page.map(\.id), in: place)) ?? []
            case .explore:
                let asked = query
                async let facetsRead = try? store.exploreFacets()
                let page = try await store.explore(asked, offset: 0, limit: Self.pageSize)
                if store.me != nil, let mine = try? await store.myReports() {
                    reported = Set(mine.compactMap(\.photoID))
                }
                if let read = await facetsRead { facets = read }
                // The filters changed while this page was on its way: that reload wins.
                guard asked == query else { return }
                served = page.count
                photos = page.filter { !reported.contains($0.id) }
                reachedEnd = page.count < Self.pageSize
                liked = await likes(among: page)
            case .winners:
                contests = try await store.contests(limit: 36)
                photos = contests.compactMap(\.winner)
                reachedEnd = true
                liked = (try? await store.likes(among: photos.map(\.id), in: place)) ?? []
            case .liked:
                photos = try await store.likedPhotos(limit: 200)
                reachedEnd = true
                liked = Set(photos.map(\.id))
            case .owner(let owner):
                let wall = try await store.wall(of: owner)
                profile = wall.profile
                items = Dictionary(wall.items.map { ($0.photoID, $0) }, uniquingKeysWith: { a, _ in a })
                photos = wall.photos.filter { $0.status == .published || owner == store.me?.id }
                reachedEnd = true
                liked = (try? await store.likes(among: photos.map(\.id), in: place)) ?? []
            }
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }

    /// 탐색's map points for the camera and look filters on now.
    func loadMap() async {
        do {
            mapCells = try await store.exploreMap(query)
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }

    /// The next page, when the last loaded photo scrolls into view.
    func loadMore() async {
        // 탐색 pages by offset (its gallery photos have no sharedAt); 순간들 by the last shared time.
        guard !loading, !reachedEnd, let lastPhoto = photos.last else { return }
        let last = lastPhoto.sharedAt
        guard source == .explore || last != nil else { return }
        loading = true
        defer { loading = false }
        do {
            let page: [MomentPhoto]
            if source == .explore {
                let asked = query
                page = try await store.explore(asked, offset: served, limit: Self.pageSize)
                guard asked == query else { return }
                served += page.count
            } else {
                page = try await store.feed(before: last, limit: Self.pageSize)
            }
            let known = Set(photos.map(\.id))
            photos += page.filter { !known.contains($0.id) && !reported.contains($0.id) }
            reachedEnd = page.count < Self.pageSize
            liked.formUnion(await likes(among: page))
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }

    /// Re-reads which photos I liked (after signing in or out).
    func refreshLikes() async {
        liked = await likes(among: photos)
    }

    func photo(_ id: UUID) -> MomentPhoto? { photos.first { $0.id == id } }

    /// Likes or unlikes at once on screen, and puts it back if the server says no.
    func toggleLike(_ id: UUID) async {
        guard store.me != nil else { errorMessage = MomentError.signedOut.localizedDescription; return }
        let on = !liked.contains(id)
        apply(id, on)
        do {
            try await store.like(id, on, in: place(of: id))
        } catch {
            apply(id, !on)
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }

    private func apply(_ id: UUID, _ on: Bool) {
        if on { liked.insert(id) } else { liked.remove(id) }
        if let i = photos.firstIndex(where: { $0.id == id }) {
            photos[i].addLike(on ? 1 : -1, in: place(of: photos[i]))
        }
    }

    /// Reports the photo and takes it off my feed. False when it failed.
    func report(_ id: UUID, _ reason: MomentReportReason) async -> Bool {
        do {
            try await store.report(id, reason: reason.rawValue, note: nil)
            reported.insert(id)
            photos.removeAll { $0.id == id }
            notice = "신고되었어요. 결과는 설정 › 계정 › 신고 내역에서 볼 수 있어요."
            return true
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
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
            if !error.isCancellation { errorMessage = error.localizedDescription }
            return false
        }
    }
}

/// Photos as a gallery wall: each in its own proportions, one column on a phone and two or
/// three on a wide window. Tap to open, double-tap to like.
struct MomentPhotoList: View {
    @ObservedObject var account: MomentAccount
    @ObservedObject var feed: MomentFeed
    var emptyText = "아직 공유된 순간이 없어요."
    @State private var width: CGFloat = 0
    @State private var opened: MomentPhoto?
    @State private var person: MomentPersonRef?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let notice = feed.notice {
                Label(notice, systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.secondary)
            }
            if let message = feed.errorMessage {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
            if feed.loaded, feed.photos.isEmpty, !feed.loading {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles").font(.title2).foregroundStyle(.tertiary)
                    Text(emptyText).font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
            } else if !feed.loaded {
                ProgressView().frame(maxWidth: .infinity, minHeight: 220)
            } else {
                // iPad, either way up: one photo a row, like the phone.
                let count = Device.isPad ? 1 : min(max(Int(width / 320), 1), 3)
                let columns = Self.columns(feed.photos, count: count)
                HStack(alignment: .top, spacing: 20) {
                    ForEach(columns.indices, id: \.self) { index in
                        LazyVStack(spacing: 30) {
                            ForEach(columns[index]) { photo in
                                MomentCard(store: feed.store, photo: photo,
                                           liked: feed.liked.contains(photo.id),
                                           canLike: account.me != nil,
                                           onOpen: { opened = photo },
                                           onOpenPerson: { person = MomentPersonRef(id: photo.owner) },
                                           onLike: { Task { await feed.toggleLike(photo.id) } })
                                    .onAppear {
                                        if photo.id == feed.photos.last?.id { Task { await feed.loadMore() } }
                                    }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                if feed.loading { ProgressView().frame(maxWidth: .infinity).padding(.top, 8) }
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .momentPush(item: $opened) { photo in
            MomentFeedDetail(account: account, feed: feed, photoID: photo.id)
        }
        .momentPersonGallery(item: $person, account: account)
    }

    /// Deals the photos into `count` columns, each next photo going to the shortest column,
    /// so the order still reads left to right, top to bottom.
    static func columns(_ photos: [MomentPhoto], count: Int) -> [[MomentPhoto]] {
        var columns = Array(repeating: [MomentPhoto](), count: count)
        var heights = Array(repeating: 0.0, count: count)
        for photo in photos {
            let shortest = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            columns[shortest].append(photo)
            heights[shortest] += Double(photo.height) / Double(max(photo.width, 1)) + 0.35
        }
        return columns
    }
}

/// One photo on the wall with its label underneath, like a caption card in a gallery: who,
/// what they wrote, and how it was shot.
private struct MomentCard: View {
    let store: MomentStore
    let photo: MomentPhoto
    let liked: Bool
    let canLike: Bool
    let onOpen: () -> Void
    let onOpenPerson: () -> Void
    let onLike: () -> Void
    @State private var burst = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Who took it: picture and names; opens their gallery.
            Button(action: onOpenPerson) {
                HStack(spacing: 10) {
                    MomentAvatarView(store: store, owner: photo.owner, author: photo.author, size: 34)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(photo.author?.title ?? "이름 없음").font(.subheadline.weight(.semibold))
                        if photo.author?.displayName != nil, let handle = photo.author?.handle {
                            Text(handle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(photo.author?.title ?? "이 사람") 님의 갤러리 보기")

            Rectangle()
                .fill(.quaternary)
                .aspectRatio(photo.aspect, contentMode: .fit)
                .overlay {
                    MomentRemoteImage(url: store.thumbURL(photo), contentMode: .fill)
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
                // The whole card (name, photo, buttons) fits on one screen, with room to spare.
                .momentFitHeight(Device.windowHeight.map { min($0 - 320, $0 * 0.68) }, aspect: photo.aspect)
                .overlay {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.3), radius: 8)
                        .scaleEffect(burst ? 1 : 0.4)
                        .opacity(burst ? 0.95 : 0)
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { doubleTapped() }
                .onTapGesture { onOpen() }
                .accessibilityElement()
                .accessibilityLabel("\(photo.author?.title ?? "") 님의 사진")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { onOpen() }

            HStack(alignment: .center, spacing: 8) {
                Button(action: onLike) {
                    HStack(spacing: 4) {
                        Image(systemName: liked ? "heart.fill" : "heart")
                            .foregroundStyle(liked ? MomentLikePlace.moment.tint : Color.primary)
                            .contentTransition(.symbolEffect(.replace))
                        if photo.momentLikeCount > 0 {
                            Text("\(photo.momentLikeCount)").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .font(.body)
                    .padding(.vertical, 4).padding(.trailing, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canLike)
                .accessibilityLabel(liked ? "좋아요 취소" : "좋아요")
                Spacer(minLength: 8)
                MomentShotTag(info: photo.info)
            }

            if let caption = photo.caption {
                Text(caption).font(.callout).lineLimit(3)
            }
        }
    }

    private func doubleTapped() {
        guard canLike else { return }
        if !liked { onLike() }
        withAnimation(.spring(duration: 0.3)) { burst = true }
        Task {
            try? await Task.sleep(for: .milliseconds(650))
            withAnimation(.easeOut(duration: 0.25)) { burst = false }
        }
    }
}

/// One shared photo: full view, who took it, caption and shot info; like, report, block.
struct MomentFeedDetail: View {
    @ObservedObject var account: MomentAccount
    @ObservedObject var feed: MomentFeed
    let photoID: UUID
    /// The author's name opens their gallery (off when this is already their gallery).
    var linksAuthor = true
    /// Comments show in someone's gallery, not on 순간들.
    var showsComments = false
    /// A page of MomentGalleryPager (someone's gallery): no navigation bar of its own, fitted to one screen.
    var paged = false
    /// The page on screen (the pager puts this photo's buttons in its toolbar).
    var isCurrent = true
    @Environment(\.dismiss) private var dismiss
    @State private var person: MomentPersonRef?
    @State private var viewing: MomentPhoto?
    @State private var viewHeight: CGFloat = 0
    @State private var showComments = false
    @StateObject private var comments: MomentComments

    init(account: MomentAccount, feed: MomentFeed, photoID: UUID, linksAuthor: Bool = true, showsComments: Bool = false,
         paged: Bool = false, isCurrent: Bool = true) {
        self.account = account
        self.feed = feed
        self.photoID = photoID
        self.linksAuthor = linksAuthor
        self.showsComments = showsComments
        self.paged = paged
        self.isCurrent = isCurrent
        _comments = StateObject(wrappedValue: MomentComments(store: account.store, photoID: photoID))
    }

    private var photo: MomentPhoto? { feed.photo(photoID) }
    private var isMine: Bool { photo?.owner == account.me?.id }
    private var signedIn: Bool { account.me != nil }

    var body: some View {
        if paged {
            page
        } else {
            NavigationStack {
                page
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { MomentCloseButton() }
                        ToolbarItem(placement: .primaryAction) {
                            MomentFeedPhotoActions(account: account, feed: feed, photoID: photoID)
                        }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 640)
            #endif
        }
    }

    @ViewBuilder private var page: some View {
        if let photo {
            content(photo)
        } else {
            Text("사진을 찾을 수 없어요.").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func content(_ photo: MomentPhoto) -> some View {
        MomentDetailLayout(paged: paged, viewHeight: viewHeight) {
            authorLine(photo)
        } image: {
            MomentFullImage(store: feed.store, photo: photo, viewHeight: paged ? 0 : viewHeight)
                .momentOpensFullScreen { viewing = photo }
        } footer: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 4) {
                    likeButton(photo)
                    if showsComments {
                        MomentCommentButton(count: comments.list.count) { showComments = true }
                    }
                    Spacer(minLength: 8)
                    MomentShotTag(info: photo.info)
                }

                MomentCaptionBlock(handle: photo.author?.handle ?? photo.author?.displayName,
                                   caption: photo.caption, date: photo.sharedAt ?? photo.createdAt)

                if !signedIn {
                    Text(showsComments ? "좋아요·댓글·신고·차단은 로그인한 뒤에 할 수 있어요."
                                       : "좋아요·신고·차단은 로그인한 뒤에 할 수 있어요.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let message = feed.errorMessage {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
            }
        }
        .momentPersonGallery(item: $person, account: account)
        .sheet(isPresented: $showComments) {
            MomentCommentsSheet(account: account, model: comments, photo: photo) { owner in
                if !linksAuthor, owner == photo.owner { return }
                person = MomentPersonRef(id: owner)
            }
        }
        .task(id: photo.id) { if showsComments { await comments.reload() } }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewHeight = $0 }
        .momentPhotoViewer($viewing, store: feed.store)
    }

    /// Profile picture and username above the photo, with "나" on my own photos.
    private func authorLine(_ photo: MomentPhoto) -> some View {
        Button {
            if linksAuthor { person = MomentPersonRef(id: photo.owner) }
        } label: {
            HStack(spacing: 10) {
                MomentAvatarView(store: feed.store, owner: photo.owner, author: photo.author, size: 34)
                authorNames(photo)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(linksAuthor)
    }

    private func authorNames(_ photo: MomentPhoto) -> some View {
        HStack(spacing: 6) {
            Text(photo.author?.handle ?? photo.author?.displayName ?? "이름 없음")
                .font(.subheadline.weight(.semibold))
            if isMine {
                Text("나").font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
        }
    }

    private func likeButton(_ photo: MomentPhoto) -> some View {
        MomentHeartButton(liked: feed.liked.contains(photo.id), count: photo.likes(in: feed.place(of: photo)),
                          place: feed.place(of: photo), enabled: signedIn) {
            Task { await feed.toggleLike(photo.id) }
        }
    }

}

/// (i) and, on someone else's photo once signed in, ⋯ (신고, 차단), with what they open. It sits
/// in the toolbar of the sheet or of someone's gallery pager (for the photo on screen).
struct MomentFeedPhotoActions: View {
    @ObservedObject var account: MomentAccount
    @ObservedObject var feed: MomentFeed
    let photoID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var reporting = false
    @State private var confirmBlock = false
    @State private var showInfo = false

    private var photo: MomentPhoto? { feed.photo(photoID) }

    var body: some View {
        if let photo {
            HStack(spacing: 16) {
                MomentInfoButton { showInfo = true }
                if photo.owner != account.me?.id, account.me != nil { moreMenu(photo) }
            }
            .sheet(isPresented: $showInfo) {
                MomentInfoSheet(info: photo.info, sharedAt: photo.sharedAt)
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
