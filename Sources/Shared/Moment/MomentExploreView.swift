import SwiftUI

/// 탐색: what is on 순간들 as a close grid. One row of chips: the order (추천, 좋아요, 최신),
/// then camera (digital or film GR), look (image control for digital, film for film) and region. Tap a photo for the same detail as 순간들.
struct MomentExploreView: View {
    @ObservedObject var account: MomentAccount
    @ObservedObject var feed: MomentFeed
    @State private var opened: MomentPhoto?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            filterRow
            if let notice = feed.notice {
                Label(notice, systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.secondary)
            }
            if let message = feed.errorMessage {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
            grid
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: feed.query) { Task { await feed.reload() } }
        .sheet(item: $opened) { photo in
            MomentFeedDetail(account: account, feed: feed, photoID: photo.id)
        }
    }

    // MARK: Filters

    /// One row of chips: the order first, then camera, look and region; wraps when narrow.
    private var filterRow: some View {
        HStack(alignment: .top, spacing: 8) {
            FlowLayout(spacing: 8) {
                sortChip
                cameraChip
                lookChip
                plainFilter("지역", selection: $feed.query.region, facets: feed.facets.regions)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if feed.query.hasFilter {
                Button {
                    feed.query.camera = nil
                    feed.query.kind = nil
                    feed.query.look = nil
                    feed.query.region = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                        .frame(height: 33)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("필터 모두 지우기")
            }
        }
    }

    /// 추천 · 좋아요 · 최신, and for 좋아요 how far back.
    private var sortChip: some View {
        let query = feed.query
        let label = query.sort == .likes ? "좋아요 · \(query.period.title)" : query.sort.title
        return Menu {
            Section("정렬") {
                ForEach(MomentExploreQuery.Sort.allCases) { sort in
                    check(sort.title, query.sort == sort) { feed.query.sort = sort }
                }
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
        .chipMenu()
        .accessibilityLabel("정렬: \(label)")
    }

    /// All, all digital GRs, all film GRs, or one camera (digital and film listed apart).
    private var cameraChip: some View {
        let query = feed.query
        let digital = feed.facets.cameras.filter { MomentExploreQuery.Kind(camera: $0.value) == .digital }
        let film = feed.facets.cameras.filter { MomentExploreQuery.Kind(camera: $0.value) == .film }
        let label = query.camera ?? query.kind?.title
        return Menu {
            check("전체", query.camera == nil && query.kind == nil) { pickCamera(nil, kind: nil) }
            ForEach(MomentExploreQuery.Kind.allCases) { kind in
                check("\(kind.title) 모두", query.camera == nil && query.kind == kind) { pickCamera(nil, kind: kind) }
            }
            if !digital.isEmpty {
                Section("디지털 GR") {
                    ForEach(digital) { facet in
                        check("\(facet.value)  \(facet.count)", query.camera == facet.value) { pickCamera(facet.value, kind: nil) }
                    }
                }
            }
            if !film.isEmpty {
                Section("필름 GR") {
                    ForEach(film) { facet in
                        check("\(facet.value)  \(facet.count)", query.camera == facet.value) { pickCamera(facet.value, kind: nil) }
                    }
                }
            }
        } label: {
            chipLabel(label ?? "기종", picked: label != nil)
        }
        .chipMenu()
        .accessibilityLabel(label.map { "기종: \($0)" } ?? "기종 필터")
    }

    /// Image controls for a digital GR, films for a film GR, both (apart) when no kind is picked.
    private var lookChip: some View {
        let query = feed.query
        let kind = query.effectiveKind
        let title = kind == .film ? "필름" : "화상"
        return Menu {
            check("전체", query.look == nil) { feed.query.look = nil }
            if kind != .film {
                lookSection(kind == nil ? "이미지 컨트롤" : nil, feed.facets.controls, picked: query.look)
            }
            if kind != .digital {
                lookSection(kind == nil ? "필름" : nil, feed.facets.films, picked: query.look)
            }
            if feed.facets.looks(for: kind).isEmpty {
                Text(kind == .film ? "아직 고를 수 있는 필름이 없어요" : "아직 고를 수 있는 화상이 없어요")
            }
        } label: {
            chipLabel(query.look ?? title, picked: query.look != nil)
        }
        .chipMenu()
        .accessibilityLabel(query.look.map { "\(title): \($0)" } ?? "\(title) 필터")
    }

    @ViewBuilder
    private func lookSection(_ header: String?, _ facets: [MomentExploreFacets.Facet], picked: String?) -> some View {
        let rows = ForEach(facets) { facet in
            check("\(facet.value)  \(facet.count)", picked == facet.value) { feed.query.look = facet.value }
        }
        if facets.isEmpty {
            EmptyView()
        } else if let header {
            Section(header) { rows }
        } else {
            rows
        }
    }

    /// Picks a camera or a kind, and lets go of a look that no longer fits.
    private func pickCamera(_ camera: String?, kind: MomentExploreQuery.Kind?) {
        var query = feed.query
        query.camera = camera
        query.kind = camera == nil ? kind : nil
        if let look = query.look, !feed.facets.looks(for: query.effectiveKind).contains(where: { $0.value == look }) {
            query.look = nil
        }
        feed.query = query
    }

    private func plainFilter(_ title: String, selection: Binding<String?>,
                             facets: [MomentExploreFacets.Facet]) -> some View {
        let picked = selection.wrappedValue
        return Menu {
            check("전체", picked == nil) { selection.wrappedValue = nil }
            if facets.isEmpty {
                Text("아직 고를 수 있는 \(title)이 없어요")
            }
            ForEach(facets) { facet in
                check("\(facet.value)  \(facet.count)", picked == facet.value) { selection.wrappedValue = facet.value }
            }
        } label: {
            chipLabel(picked ?? title, picked: picked != nil)
        }
        .chipMenu()
        .accessibilityLabel(picked.map { "\(title): \($0)" } ?? "\(title) 필터")
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
        .foregroundStyle(picked ? Color(white: 0.08) : Color.primary)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background {
            Capsule().fill(picked ? AnyShapeStyle(MomentLikePlace.moment.tint) : AnyShapeStyle(.quaternary))
        }
        .contentShape(Capsule())
    }

    // MARK: Photos

    @ViewBuilder private var grid: some View {
        if !feed.loaded {
            ProgressView().frame(maxWidth: .infinity, minHeight: 220)
        } else if feed.photos.isEmpty, !feed.loading {
            VStack(spacing: 8) {
                Image(systemName: "square.grid.3x3").font(.title2).foregroundStyle(.tertiary)
                Text(feed.query.hasFilter ? "조건에 맞는 사진이 없어요." : "아직 공유된 순간이 없어요.")
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

    private func tile(_ photo: MomentPhoto) -> some View {
        Button { opened = photo } label: {
            Rectangle()
                .fill(.quaternary)
                .aspectRatio(1, contentMode: .fit)
                .overlay { MomentRemoteImage(url: feed.store.thumbURL(photo), contentMode: .fill) }
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    if feed.query.sort == .likes, photo.momentLikeCount > 0 {
                        Label("\(photo.momentLikeCount)", systemImage: "heart.fill")
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
    func chipMenu() -> some View {
        menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}
