import SwiftUI
import ImageIO

/// 라이브러리: the camera card, then the card's photos by day, 촬영 통계, or 다운로드 기록.
/// (이미지 컨트롤 lives in the 카메라 tab.)
/// Tap to view; 선택 to pick several and save them to the Photos app.
struct LibraryTab: View {
    @EnvironmentObject var library: LibraryModel
    @EnvironmentObject var connection: ConnectionModel
    /// Switches to the 카메라 tab.
    var openCamera: () -> Void = {}
    @State private var selecting = false
    @State private var viewing: Photo?
    @State private var showFilter = false
    @State private var page: Page = .photos
    /// The page the pager rests on; `page` follows it once a swipe settles.
    @State private var shownPage: Page? = .photos
    /// The picker's height (with its banners), for the pages to start below it.
    @State private var barHeight: CGFloat = 52
    /// Where the pager is. Held in @State without observing it, so only the page bar redraws
    /// while the pages move, not the whole library (that made swiping stutter).
    @State private var swipe = PageSwipe()
    @AppStorage("iosThumbSize") private var thumbSize = 100.0
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// iPad's wider grid gets proportionally larger tiles for the same 작게/보통/크게.
    private var tileSize: CGFloat { sizeClass == .regular ? thumbSize * 1.6 : thumbSize }

    enum Page: String, CaseIterable { case photos = "사진", stats = "촬영 통계", history = "다운로드 기록" }

    private var online: Bool { connection.isConnected }
    /// Selected photos waiting on "save again?" because some were saved before.
    @State private var confirmResave: [Photo]?
    /// 다운로드 기록's 선택, in the same place as 사진's.
    @State private var historySelecting = false
    @State private var historySelected = Set<String>()
    @ObservedObject private var saveHistory = SaveHistory.shared
    private var resaveTitle: String {
        let n = confirmResave?.filter { library.isSaved($0) }.count ?? 0
        return "\(n)장은 이미 저장했던 사진이에요. 다시 저장할까요?"
    }
    /// Offline, photos with a copy in the Files app can still go back into Photos.
    private var canSaveSelection: Bool {
        online || library.visible.filter { library.selection.contains($0.id) }.allSatisfy { library.localURL($0) != nil }
    }

    /// The 사진 · 촬영 통계 · 다운로드 기록 picker, with the photo banners under it.
    private var pageBar: some View {
        VStack(spacing: 0) {
            PageBar(pages: Page.allCases.map(\.rawValue),
                    selected: Page.allCases.firstIndex(of: page) ?? 0,
                    swipe: swipe) { i in
                withAnimation(.snappy(duration: 0.32)) { shownPage = Page.allCases[i] }
            }
            .padding(.horizontal).padding(.bottom, 8)
            if page == .photos {
                if !online && !library.photos.isEmpty { offlineBanner }
                if library.refine.isActive { filterBanner }
                if let filter = library.shotFilter { shotFilterBanner(filter) }
            }
        }
        .background(.bar)
    }

    var body: some View {
        NavigationStack {
            // The picker stays put; the pages slide under it side by side, following the
            // finger as in 순간들. Swiping is off while selecting, where a sideways drag
            // selects photos.
            ZStack(alignment: .top) {
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(Page.allCases, id: \.self) { item in
                            pageView(item)
                                // Each page starts below the picker but scrolls on under
                                // it, showing through its bar background as before.
                                .safeAreaPadding(.top, barHeight)
                                .refreshable { if online { await Task { await library.reload() }.value } }
                                // Short pages (empty states) sit under the picker.
                                .frame(maxHeight: .infinity, alignment: .top)
                                .containerRelativeFrame(.horizontal)
                                .onGeometryChange(for: CGRect.self) {
                                    $0.frame(in: .scrollView(axis: .horizontal))
                                } action: { [swipe] frame in
                                    // The first page's position says where the pager is.
                                    guard item == .photos, frame.width > 0 else { return }
                                    swipe.position = min(max(-frame.minX / frame.width, 0), CGFloat(Page.allCases.count - 1))
                                }
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollIndicators(.hidden)
                .scrollPosition(id: $shownPage)
                .scrollDisabled(selecting || historySelecting)
                pageBar
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
            }
            .onChange(of: shownPage) { _, shown in if let shown, shown != page { page = shown } }
            .onChange(of: page) { _, page in
                if shownPage != page { withAnimation(.snappy(duration: 0.32)) { shownPage = page } }
            }
            .sensoryFeedback(.selection, trigger: page)
            .navigationTitle("라이브러리")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if page == .photos { toolbar }
                if page == .history { historyToolbar }
            }
            .onChange(of: page) { historySelecting = false }
            // 카메라 → 이미지 컨트롤 picked one: show those photos.
            .onChange(of: library.refine.tone) { _, tone in if tone != nil { page = .photos } }
            .sheet(isPresented: $showFilter) { FilterSheet() }
            .fullScreenCover(item: $viewing) { photo in
                PhotoPager(start: photo, photos: library.visible)
            }
            .alert(library.error?.hasPrefix("사진 목록") == true ? "사진을 불러오지 못했어요" : "저장하지 못했어요", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(library.error ?? "")
            }
        }
    }

