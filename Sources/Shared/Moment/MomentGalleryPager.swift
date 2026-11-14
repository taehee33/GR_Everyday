import SwiftUI

/// A photo opened from a gallery (mine or someone's), full screen: a back button at the top left,
/// "내 사진 3/8" in the middle, and the gallery's other photos one swipe away, a page each: up and
/// down or left and right, as picked in 설정 (MomentGalleryPaging).
/// Each page draws itself (`page(id, isCurrent)`); the buttons of the photo on screen
/// (`actions(id)`) sit in the pager's own toolbar. (Pages putting them there themselves left the
/// toolbar empty now and then after a swipe.)
struct MomentGalleryPager<Page: View, Actions: View>: View {
    let title: String
    let ids: [UUID]
    @ViewBuilder let page: (UUID, Bool) -> Page
    @ViewBuilder let actions: (UUID) -> Actions
    @Environment(\.dismiss) private var dismiss
    @AppStorage(MomentGalleryPaging.key) private var paging = MomentGalleryPaging.vertical
    @State private var current: UUID?
    /// The page dots at the edge, shown on opening and on each swipe, then faded away.
    @State private var showDots = false
    @State private var hideDots: Task<Void, Never>?
    /// The "swipe for the next photo" note, shown the first few times a gallery opens with more
    /// than one photo, until the first swipe.
    @State private var showHint = false
    @AppStorage("momentGalleryHintShown") private var hintShown = 0
    /// How far the photo has been pulled across the paging direction to close it: right for
    /// up-and-down paging (like going back), down for sideways paging.
    @State private var pull: CGFloat = 0
    /// Whether the current drag is a closing swipe (decided on its first move).
    @State private var pulling: Bool?
    @State private var size: CGSize = .zero
    private let start: UUID

    init(title: String, ids: [UUID], start: UUID, @ViewBuilder page: @escaping (UUID, Bool) -> Page,
         @ViewBuilder actions: @escaping (UUID) -> Actions) {
        self.title = title
        self.ids = ids.contains(start) ? ids : [start] + ids
        self.page = page
        self.actions = actions
        self.start = start
    }

    private var counter: String {
        guard ids.count > 1, let index = ids.firstIndex(of: current ?? start) else { return title }
        return "\(title) \(index + 1)/\(ids.count)"
    }

