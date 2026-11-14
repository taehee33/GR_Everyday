import SwiftUI

/// 순간들 (English: Moments): photos people took with their GR. Three rooms under one roof:
/// 순간들, what everyone shared; 탐색, the same sorted and filtered; and 내 갤러리, my own
/// wall (upload, share, arrange). The
/// account itself (names, log out, liked photos, reports) is in 설정 › 계정.
struct MomentView: View {
    @ObservedObject private var account = MomentAccount.shared
    @Environment(\.scenePhase) private var scenePhase
    /// The room on screen. On iPhone and iPad the rooms are pages side by side: drag
    /// sideways and the whole page follows the finger, settling on one room or the other.
    @State private var shownID: Room.ID? = Room.moments.id
    /// True while something inside needs sideways drags for itself (frames being moved).
    @State private var locked = false
    /// How far the pages have moved: 0 = 순간들, 1 = 탐색, 2 = 내 갤러리, in between while dragging.
    @State private var progress: CGFloat = 0
    @State private var pageWidth: CGFloat = 0
    /// Where each title sits in the title row, for the underline that slides between them.
    @State private var titleFrames: [Room: CGRect] = [:]

    enum Room: String, CaseIterable, Identifiable {
        case moments = "순간들"
        case explore = "탐색"
        case mine = "내 갤러리"
        var id: String { rawValue }

        var english: String {
            switch self {
            case .moments: "Moments"
            case .explore: "Explore"
            case .mine: "My Gallery"
            }
        }
        var line: String {
            switch self {
            case .moments: "누군가의 GR에 담긴, 오늘의 순간"
            case .explore: "각자의 방식으로, 기억하는 순간"
            case .mine: "흘러가는 일상 속, 특별한 순간"
            }
        }
        var index: CGFloat { CGFloat(Self.allCases.firstIndex(of: self) ?? 0) }
    }

    private var room: Room {
        let i = Int(progress.rounded())
        return Room.allCases[min(max(i, 0), Room.allCases.count - 1)]
    }