    /// One page of the pager. The refresh runs outside the refresh task: iOS cancels that
    /// one when the list redraws mid-refresh, which cancelled the request to the camera.
    @ViewBuilder private func pageView(_ item: Page) -> some View {
        switch item {
        case .photos:
            photosPage.safeAreaInset(edge: .bottom) { bottomBar }
        case .stats:
            if library.photos.isEmpty {
                emptyState
            } else {
                StatsView(stats: library.stats, section: Binding(get: { .stats }, set: { if $0 == .library { page = .photos } }))
            }
        case .history:
            DownloadHistoryView(selecting: $historySelecting, selected: $historySelected) { page = .photos }
        }
    }

    @ViewBuilder private var photosPage: some View {
        if library.photos.isEmpty {
            ScrollView {
                CameraStatusCard(ble: connection.ble, openCamera: openCamera)
                if online && library.isLoading {
                    ProgressView("사진 목록을 읽고 있어요…").padding(.top, 80)
                } else {
                    emptyState
                }
            }
        } else if library.visible.isEmpty {
            ScrollView {
                CameraStatusCard(ble: connection.ble, openCamera: openCamera)
                ContentUnavailableView("조건에 맞는 사진이 없어요", systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text("필터를 바꾸거나 해제해 보세요."))
                    .padding(.top, 40)
            }
        } else {
            grid
        }
    }

