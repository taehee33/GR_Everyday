import SwiftUI

/// 탐색: every published photo (순간들 and 갤러리) as a close grid, with a search for people on
/// top (사용자명 or 표시 이름). One row of chips: the order (추천, 좋아요, 최신,
/// or 이전 당선작), then camera (digital or film GR), look (image control for digital, film for
/// film) and region. Tap a photo for the same detail as 순간들.
struct MomentExploreView: View {
    @ObservedObject var account: MomentAccount
    @ObservedObject var feed: MomentFeed
    /// 이달의 사진관: the months and their winners.
    @ObservedObject private var contests: MomentFeed
    @State private var opened: MomentPhoto?
    @State private var openedWinner: MomentPhoto?
    @State private var choosingRegion = false
    /// 검색: what is typed, the people found for it, and the one opened.
    @State private var searchText = ""
    @State private var people: [MomentPersonResult] = []
    @State private var searchedFor: String?
    @State private var searchError: String?
    @State private var person: MomentPersonRef?

    private var searchQuery: String { searchText.trimmingCharacters(in: .whitespaces) }

    init(account: MomentAccount, feed: MomentFeed) {
        self.account = account
        self.feed = feed
        self.contests = account.contests
    }

    private var showsWinners: Bool { feed.query.sort == .winners }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            searchField
            if !searchQuery.isEmpty {
                peopleList
            } else {
                photos
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: searchQuery) { await search(searchQuery) }
        .momentPersonGallery(item: $person, account: account)
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("사용자명이나 이름으로 검색", text: $searchText)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                #endif
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("검색어 지우기")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Waits a moment after the last key, then asks the server.
    private func search(_ text: String) async {
        guard !text.isEmpty else { people = []; searchedFor = nil; searchError = nil; return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        do {
            let found = try await account.store.searchPeople(text)
            guard !Task.isCancelled else { return }
            people = found
            searchedFor = text
            searchError = nil
        } catch {
            if !error.isCancellation { searchError = error.localizedDescription }
        }
    }

    @ViewBuilder private var peopleList: some View {
        if let searchError {
            Text(searchError).font(.footnote).foregroundStyle(.red)
        }
        if searchedFor != searchQuery, people.isEmpty {
            ProgressView().frame(maxWidth: .infinity, minHeight: 120)
        } else if people.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.questionmark").font(.title2).foregroundStyle(.tertiary)
                Text("‘\(searchQuery)’에 맞는 사람이 없어요.").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 160)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(people) { found in
                    Button { person = MomentPersonRef(id: found.id) } label: {
                        HStack(spacing: 12) {
                            MomentAvatarView(store: account.store, owner: found.id, author: found.author, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(found.author.displayName ?? found.author.handle ?? "이름 없음")
                                    .font(.body.weight(.semibold)).lineLimit(1)
                                if let handle = found.author.handle {
                                    Text("@\(handle)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 8)
                            Text("사진 \(found.photoCount)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(found.author.title), 사진 \(found.photoCount)장")
                    Divider()
                }
            }
        }
    }

    // MARK: Photos

    private var photos: some View {
        VStack(alignment: .leading, spacing: 14) {
            filterRow
            if let notice = feed.notice {
                Label(notice, systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.secondary)
            }
            if let message = feed.errorMessage {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
            if showsWinners { winnersGrid } else { grid }
        }
        .onChange(of: feed.query) { _, new in
            if new.sort == .winners {
                // The winners come with 이달의 사진관, not from 탐색's server query.
                if !contests.loaded { Task { await contests.reload() } }
            } else {
                Task { await feed.reload() }
            }
        }
        .sheet(item: $opened) { photo in
            MomentFeedDetail(account: account, feed: feed, photoID: photo.id)
        }
        .sheet(isPresented: $choosingRegion) {
            MomentExploreRegionSheet(feed: feed)
        }
        .sheet(item: $openedWinner) { photo in
            MomentFeedDetail(account: account, feed: contests, photoID: photo.id)
        }
    }

    // MARK: Filters

    /// One row of chips: the order first, then camera, look and region; wraps when narrow.
    private var filterRow: some View {
        HStack(alignment: .top, spacing: 8) {
            FlowLayout(spacing: 8) {
                sortChip
                if !showsWinners {
                    cameraChip
                    lookChip
                    regionChip
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if feed.query.hasFilter, !showsWinners {
                Button {
                    feed.query.camera = nil
                    feed.query.kind = nil
                    feed.query.look = nil
                    feed.query.region = nil
                    feed.query.district = nil
                    feed.query.area = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                        .frame(height: 33)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("필터 모두 지우기")
            }
        }
    }

    /// 지역: opens the list (시·도 › 시·군·구, 내 주변) and the map.
    private var regionChip: some View {
        let query = feed.query
        let label = query.area?.label ?? query.region.map { region in query.district.map { "\(region) \($0)" } ?? region }
        return Button { choosingRegion = true } label: {
            chipLabel(label ?? "지역", icon: query.area != nil ? "map" : nil, picked: label != nil)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(label.map { "지역: \($0)" } ?? "지역 필터")
    }

    /// 추천 · 좋아요 · 최신, and for 좋아요 how far back.
    private var sortChip: some View {
        let query = feed.query
        let label = query.sort == .likes ? "좋아요 · \(query.period.title)" : query.sort.title
        return Menu {
            Section("정렬") {
                ForEach(MomentExploreQuery.Sort.orders) { sort in
                    check(sort.title, query.sort == sort) { feed.query.sort = sort }
                }
            }
            Section {
                check(MomentExploreQuery.Sort.winners.title, query.sort == .winners) { feed.query.sort = .winners }
            }
            if query.sort == .likes {
                Section("기간") {
                    ForEach(MomentExploreQuery.Period.allCases) { period in
                        check(period.title, query.period == period) { feed.query.period = period }
                    }
                }
            }
        } label: {
            chipLabel(label, icon: "arrow.up.arrow.down", picked: false)
        }
        .chipMenu(id: label)
        .accessibilityLabel("정렬: \(label)")
    }

    /// All, all digital GRs, all film GRs, or one camera (digital and film listed apart).
    private var cameraChip: some View {
        let query = feed.query
        let shared = feed.facets.cameras
        let digital = Self.options(MomentShotInfo.digitalCameras, shared.filter { MomentExploreQuery.Kind(camera: $0.value) == .digital })
        let film = Self.options(MomentShotInfo.filmCameras, shared.filter { MomentExploreQuery.Kind(camera: $0.value) == .film })
        let label = query.camera ?? query.kind?.title
        return Menu {
            check("전체", query.camera == nil && query.kind == nil) { pickCamera(nil, kind: nil) }
            // Folded until opened: each kind's "모두" and its cameras.
            ForEach(MomentExploreQuery.Kind.allCases) { kind in
                let cameras = kind == .digital ? digital : film
                folder(kind.title, on: query.effectiveKind == kind) {
                    check("\(kind.title) 모두", query.camera == nil && query.kind == kind) { pickCamera(nil, kind: kind) }
                    ForEach(cameras) { facet in
                        check(Self.title(facet), query.camera == facet.value) { pickCamera(facet.value, kind: nil) }
                    }
                }
            }
        } label: {
            chipLabel(label ?? "기종", picked: label != nil)
        }
        .chipMenu(id: label ?? "기종")
        .accessibilityLabel(label.map { "기종: \($0)" } ?? "기종 필터")
    }

    /// Image controls for a digital GR, films for a film GR, both (apart) when no kind is picked.
    private var lookChip: some View {
        let query = feed.query
        let kind = query.effectiveKind
        let title = kind == .film ? "필름" : "화상"
        return Menu {
            check("전체", query.look == nil) { feed.query.look = nil }
            // Folded until opened; only the one that fits a picked camera kind.
            if kind != .film {
                lookFolder("이미지 컨트롤", Self.options(Self.imageControls, feed.facets.controls), picked: query.look)
            }
            if kind != .digital {
                lookFolder("필름", Self.options(MomentShotInfo.filmChoices, feed.facets.films), picked: query.look)
            }
        } label: {
            chipLabel(query.look ?? title, picked: query.look != nil)
        }
        .chipMenu(id: query.look ?? title)
        .accessibilityLabel(query.look.map { "\(title): \($0)" } ?? "\(title) 필터")
    }

    private func lookFolder(_ title: String, _ facets: [MomentExploreFacets.Facet], picked: String?) -> some View {
        folder(title, on: facets.contains { $0.value == picked }) {
            ForEach(facets) { facet in
                check(Self.title(facet), picked == facet.value) { feed.query.look = facet.value }
            }
        }
    }

    /// A folded group inside a filter menu: a row with › that opens to its choices. Checked
    /// when what is picked now is inside it.
    private func folder<Content: View>(_ title: String, on: Bool, @ViewBuilder content: () -> Content) -> some View {
        Menu {
            content()
        } label: {
            if on { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    /// Picks a camera or a kind, and lets go of a look that no longer fits.
    private func pickCamera(_ camera: String?, kind: MomentExploreQuery.Kind?) {
        var query = feed.query
        query.camera = camera
        query.kind = camera == nil ? kind : nil
        if let look = query.look, !Self.looks(for: query.effectiveKind, feed.facets).contains(look) {
            query.look = nil
        }
        feed.query = query
    }

    /// The same choices as the upload screen, in its order, with how many shared photos have
    /// each; values that are on 순간들 but not in the list (a typed film) come after.
    static func options(_ all: [String], _ shared: [MomentExploreFacets.Facet]) -> [MomentExploreFacets.Facet] {
        let counts = Dictionary(shared.map { ($0.value, $0.count) }, uniquingKeysWith: +)
        var seen = Set<String>()
        let listed = all.filter { seen.insert($0).inserted }
            .map { MomentExploreFacets.Facet(value: $0, count: counts[$0] ?? 0) }
        return listed + shared.filter { !seen.contains($0.value) }
    }

    /// "GR IV  3", or just "GR IIIx" when no shared photo has it.
    static func title(_ facet: MomentExploreFacets.Facet) -> String {
        facet.count > 0 ? "\(facet.value)  \(facet.count)" : facet.value
    }

    /// Every image control the app can read from a GR (as in the upload screen), in code order.
    static let imageControls: [String] = MakerNote.imageToneNames.sorted { $0.key < $1.key }.map(\.value)

    /// The 화상 values that fit `kind`.
    static func looks(for kind: MomentExploreQuery.Kind?, _ facets: MomentExploreFacets) -> Set<String> {
        var values = Set<String>()
        if kind != .film { values.formUnion(imageControls); values.formUnion(facets.controls.map(\.value)) }
        if kind != .digital { values.formUnion(MomentShotInfo.filmChoices); values.formUnion(facets.films.map(\.value)) }
        return values
    }

    private func check(_ title: String, _ on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if on { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    /// A chip: plain until something is picked, then filled.
    private func chipLabel(_ text: String, icon: String? = nil, picked: Bool) -> some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.caption.weight(.semibold)) }
            Text(text).lineLimit(1)
            Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
        }
        .font(.subheadline.weight(picked ? .semibold : .regular))
        .foregroundStyle(picked ? MomentLikePlace.moment.onTint : Color.primary)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background {
            Capsule().fill(picked ? AnyShapeStyle(MomentLikePlace.moment.tint) : AnyShapeStyle(.quaternary))
        }
        .contentShape(Capsule())
    }

    @ViewBuilder private var grid: some View {
        if !feed.loaded {
            ProgressView().frame(maxWidth: .infinity, minHeight: 220)
        } else if feed.photos.isEmpty, !feed.loading {
            VStack(spacing: 8) {
                Image(systemName: "square.grid.3x3").font(.title2).foregroundStyle(.tertiary)
                Text(feed.query.hasFilter ? "조건에 맞는 사진이 없어요." : "아직 올라온 사진이 없어요.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 220)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 3)], spacing: 3) {
                ForEach(feed.photos) { photo in
                    tile(photo)
                        .onAppear {
                            if photo.id == feed.photos.last?.id { Task { await feed.loadMore() } }
                        }
                }
            }
            if feed.loading { ProgressView().frame(maxWidth: .infinity).padding(.top, 8) }
        }
    }

    /// Every announced month's winner, newest first, with its month under it.
    @ViewBuilder private var winnersGrid: some View {
        let winners = contests.contests.compactMap { c in c.isAnnounced ? c.winner.map { (c, $0) } : nil }
        if !contests.loaded {
            ProgressView().frame(maxWidth: .infinity, minHeight: 220)
        } else if winners.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "trophy").font(.title2).foregroundStyle(.tertiary)
                Text("아직 발표된 당선작이 없어요.").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 220)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 3)], spacing: 14) {
                ForEach(winners, id: \.0.id) { contest, photo in
                    Button { openedWinner = photo } label: {
                        VStack(spacing: 6) {
                            Rectangle()
                                .fill(.quaternary)
                                .aspectRatio(1, contentMode: .fit)
                                .overlay { MomentRemoteImage(url: account.store.thumbURL(photo), contentMode: .fill) }
                                .clipped()
                            Text(contest.longMonthTitle).font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(contest.longMonthTitle) 당선작, \(photo.author?.title ?? "") 님의 순간")
                }
            }
        }
    }

    private func tile(_ photo: MomentPhoto) -> some View {
        Button { opened = photo } label: {
            Rectangle()
                .fill(.quaternary)
                .aspectRatio(1, contentMode: .fit)
                .overlay { MomentRemoteImage(url: feed.store.thumbURL(photo), contentMode: .fill) }
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    if feed.query.sort == .likes, photo.likes(in: feed.place(of: photo)) > 0 {
                        Label("\(photo.likes(in: feed.place(of: photo)))", systemImage: "heart.fill")
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.5), radius: 3)
                            .padding(6)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(photo.author?.title ?? "") 님의 사진")
    }
}

private extension View {
    /// `id` is the chip's text. A new text makes a new chip: otherwise the menu, closing,
    /// shrank back into the old chip's size and only snapped to the new one a moment later.
    func chipMenu(id: String) -> some View {
        menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().id(id)
    }
}
