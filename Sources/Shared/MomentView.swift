import SwiftUI

/// 순간들 (English: Moments): photos people took with their GR. Two rooms under one roof:
/// 순간들, what everyone shared, and 내 갤러리, my own wall (upload, share, arrange). The
/// account itself (names, log out, liked photos, reports) is in 설정 › 계정.
struct MomentView: View {
    @ObservedObject private var account = MomentAccount.shared
    /// The room on screen. On iPhone and iPad the two rooms are pages side by side: drag
    /// sideways and the whole page follows the finger, settling on one room or the other.
    @State private var shownID: Room.ID? = Room.moments.id
    /// True while something inside needs sideways drags for itself (frames being moved).
    @State private var locked = false
    /// How far the pages have moved: 0 = 순간들, 1 = 내 갤러리, in between while dragging.
    @State private var progress: CGFloat = 0
    @State private var pageWidth: CGFloat = 0
    /// Where each title sits in the title row, for the underline that slides between them.
    @State private var titleFrames: [Room: CGRect] = [:]

    enum Room: String, CaseIterable, Identifiable {
        case moments = "순간들"
        case mine = "내 갤러리"
        var id: String { rawValue }

        var english: String { self == .moments ? "Moments" : "My Gallery" }
        var line: String {
            self == .moments ? "누군가의 GR에 담긴, 오늘의 순간" : "흘러가는 일상 속, 특별한 순간"
        }
    }

    private var room: Room { progress > 0.5 ? .mine : .moments }

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
                                progress = min(max(-frame.minX / frame.width, 0), 1)
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
                    MomentPhotoList(account: account, feed: account.feed)
                        .task { if !account.feed.loaded { await account.feed.reload() } }
                        .task(id: account.me?.id) { if account.feed.loaded { await account.feed.reload() } }
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
            if item == .moments { await account.feed.reload() } else { await account.reloadPhotos() }
        }
    }

    /// The title stays where it is while the pages slide under it: each page's copy is moved
    /// back by as much as its page has moved. Both copies draw the same thing (it follows the
    /// drag), so only the one of the nearer page shows.
    private func pinnedHeader(_ item: Room) -> some View {
        #if os(iOS)
        let index: CGFloat = item == .moments ? 0 : 1
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
        withAnimation(.snappy(duration: 0.3)) { progress = item == .mine ? 1 : 0 }
        #endif
    }

    /// How much `item` is the room on screen: 1 when it is, 0 when the other is, in between
    /// while dragging.
    private func amount(_ item: Room) -> Double { Double(item == .moments ? 1 - progress : progress) }

    /// For text that differs between the rooms: the old one is gone by halfway, then the new
    /// one comes in, so the two never show on top of each other.
    private func handover(_ item: Room) -> Double { max(amount(item) * 2 - 1, 0) }

    /// The two rooms as the page's title, following the drag: the room you are in is bright and
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
                if room == .moments {
                    Button { Task { await account.feed.reload() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .disabled(account.feed.loading)
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
        if let a = titleFrames[.moments], let b = titleFrames[.mine] {
            let t = min(max(progress, 0), 1)
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
    /// Holds the 순간들 ↔ 내 갤러리 pages still while `active`.
    func momentNoRoomSwipe(_ active: Bool = true) -> some View {
        preference(key: MomentRoomLock.self, value: active)
    }
}