    private var emptyState: some View {
        VStack(spacing: 28) {
            ConnectIllustration()
            Text(online ? "카메라에 사진이 없어요." : "카메라를 연결하면 사진이 여기에 보여요.\n한 번 연결하면 카메라 없이도 목록을 볼 수 있어요.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32).padding(.top, 60)
        .frame(maxWidth: .infinity)
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                CameraStatusCard(ble: connection.ble, openCamera: openCamera)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: tileSize), spacing: 2)], spacing: 2,
                          pinnedViews: [.sectionHeaders]) {
                    ForEach(library.sections) { section in
                        Section {
                            ForEach(section.photos) { photo in
                                Thumb(photo: photo, selecting: selecting)
                                    .id(photo.id)
                                    .onTapGesture {
                                        if selecting { library.toggle(photo) } else { viewing = photo }
                                    }
                                    // Where each tile is on screen, for drag selecting.
                                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                                        layout.tiles[photo.id] = frame
                                    }
                                    .onDisappear { layout.tiles[photo.id] = nil }
                            }
                        } header: {
                            if !section.title.isEmpty { header(section) }
                        }
                    }
                }
                .background(DragSelectRecognizer(enabled: selecting,
                                                 began: { start, band in
                                                     layout.band = band
                                                     return beginDragSelect(at: start, proxy: proxy)
                                                 },
                                                 moved: { moveDragSelect(to: $0) },
                                                 ended: endDragSelect))
            }
        }
    }

    // MARK: Drag selecting (as in the Photos app)

    /// Where tiles are on screen; a plain object, so recording them while scrolling doesn't
    /// redraw the library.
    @State private var layout = GridLayout()

    final class GridLayout {
        /// Tile frames on screen (window coordinates, as the drag recognizer reports).
        var tiles: [String: CGRect] = [:]
        /// The part of the scroll view not under the bars.
        var band: ClosedRange<CGFloat> = 0...0
    }
    @State private var dragSelect: DragSelect?
    @State private var autoScroll: Task<Void, Never>?

    private struct DragSelect {
        /// Photos in grid order, and where the drag started in it.
        let order: [Photo]
        let anchor: Int
        /// Starting on an unselected photo selects; on a selected one, deselects.
        let adding: Bool
        /// The selection before the drag; the dragged range is added to / taken from it.
        let base: Set<String>
        var location: CGPoint
    }

    /// A sideways drag on a photo starts selecting (DragSelectRecognizer); moving up and
    /// down then widens the range over whole rows, and holding near the top or bottom edge
    /// scrolls. Returns false when the drag didn't start on a photo.
    private func beginDragSelect(at start: CGPoint, proxy: ScrollViewProxy) -> Bool {
        let order = library.sections.flatMap(\.photos)
        guard let id = tileID(at: start), let anchor = order.firstIndex(where: { $0.id == id }) else {
            DebugLog.write("drag select: no tile at \(start), \(layout.tiles.count) tiles known")
            return false
        }
        dragSelect = DragSelect(order: order, anchor: anchor, adding: !library.selection.contains(id),
                                base: library.selection, location: start)
        UISelectionFeedbackGenerator().selectionChanged()
        applyDragSelect()
        startAutoScroll(proxy)
        return true
    }

    private func moveDragSelect(to point: CGPoint) {
        dragSelect?.location = point
        applyDragSelect()
    }

    private func endDragSelect() {
        dragSelect = nil
        autoScroll?.cancel()
        autoScroll = nil
    }

    private func tileID(at point: CGPoint) -> String? {
        layout.tiles.first { $0.value.insetBy(dx: -1, dy: -1).contains(point) }?.key
    }

    /// The tile under the finger, or (between tiles, over a header) the nearest one.
    private func tileIndex(at point: CGPoint, in order: [Photo]) -> Int? {
        let id = tileID(at: point) ?? layout.tiles.min { a, b in
            hypot(a.value.midX - point.x, a.value.midY - point.y) < hypot(b.value.midX - point.x, b.value.midY - point.y)
        }?.key
        return id.flatMap { id in order.firstIndex { $0.id == id } }
    }

    private func applyDragSelect() {
        guard let drag = dragSelect, let current = tileIndex(at: drag.location, in: drag.order) else { return }
        let range = drag.order[min(drag.anchor, current)...max(drag.anchor, current)].map(\.id)
        let selection = drag.adding ? drag.base.union(range) : drag.base.subtracting(range)
        if selection != library.selection { library.selection = selection }
    }

    /// While the finger is within 60pt of the top or bottom of the visible grid, scroll a row
    /// at a time and keep widening the selection.
    private func startAutoScroll(_ proxy: ScrollViewProxy) {
        autoScroll?.cancel()
        autoScroll = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(90))
                guard let drag = dragSelect else { return }
                let y = drag.location.y
                let up = y < layout.band.lowerBound + 60, down = y > layout.band.upperBound - 60
                guard up || down else { continue }
                let visible = layout.tiles.filter { $0.value.maxY > layout.band.lowerBound && $0.value.minY < layout.band.upperBound }
                let indices = visible.keys.compactMap { id in drag.order.firstIndex { $0.id == id } }
                guard let first = indices.min(), let last = indices.max() else { continue }
                let columns = max(1, visible.values.filter { abs($0.minY - (visible.values.map(\.minY).min() ?? 0)) < 1 }.count)
                let target = up ? max(0, first - columns) : min(drag.order.count - 1, last + columns)
                guard target != (up ? first : last) else { continue }
                withAnimation(.linear(duration: 0.09)) {
                    proxy.scrollTo(drag.order[target].id, anchor: up ? .top : .bottom)
                }
                try? await Task.sleep(for: .milliseconds(30))
                applyDragSelect()
            }
        }
    }

    /// Day title and count; the circle selects the whole day (and starts selecting).
    private func header(_ section: LibraryModel.DaySection) -> some View {
        let ids = Set(section.photos.map(\.id))
        let all = ids.isSubset(of: library.selection)
        let some = !all && !ids.isDisjoint(with: library.selection)
        return HStack {
            Text(section.title).font(.subheadline.bold())
            Text("\(section.photos.count)장").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button {
                selecting = true
                library.toggleSection(section.photos)
            } label: {
                Image(systemName: all ? "checkmark.circle.fill" : some ? "minus.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(all || some ? Color.accentColor : .secondary)
            }
            .accessibilityLabel(all ? "이 날짜 선택 해제" : "이 날짜 모두 선택")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.bar)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { showFilter = true } label: {
                Label("필터", systemImage: library.refine.isActive
                      ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .disabled(library.photos.isEmpty)
        }
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker("정렬", selection: $library.sort) {
                    ForEach(LibraryModel.Sort.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("날짜별로 묶기", isOn: $library.groupByDate)
                Picker("크기", selection: $thumbSize) {
                    Text("작게").tag(76.0)
                    Text("보통").tag(100.0)
                    Text("크게").tag(150.0)
                }
            } label: {
                Label("보기", systemImage: "arrow.up.arrow.down.circle")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(selecting ? "완료" : "선택") {
                selecting.toggle()
                if !selecting { library.clearSelection() }
            }
            .disabled(library.photos.isEmpty)
        }
    }

    @ToolbarContentBuilder private var historyToolbar: some ToolbarContent {
        if historySelecting {
            // 완료 where 선택 was, so the button doesn't move.
            ToolbarItem(placement: .topBarLeading) {
                Text("\(historySelected.count)개 선택")
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 6)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("완료") { withAnimation(.snappy(duration: 0.2)) { historySelecting = false } }
                    .fontWeight(.semibold)
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Button("선택") { withAnimation(.snappy(duration: 0.2)) { historySelecting = true } }
                    .disabled(saveHistory.records.isEmpty && library.goneFromPhotos.isEmpty)
            }
        }
    }

    /// A 촬영 통계 row or day narrowed the photos; say which and offer a way out.
    private func shotFilterBanner(_ filter: ShotFilter) -> some View {
        HStack {
            Label("\(filter.label) · \(library.visible.count)장", systemImage: "chart.bar.xaxis").lineLimit(1)
            Spacer()
            Button("해제") { library.shotFilter = nil }.tint(.red)
        }
        .font(.footnote)
        .padding(.horizontal).padding(.vertical, 6)
    }

    @ViewBuilder private var bottomBar: some View {
        if !library.transfers.isEmpty {
            TransferBar()
        } else if !library.resumable.isEmpty, connection.isConnected, !selecting {
            HStack {
                Label("저장하지 못한 \(library.resumable.count)장이 있어요", systemImage: "arrow.clockwise.circle")
                    .font(.callout)
                Spacer()
                Button("이어서 저장") { library.resumeSave() }
            }
            .padding(.horizontal).padding(.vertical, 8)
            .background(.bar)
        } else if selecting {
            HStack(spacing: 12) {
                Button {
                    library.clearSelection()
                    selecting = false
                } label: {
                    Image(systemName: "xmark").font(.headline).frame(width: 32, height: 32)
                }
                .accessibilityLabel("선택 끝내기")
                Menu {
                    Button("전체 선택") { library.selectAll() }
                    Button("미저장만 선택") { library.selectUnsaved() }
                    Button("선택 해제") { library.clearSelection() }
                } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(library.selection.count)장 선택").font(.subheadline.bold())
                        if let size = selectedSize { Text(size).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .foregroundStyle(.primary)
                Spacer()
                Button {
                    let picked = library.visible.filter { library.selection.contains($0.id) }
                    if picked.contains(where: { library.isSaved($0) }) {
                        confirmResave = picked
                    } else {
                        library.save(picked)
                        selecting = false
                    }
                } label: {
                    Label("사진 앱에 저장", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .disabled(library.selection.isEmpty || !canSaveSelection)
                .confirmationDialog(resaveTitle, isPresented: Binding(
                    get: { confirmResave != nil }, set: { if !$0 { confirmResave = nil } }
                ), titleVisibility: .visible) {
                    Button("이미 저장한 사진도 다시 저장") {
                        if let p = confirmResave { library.save(p, force: true) }
                        confirmResave = nil; selecting = false
                    }
                    Button("저장 안 한 사진만 저장") {
                        if let p = confirmResave?.filter({ !library.isSaved($0) }), !p.isEmpty { library.save(p) }
                        confirmResave = nil; selecting = false
                    }
                    Button("취소", role: .cancel) { confirmResave = nil }
                }
            }
            .padding(.horizontal).padding(.vertical, 8)
            .background(.bar)
        }
    }

    /// Total size of the selected files, from the camera's per-photo info.
    private var selectedSize: String? {
        let sizes = library.selection.compactMap { library.infos[$0]?.extras["size"].flatMap(Int64.init) }
        guard !sizes.isEmpty else { return nil }
        return ByteCountFormatter.string(fromByteCount: sizes.reduce(0, +), countStyle: .file)
    }

    /// What the filter keeps, how many, and a way out.
    private var filterBanner: some View {
        let r = library.refine
        var parts: [String] = []
        if let kind = r.kind { parts.append(kind == .video ? "동영상" : kind.rawValue) }
        if r.saved != .all { parts.append(r.saved.rawValue) }
        let day = { (d: Date) in d.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)) }
        if r.from != nil || r.to != nil { parts.append("\(r.from.map(day) ?? "")~\(r.to.map(day) ?? "")") }
        if let tone = r.tone { parts.append(MakerNote.imageToneNames[tone] ?? "이미지 컨트롤 \(tone)") }
        return HStack {
            Button { showFilter = true } label: {
                Label(parts.joined(separator: " · ") + " · \(library.visible.count)장", systemImage: "line.3.horizontal.decrease.circle.fill")
                    .lineLimit(1)
            }
            Spacer()
            Button("해제") { library.refine = LibraryModel.Refine() }.tint(.red)
        }
        .font(.footnote)
        .padding(.horizontal).padding(.vertical, 6)
    }

    private var offlineBanner: some View {
        let when = library.listSavedAt.map { $0.formatted(date: .abbreviated, time: .shortened) }
        return Label("카메라 연결 안 됨" + (when.map { " · \($0)에 본 목록이에요" } ?? ""), systemImage: "camera.badge.ellipsis")
            .font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }
}

/// A square tile; the camera's own small thumbnail, kept on disk.
struct Thumb: View {
    @EnvironmentObject var library: LibraryModel
    let photo: Photo
    var selecting = false
    /// The grid shows this photo's part in a save; the transfer list has its own marks.
    var showsTransfer = true
    @State private var image: PlatformImage?

    var body: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(platformImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 3) {
                    if photo.kind == .raw { badge("RAW") }
                    if photo.kind == .video { Image(systemName: "video.fill").font(.caption2) }
                    if library.isSaved(photo) {
                        Image(systemName: "checkmark.circle.fill").font(.caption2)
                    } else if library.isGone(photo) {
                        // Saved once, deleted in the Photos app since.
                        Image(systemName: "checkmark.circle.badge.xmark").font(.caption2).opacity(0.85)
                            .accessibilityLabel("사진 앱에서 지워짐")
                    }
                }
                .foregroundStyle(.white).shadow(radius: 2)
                .padding(4)
            }
            .overlay(alignment: .topTrailing) {
                if !selecting, showsTransfer, let transfer = library.transfer(photo) {
                    TransferBadge(status: transfer.status).padding(4)
                }
            }
            .overlay(alignment: .topTrailing) {
                if selecting {
                    Image(systemName: library.selection.contains(photo.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(library.selection.contains(photo.id) ? Color.accentColor : .white)
                        .shadow(radius: 2)
                        .padding(4)
                }
            }
            .contentShape(Rectangle())
            .task(id: "\(photo.id)#\(library.orientation(photo))") {
                image = await ImageCache.shared.image(for: library.thumbURL(photo),
                                                      orientation: library.orientation(photo))
            }
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 3).padding(.vertical, 1)
            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 3))
    }
}