    var body: some View {
        Group {
            #if os(iOS)
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Room.allCases) { item in
                        page(item)
                            .containerRelativeFrame(.horizontal)
                            .onGeometryChange(for: CGRect.self) {
                                $0.frame(in: .scrollView(axis: .horizontal))
                            } action: { frame in
                                // The first page's position says where the pager is.
                                guard item == .moments, frame.width > 0 else { return }
                                pageWidth = frame.width
                                progress = min(max(-frame.minX / frame.width, 0), CGFloat(Room.allCases.count - 1))
                            }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .scrollPosition(id: $shownID)
            .scrollDisabled(locked)
            .onPreferenceChange(MomentRoomLock.self) { locked = $0 }
            #else
            page(room)
            #endif
        }
        .task { if account.state == .loading { await account.load() } }
        // An admin may have changed the 순간들 heart color (어드민 › 당선작) since we last looked.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, account.store is SupabaseMomentStore {
                Task { await MomentHeartColor.shared.refresh() }
            }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #else
        .navigationTitle(Pane.moment.rawValue)
        #endif
    }

    /// One room, top to bottom: its title and what is in it, scrolling on its own.
    private func page(_ item: Room) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                pinnedHeader(item)
                switch item {
                case .moments:
                    MomentContestNotice(account: account)
                    MomentPhotoList(account: account, feed: account.feed)
                        .task { if !account.feed.loaded { await account.feed.reload() } }
                        .task { if !account.contests.loaded { await account.contests.reload() } }
                        .task(id: account.me?.id) { if account.feed.loaded { await account.feed.reload() } }
                case .explore:
                    MomentExploreView(account: account, feed: account.explore)
                        .task { if !account.explore.loaded { await account.explore.reload() } }
                        .task { if !account.contests.loaded { await account.contests.reload() } }
                        .task(id: account.me?.id) { if account.explore.loaded { await account.explore.reload() } }
                case .mine:
                    MomentAccountView(account: account)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 40)
            .frame(maxWidth: 1200)
            .frame(maxWidth: .infinity)
        }
        // The title carried over from the other page reaches past this page's edge.
        .scrollClipDisabled()
        .refreshable {
            switch item {
            case .moments:
                async let contests: Void = account.contests.reload()
                await account.feed.reload()
                await contests
            case .explore:
                async let contests: Void = account.contests.reload()
                await account.explore.reload()
                await contests
            case .mine: await account.reloadPhotos()
            }
        }
    }

    /// The title stays where it is while the pages slide under it: each page's copy is moved
    /// back by as much as its page has moved. Both copies draw the same thing (it follows the
    /// drag), so only the one of the nearer page shows.
    private func pinnedHeader(_ item: Room) -> some View {
        #if os(iOS)
        let index = item.index
        let near = abs(progress - index) < 0.5
        return header
            .offset(x: (progress - index) * pageWidth)
            .opacity(near ? 1 : 0)
            .allowsHitTesting(near)
        #else
        return header
        #endif
    }

    private func go(to item: Room) {
        guard item != room else { return }
        #if os(iOS)
        withAnimation(.snappy(duration: 0.35)) { shownID = item.id }
        #else
        withAnimation(.snappy(duration: 0.3)) { progress = item.index }
        #endif
    }

    /// How much `item` is the room on screen: 1 when it is, 0 when the other is, in between
    /// while dragging.
    private func amount(_ item: Room) -> Double { Double(max(0, 1 - abs(progress - item.index))) }

    /// For text that differs between the rooms: the old one is gone by halfway, then the new
    /// one comes in, so the two never show on top of each other.
    private func handover(_ item: Room) -> Double { max(amount(item) * 2 - 1, 0) }

    /// The rooms as the page's title, following the drag: the room you are in is bright and
    /// underlined, the other waits dimmed; while dragging the brightness moves across and the
    /// underline slides from one title to the other.
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .leading) {
                ForEach(Room.allCases) { item in
                    Text(item.english.uppercased()).opacity(handover(item))
                }
            }
            .font(.system(.caption, design: .serif).weight(.medium))
            .tracking(4)
            .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 22) {
                ForEach(Room.allCases) { item in
                    Button {
                        go(to: item)
                    } label: {
                        // Bold and plain on top of each other, so the width never jumps.
                        ZStack(alignment: .leading) {
                            Text(item.rawValue).font(.system(size: 30, weight: .bold))
                                .foregroundStyle(.primary).opacity(amount(item))
                            Text(item.rawValue).font(.system(size: 30, weight: .regular))
                                .foregroundStyle(.tertiary).opacity(1 - amount(item))
                        }
                        .padding(.bottom, 8)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("momentTitles")) } action: {
                            titleFrames[item] = $0
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(room == item ? .isSelected : [])
                }
                Spacer(minLength: 0)
                #if os(macOS)
                if room != .mine {
                    let list = room == .moments ? account.feed : account.explore
                    Button { Task { await list.reload() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .disabled(list.loading)
                        .help("새로고침")
                }
                #endif
            }
            .coordinateSpace(.named("momentTitles"))
            .overlay(alignment: .bottomLeading) { underline }
            ZStack(alignment: .leading) {
                ForEach(Room.allCases) { item in
                    Text(item.line).opacity(handover(item))
                }
            }
            .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    /// One line under the titles, as wide as the one it is under, sliding with the drag.
    @ViewBuilder private var underline: some View {
        let rooms = Room.allCases
        let p = min(max(progress, 0), CGFloat(rooms.count - 1))
        let lower = min(Int(p), rooms.count - 2)
        if let a = titleFrames[rooms[lower]], let b = titleFrames[rooms[lower + 1]] {
            let t = p - CGFloat(lower)
            Capsule().fill(Color.primary)
                .frame(width: a.width + (b.width - a.width) * t, height: 2)
                .offset(x: a.minX + (b.minX - a.minX) * t, y: (a.maxY + (b.maxY - a.maxY) * t) - max(a.maxY, b.maxY))
                .allowsHitTesting(false)
        }
    }
}

/// Set by something inside 순간들 that needs sideways drags for itself, so the pages hold still.
struct MomentRoomLock: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

extension View {
    /// Holds the 순간들 · 탐색 · 내 갤러리 pages still while `active`.
    func momentNoRoomSwipe(_ active: Bool = true) -> some View {
        preference(key: MomentRoomLock.self, value: active)
    }
}