    var body: some View {
        NavigationStack {
            // The pages run under the bars, a whole screen each, so paging lands exactly on
            // one; each page keeps its content clear of the bars itself.
            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView(paging.axis) {
                        if paging == .vertical {
                            LazyVStack(spacing: 0) { pages(geo) }.scrollTargetLayout()
                        } else {
                            LazyHStack(spacing: 0) { pages(geo) }.scrollTargetLayout()
                        }
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollPosition(id: $current)
                    .scrollIndicators(.hidden)
                    .ignoresSafeArea(edges: .vertical)
                    // A fresh lazy stack ignores a starting scrollPosition: once it is laid out,
                    // move to the photo opened.
                    .task {
                        proxy.scrollTo(start, anchor: .topLeading)
                        current = start
                        guard ids.count > 1 else { return }
                        flashDots()
                        if hintShown < 3 {
                            hintShown += 1
                            try? await Task.sleep(for: .milliseconds(600))
                            withAnimation(.spring(duration: 0.5)) { showHint = true }
                        }
                    }
                }
            }
            .overlay(alignment: paging == .vertical ? .trailing : .bottom) {
                if ids.count > 1 {
                    MomentPageDots(count: ids.count, index: ids.firstIndex(of: current ?? start) ?? 0,
                                   axis: paging)
                        .padding(paging == .vertical ? .trailing : .bottom, 6)
                        .opacity(showDots ? 1 : 0)
                        .animation(.easeInOut(duration: 0.35), value: showDots)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                if showHint {
                    MomentSwipeHint(paging: paging)
                        .padding(.bottom, paging == .vertical ? 24 : 40)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: current) { old, _ in
                guard old != nil else { return }
                flashDots()
                if showHint { withAnimation(.easeOut(duration: 0.25)) { showHint = false } }
            }
            .navigationTitle(counter)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: Self.backPlacement) {
                    Button { back() } label: { Image(systemName: "chevron.backward") }
                        .accessibilityLabel("뒤로")
                }
                ToolbarItem(placement: .primaryAction) {
                    // A fresh view per photo, so a sheet or question left open never carries over.
                    actions(current ?? start).id(current ?? start)
                }
            }
            .onChange(of: ids) { old, new in
                // The photo on screen went away (deleted): show the one after it, or before it.
                guard let current, !new.contains(current) else { return }
                if new.isEmpty { dismiss(); return }
                let index = old.firstIndex(of: current) ?? 0
                self.current = old[(index + 1)...].first(where: new.contains)
                    ?? old[..<index].last(where: new.contains) ?? new.first
            }
        }
        #if os(iOS)
        // The whole page, bars and all, follows the finger and slides off the way it was
        // swiped, with the gallery showing behind it.
        .background(Color(uiColor: .systemBackground))
        .shadow(color: .black.opacity(pull > 0 ? 0.25 : 0), radius: 12)
        .offset(x: paging == .vertical ? pull : 0, y: paging == .horizontal ? pull : 0)
        .simultaneousGesture(closeSwipe)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .presentationBackground(.clear)
        #endif
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 640)
        #endif
    }

    private func back() {
        #if os(iOS)
        slideAway()
        #else
        dismiss()
        #endif
    }

    #if os(iOS)
    private var closeLength: CGFloat {
        max(paging == .vertical ? size.width : size.height, 1)
    }

    /// Slides the page off across the paging direction, then takes it away.
    private func slideAway() {
        withAnimation(.easeOut(duration: 0.22)) {
            pull = max(closeLength, 1000)
        } completion: {
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) { dismiss() }
        }
    }
    #endif

    /// Across the paging direction a swipe closes the photo: to the right when photos page up
    /// and down, down when they page sideways. Short or slow pulls spring back.
    #if os(iOS)
    private var closeSwipe: some Gesture {
        DragGesture(minimumDistance: 20, coordinateSpace: .global)
            .onChanged { value in
                if pulling == nil {
                    pulling = (closeDistance(value.translation) ?? 0) > 0
                }
                guard pulling == true else { return }
                let t = value.translation
                pull = max(paging == .vertical ? t.width : t.height, 0)
            }
            .onEnded { value in
                defer { pulling = nil }
                guard pulling == true else { return }
                let t = value.translation, p = value.predictedEndTranslation
                let along = paging == .vertical ? t.width : t.height
                let flung = paging == .vertical ? p.width : p.height
                if along > closeLength * 0.25 || flung > closeLength * 0.5 {
                    slideAway()
                } else {
                    withAnimation(.spring(duration: 0.25)) { pull = 0 }
                }
            }
    }
    #endif

    /// How far a drag went in the closing direction, or nil when it mostly went along the paging
    /// direction (that one turns the page).
    private func closeDistance(_ t: CGSize) -> CGFloat? {
        switch paging {
        case .vertical: abs(t.width) > abs(t.height) * 1.2 ? t.width : nil
        case .horizontal: abs(t.height) > abs(t.width) * 1.2 ? t.height : nil
        }
    }

    private func flashDots() {
        showDots = true
        hideDots?.cancel()
        hideDots = Task {
            try? await Task.sleep(for: .seconds(1.6))
            if !Task.isCancelled { showDots = false }
        }
    }

    private func pages(_ geo: GeometryProxy) -> some View {
        ForEach(ids, id: \.self) { id in
            page(id, id == (current ?? start))
                .padding(.top, geo.safeAreaInsets.top)
                .padding(.bottom, geo.safeAreaInsets.bottom)
                .containerRelativeFrame([.horizontal, .vertical])
                .id(id)
        }
    }

    private static var backPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .cancellationAction
        #endif
    }
}