/// Swipe through the photos like the Photos app: the photo fills the screen behind
/// see-through bars, a tap hides everything but the photo, and dragging down returns to
/// the library. The camera's larger preview, or the saved file.
struct PhotoPager: View {
    @EnvironmentObject var library: LibraryModel
    @EnvironmentObject var connection: ConnectionModel
    @Environment(\.dismiss) private var dismiss
    let start: Photo
    let photos: [Photo]
    @State private var current: Photo.ID?
    @State private var chrome = true
    /// The current photo is zoomed in: its pans are for moving around, not closing.
    @State private var zoomed = false
    /// How far the photo has been dragged down; past the threshold it closes.
    @State private var drag: CGSize = .zero
    /// The (i) sheet: EXIF and shooting settings of the photo shown.
    @State private var showInfo = false
    /// The phone could already turn freely when the viewer opened (left as it was on close).
    @State private var wasFree = false

    private var currentPhoto: Photo? { photos.first { $0.id == current } }
    /// 0 at rest, 1 when dragged far enough to close.
    private var pull: CGFloat { min(max(drag.height, 0) / 300, 1) }

    var body: some View {
        ZStack {
            Color.black.opacity(1 - pull).ignoresSafeArea()
            TabView(selection: $current) {
                ForEach(photos) { photo in
                    PhotoPage(photo: photo, zoomed: $zoomed) {
                        withAnimation(.easeInOut(duration: 0.2)) { chrome.toggle() }
                    }
                    .tag(Optional(photo.id))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .scaleEffect(1 - pull * 0.3)
            .offset(x: drag.width * pull, y: max(drag.height, 0))
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        // Only a mostly downward drag; sideways is for the next photo.
                        guard !zoomed, value.translation.height > abs(value.translation.width) || drag != .zero else { return }
                        drag = value.translation
                    }
                    .onEnded { value in
                        if drag.height > 120 || value.predictedEndTranslation.height > 400 {
                            dismiss()
                        } else {
                            withAnimation(.spring(duration: 0.3)) { drag = .zero }
                        }
                    }
            )
            if chrome && drag == .zero {
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    bottomBar
                }
                .transition(.opacity)
            }
        }
        .presentationBackground(.clear)
        .statusBarHidden(!chrome)
        .persistentSystemOverlays(chrome ? .automatic : .hidden)
        .onAppear {
            current = start.id
            // Turn the phone to see a landscape photo full width, as in the Photos app.
            wasFree = Orientation.free
            Orientation.setFree(true)
        }
        .onDisappear { if !wasFree { Orientation.setFree(false) } }
        .sheet(isPresented: $showInfo) {
            if let photo = currentPhoto { PhotoInfoSheet(photo: photo) }
        }
    }

    /// What the photo shown is, when it isn't the camera's live copy.
    private var caption: String? {
        guard let photo = currentPhoto else { return nil }
        if library.localURL(photo) != nil, photo.kind != .video { return "\(Device.name)에 저장된 원본" }
        if !connection.isConnected { return "카메라 연결 안 됨 · 지난 연결 때 받아 둔 작은 미리보기" }
        return nil
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down").font(.headline).frame(width: 36, height: 36)
            }
            Spacer()
            VStack(spacing: 1) {
                Text(currentPhoto?.name ?? "").font(.headline)
                if let caption { Text(caption).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Button { showInfo = true } label: {
                Image(systemName: "info.circle").font(.headline).frame(width: 36, height: 36)
            }
            .disabled(currentPhoto == nil)
        }
        .foregroundStyle(.white)
        .padding(.horizontal).padding(.vertical, 8)
        .background(.ultraThinMaterial.opacity(0.8), in: Rectangle())
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var bottomBar: some View {
        if let photo = currentPhoto {
            HStack {
                let toPhotos = PhotosLibrary.target.toPhotos
                if library.isSaved(photo) {
                    Label(toPhotos ? "사진 앱에 저장됨" : "파일 앱에 저장됨", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    let gone = library.isGone(photo)
                    Button { library.save([photo]) } label: {
                        Label(gone ? "사진 앱에서 지워짐 · 다시 저장" : toPhotos ? "사진 앱에 저장" : "파일 앱에 저장",
                              systemImage: "square.and.arrow.down")
                    }
                    .disabled((!connection.isConnected && library.localURL(photo) == nil) || library.isTransferring)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial.opacity(0.8), in: Rectangle())
            .environment(\.colorScheme, .dark)
        }
    }
}

struct PhotoPage: View {
    @EnvironmentObject var library: LibraryModel
    let photo: Photo
    @Binding var zoomed: Bool
    let onTap: () -> Void
    @State private var image: PlatformImage?
    /// The camera's original has replaced the preview (asked for on the first zoom in).
    @State private var original = false
    @State private var loadingOriginal = false

    var body: some View {
        ZStack {
            if let image {
                // Fit to the whole screen, under the bars: full height in landscape.
                ZoomablePhoto(image: image, zoomed: $zoomed, onTap: onTap, onZoomIn: loadOriginal)
                    .ignoresSafeArea()
                if loadingOriginal {
                    ProgressView().tint(.white).padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(.top, 60).padding(.trailing, 16)
                }
            } else {
                ProgressView().tint(.white)
            }
            if photo.kind == .video {
                Label("동영상은 저장한 뒤 사진 앱에서 재생해 주세요", systemImage: "video")
                    .font(.footnote).padding(8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .bottom).padding()
            }
        }
        .task(id: photo.id) {
            let orientation = library.orientation(photo)
            image = await ImageCache.shared.image(for: library.thumbURL(photo), orientation: orientation)
            if let local = library.localURL(photo), photo.kind != .video,
               let data = try? Data(contentsOf: local), let full = PlatformImage(data: data) {
                image = full
                original = true
            } else if photo.kind != .video {
                // 720 px comes quickly; the 1920 px one is what the screen needs.
                if let preview = await ImageCache.shared.image(for: CameraAPI.photoURL(photo, size: .view), orientation: orientation) {
                    image = preview
                }
                if let sharp = await ImageCache.shared.image(for: CameraAPI.photoURL(photo, size: .xs), orientation: orientation),
                   !Task.isCancelled, !original {
                    image = sharp
                }
            }
        }
    }

    /// Zooming into a JPEG still on the camera: pull its original (~10 MB) for this page only,
    /// decoded at up to 4096 px and kept just while the page is shown.
    private func loadOriginal() {
        guard !original, !loadingOriginal, photo.kind == .jpeg, library.localURL(photo) == nil, CameraAPI.online else { return }
        loadingOriginal = true
        Task {
            defer { loadingOriginal = false }
            guard let (data, response) = try? await CameraAPI.session.data(from: CameraAPI.photoURL(photo)),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let decoded = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 4096,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ] as CFDictionary)
            }.value
            if let decoded {
                image = PlatformImage(cgImageValue: decoded)
                original = true
            }
        }
    }
}

