import SwiftUI

/// A photo opened from a gallery (mine or someone's), full screen: a back button at the top left,
/// "내 사진 3/8" in the middle, and the gallery's other photos one swipe away, a page each: up and
/// down or left and right, as picked in 설정 (MomentGalleryPaging).
/// Each page draws itself (`page(id, isCurrent)`); only the page on screen puts its buttons in
/// the toolbar.
struct MomentGalleryPager<Page: View>: View {
    let title: String
    let ids: [UUID]
    @ViewBuilder let page: (UUID, Bool) -> Page
    @Environment(\.dismiss) private var dismiss
    @AppStorage(MomentGalleryPaging.key) private var paging = MomentGalleryPaging.vertical
    @State private var current: UUID?
    private let start: UUID

    init(title: String, ids: [UUID], start: UUID, @ViewBuilder page: @escaping (UUID, Bool) -> Page) {
        self.title = title
        self.ids = ids.contains(start) ? ids : [start] + ids
        self.page = page
        self.start = start
    }

    private var counter: String {
        guard let index = ids.firstIndex(of: current ?? start) else { return title }
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
                    }
                }
            }
            .navigationTitle(counter)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: Self.backPlacement) {
                    Button { dismiss() } label: { Image(systemName: "chevron.backward") }
                        .accessibilityLabel("뒤로")
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
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 640)
        #endif
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

extension View {
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

/// The order a gallery's photos are hung in, so swiping goes the way the gallery reads:
/// grid order for 그리드, top to bottom (left to right on a sideways wall) for 액자.
enum MomentGalleryOrder {
    static func ids(_ photos: [MomentPhoto], items: [UUID: WallItem],
                    style: MomentProfile.WallStyle, direction: MomentProfile.WallDirection) -> [UUID] {
        switch style {
        case .grid:
            return MomentProfileGrid.ordered(photos, items: items).map(\.id)
        case .free:
            return WallGeometry(unit: 400, direction: direction).resolved(photos, items: items)
                .sorted { a, b in abs(a.y - b.y) > 0.02 ? a.y < b.y : a.x < b.x }
                .map(\.photoID)
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