/// Where this photo is among the gallery's: a dot each, the current one long, in a column at the
/// right edge for up-and-down paging or a row at the bottom for sideways paging.
private struct MomentPageDots: View {
    let count: Int
    let index: Int
    let axis: MomentGalleryPaging

    var body: some View {
        let layout = axis == .vertical ? AnyLayout(VStackLayout(spacing: 5)) : AnyLayout(HStackLayout(spacing: 5))
        layout {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == index ? Color.primary : Color.primary.opacity(0.25))
                    .frame(width: axis == .vertical ? 5 : (i == index ? 14 : 5),
                           height: axis == .vertical ? (i == index ? 14 : 5) : 5)
            }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: Capsule())
        .animation(.spring(duration: 0.3), value: index)
        .accessibilityHidden(true)
    }
}

/// "위로 밀면 다음 사진": a small note with a bobbing arrow, the first few times.
private struct MomentSwipeHint: View {
    let paging: MomentGalleryPaging
    @State private var bob = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: paging == .vertical ? "chevron.up" : "chevron.left")
                .font(.footnote.bold())
                .offset(x: paging == .horizontal ? (bob ? -4 : 2) : 0,
                        y: paging == .vertical ? (bob ? -4 : 2) : 0)
            Text(paging == .vertical ? "위로 밀면 다음 사진" : "옆으로 밀면 다음 사진")
                .font(.footnote.weight(.medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { bob = true }
        }
    }
}

extension View {
    /// Opens a gallery photo: from 갤러리 (`alone`) as a sheet with just that photo, the way
    /// 순간들 opens one; from 그리드 full screen in the pager.
    func momentPhotoOpen<Item: Identifiable, Single: View, Paged: View>(
        item: Binding<Item?>, alone: Bool,
        @ViewBuilder single: @escaping (Item) -> Single,
        @ViewBuilder paged: @escaping (Item) -> Paged) -> some View {
        let none = Binding<Item?>(get: { nil }, set: { _ in })
        return sheet(item: alone ? item : none, content: single)
            .momentGalleryCover(item: alone ? none : item, content: paged)
    }

    /// Opens a gallery photo: full screen on iPhone and iPad, a sheet on the Mac.
    @ViewBuilder
    func momentGalleryCover<Item: Identifiable, Content: View>(item: Binding<Item?>,
                                                               @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        #if os(iOS)
        fullScreenCover(item: item, content: content)
        #else
        sheet(item: item, content: content)
        #endif
    }
}

/// The photos a gallery photo swipes through, in the order the gallery reads: grid order for
/// 그리드. A photo opened from 갤러리 (the framed wall) stands alone, one post like on 순간들, so
/// there is nothing to swipe to.
enum MomentGalleryOrder {
    static func ids(_ photos: [MomentPhoto], items: [UUID: WallItem],
                    style: MomentProfile.WallStyle, direction: MomentProfile.WallDirection) -> [UUID] {
        switch style {
        case .grid: MomentProfileGrid.ordered(photos, items: items).map(\.id)
        case .free: []
        }
    }
}

/// Which way a gallery photo swipes to the next one, picked in 설정.
enum MomentGalleryPaging: String, CaseIterable, Identifiable {
    case vertical, horizontal
    static let key = "momentGalleryPaging"

    var id: String { rawValue }
    var axis: Axis.Set { self == .vertical ? .vertical : .horizontal }
    var title: String { self == .vertical ? "위아래" : "좌우" }
}

/// 설정 › 갤러리: how a photo opened from a gallery moves to the next one. In both apps' settings.
struct MomentGalleryPagingSection: View {
    @AppStorage(MomentGalleryPaging.key) private var paging = MomentGalleryPaging.vertical

    var body: some View {
        Section {
            Picker("사진 넘기기", selection: $paging) {
                ForEach(MomentGalleryPaging.allCases) { Text($0.title).tag($0) }
            }
        } header: {
            Text("갤러리")
        } footer: {
            Text("내 갤러리나 다른 사람 갤러리에서 사진을 열었을 때, 이전·다음 사진으로 넘기는 방향이에요.")
        }
    }
}