/// Pinch and double-tap zoom with UIScrollView, as in the Photos app. A single tap (one
/// that isn't the start of a double tap) goes to `onTap`.
struct ZoomablePhoto: UIViewRepresentable {
    let image: UIImage
    @Binding var zoomed: Bool
    let onTap: () -> Void
    /// Called when a zoom in starts, to swap in a sharper image.
    var onZoomIn: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PhotoScrollView {
        let scroll = PhotoScrollView()
        scroll.delegate = context.coordinator
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.decelerationRate = .fast
        scroll.show(image)
        let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTap))
        single.require(toFail: double)
        scroll.addGestureRecognizer(double)
        scroll.addGestureRecognizer(single)
        return scroll
    }

    func updateUIView(_ scroll: PhotoScrollView, context: Context) {
        context.coordinator.parent = self
        if scroll.imageView.image !== image { scroll.show(image) }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomablePhoto
        init(_ parent: ZoomablePhoto) { self.parent = parent }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? PhotoScrollView)?.imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? PhotoScrollView)?.centerImage()
            let zoomed = scrollView.zoomScale > scrollView.minimumZoomScale * 1.01
            if zoomed != parent.zoomed {
                DispatchQueue.main.async { self.parent.zoomed = zoomed }
                if zoomed, let onZoomIn = parent.onZoomIn { DispatchQueue.main.async { onZoomIn() } }
            }
        }

        @objc func doubleTap(_ tap: UITapGestureRecognizer) {
            guard let scroll = tap.view as? UIScrollView else { return }
            if scroll.zoomScale > scroll.minimumZoomScale * 1.01 {
                scroll.setZoomScale(scroll.minimumZoomScale, animated: true)
            } else {
                let point = tap.location(in: (scroll as? PhotoScrollView)?.imageView)
                let scale = scroll.minimumZoomScale * 2.5
                let size = CGSize(width: scroll.bounds.width / scale, height: scroll.bounds.height / scale)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                       width: size.width, height: size.height), animated: true)
            }
        }

        @objc func singleTap() { parent.onTap() }
    }
}

/// The scroll view holding one photo, as in the Photos app: the image view is the photo's own
/// size, the smallest zoom fits it to the screen, and it stays centred whenever it is smaller
/// than the screen (so zooming out or turning the phone never leaves it off to one side).
final class PhotoScrollView: UIScrollView {
    let imageView = UIImageView()
    private var fittedBounds: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows `image`. A sharper copy of the same photo keeps the zoom and the spot looked at;
    /// a different shape starts over, fitted.
    func show(_ image: UIImage) {
        let old = imageView.image
        let same = old.map { abs($0.size.width / max($0.size.height, 1) - image.size.width / max(image.size.height, 1)) < 0.02 } ?? false
        imageView.image = image
        guard image.size.width > 0, image.size.height > 0 else { return }
        if same, let old, zoomScale > minimumZoomScale * 1.01 {
            // Same picture, more pixels: shrink the zoom by the same factor so nothing moves.
            let factor = old.size.width / image.size.width
            let offset = contentOffset
            let zoom = zoomScale * factor
            zoomScale = 1
            imageView.frame = CGRect(origin: .zero, size: image.size)
            contentSize = image.size
            updateZoomLimits()
            zoomScale = min(max(zoom, minimumZoomScale), maximumZoomScale)
            contentOffset = offset
            centerImage()
        } else {
            zoomScale = 1
            imageView.frame = CGRect(origin: .zero, size: image.size)
            contentSize = image.size
            fittedBounds = .zero
            setNeedsLayout()
        }
    }

    private func updateZoomLimits() {
        guard let size = imageView.image?.size, size.width > 0, size.height > 0,
              bounds.width > 0, bounds.height > 0 else { return }
        let fit = min(bounds.width / size.width, bounds.height / size.height)
        minimumZoomScale = fit
        // Up to 5× the fitted size, and at least the photo's own pixels.
        maximumZoomScale = max(fit * 5, 1 / UIScreen.main.scale)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard imageView.image != nil, bounds.width > 0 else { return }
        if bounds.size != fittedBounds {
            // First layout or the phone turned: fit again unless zoomed in, then keep the zoom in range.
            let wasFitted = fittedBounds == .zero || zoomScale <= minimumZoomScale * 1.01
            fittedBounds = bounds.size
            updateZoomLimits()
            if wasFitted || zoomScale < minimumZoomScale {
                zoomScale = minimumZoomScale
                centerImage()
                contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
            }
        }
        centerImage()
    }

    /// Keeps the photo in the middle along any side where it is smaller than the screen.
    func centerImage() {
        let w = contentSize.width, h = contentSize.height
        let x = max((bounds.width - w) / 2, 0)
        let y = max((bounds.height - h) / 2, 0)
        let inset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
        if contentInset != inset { contentInset = inset }
    }
}

/// A pan recognizer on the grid's UIScrollView that takes sideways drags for selecting,
/// as the Photos app does; up and down drags still scroll. SwiftUI's own drag gesture lost
/// to the scroll view's pan (the grid scrolled, or pulled to refresh, instead).
/// Points are in window coordinates, like SwiftUI's .global frames.
struct DragSelectRecognizer: UIViewRepresentable {
    var enabled: Bool
    /// Where the drag started, and the part of the scroll view not under the bars.
    var began: (CGPoint, ClosedRange<CGFloat>) -> Bool
    var moved: (CGPoint) -> Void
    var ended: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> Finder {
        let view = Finder()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ view: Finder, context: Context) {
        context.coordinator.parent = self
        // Turning 선택 on is when it must be ready; check the scroll view is still the one.
        DispatchQueue.main.async { context.coordinator.attach(from: view) }
    }

    /// Finds the enclosing scroll view. SwiftUI can put this view in the window before it
    /// sits inside the scroll view (seen on iPhone: the first drag after opening the
    /// library selected nothing), so it looks again whenever it moves or is laid out.
    final class Finder: UIView {
        weak var coordinator: Coordinator?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.attach(from: self)
        }
        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            coordinator?.attach(from: self)
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            coordinator?.attach(from: self)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: DragSelectRecognizer
        private weak var scrollView: UIScrollView?
        private let pan = UIPanGestureRecognizer()
        private var active = false

        init(_ parent: DragSelectRecognizer) {
            self.parent = parent
            super.init()
            pan.addTarget(self, action: #selector(handle(_:)))
            pan.delegate = self
            pan.maximumNumberOfTouches = 1
        }

        func attach(from view: UIView) {
            var next = view.superview
            while let v = next, !(v is UIScrollView) { next = v.superview }
            guard let found = next as? UIScrollView, found !== scrollView else { return }
            DebugLog.write("drag select: attached to scroll view (\(scrollView == nil ? "first" : "changed"))")
            scrollView?.removeGestureRecognizer(pan)
            scrollView = found
            found.addGestureRecognizer(pan)
            // The scroll waits for this one to fail, which it does at once unless selecting
            // and the drag starts sideways.
            found.panGestureRecognizer.require(toFail: pan)
        }

        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard parent.enabled else { return false }
            guard let scrollView else {
                DebugLog.write("drag select: no scroll view yet")
                return false
            }
            let v = pan.velocity(in: scrollView)
            return abs(v.x) > abs(v.y)
        }

        @objc private func handle(_ gesture: UIPanGestureRecognizer) {
            guard let scrollView else { return }
            let here = gesture.location(in: nil)
            switch gesture.state {
            case .began:
                let moved = gesture.translation(in: scrollView)
                let insets = scrollView.adjustedContentInset
                let frame = scrollView.convert(scrollView.bounds, to: nil)
                let top = frame.minY + insets.top, bottom = max(top, frame.maxY - insets.bottom)
                active = parent.began(CGPoint(x: here.x - moved.x, y: here.y - moved.y), top...bottom)
                if !active {
                    // Not on a photo: give the touch back so the grid can still scroll.
                    DebugLog.write("drag select: start not on a photo")
                    gesture.isEnabled = false
                    gesture.isEnabled = true
                }
                if active { parent.moved(here) }
            case .changed:
                if active { parent.moved(here) }
            default:
                if active { parent.ended() }
                active = false
            }
        }
    }
}

/// Where the library's pager is: 0 = 사진, 1 = 촬영 통계, 2 = 다운로드 기록, in between
/// while sliding.
final class PageSwipe: ObservableObject {
    @Published var position: CGFloat = 0
}

/// The 사진 · 촬영 통계 · 다운로드 기록 switch. Looks like a segmented control, but its
/// highlight slides with the finger while swiping between pages.
struct PageBar: View {
    let pages: [String]
    let selected: Int
    /// Where the pager is; the highlight follows it.
    @ObservedObject var swipe: PageSwipe
    var select: (Int) -> Void

    var body: some View {
        GeometryReader { proxy in
            let count = CGFloat(max(pages.count, 1))
            let inset: CGFloat = 3
            let segment = (proxy.size.width - inset * 2) / count
            // The highlight moves with the pages: one page across, one segment along.
            let raw = swipe.position
            let position = min(max(raw, -0.12), count - 1 + 0.12)
            let nearest = Int(min(max(raw.rounded(), 0), count - 1))
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.tertiarySystemFill))
                Capsule()
                    .fill(Color(.systemBackground))
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                    .frame(width: segment, height: proxy.size.height - inset * 2)
                    .offset(x: inset + position * segment)
                HStack(spacing: 0) {
                    ForEach(pages.indices, id: \.self) { i in
                        Button { select(i) } label: {
                            Text(pages[i])
                                .font(.subheadline.weight(i == nearest ? .semibold : .regular))
                                .foregroundStyle(i == nearest ? Color.primary : Color.secondary)
                                .lineLimit(1).minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(i == selected ? .isSelected : [])
                    }
                }
                .padding(.horizontal, inset)
            }
        }
        .frame(height: 36)
        .accessibilityElement(children: .contain)
    }
}
